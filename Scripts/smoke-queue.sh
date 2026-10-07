#!/bin/bash
# The derivation queue keeps photos ahead of video transcodes. Only one
# transcode runs at a time, on two threads (two cores, on Linux). A restart
# puts photos the queue gave up on back in line before any lane starts. And a
# photo opened before its thumbnail was made gets one there and then.
#
#   FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-queue.sh
#
# Runs its own server against its own database and blob store.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"

DB=framestation_queue; PORT=8098; API="http://127.0.0.1:$PORT"
export FRAMESTATION_DATABASE_URL="postgres://framestation:x@127.0.0.1:55432/$DB?sslmode=disable"
ROOT="$SCRATCH/queue"; rm -rf "$ROOT"; mkdir -p "$ROOT/blobroot" "$ROOT/lib"
ROOT=$(cd "$ROOT" && pwd -P)
export FRAMESTATION_BLOB_ROOT="$ROOT/blobroot"
LIB="$ROOT/lib"

PASS=0; FAIL=0
q(){ psql -h 127.0.0.1 -p 55432 -U framestation -d $DB -tAqc "$1"; }
admin(){ psql -h 127.0.0.1 -p 55432 -U framestation -d postgres -tAqc "$1"; }
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; echo "      expected: $2"; echo "      actual:   $3"; FAIL=$((FAIL+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
jq(){ python3 -c "import sys,json; print(json.load(sys.stdin)$1)" 2>/dev/null; }

(cd "$SERVER_DIR" && swift build >/dev/null 2>&1) || { echo "server build failed"; exit 1; }
BIN="$(cd "$SERVER_DIR" && swift build --show-bin-path)/FrameStationServer"
admin "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1; admin "CREATE DATABASE $DB" >/dev/null

SERVER=""
serve(){
  "$BIN" serve --hostname 127.0.0.1 --port $PORT >> "$ROOT/server.log" 2>&1 &
  SERVER=$!
  for _ in $(seq 1 120); do curl -s -o /dev/null "$API/health" && return; sleep 0.5; done
  echo "server didn't start:"; tail -20 "$ROOT/server.log"; exit 1
}
stop(){ kill "$SERVER" 2>/dev/null; wait "$SERVER" 2>/dev/null; }
trap stop EXIT

asset(){ q "SELECT a.$2 FROM assets a JOIN space_assets sa ON sa.asset_id = a.id WHERE sa.filename = '$1'"; }
job(){ q "SELECT $3 FROM derivation_jobs WHERE asset_id = '$1' AND kind = '$2'"; }
derived(){ q "SELECT derived_at IS NOT NULL FROM assets WHERE id = '$1'"; }
open(){ curl -s -o "$ROOT/opened.jpg" -w '%{http_code}' "$API/v1/assets/$1/preview" \
  -H "Authorization: Bearer $TOKEN"; }

echo "Three videos that each need a cellular copy"
# 4K at about 24 Mbps, over the 12 Mbps line, and a few seconds' transcode
# each, so ones that overlap can be seen. The tones differ so they aren't
# stored once as the same file.
for tone in 440 550 660; do
  ffmpeg -v error -y -f lavfi -i "testsrc2=size=3840x2160:rate=30:duration=6" \
    -f lavfi -i "sine=frequency=$tone:duration=6" -c:v libx264 -preset ultrafast \
    -b:v 24M -maxrate 24M -bufsize 24M -pix_fmt yuv420p -c:a aac -shortest "$LIB/clip-$tone.mp4"
done
for p in photo photo2; do
  vips gaussnoise "$ROOT/n.v" 900 600 >/dev/null 2>&1 && vips copy "$ROOT/n.v" "$LIB/$p.jpg" >/dev/null 2>&1
done

serve
CODE=$(cd "$SERVER_DIR" && "$BIN" invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
R=$(curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$CODE\",\"displayName\":\"Tester\",\"deviceName\":\"iPhone\",\"platform\":\"ios\"}")
TOKEN=$(echo "$R" | jq '["token"]'); SPACE=$(echo "$R" | jq '["personalSpace"]["id"]')
check "the worker says how it transcodes" "1" "$(grep -c "one transcode at a time on" "$ROOT/server.log")"

# Watched from the start of the import: the jobs in the database, and the
# ffmpeg processes themselves. Photos have playback jobs too, which do
# nothing, so only the videos' are counted.
VIDEO_JOBS="FROM derivation_jobs j JOIN assets a ON a.id = j.asset_id
  WHERE j.kind = 'playback' AND a.media_type = 'video'"
(cd "$SERVER_DIR" && "$BIN" import --path "$LIB" --space "$SPACE" >/dev/null 2>&1) &
IMPORTER=$!
MOST=0; MOST_FFMPEG=0; ARGS=""
for _ in $(seq 1 1200); do
  IFS='|' read -r RUNNING SETTLED <<< "$(q "SELECT count(*) FILTER (WHERE j.state = 'running'),
      count(*) FILTER (WHERE j.state IN ('done', 'failed')) $VIDEO_JOBS")"
  PIDS=$(pgrep -f 'playback-1080.mp4.partial')
  FF=$(echo "$PIDS" | grep -c .)
  [ "${RUNNING:-0}" -gt "$MOST" ] && MOST=$RUNNING
  [ "$FF" -gt "$MOST_FFMPEG" ] && MOST_FFMPEG=$FF
  [ -z "$ARGS" ] && [ "$FF" -gt 0 ] && ARGS=$(ps -o args= -p "$(echo "$PIDS" | head -1)")
  [ "${SETTLED:-0}" = "3" ] && break
  sleep 0.1
done
wait $IMPORTER
for _ in $(seq 1 120); do [ "$(q "SELECT count(*) FROM assets WHERE derived_at IS NULL")" = "0" ] && break; sleep 0.5; done

check "every video gets its cellular copy" "3" "$(q "SELECT count(*) $VIDEO_JOBS AND j.state = 'done'")"
check "and they're on disk" "3" \
  "$(find "$FRAMESTATION_BLOB_ROOT/derivatives" -name playback-1080.mp4 | wc -l | tr -d ' ')"
check "but never more than one at a time" "1" "$MOST"
check "with only ever one ffmpeg transcoding" "1" "$MOST_FFMPEG"
check "on two threads to decode and two to encode" "2" \
  "$(echo "$ARGS" | grep -o -- '-threads 2' | wc -l | tr -d ' ')"
check "and every photo and video has its thumbnail" "0" "$(q "SELECT count(*) FROM assets WHERE derived_at IS NULL")"

echo "A photo opened before its thumbnail was made"
PHOTO=$(asset photo.jpg id); SHA=$(asset photo.jpg sha256)
DIR="$FRAMESTATION_BLOB_ROOT/derivatives/${SHA:0:2}/${SHA:2:2}/$SHA"
PLACEMENT=$(q "SELECT id FROM space_assets WHERE asset_id = '$PHOTO'")
# The queue tried three times and gave up, so only opening it can make it now.
q "UPDATE assets SET derived_at = NULL WHERE id = '$PHOTO'" >/dev/null
q "UPDATE derivation_jobs SET state = 'failed', attempts = 3, last_error = 'gave up'
   WHERE asset_id = '$PHOTO' AND kind = 'thumbnails'" >/dev/null
rm -f "$DIR"/thumb-*.jpg "$DIR/preview-2048.jpg"
SEQ=$(q "SELECT coalesce(max(seq), 0) FROM change_log")
check "it opens" "200" "$(open "$PHOTO")"
for _ in $(seq 1 40); do [ "$(derived "$PHOTO")" = "t" ] && break; sleep 0.25; done
check "and its thumbnail is made while it's open" "t" "$(derived "$PHOTO")"
[ -s "$DIR/thumb-256.jpg" ] && [ -s "$DIR/thumb-512.jpg" ] && ok "both sizes are on disk" \
  || bad "both sizes are on disk" "thumb-256.jpg and thumb-512.jpg" "$(ls "$DIR" | tr '\n' ' ')"
check "its job is done, the old error cleared" "done|" "$(job "$PHOTO" thumbnails "state, last_error")"
check "and phones are told" "1" "$(q "SELECT count(*) FROM change_log
  WHERE seq > $SEQ AND entity = 'space_asset' AND entity_id = '$PLACEMENT'")"
check "the log says why" "1" "$(grep -ci "asset $PHOTO opened before its thumbnail was made" "$ROOT/server.log")"

PHOTO2=$(asset photo2.jpg id)
BEFORE=$(job "$PHOTO2" thumbnails finished_at)
open "$PHOTO2" >/dev/null; sleep 1.5
check "a photo that has its thumbnail isn't made again" "$BEFORE" "$(job "$PHOTO2" thumbnails finished_at)"

# A video's thumbnails rebuild its poster and delete the preview made from
# it, which could still be on its way to whoever opened it.
VIDEO=$(asset clip-440.mp4 id)
q "UPDATE assets SET derived_at = NULL WHERE id = '$VIDEO'" >/dev/null
q "UPDATE derivation_jobs SET state = 'failed', attempts = 3
   WHERE asset_id = '$VIDEO' AND kind = 'thumbnails'" >/dev/null
open "$VIDEO" >/dev/null; sleep 1.5
check "a video opened early is left to the queue" "f" "$(derived "$VIDEO")"

echo "A restart puts photos back in line before any lane starts"
stop
# The photo's thumbnail failed for good, and every transcode is waiting. One
# lane, so whichever it claims first shows.
q "UPDATE assets SET derived_at = NULL WHERE id = '$PHOTO'" >/dev/null
q "UPDATE derivation_jobs SET state = 'failed', attempts = 3, started_at = NULL
   WHERE asset_id = '$PHOTO' AND kind = 'thumbnails'" >/dev/null
q "UPDATE derivation_jobs SET state = 'pending', attempts = 0, started_at = NULL
   WHERE kind = 'playback'" >/dev/null
FRAMESTATION_DERIVATION_LANES=1 serve
for _ in $(seq 1 120); do
  [ "$(derived "$PHOTO")" = "t" ] && [ "$(derived "$VIDEO")" = "t" ] && break
  sleep 0.5
done
check "the photo's thumbnail is made" "t" "$(derived "$PHOTO")"
check "before any transcode started" "t" "$(q "SELECT j.started_at < COALESCE(
    (SELECT min(started_at) FROM derivation_jobs WHERE kind = 'playback'), 'infinity')
  FROM derivation_jobs j WHERE j.asset_id = '$PHOTO' AND j.kind = 'thumbnails'")"
check "and the video left to the queue is made too" "t" "$(derived "$VIDEO")"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
