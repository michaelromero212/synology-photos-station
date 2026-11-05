#!/bin/bash
# The analyzer image, run the way docker-compose.yml runs it on the NAS: no
# network, root with every capability dropped but reading, a read-only root
# filesystem, a tmpfs, and its socket in a volume. Checks that it serves,
# analyzes, refuses what's outside its roots, and stops promptly.
#
#   Scripts/smoke-analyzer-image.sh framestation-analyzer:ci
#
# CI runs it after building the image (and after the self-test, which also
# checks the container can reach nothing). Needs only Docker.
set -euo pipefail
IMAGE="${1:?usage: $0 <image>}"
NAME="framestation-analyzer-smoke-$$"
VOLUME="$NAME-run"
PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; echo "      expected: $2"; echo "      actual:   $3"; FAIL=$((FAIL+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
cleanup(){ docker rm -f "$NAME" >/dev/null 2>&1 || true; docker volume rm "$VOLUME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker volume create "$VOLUME" >/dev/null
docker run -d --name "$NAME" --network none --user 0:0 \
  --cap-drop ALL --cap-add DAC_READ_SEARCH --cap-add DAC_OVERRIDE \
  --security-opt no-new-privileges:true --read-only --tmpfs /tmp:size=64m,mode=1777 --memory 2g \
  -e ANALYZER_ROOTS=/opt/analyzer/fixtures \
  -v "$VOLUME:/run/framestation-analyzer" "$IMAGE" >/dev/null

# ask <method> <path> [json] → "<status> <body>", over the container's own socket.
ask(){
  docker exec -i "$NAME" python - "$@" <<'PY'
import http.client, socket, sys
class Unix(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect("/run/framestation-analyzer/analyzer.sock")
method, path = sys.argv[1], sys.argv[2]
body = sys.argv[3].encode() if len(sys.argv) > 3 else None
c = Unix("local", timeout=120)
c.request(method, path, body=body, headers={"Content-Type": "application/json"} if body else {})
r = c.getresponse()
print(r.status, r.read().decode())
PY
}

for _ in $(seq 1 90); do
  docker exec "$NAME" test -S /run/framestation-analyzer/analyzer.sock 2>/dev/null && break
  [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" = "true" ] || break
  sleep 1
done
if ! docker exec "$NAME" test -S /run/framestation-analyzer/analyzer.sock 2>/dev/null; then
  echo "the analyzer didn't start:"; docker logs "$NAME" 2>&1 | tail -20; exit 1
fi
check "runs with no network but loopback" "lo" "$(docker exec "$NAME" python -c 'import socket; print(",".join(sorted(n for _, n in socket.if_nameindex())))')"

HEALTH=$(ask GET /v1/health)
check "health answers" "200" "${HEALTH%% *}"
case "$HEALTH" in *'"protocol":1'*) ok "speaks protocol 1";; *) bad "speaks protocol 1" "protocol 1" "$HEALTH";; esac

RESULT=$(ask POST /v1/analyze '{"path":"/opt/analyzer/fixtures/hdr-gain-map.heic","kind":"photo","faces":true}')
check "analyzes a HEIC from its roots" "200" "${RESULT%% *}"
FRAMES=$(echo "${RESULT#* }" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["frames"]))' 2>/dev/null || echo "?")
check "one frame for a photo" "1" "$FRAMES"

OUTSIDE=$(ask POST /v1/analyze '{"path":"/etc/passwd","kind":"photo"}')
check "refuses a path outside its roots" '422 {"error":"outside-roots"}' "$OUTSIDE"
check "can't write to its own filesystem" "refused" \
  "$(docker exec "$NAME" sh -c 'touch /opt/analyzer/x 2>/dev/null && echo written || echo refused')"

START=$(date +%s); docker stop -t 20 "$NAME" >/dev/null; STOP=$(( $(date +%s) - START ))
[ "$STOP" -le 5 ] && ok "stops promptly (${STOP} s)" || bad "stops promptly" "≤ 5 s" "${STOP} s"

echo "smoke-analyzer-image: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
