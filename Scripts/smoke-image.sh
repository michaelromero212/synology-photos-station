#!/bin/bash
# Starts a built server image the way the NAS runs it — against Postgres, with
# its data directory bind-mounted — and checks it before anyone can pull it:
#
#   1. the tools the media pipeline shells out to are in the image;
#   2. it migrates an empty database and answers /health, naming the commit it
#      was built from;
#   3. the M1a upload flow passes against it (Scripts/smoke-m1a.sh): chunked
#      and resumable upload, dedup, hash verification, access control.
#
#   Scripts/smoke-image.sh <image> [expected-revision]
#
# CI runs this between building the image and publishing it. Needs Docker,
# curl and python3 on the host, and port 8099 free; psql runs inside the
# database container.
set -euo pipefail

IMAGE="${1:?usage: smoke-image.sh <image> [expected-revision]}"
REVISION="${2:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
MIGRATIONS="$HERE/../Server/Sources/FrameStationServer/Migrations/SQL"
NAME="framestation-smoke-$$"
SCRATCH="$(mktemp -d)"
mkdir -p "$SCRATCH/blobroot"
PASSWORD=smoke

cleanup() {
  local status=$?
  if [ "$status" -ne 0 ]; then
    # The head, not the tail: a crash report starts with what went wrong and
    # which thread, then runs to hundreds of lines of other threads' stacks.
    echo
    echo "=== server: $(docker inspect -f 'exit code {{.State.ExitCode}}, OOM-killed {{.State.OOMKilled}}' "$NAME-server" 2>/dev/null) ==="
    docker logs "$NAME-server" 2>&1 | head -n 150 || true
  fi
  docker rm -f "$NAME-server" "$NAME-db" >/dev/null 2>&1 || true
  docker network rm "$NAME" >/dev/null 2>&1 || true
  # What the server wrote belongs to root; remove it from inside a container
  # rather than asking for sudo.
  docker run --rm --user 0:0 -v "$SCRATCH:/scratch" --entrypoint rm "$IMAGE" -rf /scratch/blobroot \
    >/dev/null 2>&1 || true
  rm -rf "$SCRATCH"
  exit "$status"
}
trap cleanup EXIT

fail() { echo "  ✗ $1"; exit 1; }
pass() { echo "  ✓ $1"; }

echo "=== media tools in the image ==="
docker run --rm --entrypoint sh "$IMAGE" -c '
  set -e
  echo "  vips     $(vips --version)"
  echo "  exiftool $(exiftool -ver)"
  echo "  ffmpeg   $(ffmpeg -hide_banner -version | head -n 1)"
  echo "  ffprobe  $(ffprobe -hide_banner -version | head -n 1)"
  vips -l | grep -q heif
' || fail "vips, exiftool, ffmpeg and ffprobe with HEIF support"
pass "vips (with HEIF), exiftool, ffmpeg and ffprobe present"

echo
echo "=== start Postgres and the server ==="
docker network create "$NAME" >/dev/null
# The same Postgres image docker-compose.yml runs on the NAS.
docker run -d --name "$NAME-db" --network "$NAME" \
  -e POSTGRES_USER=framestation -e POSTGRES_PASSWORD="$PASSWORD" -e POSTGRES_DB=framestation \
  postgres:16-alpine >/dev/null
# Over TCP on purpose: during first-run initialisation the image's temporary
# server listens on the Unix socket only, so a TCP answer means the real one.
DBPSQL="docker exec -e PGPASSWORD=$PASSWORD $NAME-db psql -h 127.0.0.1 -U framestation -d framestation"
for _ in $(seq 1 60); do
  $DBPSQL -qAtc 'select 1' >/dev/null 2>&1 && break
  sleep 1
done
$DBPSQL -qAtc 'select 1' >/dev/null || fail "Postgres accepting connections"

# As root, the way docker-compose.yml runs it on the NAS. Not as whoever runs
# this script: /app is the image user's home, 0750, so to any other uid the
# server's own resource bundle beside the binary is invisible and it dies at
# launch — a failure no deployment can have, and so not one worth testing for.
docker run -d --name "$NAME-server" --network "$NAME" --user 0:0 \
  -e FRAMESTATION_DATABASE_URL="postgres://framestation:$PASSWORD@$NAME-db:5432/framestation?sslmode=disable" \
  -e FRAMESTATION_BLOB_ROOT=/data \
  -v "$SCRATCH/blobroot:/data" \
  -p 127.0.0.1:8099:8080 "$IMAGE" >/dev/null

HEALTH=""
for _ in $(seq 1 90); do
  HEALTH=$(curl -fsS http://127.0.0.1:8099/health 2>/dev/null) && break
  [ "$(docker inspect -f '{{.State.Running}}' "$NAME-server")" = "true" ] \
    || fail "server still running (it exited during startup)"
  sleep 1
done
[ -n "$HEALTH" ] || fail "/health answering within 90 seconds"
echo "  $HEALTH"

field() { python3 -c "import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2]))" "$HEALTH" "$1"; }
[ "$(field status)" = "ok" ] && pass "status ok" || fail "status ok, got $(field status)"
[ "$(field database)" = "up" ] && pass "database up" || fail "database up, got $(field database)"
expected=$(find "$MIGRATIONS" -name '*.sql' | wc -l | tr -d ' ')
[ "$(field migrationsApplied)" = "$expected" ] \
  && pass "all $expected migrations applied to an empty database" \
  || fail "$expected migrations applied, got $(field migrationsApplied)"
if [ -n "$REVISION" ]; then
  [ "$(field revision)" = "$REVISION" ] \
    && pass "built from $REVISION" \
    || fail "revision $REVISION, got $(field revision)"
fi

echo
FRAMESTATION_TEST_DIR="$SCRATCH" \
FRAMESTATION_API="http://127.0.0.1:8099" \
FRAMESTATION_CLI="docker exec $NAME-server ./FrameStationServer" \
FRAMESTATION_PSQL="$DBPSQL -tAqc" \
  "$HERE/smoke-m1a.sh"
