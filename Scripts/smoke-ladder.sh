#!/bin/bash
# The stream ladder: what a phone plays away from home. Every video fat enough
# to need one gets a few sizes, cut into one-second pieces that start at the
# same instants in every size, with playlists a player can choose between. An
# app that asks for one gets a link to it; an app from before ladders goes on
# getting what it always did. And the link is checked on every piece.
#
#   FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-ladder.sh
#
# Runs its own server against its own database and blob store.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"

DB=framestation_ladder; PORT=8064; API="http://127.0.0.1:$PORT"
export FRAMESTATION_DATABASE_URL="postgres://framestation:x@127.0.0.1:55432/$DB?sslmode=disable"
ROOT="$SCRATCH/ladder"; rm -rf "$ROOT"; mkdir -p "$ROOT/blobroot" "$ROOT/files"
ROOT=$(cd "$ROOT" && pwd -P)
export FRAMESTATION_BLOB_ROOT="$ROOT/blobroot"
PASS=0; FAIL=0
q(){ psql -h 127.0.0.1 -p 55432 -U framestation -d $DB -tAqc "$1"; }
admin(){ psql -h 127.0.0.1 -p 55432 -U framestation -d postgres -tAqc "$1"; }
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; echo "      expected: $2"; echo "      actual:   $3"; FAIL=$((FAIL+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
has(){ case "$3" in *"$2"*) ok "$1";; *) bad "$1" "contains '$2'" "$3";; esac }
jq(){ python3 -c "import sys,json; print(json.load(sys.stdin)$1)" 2>/dev/null; }
code(){ curl -s -o /dev/null -w '%{http_code}' "$@"; }

(cd "$SERVER_DIR" && swift build >/dev/null 2>&1) || { echo "server build failed"; exit 1; }
BIN="$(cd "$SERVER_DIR" && swift build --show-bin-path)/FrameStationServer"
# Whatever already answers on this port would be tested in this server's place.
curl -s -o /dev/null "$API/health" && { echo "port $PORT is already in use"; exit 1; }
admin "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1; admin "CREATE DATABASE $DB" >/dev/null
"$BIN" serve --hostname 127.0.0.1 --port $PORT > "$ROOT/server.log" 2>&1 &
SERVER=$!
# The log stays for a look after a failure; the files made for the run go.
trap 'kill $SERVER 2>/dev/null; wait $SERVER 2>/dev/null; rm -rf "$ROOT/files" "$ROOT/blobroot"' EXIT
for _ in $(seq 1 120); do curl -s -o /dev/null "$API/health" && break; sleep 0.5; done
curl -s -o /dev/null "$API/health" || { echo "server didn't start:"; tail -20 "$ROOT/server.log"; exit 1; }

newuser(){ local c; c=$(cd "$SERVER_DIR" && "$BIN" invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
  curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
    -d "{\"code\":\"$c\",\"displayName\":\"$1\",\"deviceName\":\"$1-phone\",\"platform\":\"ios\"}" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["token"],d["personalSpace"]["id"],d["user"]["id"])'; }
read -r T1 P1 U1 <<< "$(newuser Michael)"
read -r T2 P2 U2 <<< "$(newuser Morgan)"
A1="Authorization: Bearer $T1"; A2="Authorization: Bearer $T2"

# file mime width height -> assetID
upload(){
  local f="$1" sha size up
  sha=$(shasum -a 256 "$f" | awk '{print $1}'); size=$(stat -f%z "$f")
  up=$(curl -s -X POST "$API/v1/uploads/probe" -H "$A1" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$P1\",\"sha256\":\"$sha\",\"byteSize\":$size,\"filename\":\"$(basename "$f")\"}" | jq '["uploadID"]')
  curl -s -X PUT "$API/v1/uploads/$up/chunk/0" -H "$A1" --data-binary "@$f" >/dev/null
  curl -s -X POST "$API/v1/uploads/$up/commit" -H "$A1" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$P1\",\"mediaType\":\"video\",\"mime\":\"$2\",\"width\":$3,\"height\":$4,\"isRaw\":false,\"burstPick\":false}" | jq '["assetID"]'
}
clip(){ ffmpeg -v error -y -f lavfi -i "testsrc2=size=$2:rate=$3:duration=$4" "${@:5}" "$ROOT/files/$1"; }
tone(){ echo -f lavfi -i "sine=frequency=$1:duration=5"; }

echo "Four videos: 1080p at 60 fps, a portrait one, one with uncompressed sound, one already lean"
# Encoded fast and fat, well over the ladder's 2.5 Mbps line; the tones keep
# them from being stored once as the same file.
clip sixty.mp4 1920x1080 60 5 $(tone 440) -c:v libx264 -preset ultrafast -b:v 20M -maxrate 20M \
  -bufsize 20M -pix_fmt yuv420p -c:a aac -shortest
clip portrait.mp4 1080x1920 30 4 $(tone 550) -c:v libx264 -preset ultrafast -b:v 10M -maxrate 10M \
  -bufsize 10M -pix_fmt yuv420p -c:a aac -shortest
clip pcm.mov 1280x720 30 4 $(tone 660) -c:v libx264 -preset ultrafast -b:v 8M -maxrate 8M \
  -bufsize 8M -pix_fmt yuv420p -c:a pcm_s16le -shortest
clip lean.mp4 640x360 30 4 -c:v libx264 -b:v 400k -maxrate 400k -bufsize 400k -pix_fmt yuv420p
SIXTY=$(upload "$ROOT/files/sixty.mp4" video/mp4 1920 1080)
PORTRAIT=$(upload "$ROOT/files/portrait.mp4" video/mp4 1080 1920)
PCM=$(upload "$ROOT/files/pcm.mov" video/quicktime 1280 720)
LEAN=$(upload "$ROOT/files/lean.mp4" video/mp4 640 360)

for _ in $(seq 1 360); do
  [ "$(q "SELECT count(*) FROM derivation_jobs WHERE kind = 'ladder' AND state IN ('done', 'failed')")" = "4" ] && break
  sleep 0.5
done
check "every video's ladder job finishes" "4|0" \
  "$(q "SELECT count(*) FILTER (WHERE state = 'done') || '|' || count(*) FILTER (WHERE state = 'failed')
        FROM derivation_jobs WHERE kind = 'ladder'")"
check "and no one-file rendition is queued any more" "0" "$(q "SELECT count(*) FROM derivation_jobs WHERE kind = 'playback'")"
dir(){ local s; s=$(q "SELECT sha256 FROM assets WHERE id = '$1'"); echo "$FRAMESTATION_BLOB_ROOT/derivatives/${s:0:2}/${s:2:2}/$s/stream-v1"; }
LADDER=$(dir "$SIXTY")
check "the 60 fps clip gets four sizes" "v1080 v270 v432 v720" \
  "$(ls "$LADDER" | grep m3u8 | grep -v master | sed 's/.m3u8//' | sort | tr '\n' ' ' | sed 's/ $//')"
check "the lean clip gets none" "no" "$([ -e "$(dir "$LEAN")" ] && echo yes || echo no)"
check "and nothing half-built is left behind" "0" "$(find "$FRAMESTATION_BLOB_ROOT" -name '*.partial' | wc -l | tr -d ' ')"

echo
echo "The top-level playlist"
MASTER=$(cat "$LADDER/master.m3u8")
has "a player can choose between them" "#EXT-X-STREAM-INF" "$MASTER"
check "listing every size" "4" "$(echo "$MASTER" | grep -c '^#EXT-X-STREAM-INF')"
python3 - "$LADDER" > "$ROOT/variants.txt" <<'PY'
import re, sys
lines = open(sys.argv[1] + "/master.m3u8").read().splitlines()
for i, line in enumerate(lines):
    if line.startswith("#EXT-X-STREAM-INF:"):
        attrs = dict(re.findall(r'([A-Z-]+)=("[^"]*"|[^,]*)', line[len("#EXT-X-STREAM-INF:"):]))
        print(lines[i + 1].replace(".m3u8", ""), attrs["RESOLUTION"], attrs["FRAME-RATE"],
              attrs["CODECS"].strip('"'), attrs["BANDWIDTH"], attrs["AVERAGE-BANDWIDTH"])
PY
variant(){ awk -v n="$1" '$1 == n' "$ROOT/variants.txt"; }
check "1080p keeps the clip's 60 frames a second" "1920x1080 60.000" "$(variant v1080 | awk '{print $2, $3}')"
check "720p at half that" "1280x720 30.000" "$(variant v720 | awk '{print $2, $3}')"
check "and the small two" "768x432 480x270" "$(echo "$(variant v432 | awk '{print $2}') $(variant v270 | awk '{print $2}')")"
has "each says what decodes it" "avc1.64" "$(variant v720 | awk '{print $4}')"
has "sound included" "mp4a.40.2" "$(variant v720 | awk '{print $4}')"
check "peak never under average" "ok" "$(awk '$5 < $6 {bad=1} END {print bad ? "bad" : "ok"}' "$ROOT/variants.txt")"
FIRST=$(head -1 "$ROOT/variants.txt" | awk '{print $1, $6}')
check "it starts on a size near 2 Mbps, not the largest" "yes" \
  "$(echo "$FIRST" | awk '{fits = ($2 <= 2000000 || $1 == "v270") && ($1 != "v1080"); print fits ? "yes" : "no"}')"

echo
echo "Every size cut at the same instants"
python3 - "$LADDER" > "$ROOT/cuts.txt" <<'PY'
import sys, os
base = sys.argv[1]
for name in sorted(n[:-5] for n in os.listdir(base) if n.endswith(".m3u8") and n != "master.m3u8"):
    durations, uris, maps = [], set(), set()
    for line in open(f"{base}/{name}.m3u8").read().splitlines():
        if line.startswith("#EXTINF:"):
            durations.append(round(float(line[8:].split(",")[0]), 3))
        elif line.startswith("#EXT-X-MAP:"):
            maps.add(line.split('URI="')[1].split('"')[0])
        elif line and not line.startswith("#"):
            uris.add(line)
    print(name, ",".join(map(str, durations)), "|".join(sorted(uris)), "|".join(sorted(maps)))
PY
check "the same pieces in every size" "1" "$(awk '{print $2}' "$ROOT/cuts.txt" | sort -u | wc -l | tr -d ' ')"
check "a second each" "1.0" "$(awk 'NR == 1 {n = split($2, d, ","); print d[1]}' "$ROOT/cuts.txt")"
check "five of them" "5" "$(awk 'NR == 1 {print split($2, d, ",")}' "$ROOT/cuts.txt")"
check "each playlist names its own file, beside it" "v1080.m4s v1080.m4s" "$(awk '$1 == "v1080" {print $3, $4}' "$ROOT/cuts.txt")"

echo
echo "The odd ones"
PDIR=$(dir "$PORTRAIT")
check "a portrait clip stays portrait" "720x1280" \
  "$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$PDIR/v720.m4s")"
check "uncompressed sound arrives as AAC" "aac" \
  "$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$(dir "$PCM")/v720.m4s")"
check "a 720p clip tops out at 720p" "v270 v432 v720" \
  "$(ls "$(dir "$PCM")" | grep m3u8 | grep -v master | sed 's/.m3u8//' | sort | tr '\n' ' ' | sed 's/ $//')"

echo
echo "Which link an app gets"
link(){ curl -s "$API/v1/assets/$1/playback?quality=$2${3:+&adaptive=1}" -H "$A1"; }
R=$(link "$SIXTY" mobile yes)
check "an app that can play a ladder gets one" "adaptive" "$(echo "$R" | jq '["kind"]')"
URL=$(echo "$R" | jq '["url"]')
has "named by its top-level playlist" "/v1/hls/$SIXTY/$U1/" "$URL"
LIFE=$(echo "$R" | python3 -c 'import sys,json,datetime as d; r=json.load(sys.stdin); print(int(d.datetime.fromisoformat(r["expiresAt"].replace("Z","+00:00")).timestamp() - d.datetime.now(d.timezone.utc).timestamp()))')
check "lasting ten minutes for a five-second clip" "yes" "$([ "$LIFE" -ge 590 ] && [ "$LIFE" -le 615 ] && echo yes || echo "no ($LIFE s)")"
check "an app from before ladders gets the file, as it always did" "direct" "$(link "$SIXTY" mobile | jq '["kind"]')"
check "and it plays" "206" "$(code -H 'Range: bytes=0-99' "$(link "$SIXTY" mobile | jq '["url"]')")"
check "at home, the original" "direct" "$(link "$SIXTY" original yes | jq '["kind"]')"
check "a lean clip, as it is" "direct" "$(link "$LEAN" mobile yes | jq '["kind"]')"
check "no one else can ask for one" "404" "$(code "$API/v1/assets/$SIXTY/playback?quality=mobile&adaptive=1" -H "$A2")"

echo
echo "What a player fetches through it"
BASE="${URL%/master.m3u8}"
check "the top-level playlist" "200" "$(code "$URL")"
has "as a playlist" "application/vnd.apple.mpegurl" "$(curl -s -o /dev/null -D- "$URL" | tr -d '\r' | tr 'A-Z' 'a-z')"
check "word for word what's on disk" "$(shasum -a 256 < "$LADDER/master.m3u8")" "$(curl -s "$URL" | shasum -a 256)"
check "a size's playlist beside it" "200" "$(code "$BASE/v432.m3u8")"
RANGE=$(grep -m1 '^#EXT-X-BYTERANGE' "$LADDER/v432.m3u8" | cut -d: -f2)
LEN=${RANGE%@*}; AT=${RANGE#*@}
check "a piece, by the range its playlist gives" "206" "$(code -H "Range: bytes=$AT-$((AT + LEN - 1))" "$BASE/v432.m4s")"
check "exactly those bytes" \
  "$(dd if="$LADDER/v432.m4s" bs=1 skip="$AT" count="$LEN" 2>/dev/null | shasum -a 256)" \
  "$(curl -s -H "Range: bytes=$AT-$((AT + LEN - 1))" "$BASE/v432.m4s" | shasum -a 256)"

echo
echo "The link is checked on every piece"
SIG=$(echo "$URL" | awk -F/ '{print $(NF-1)}'); EXP=$(echo "$URL" | awk -F/ '{print $(NF-2)}')
check "a forged signature" "404" "$(code "${BASE%/*}/AAAA/v432.m3u8")"
check "a later expiry it wasn't signed for" "404" "$(code "${BASE%/*/*}/$((EXP + 60))/$SIG/v432.m3u8")"
check "an expiry long past" "404" "$(code "$(echo "$BASE" | sed -E "s#/$EXP/#/1000000000/#")/v432.m3u8")"
check "someone else's id in it" "404" "$(code "$(echo "$BASE" | sed "s#/$U1/#/$U2/#")/v432.m3u8")"
check "a file a ladder doesn't have" "404" "$(code "$BASE/v999.m3u8")"
check "or a name built to climb out" "404" "$(code "$BASE/..%2F..%2Fthumb-256.jpg")"
check "or the folder itself" "404" "$(code "$BASE/stream-v1")"
curl -s -X DELETE "$API/v1/spaces/$P1/assets/$SIXTY" -H "$A1" -H 'Content-Type: application/json' -d '{}' >/dev/null
check "a clip in Recently Deleted still plays" "200" "$(code "$BASE/v432.m3u8")"
q "UPDATE space_assets SET purged_at = now() WHERE asset_id = '$SIXTY'" >/dev/null
check "and one deleted for good stops on the next piece" "404" "$(code "$BASE/v432.m3u8")"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
