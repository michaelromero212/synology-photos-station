"""Proves an analyzer build works before it ships.

    python -m analyzer.selftest

Checks:
- the models match their pinned hashes;
- photos decode (a HEIC with an iOS 18 HDR gain map, a rotated JPEG, a PNG
  with transparency), and so do videos;
- the same file gives the same bytes twice;
- paths outside the allowed roots are refused.

With SELFTEST_REQUIRE_NO_NETWORK=1 (CI runs it under `--network none`) it also
checks that nothing outside the container can be reached. Every picture and
clip it uses is made here, from gradients. Exits non-zero on any failure.
"""
import base64
import json
import os
import shutil
import socket
import sys
import tempfile
import time

import av
import numpy as np
from PIL import Image

from . import core

FIXTURE = os.path.abspath(os.environ.get("ANALYZER_FIXTURE", "/opt/analyzer/fixtures/hdr-gain-map.heic"))
failures = []


def check(name, condition, detail=""):
    print(("  ok    " if condition else "  FAIL  ") + name + (("  (" + detail + ")") if detail and not condition else ""))
    if not condition:
        failures.append(name)


def floats(b64, count):
    data = base64.b64decode(b64)
    values = np.frombuffer(data, dtype="<f4")
    return values if values.size == count else None


def check_frames(name, result, expect_frames=None):
    frames = result["frames"]
    if expect_frames is not None:
        check(name + ": frame count", len(frames) == expect_frames, "%d frames" % len(frames))
    for index, frame in enumerate(frames):
        scene = floats(frame["scene"], 768)
        check("%s: frame %d scene is 768 finite numbers" % (name, index),
              scene is not None and bool(np.all(np.isfinite(scene))) and float(np.linalg.norm(scene)) > 0)
        for face in frame["faces"]:
            embedding = floats(face["embedding"], 128)
            check("%s: face embedding is 128 finite numbers" % name,
                  embedding is not None and bool(np.all(np.isfinite(embedding))))


def gradient(width, height):
    yy, xx = np.mgrid[0:height, 0:width]
    return np.stack([
        (xx * 255 // max(1, width - 1)),
        (yy * 255 // max(1, height - 1)),
        ((xx + yy) * 127 // max(1, width + height - 2)),
    ], axis=-1).astype(np.uint8)


def make_video(path, seconds=12, fps=10):
    for codec in ("mpeg4", "mjpeg"):
        try:
            with av.open(path, "w") as out:
                stream = out.add_stream(codec, rate=fps)
                stream.width, stream.height, stream.pix_fmt = 320, 240, "yuv420p" if codec == "mpeg4" else "yuvj420p"
                stream.gop_size = fps  # a keyframe every second, like an iPhone
                for i in range(seconds * fps):
                    picture = np.roll(gradient(320, 240), i * 3, axis=1)
                    for packet in stream.encode(av.VideoFrame.from_ndarray(picture, format="rgb24")):
                        out.mux(packet)
                for packet in stream.encode():
                    out.mux(packet)
            return codec
        except (av.error.FFmpegError, ValueError):
            continue
    raise SystemExit("no video encoder in this PyAV build to make a test clip with")


def network_reachable():
    try:
        with socket.create_connection(("1.1.1.1", 443), timeout=2):
            return True
    except OSError:
        return False


def main():
    work = tempfile.mkdtemp(prefix="analyzer-selftest-")
    try:
        roots = [work, os.path.dirname(FIXTURE)]
        started = time.perf_counter()
        analyzer = core.Analyzer(
            os.environ.get("ANALYZER_MODELS", "/opt/analyzer/models"),
            os.environ.get("ANALYZER_MANIFEST", "/opt/analyzer/models.json"),
            roots,
        )
        print("models verified and loaded in %.1f s" % (time.perf_counter() - started))
        print(json.dumps(analyzer.health()))

        if os.environ.get("SELFTEST_REQUIRE_NO_NETWORK") == "1":
            names = sorted(name for _, name in socket.if_nameindex())
            check("no network interface but loopback", names == ["lo"], ", ".join(names))
            check("the internet is unreachable", not network_reachable())

        if os.path.exists(FIXTURE):
            heic = analyzer.analyze(FIXTURE, "photo")
            check_frames("HEIC with an HDR gain map", heic, 1)
            again = analyzer.analyze(FIXTURE, "photo")
            heic.pop("timings")
            again.pop("timings")
            check("the same HEIC gives the same bytes twice",
                  json.dumps(heic, sort_keys=True) == json.dumps(again, sort_keys=True))
        else:
            check("HEIC fixture present", os.environ.get("SELFTEST_REQUIRE_FIXTURE") != "1", FIXTURE)

        # A sideways JPEG: EXIF orientation 6 means "turn clockwise to view".
        jpeg = os.path.join(work, "rotated.jpg")
        exif = Image.Exif()
        exif[0x0112] = 6
        Image.fromarray(gradient(2400, 1600)).save(jpeg, quality=90, exif=exif.tobytes())
        rotated = analyzer.analyze(jpeg, "photo")
        check_frames("rotated JPEG", rotated, 1)
        frame = rotated["frames"][0]
        check("EXIF orientation is applied", (frame["width"], frame["height"]) == (853, 1280),
              "%dx%d" % (frame["width"], frame["height"]))

        png = os.path.join(work, "transparent.png")
        rgba = np.dstack([gradient(640, 480), np.full((480, 640), 128, dtype=np.uint8)])
        Image.fromarray(rgba, "RGBA").save(png)
        check_frames("PNG with transparency", analyzer.analyze(png, "photo"), 1)

        clip = os.path.join(work, "clip.mp4")
        codec = make_video(clip)
        started = time.perf_counter()
        video = analyzer.analyze(clip, "video")
        check_frames("12 s %s clip" % codec, video, 3)
        times = [f["ms"] for f in video["frames"]]
        check("frames are in time order", times == sorted(times), str(times))
        again = analyzer.analyze(clip, "video")
        video.pop("timings")
        again.pop("timings")
        check("the same clip gives the same bytes twice",
              json.dumps(video, sort_keys=True) == json.dumps(again, sort_keys=True))
        print("video analyzed twice in %.2f s" % (time.perf_counter() - started))

        def rejected(path, kind="photo"):
            try:
                analyzer.analyze(path, kind)
            except core.Rejected as r:
                return r.code
            return None

        outside = tempfile.mkdtemp(prefix="analyzer-outside-")
        try:
            secret = os.path.join(outside, "secret.jpg")
            shutil.copy(jpeg, secret)
            link = os.path.join(work, "link.jpg")
            os.symlink(secret, link)
            check("a file outside the roots is refused", rejected(secret) == "outside-roots")
            check("a symlink out of the roots is refused", rejected(link) == "outside-roots")
        finally:
            shutil.rmtree(outside, ignore_errors=True)
        check("a relative path is refused", rejected("rotated.jpg") == "bad-request")
        check("a directory is refused", rejected(work) == "not-a-file")
        check("a missing file is reported", rejected(os.path.join(work, "nope.jpg")) == "not-found")
        junk = os.path.join(work, "junk.jpg")
        with open(junk, "wb") as f:
            f.write(b"not an image at all" * 100)
        check("a file that isn't an image is unsupported", rejected(junk) == "unsupported")
        check("a file that isn't a video is unsupported", rejected(junk, "video") == "unsupported")
        check("an unknown kind is refused", rejected(jpeg, "audio") == "bad-request")
    finally:
        shutil.rmtree(work, ignore_errors=True)

    if failures:
        print("selftest FAILED: %d check(s)" % len(failures))
        sys.exit(1)
    print("selftest ok")


if __name__ == "__main__":
    main()
