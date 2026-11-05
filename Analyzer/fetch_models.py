"""Downloads the analyzer's pinned models and checks each against its SHA-256.

    python3 fetch_models.py models.json <directory>

Used by the image build and by the dev setup, so both hold exactly the same
files. A file already present with the right hash is kept; anything else is
downloaded again, and a download that doesn't match is deleted and fails the
run. Standard library only.
"""
import hashlib
import json
import os
import shutil
import sys
import urllib.request


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def main():
    manifest_path, directory = sys.argv[1], sys.argv[2]
    with open(manifest_path) as f:
        models = json.load(f)["models"]
    os.makedirs(directory, exist_ok=True)
    for model in models:
        destination = os.path.join(directory, model["file"])
        if os.path.exists(destination) and sha256(destination) == model["sha256"]:
            print("have", model["file"])
            continue
        url = "https://huggingface.co/%s/resolve/%s/%s" % (
            model["repo"], model["revision"], model["path"]
        )
        partial = destination + ".part"
        request = urllib.request.Request(url, headers={"User-Agent": "framestation-analyzer-build"})
        with urllib.request.urlopen(request, timeout=120) as response, open(partial, "wb") as out:
            shutil.copyfileobj(response, out, 1 << 20)
        digest = sha256(partial)
        if digest != model["sha256"]:
            os.remove(partial)
            sys.exit(
                "%s: SHA-256 %s does not match the pinned %s" % (model["file"], digest, model["sha256"])
            )
        os.replace(partial, destination)
        print("fetched", model["file"], "(%d bytes)" % os.path.getsize(destination))


if __name__ == "__main__":
    main()
