#!/bin/bash
#
# The analyzer on the Mac, for development and the smoke tests.
#
#   Analyzer/dev.sh setup                       venv + models, in ~/.framestation-dev/analyzer
#   Analyzer/dev.sh selftest                    the same self-test the image build runs
#   Analyzer/dev.sh run <socket> <root>[:<root>…]   serve on a Unix socket, in the foreground
#
# Same lock file and same pinned models as the image. The NAS runs the image;
# nothing here is ever reachable from the network (it only listens on a socket
# file). Needs Python 3.12.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HOME_DIR="${FRAMESTATION_ANALYZER_HOME:-$HOME/.framestation-dev/analyzer}"
VENV="$HOME_DIR/venv"
MODELS="$HOME_DIR/models"

python312() {
  for candidate in python3.12 /Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12 /opt/homebrew/bin/python3.12; do
    if command -v "$candidate" >/dev/null 2>&1; then echo "$candidate"; return; fi
  done
  echo "Python 3.12 not found" >&2; exit 1
}

setup() {
  mkdir -p "$HOME_DIR"
  local stamp="$VENV/.lock-sha256" want
  want=$(shasum -a 256 "$HERE/requirements.lock" | awk '{print $1}')
  if [ ! -x "$VENV/bin/python" ] || [ "$(cat "$stamp" 2>/dev/null)" != "$want" ]; then
    rm -rf "$VENV"
    "$(python312)" -m venv "$VENV"
    "$VENV/bin/python" -m pip install -q --disable-pip-version-check --no-deps --require-hashes \
      --only-binary=:all: -r "$HERE/requirements.lock"
    echo "$want" > "$stamp"
  fi
  # python.org's macOS Python ships without a certificate store of its own;
  # point it at the system's for the model download.
  if [ -z "${SSL_CERT_FILE:-}" ] && [ -f /etc/ssl/cert.pem ]; then export SSL_CERT_FILE=/etc/ssl/cert.pem; fi
  "$VENV/bin/python" "$HERE/fetch_models.py" "$HERE/models.json" "$MODELS" >/dev/null
}

env_for() {
  export PYTHONPATH="$HERE" ANALYZER_MODELS="$MODELS" ANALYZER_MANIFEST="$HERE/models.json"
  export ANALYZER_THREADS="${ANALYZER_THREADS:-2}" PYTHONDONTWRITEBYTECODE=1
  # ONNX Runtime's telemetry, off; see analyzer/__init__.py.
  export ORT_DISABLE_TELEMETRY=1
}

case "${1:-}" in
  setup)
    setup
    echo "analyzer ready in $HOME_DIR"
    ;;
  selftest)
    setup; env_for
    ANALYZER_FIXTURE="$REPO/Scripts/fixtures/hdr-gain-map.heic" SELFTEST_REQUIRE_FIXTURE=1 \
      exec "$VENV/bin/python" -m analyzer.selftest
    ;;
  run)
    [ $# -ge 3 ] || { echo "usage: $0 run <socket> <root>[:<root>…]" >&2; exit 2; }
    setup; env_for
    ANALYZER_SOCKET="$2" ANALYZER_ROOTS="$3" exec "$VENV/bin/python" -m analyzer.server
    ;;
  *)
    sed -n '3,8p' "$0"; exit 2
    ;;
esac
