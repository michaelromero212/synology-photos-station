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
# curl and python3 on the host, and port 8085 free; psql runs inside the
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
# Not 8099, the dev stack's port: on a Mac running the dev stack, the container
# couldn't start.
PORT=8085

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
  -p 127.0.0.1:$PORT:8080 "$IMAGE" >/dev/null

HEALTH=""
for _ in $(seq 1 90); do
  HEALTH=$(curl -fsS "http://127.0.0.1:$PORT/health" 2>/dev/null) && break
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
FRAMESTATION_API="http://127.0.0.1:$PORT" \
FRAMESTATION_CLI="docker exec $NAME-server ./FrameStationServer" \
FRAMESTATION_PSQL="$DBPSQL -tAqc" \
  "$HERE/smoke-m1a.sh"

echo
echo "=== a stream ladder, cut by this image's ffmpeg ==="
# The Mac that writes the ladder command runs a much newer ffmpeg than the
# Ubuntu one in this image, which is the one the NAS runs. Built here, by the
# real thing, before the NAS can pull it.
API="http://127.0.0.1:$PORT"
docker exec "$NAME-server" ffmpeg -v error -y \
  -f lavfi -i "testsrc2=size=1280x720:rate=30:duration=3" -f lavfi -i "sine=frequency=440:duration=3" \
  -c:v libx264 -preset ultrafast -b:v 6M -pix_fmt yuv420p -c:a aac -shortest /data/ladder-test.mp4 \
  || fail "a test clip made"
CLIP="$SCRATCH/blobroot/ladder-test.mp4"
CODE=$(docker exec "$NAME-server" ./FrameStationServer invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
read -r TOKEN SPACE <<< "$(curl -fsS -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$CODE\",\"displayName\":\"Ladder\",\"deviceName\":\"ladder-phone\",\"platform\":\"ios\"}" \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["token"], d["personalSpace"]["id"])')"
AUTH="Authorization: Bearer $TOKEN"
SHA=$(sha256sum "$CLIP" | awk '{print $1}'); SIZE=$(stat -c%s "$CLIP")
UPLOAD=$(curl -fsS -X POST "$API/v1/uploads/probe" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"spaceID\":\"$SPACE\",\"sha256\":\"$SHA\",\"byteSize\":$SIZE,\"filename\":\"ladder-test.mp4\"}" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["uploadID"])')
curl -fsS -X PUT "$API/v1/uploads/$UPLOAD/chunk/0" -H "$AUTH" --data-binary "@$CLIP" >/dev/null
VIDEO=$(curl -fsS -X POST "$API/v1/uploads/$UPLOAD/commit" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"spaceID\":\"$SPACE\",\"mediaType\":\"video\",\"mime\":\"video/mp4\",\"width\":1280,\"height\":720,\"isRaw\":false,\"burstPick\":false}" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["assetID"])')
STATE=""
for _ in $(seq 1 120); do
  STATE=$($DBPSQL -tAqc "SELECT state FROM derivation_jobs WHERE asset_id = '$VIDEO' AND kind = 'ladder'")
  [ "$STATE" = "done" ] || [ "$STATE" = "failed" ] && break
  sleep 1
done
[ "$STATE" = "done" ] || {
  docker logs "$NAME-server" 2>&1 | grep -iE "ladder|ffmpeg" | tail -20
  fail "the ladder job done, got '$STATE': $($DBPSQL -tAqc "SELECT last_error FROM derivation_jobs WHERE asset_id = '$VIDEO' AND kind = 'ladder'")"
}
LADDER="$SCRATCH/blobroot/derivatives/${SHA:0:2}/${SHA:2:2}/$SHA/stream-v1"
[ "$(grep -c '^#EXT-X-STREAM-INF' "$LADDER/master.m3u8" 2>/dev/null)" = "3" ] \
  && pass "three sizes for a 720p clip" || fail "three sizes in $(ls "$LADDER" 2>&1 | tr '\n' ' ')"
PIECES=$(for p in v720 v432 v270; do grep -c '^#EXTINF' "$LADDER/$p.m3u8" || true; done | sort -u | tr '\n' ' ')
[ "$PIECES" = "3 " ] && pass "each cut into the same three one-second pieces" || fail "three pieces each, got $PIECES"
grep -q '^#EXT-X-MAP:URI="v432.m4s",BYTERANGE=' "$LADDER/v432.m3u8" \
  && pass "each a single file its playlist reads by byte range" \
  || fail "a byte-range map in $(grep EXT-X-MAP "$LADDER/v432.m3u8")"
LINK=$(curl -fsS "$API/v1/assets/$VIDEO/playback?quality=mobile&adaptive=1" -H "$AUTH" \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["kind"], d["url"])')
[ "${LINK%% *}" = "adaptive" ] && pass "and handed out as one" || fail "an adaptive link, got $LINK"
MASTER="${LINK#* }"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$MASTER")" = "200" ] \
  && [ "$(curl -s -o /dev/null -w '%{http_code}' "${MASTER%/master.m3u8}/v432.m3u8")" = "200" ] \
  && pass "that a player can fetch" || fail "the playlists through the link"
