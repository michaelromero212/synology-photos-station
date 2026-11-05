"""The analyzer's one way in: HTTP over a Unix socket, one request at a time.

    GET  /v1/health    the protocol, the analyzer version and the model ids
    POST /v1/analyze   {"path": "/homes/…", "kind": "photo"|"video", "faces": true}

The container has no network (`network_mode: none`), so this socket, in a
volume only the server also mounts, is the only thing that can reach it.
Nothing about a request is logged: not the path, not the answer.
"""
import http.server
import json
import os
import signal
import socketserver
import sys
import time

from . import core

MAX_REQUEST_BYTES = 64 * 1024


def log(message):
    sys.stderr.write("%s analyzer: %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), message))
    sys.stderr.flush()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    server_version = "framestation-analyzer"
    sys_version = ""

    def address_string(self):
        # A Unix socket has no peer address, and the default would raise.
        return "local"

    def log_message(self, format, *args):
        pass

    def _send(self, status, body):
        data = json.dumps(body, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/v1/health":
            self._send(200, self.server.analyzer.health())
        else:
            self._send(404, {"error": "not-found"})

    def do_POST(self):
        if self.path != "/v1/analyze":
            self._send(404, {"error": "not-found"})
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_REQUEST_BYTES:
            self._send(400, {"error": "bad-request"})
            return
        try:
            request = json.loads(self.rfile.read(length))
            if not isinstance(request, dict):
                raise ValueError
        except ValueError:
            self._send(400, {"error": "bad-request"})
            return
        try:
            result = self.server.analyzer.analyze(
                request.get("path"), request.get("kind"), bool(request.get("faces", True))
            )
        except core.Rejected as rejected:
            self._send(422, {"error": rejected.code})
            return
        except MemoryError:
            self._send(422, {"error": "too-large"})
            return
        except Exception as error:  # noqa: BLE001 - the type is all that's logged
            log("analysis failed: %s" % type(error).__name__)
            self._send(500, {"error": "internal"})
            return
        self._send(200, result)


class Server(socketserver.UnixStreamServer):
    def __init__(self, path, analyzer):
        self.analyzer = analyzer
        super().__init__(path, Handler)


def main():
    socket_path = os.environ.get("ANALYZER_SOCKET", "/run/framestation-analyzer/analyzer.sock")
    models = os.environ.get("ANALYZER_MODELS", "/opt/analyzer/models")
    manifest = os.environ.get("ANALYZER_MANIFEST", "/opt/analyzer/models.json")
    roots = [r for r in os.environ.get("ANALYZER_ROOTS", "").split(os.pathsep) if r]

    started = time.perf_counter()
    analyzer = core.Analyzer(models, manifest, roots)
    log("models verified and loaded in %.1f s: %s" % (
        time.perf_counter() - started,
        ", ".join("%s %s" % (role, name) for role, name in sorted(analyzer.models.items())),
    ))

    # A socket left by a previous run would make bind fail.
    os.makedirs(os.path.dirname(socket_path), exist_ok=True)
    try:
        os.unlink(socket_path)
    except FileNotFoundError:
        pass
    previous = os.umask(0o117)  # the socket: owner and group only
    try:
        server = Server(socket_path, analyzer)
    finally:
        os.umask(previous)

    # As PID 1 in a container, a signal with no handler is ignored, and
    # `docker stop` would wait out its timeout before killing us.
    def stop(signum, frame):
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    log("ready: version %d, protocol %d, %d threads, %d roots" % (
        core.ANALYZER_VERSION, core.PROTOCOL, core.THREADS, len(analyzer.roots)
    ))
    try:
        server.serve_forever(poll_interval=1.0)
    finally:
        server.server_close()
        try:
            os.unlink(socket_path)
        except OSError:
            pass


if __name__ == "__main__":
    main()
