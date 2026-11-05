"""What the analyzer sees in a photo or a video: numbers, never words.

Everything here is deterministic. The model files are checked by hash, the
thread count is fixed, frames and faces come back in a fixed order, and nothing
is random, so the same file always gives the same bytes. See NAS-ANALYSIS.md.

Nothing here logs, prints or keeps anything about a file it was asked about.
"""
import base64
import hashlib
import json
import math
import os
import stat
import time

# OpenCV's new DNN engine warns on every model load about a setting this code
# doesn't use; errors still come through.
os.environ.setdefault("OPENCV_LOG_LEVEL", "ERROR")
# No telemetry from ONNX Runtime; see __init__.py. Forced, not defaulted.
os.environ["ORT_DISABLE_TELEMETRY"] = "1"

import av
import cv2
import numpy as np
import onnxruntime as ort
import pillow_heif
from PIL import Image, ImageOps

# Bumped whenever the same file would give a different answer: a new model, a
# new render size, a new sampling rule. The server analyzes again whatever an
# older version produced, newest first.
ANALYZER_VERSION = 1
# The shape of a request and its answer. The server refuses an analyzer whose
# protocol it doesn't know.
PROTOCOL = 1

THREADS = max(1, int(os.environ.get("ANALYZER_THREADS", "2")))
# The long side faces are found and aligned at. At 640 the face model missed
# about one face in seven on the family library.
FACE_SIDE = 1280
# SigLIP 2 B/32 was trained on 256 x 256, the whole picture squashed to fit.
SCENE_SIZE = 256
FACE_SCORE = 0.8
FACE_NMS = 0.3
# Smaller than this is a speck in a crowd: found, but not recognizable.
MIN_FACE_PX = 16
MAX_FACES_PER_FRAME = 64
# Keyframes only: one about every 5 seconds, at most 12, spread over the clip.
VIDEO_EVERY_S = 5.0
VIDEO_MAX_FRAMES = 12
# Panoramas run to a few hundred megapixels; past this a file is refused
# rather than decoded into gigabytes.
MAX_PIXELS = 250_000_000
MAX_FILE_BYTES = 64 * 1024 ** 3
# Only these parsers ever see a file. Anything else is "unsupported", which
# keeps a crafted file away from the long tail of formats nobody's camera
# writes, and keeps FFmpeg from reading a text file as an image sequence.
PHOTO_FORMATS = ("JPEG", "MPO", "HEIF", "PNG", "TIFF", "WEBP", "GIF", "BMP")  # MPO opens as JPEG
VIDEO_FORMATS = {"mov,mp4,m4a,3gp,3g2,mj2", "matroska,webm", "avi", "mpegts"}

ort.disable_telemetry_events()
Image.MAX_IMAGE_PIXELS = MAX_PIXELS
pillow_heif.register_heif_opener()
Image.init()
# The ones this Pillow can open. MPO isn't an opener of its own: the JPEG
# plugin hands back an MPO image when the file is one.
_OPENABLE = tuple(f for f in PHOTO_FORMATS if f in Image.OPEN)
pillow_heif.options.DECODE_THREADS = THREADS
cv2.setNumThreads(THREADS)


class Rejected(Exception):
    """A file the analyzer won't or can't read. `code` is all that's sent back:
    never a path, never anything from inside the file."""

    def __init__(self, code):
        super().__init__(code)
        self.code = code


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def _b64(array):
    return base64.b64encode(np.ascontiguousarray(array, dtype="<f4").tobytes()).decode("ascii")


def _clamp(value):
    return min(1.0, max(0.0, float(value)))


def _round(value):
    return round(float(value), 6)


class Analyzer:
    """The three models, loaded once, and the roots files may be read from."""

    def __init__(self, models_dir, manifest_path, roots):
        self.roots = [os.path.realpath(r) for r in roots if r]
        if not self.roots:
            raise SystemExit("ANALYZER_ROOTS names no directory, so no file could be read")
        with open(manifest_path) as f:
            manifest = json.load(f)["models"]
        paths = {}
        self.models = {}
        for entry in manifest:
            path = os.path.join(models_dir, entry["file"])
            if not os.path.isfile(path):
                raise SystemExit("model %s is missing" % entry["file"])
            digest = sha256_of(path)
            if digest != entry["sha256"]:
                raise SystemExit("model %s does not match its pinned SHA-256" % entry["file"])
            paths[entry["role"]] = path
            self.models[entry["role"]] = "%s@%s" % (entry["name"], digest[:12])

        options = ort.SessionOptions()
        options.intra_op_num_threads = THREADS
        options.inter_op_num_threads = 1
        options.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
        options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
        # Idle threads sleep instead of spinning: between requests this
        # process should cost the NAS nothing.
        options.add_session_config_entry("session.intra_op.allow_spinning", "0")
        options.add_session_config_entry("session.inter_op.allow_spinning", "0")
        self.scene = ort.InferenceSession(paths["scene"], options, providers=["CPUExecutionProvider"])
        self.scene_input = self.scene.get_inputs()[0].name
        outputs = [o.name for o in self.scene.get_outputs()]
        self.scene_output = "pooler_output" if "pooler_output" in outputs else outputs[0]

        self.detector = cv2.FaceDetectorYN.create(
            paths["face-detector"], "", (320, 320), FACE_SCORE, FACE_NMS, 5000
        )
        self.recognizer = cv2.FaceRecognizerSF.create(paths["face-recognizer"], "")

    # ------------------------------------------------------------ requests

    def health(self):
        return {
            "status": "ok",
            "protocol": PROTOCOL,
            "analyzer": ANALYZER_VERSION,
            "models": self.models,
            "threads": THREADS,
        }

    def resolve(self, path):
        """The real path of a regular file under one of the roots, or Rejected."""
        if not isinstance(path, str) or not path or "\x00" in path or not os.path.isabs(path):
            raise Rejected("bad-request")
        real = os.path.realpath(path)
        if not any(real == root or real.startswith(root + os.sep) for root in self.roots):
            raise Rejected("outside-roots")
        try:
            info = os.stat(real)
        except FileNotFoundError:
            raise Rejected("not-found")
        except PermissionError:
            raise Rejected("unreadable")
        if not stat.S_ISREG(info.st_mode):
            raise Rejected("not-a-file")
        if info.st_size > MAX_FILE_BYTES:
            raise Rejected("too-large")
        return real

    def analyze(self, path, kind, faces=True):
        started = time.perf_counter()
        real = self.resolve(path)
        if kind == "photo":
            frames = [(None, _photo(real))]
        elif kind == "video":
            frames = _video_frames(real)
        else:
            raise Rejected("bad-request")
        decoded = time.perf_counter()

        face_s = scene_s = 0.0
        out = []
        for ms, rgb in frames:
            height, width = rgb.shape[:2]
            t0 = time.perf_counter()
            found = self._faces(cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)) if faces else []
            t1 = time.perf_counter()
            scene = self._scene(rgb)
            t2 = time.perf_counter()
            face_s += t1 - t0
            scene_s += t2 - t1
            out.append({
                "ms": ms,
                "width": int(width),
                "height": int(height),
                "scene": _b64(scene),
                "faces": found,
            })
        return {
            "protocol": PROTOCOL,
            "analyzer": ANALYZER_VERSION,
            "models": self.models,
            "frames": out,
            "timings": {
                "decodeMS": round((decoded - started) * 1000),
                "facesMS": round(face_s * 1000),
                "sceneMS": round(scene_s * 1000),
                "totalMS": round((time.perf_counter() - started) * 1000),
            },
        }

    # ------------------------------------------------------------ models

    def _scene(self, rgb):
        square = Image.fromarray(rgb).resize((SCENE_SIZE, SCENE_SIZE), Image.BILINEAR)
        x = np.asarray(square, dtype=np.float32) * np.float32(1.0 / 255.0)
        x = (x - np.float32(0.5)) / np.float32(0.5)
        tensor = np.ascontiguousarray(x.transpose(2, 0, 1)[None])
        embedding = self.scene.run([self.scene_output], {self.scene_input: tensor})[0][0]
        if embedding.shape != (768,) or not np.all(np.isfinite(embedding)):
            raise Rejected("model-output")
        return embedding

    def _faces(self, bgr):
        height, width = bgr.shape[:2]
        self.detector.setInputSize((width, height))
        _, found = self.detector.detect(bgr)
        if found is None:
            return []
        # Strongest first, then top to bottom and left to right, so the same
        # photo always lists its faces in the same order.
        rows = sorted(found.tolist(), key=lambda r: (-round(r[14], 5), round(r[1], 2), round(r[0], 2)))
        faces = []
        for row in rows:
            x, y, w, h = row[0], row[1], row[2], row[3]
            if min(w, h) < MIN_FACE_PX:
                continue
            aligned = self.recognizer.alignCrop(bgr, np.asarray(row, dtype=np.float32))
            feature = self.recognizer.feature(aligned).astype(np.float32).ravel()
            if feature.shape != (128,) or not np.all(np.isfinite(feature)):
                continue
            gray = cv2.cvtColor(aligned, cv2.COLOR_BGR2GRAY)
            sharpness = float(cv2.Laplacian(gray, cv2.CV_64F).var())
            x0, y0 = max(0.0, x), max(0.0, y)
            x1, y1 = min(float(width), x + w), min(float(height), y + h)
            landmarks = []
            for i in range(5):
                landmarks.append(_round(_clamp(row[4 + 2 * i] / width)))
                landmarks.append(_round(_clamp(row[5 + 2 * i] / height)))
            faces.append({
                "box": [
                    _round(x0 / width), _round(y0 / height),
                    _round(max(0.0, x1 - x0) / width), _round(max(0.0, y1 - y0) / height),
                ],
                "landmarks": landmarks,
                "score": _round(row[14]),
                "size": int(round(min(w, h))),
                "sharpness": _round(sharpness),
                "embedding": _b64(feature),
            })
            if len(faces) >= MAX_FACES_PER_FRAME:
                break
        return faces


# ---------------------------------------------------------------- decoding

def _to_rgb(image):
    if image.mode == "RGB":
        return image
    if image.mode in ("RGBA", "LA", "PA") or (image.mode == "P" and "transparency" in image.info):
        # Transparent pixels over white, as a viewer shows them.
        rgba = image.convert("RGBA")
        background = Image.new("RGB", rgba.size, (255, 255, 255))
        background.paste(rgba, mask=rgba.getchannel("A"))
        return background
    return image.convert("RGB")


def _photo(path):
    """The photo upright, its long side at most FACE_SIDE, as RGB bytes."""
    try:
        image = Image.open(path, formats=_OPENABLE)
    except FileNotFoundError:
        raise Rejected("not-found")
    except PermissionError:
        raise Rejected("unreadable")
    except Image.DecompressionBombError:
        raise Rejected("too-large")
    except (OSError, ValueError, SyntaxError):
        raise Rejected("unsupported")
    try:
        with image:
            if image.format in ("JPEG", "MPO"):
                # Decode at a fraction of full size when the JPEG allows it,
                # as vips does for thumbnails.
                image.draft("RGB", (FACE_SIDE, FACE_SIDE))
            upright = ImageOps.exif_transpose(image)
            rgb = _to_rgb(upright)
            rgb.thumbnail((FACE_SIDE, FACE_SIDE), Image.BILINEAR, reducing_gap=2.0)
            array = np.asarray(rgb, dtype=np.uint8)
    except Image.DecompressionBombError:
        raise Rejected("too-large")
    except MemoryError:
        raise Rejected("too-large")
    except (OSError, ValueError, SyntaxError, TypeError):
        raise Rejected("decode")
    if array.ndim != 3 or array.shape[2] != 3 or min(array.shape[:2]) < 8:
        raise Rejected("decode")
    return np.ascontiguousarray(array)


def _rotate_upright(rgb, frame, stream):
    """Applies the video's display rotation, as players do.

    PyAV's `rotation` is FFmpeg's display-matrix angle, counterclockwise; a
    player turns the picture clockwise by its negative. Older files carry a
    `rotate` tag instead, which is already the clockwise turn.
    """
    counterclockwise = getattr(frame, "rotation", None)
    if counterclockwise is not None:
        clockwise = (-int(round(float(counterclockwise)))) % 360
    else:
        try:
            clockwise = int(stream.metadata.get("rotate", "0")) % 360
        except (TypeError, ValueError):
            clockwise = 0
    clockwise = int(round(clockwise / 90.0)) * 90 % 360
    if clockwise == 0:
        return rgb
    # np.rot90 turns counterclockwise.
    return np.ascontiguousarray(np.rot90(rgb, k=((360 - clockwise) % 360) // 90))


def _frame_rgb(frame, stream):
    scale = min(1.0, FACE_SIDE / float(max(frame.width, frame.height)))
    width = max(2, int(round(frame.width * scale)))
    height = max(2, int(round(frame.height * scale)))
    rgb = frame.reformat(width=width, height=height, format="rgb24", interpolation="AREA").to_ndarray()
    return _rotate_upright(rgb, frame, stream)


def _video_frames(path):
    """Keyframes spread across the clip: (milliseconds, RGB) pairs, in order."""
    try:
        container = av.open(path)
    except FileNotFoundError:
        raise Rejected("not-found")
    except PermissionError:
        raise Rejected("unreadable")
    except (av.error.FFmpegError, OSError, ValueError):
        raise Rejected("unsupported")
    try:
        with container:
            if container.format.name not in VIDEO_FORMATS or not container.streams.video:
                raise Rejected("unsupported")
            stream = container.streams.video[0]
            stream.thread_type = "AUTO"
            stream.codec_context.thread_count = THREADS
            # Only keyframes are decoded at all. A 4K60 clip costs about 4 s
            # per second of video to decode in full on the J4125, and a
            # keyframe about 0.18 s.
            stream.codec_context.skip_frame = "NONKEY"

            duration = None
            if stream.duration and stream.time_base:
                duration = float(stream.duration * stream.time_base)
            elif container.duration:
                duration = container.duration / 1_000_000.0
            if duration and duration > 0:
                count = min(VIDEO_MAX_FRAMES, max(1, int(math.ceil(duration / VIDEO_EVERY_S))))
                targets = [duration * (i + 0.5) / count for i in range(count)]
            else:
                targets = [0.0]

            start = stream.start_time or 0
            seen = set()
            frames = []
            for target in targets:
                if stream.time_base:
                    container.seek(start + int(target / stream.time_base), stream=stream,
                                   backward=True, any_frame=False)
                frame = None
                for decoded in container.decode(stream):
                    frame = decoded
                    break
                if frame is None or frame.pts in seen:
                    continue
                seen.add(frame.pts)
                ms = int(round(frame.time * 1000)) if frame.time is not None else None
                frames.append((ms, _frame_rgb(frame, stream)))
            if not frames:
                raise Rejected("decode")
            frames.sort(key=lambda item: (item[0] is None, item[0] or 0))
            return frames
    except Rejected:
        raise
    except MemoryError:
        raise Rejected("too-large")
    except (av.error.FFmpegError, OSError, ValueError, StopIteration):
        raise Rejected("decode")
