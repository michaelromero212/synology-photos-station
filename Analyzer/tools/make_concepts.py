"""Makes the concept vectors the server scores NAS scene embeddings against.

    ORT_DISABLE_TELEMETRY=1 python Analyzer/tools/make_concepts.py <siglip2 dir> <vision.onnx> <out.json>

- <siglip2 dir> holds tokenizer.json, tokenizer_config.json,
  onnx/text_model.onnx and onnx/model.onnx, from
  onnx-community/siglip2-base-patch32-256-ONNX at the commit the analyzer
  pins. That's the same model as the analyzer's vision tower, which is the
  second argument.
- Run on a Mac whenever Analyzer/concepts.json changes, and commit the output.
- Needs onnxruntime, numpy and transformers (the tokenizer only; no torch).

The scores the server computes are SigLIP's own:
    logit = exp(logit_scale) * cos(image, text) + logit_bias.
Both scalars are read from Google's original checkpoint, by byte range, not
from the conversion. Before writing, this checks that its vision, text, scale
and bias give the full model's logits.
"""
import base64
import hashlib
import json
import os
import struct
import sys
import urllib.request

os.environ["ORT_DISABLE_TELEMETRY"] = "1"

import numpy as np  # noqa: E402
import onnxruntime as ort  # noqa: E402
from transformers import AutoTokenizer  # noqa: E402

GOOGLE = "https://huggingface.co/google/siglip2-base-patch32-256/resolve/94dffa8cb1179de3e03f091dbc3917e5d5a9ae84/model.safetensors"
HERE = os.path.dirname(os.path.abspath(__file__))
MAX_LENGTH = 64


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def ranged(url, start, end):
    request = urllib.request.Request(url, headers={"Range": "bytes=%d-%d" % (start, end)})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def checkpoint_scalars():
    """logit_scale and logit_bias from Google's safetensors, read by range."""
    header_len = struct.unpack("<Q", ranged(GOOGLE, 0, 7))[0]
    header = json.loads(ranged(GOOGLE, 8, 8 + header_len - 1))
    values = {}
    for name in ("logit_scale", "logit_bias"):
        meta = header[name]
        assert meta["dtype"] == "F32", meta
        start, end = meta["data_offsets"]
        raw = ranged(GOOGLE, 8 + header_len + start, 8 + header_len + end - 1)
        values[name] = float(np.frombuffer(raw, dtype="<f4").ravel()[0])
    return values["logit_scale"], values["logit_bias"]


def unit(x):
    return x / np.linalg.norm(x, axis=-1, keepdims=True)


def main():
    siglip, vision_path, out = sys.argv[1], sys.argv[2], sys.argv[3]
    spec = json.load(open(os.path.join(HERE, "..", "concepts.json")))
    template = spec["template"]
    concepts = spec["concepts"]
    prompts = [template.format(c["phrase"]) for c in concepts]

    # The tokenizer SigLIP 2 was trained with, configured as transformers'
    # zero-shot pipeline uses it for SigLIP: padded to 64, end token added.
    tokenizer = AutoTokenizer.from_pretrained(siglip)
    ids = np.array(
        tokenizer(prompts, padding="max_length", max_length=MAX_LENGTH, truncation=True)["input_ids"],
        dtype=np.int64,
    )
    assert ids.shape == (len(prompts), MAX_LENGTH)
    assert all(int(row[-1]) == tokenizer.pad_token_id for row in ids), "a prompt filled all 64 tokens"

    options = ort.SessionOptions()
    options.intra_op_num_threads = 4
    text = ort.InferenceSession(os.path.join(siglip, "onnx", "text_model.onnx"), options, providers=["CPUExecutionProvider"])
    names = [o.name for o in text.get_outputs()]
    pooled = names.index("pooler_output") if "pooler_output" in names else 0
    text_in = text.get_inputs()[0].name
    vectors = np.concatenate([
        text.run(None, {text_in: ids[i:i + 32]})[pooled] for i in range(0, len(ids), 32)
    ]).astype(np.float32)
    assert vectors.shape == (len(prompts), 768) and np.all(np.isfinite(vectors))

    scale, bias = checkpoint_scalars()

    # Our pieces against the full model, on images made here.
    vision = ort.InferenceSession(vision_path, options, providers=["CPUExecutionProvider"])
    vnames = [o.name for o in vision.get_outputs()]
    vpooled = vnames.index("pooler_output") if "pooler_output" in vnames else 0
    full = ort.InferenceSession(os.path.join(siglip, "onnx", "model.onnx"), options, providers=["CPUExecutionProvider"])
    full_inputs = {i.name for i in full.get_inputs()}
    fnames = [o.name for o in full.get_outputs()]
    rng = np.random.RandomState(11)
    yy, xx = np.mgrid[0:256, 0:256] / 256.0
    images = np.stack([
        rng.uniform(-1, 1, (3, 256, 256)),
        np.stack([np.sin(xx * 9), np.cos(yy * 7), xx * yy * 2 - 1]),
        rng.uniform(-1, 1, (3, 8, 8)).repeat(32, 1).repeat(32, 2),
    ]).astype(np.float32)
    sample = list(range(0, len(prompts), max(1, len(prompts) // 12)))[:12]
    feeds = {"pixel_values": images, "input_ids": ids[sample]}
    if "attention_mask" in full_inputs:
        feeds["attention_mask"] = (ids[sample] != tokenizer.pad_token_id).astype(np.int64)
    reference = full.run(None, feeds)[fnames.index("logits_per_image")]
    image_vectors = vision.run(None, {vision.get_inputs()[0].name: images})[vpooled]
    ours = np.exp(scale) * unit(image_vectors) @ unit(vectors[sample]).T + bias
    worst = float(np.abs(ours - reference).max())
    print("checked against the full model: worst logit difference %.2e over %d pairs" % (worst, reference.size))
    assert worst < 1e-3, "the pieces don't reproduce the full model"

    doc = {
        "_comment": "Generated by Analyzer/tools/make_concepts.py from Analyzer/concepts.json. Do not edit.",
        "model": "siglip2-base-patch32-256",
        "visionSHA256": sha256(vision_path),
        "textSHA256": sha256(os.path.join(siglip, "onnx", "text_model.onnx")),
        "tokenizerSHA256": sha256(os.path.join(siglip, "tokenizer.json")),
        "template": template,
        "logitScale": float(np.exp(scale)),
        "logitBias": bias,
        "dimensions": 768,
        "concepts": [
            {"id": c["id"], "phrase": c["phrase"],
             "vector": base64.b64encode(unit(v).astype("<f4").tobytes()).decode("ascii")}
            for c, v in zip(concepts, vectors)
        ],
    }
    with open(out, "w") as f:
        json.dump(doc, f, indent=0, separators=(",", ":"))
        f.write("\n")
    print("wrote %d concepts, scale %.4f, bias %.4f, to %s" % (len(concepts), np.exp(scale), bias, out))


if __name__ == "__main__":
    main()
