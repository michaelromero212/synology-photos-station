#!/bin/bash
# Video posters. A video's thumbnail comes from the sharpest of a few early
# frames that isn't black, blown out or blank, rather than whatever was on
# screen one second in. One second in stays the choice while it's about as
# sharp as the best. Videos have their own thumbnail version, so a change to
# posters rebuilds only videos, and a photo with no thumbnail yet is made
# before any rebuild, so new uploads never wait behind one.
#
#   FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-poster.sh
#
# Runs its own server against its own database and blob store.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"

DB=framestation_poster; PORT=8095; API="http://127.0.0.1:$PORT"
export FRAMESTATION_DATABASE_URL="postgres://framestation:x@127.0.0.1:55432/$DB?sslmode=disable"
ROOT="$SCRATCH/poster"; rm -rf "$ROOT"; mkdir -p "$ROOT/blobroot" "$ROOT/lib"
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
above(){ python3 -c "print('yes' if float('$1') > float('$2') else 'no')"; }
truthy(){ [ "$2" = "yes" ] && ok "$1" || bad "$1" "yes" "no — $3"; }

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

# A frame measured the way the server measures candidates: squeezed to a
# 384 px gray square. Prints "brightness sharpness".
measure(){ # file [seconds into a video]
  # Positional rather than an array: macOS's bash 3.2 calls an empty array
  # unbound under `set -u`.
  if [ -n "${2:-}" ]; then set -- -ss "$2" -i "$1"; else set -- -i "$1"; fi
  ffmpeg -v error "$@" -frames:v 1 -vf "scale=384:384:flags=area,format=gray" \
    -f rawvideo - 2>/dev/null | python3 -c '
import sys
d = sys.stdin.buffer.read(); s = 384
if len(d) != s * s: print("0 0"); sys.exit()
mean = sum(d) / len(d)
lap = [4*d[i] - d[i-1] - d[i+1] - d[i-s] - d[i+s]
       for y in range(1, s-1) for i in range(y*s+1, y*s+s-1)]
m = sum(lap) / len(lap)
print(f"{mean:.1f} {sum(v*v for v in lap)/len(lap) - m*m:.1f}")'
}
asset(){ q "SELECT a.$2 FROM assets a JOIN space_assets sa ON sa.asset_id = a.id WHERE sa.filename = '$1'"; }
poster(){ local sha; sha=$(asset "$1" sha256)
  echo "$FRAMESTATION_BLOB_ROOT/derivatives/${sha:0:2}/${sha:2:2}/$sha/poster.jpg"; }
said(){ grep -c "derive $(asset "$1" sha256 | cut -c1-8): poster from $2" "$ROOT/server.log"; }

echo "Videos that start badly, and some that don't"
mk(){ ffmpeg -v error -y -f lavfi -i "$2" ${3:+-vf "$3"} -c:v libx264 -g 30 -pix_fmt yuv420p "$LIB/$1"; }
mk blurry-start.mp4 "testsrc2=size=1280x720:rate=30:duration=5" \
  "boxblur=luma_radius=24:luma_power=3:chroma_radius=12:enable='lt(t,1.8)'"
mk black-start.mp4 "testsrc2=size=1280x720:rate=30:duration=5" \
  "drawbox=color=black:t=fill:enable='lt(t,1.2)'"
mk steady.mp4 "smptehdbars=size=1280x720:rate=30:duration=5"
mk short.mp4 "testsrc2=size=1280x720:rate=30:duration=0.4"
mk dark.mp4 "testsrc2=size=1280x720:rate=30:duration=5" "lutyuv=y=val*0.07"
for p in photo photo2; do
  vips gaussnoise "$ROOT/n.v" 900 600 >/dev/null 2>&1 && vips copy "$ROOT/n.v" "$LIB/$p.jpg" >/dev/null 2>&1
done

serve
CODE=$(cd "$SERVER_DIR" && "$BIN" invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
R=$(curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$CODE\",\"displayName\":\"Tester\",\"deviceName\":\"iPhone\",\"platform\":\"ios\"}")
SPACE=$(echo "$R" | jq '["personalSpace"]["id"]')
(cd "$SERVER_DIR" && "$BIN" import --path "$LIB" --space "$SPACE" >/dev/null 2>&1)
for _ in $(seq 1 120); do [ "$(q "SELECT count(*) FROM assets WHERE derived_at IS NULL")" = "0" ] && break; sleep 1; done

BLURRED=$(measure "$LIB/blurry-start.mp4" 1.0 | awk '{print $2}')
SHARP=$(measure "$LIB/blurry-start.mp4" 3.0 | awk '{print $2}')
GOT=$(measure "$(poster blurry-start.mp4)" | awk '{print $2}')
truthy "a blurry start gives way to a sharp frame" "$(above "$GOT" "$(python3 -c "print($SHARP * 0.6)")")" \
  "poster sharpness $GOT, sharp frame $SHARP, blurred frame $BLURRED"
check "and the log says which" "1" "$(said blurry-start.mp4 '[234]\.0s')"
BRIGHT=$(measure "$(poster black-start.mp4)" | awk '{print $1}')
truthy "a black start is skipped" "$(above "$BRIGHT" 40)" "poster brightness $BRIGHT"
check "a steady video keeps the frame at one second" "0" "$(said steady.mp4 '')"
[ -s "$(poster steady.mp4)" ] && ok "and has its poster" || bad "and has its poster" "a poster" "none"
check "a clip shorter than any candidate uses its first frame" "1" "$(said short.mp4 '0\.0s')"
[ -s "$(poster dark.mp4)" ] && ok "a video dark all the way through still gets a poster" \
  || bad "a video dark all the way through still gets a poster" "a poster" "none"
check "videos carry the video thumbnail version" "4 4 4 4 4" \
  "$(for f in blurry-start black-start steady short dark; do asset "$f.mp4" thumb_version; done | tr '\n' ' ' | sed 's/ $//')"
check "photos keep the photo version" "3 3" "$(asset photo.jpg thumb_version) $(asset photo2.jpg thumb_version)"
stop

echo "Rebuilding: only videos, and never ahead of a new photo"
BLURRY=$(asset blurry-start.mp4 id); PHOTO=$(asset photo.jpg id)
# One video built before this version, with a full-screen preview made from
# its old poster.
q "UPDATE assets SET thumb_version = 3 WHERE id = '$BLURRY'" >/dev/null
PREVIEW="$(dirname "$(poster blurry-start.mp4)")/preview-2048.jpg"
cp "$(poster blurry-start.mp4)" "$PREVIEW"
# A photo that has no thumbnail yet, queued an hour after the rebuild job, so
# oldest-first alone would make it wait.
q "UPDATE assets SET derived_at = NULL WHERE id = '$PHOTO'" >/dev/null
q "UPDATE derivation_jobs SET state = 'pending', started_at = NULL, created_at = now() - interval '2 hours'
   WHERE asset_id = '$BLURRY' AND kind = 'thumbnails'" >/dev/null
q "UPDATE derivation_jobs SET state = 'pending', started_at = NULL, created_at = now() - interval '1 hour'
   WHERE asset_id = '$PHOTO' AND kind = 'thumbnails'" >/dev/null
OTHERS="SELECT string_agg(j.started_at::text, ',' ORDER BY j.id) FROM derivation_jobs j
        WHERE j.kind = 'thumbnails' AND j.asset_id NOT IN ('$BLURRY', '$PHOTO')"
BEFORE=$(q "$OTHERS")
FRAMESTATION_DERIVATION_LANES=1 serve
for _ in $(seq 1 120); do
  [ "$(asset blurry-start.mp4 thumb_version)" = "4" ] \
    && [ "$(q "SELECT derived_at IS NOT NULL FROM assets WHERE id = '$PHOTO'")" = "t" ] && break
  sleep 1
done
sleep 2
check "the old video is rebuilt to the new version" "4" "$(asset blurry-start.mp4 thumb_version)"
[ -e "$PREVIEW" ] && bad "its stale full-screen preview is dropped" "gone" "still there" \
  || ok "its stale full-screen preview is dropped"
check "the photo with no thumbnail went first" "t" \
  "$(q "SELECT p.started_at < v.started_at FROM derivation_jobs p, derivation_jobs v
        WHERE p.asset_id = '$PHOTO' AND p.kind = 'thumbnails'
          AND v.asset_id = '$BLURRY' AND v.kind = 'thumbnails'")"
check "nothing else was rebuilt, photo or video" "$BEFORE" "$(q "$OTHERS")"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
