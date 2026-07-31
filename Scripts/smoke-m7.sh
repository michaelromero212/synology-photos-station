#!/bin/bash
# M7 smoke test: signed playback URLs and Range-served direct play.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
API="${FRAMESTATION_API:-http://127.0.0.1:8099}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"
export FRAMESTATION_DATABASE_URL="${FRAMESTATION_DATABASE_URL:-postgres://framestation:x@127.0.0.1:55432/framestation?sslmode=disable}"
export FRAMESTATION_BLOB_ROOT="${FRAMESTATION_BLOB_ROOT:-$SCRATCH/blobroot}"
mkdir -p "$SCRATCH/m7"; PASS=0; FAIL=0
q(){ psql -h 127.0.0.1 -p 55432 -U framestation -d framestation -tAqc "$1"; }
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; echo "      expected: $2"; echo "      actual:   $3"; FAIL=$((FAIL+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
has(){ case "$3" in *"$2"*) ok "$1";; *) bad "$1" "contains '$2'" "$3";; esac }
jq(){ python3 -c "import sys,json; print(json.load(sys.stdin)$1)" 2>/dev/null; }
code(){ curl -s -o /dev/null -w '%{http_code}' "$@"; }
hdr(){ curl -s -o /dev/null -D- "$@" | tr -d '\r'; }

newuser(){ local c; c=$(cd "$SERVER_DIR" && swift run FrameStationServer invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
  curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
    -d "{\"code\":\"$c\",\"displayName\":\"$1\",\"deviceName\":\"$1-phone\",\"platform\":\"ios\"}" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["token"],d["personalSpace"]["id"],d["user"]["id"])'; }
read -r T1 P1 U1 <<< "$(newuser Michael)"
read -r T2 P2 U2 <<< "$(newuser Morgan)"
A1="Authorization: Bearer $T1"; A2="Authorization: Bearer $T2"

# label kind width height duration -> assetID
put(){
  local label="$1" f
  if [ "$2" = video ]; then
    f="$SCRATCH/m7/$label.mp4"
    ffmpeg -y -f lavfi -i "testsrc=size=$3x$4:rate=30:duration=$5" -c:v libx264 -pix_fmt yuv420p \
      -movflags +faststart "$f" >/dev/null 2>&1
  else
    f="$SCRATCH/m7/$label.jpg"
    vips gaussnoise "$SCRATCH/m7/$label.v" 640 480 >/dev/null 2>&1
    vips copy "$SCRATCH/m7/$label.v" "$f" >/dev/null 2>&1
  fi
  local sha size up mime kind
  sha=$(shasum -a 256 "$f" | awk '{print $1}'); size=$(stat -f%z "$f")
  [ "$2" = video ] && { mime=video/mp4; kind=video; } || { mime=image/jpeg; kind=photo; }
  up=$(curl -s -X POST "$API/v1/uploads/probe" -H "$A1" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$P1\",\"sha256\":\"$sha\",\"byteSize\":$size,\"filename\":\"$(basename "$f")\"}" | jq '["uploadID"]')
  curl -s -X PUT "$API/v1/uploads/$up/chunk/0" -H "$A1" --data-binary "@$f" >/dev/null
  curl -s -X POST "$API/v1/uploads/$up/commit" -H "$A1" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$P1\",\"mediaType\":\"$kind\",\"mime\":\"$mime\",\"width\":$3,\"height\":$4,\"isRaw\":false,\"burstPick\":false}" | jq '["assetID"]'
}

V1080=$(put hd video 1920 1080 6)
V4K=$(put uhd video 3840 2160 4)
PHOTO=$(put still photo 640 480 0)
echo "=== 1. playback URL ==="
R=$(curl -s "$API/v1/assets/$V1080/playback" -H "$A1")
URL=$(echo "$R" | jq '["url"]')
check "kind is direct play" "direct" "$(echo "$R" | jq '["kind"]')"
has "points at the stream route" "/v1/stream/$V1080" "$URL"
has "carries a signature" "sig=" "$URL"
has "carries an expiry" "exp=" "$URL"
check "photos have no playback URL" "400" "$(code "$API/v1/assets/$PHOTO/playback" -H "$A1")"
check "non-member can't mint one" "404" "$(code "$API/v1/assets/$V1080/playback" -H "$A2")"
check "unauthenticated can't mint one" "401" "$(code "$API/v1/assets/$V1080/playback")"

echo
echo "=== 2. the signed URL plays, without a bearer token ==="
H=$(hdr "$URL")
has "200 OK"            "200" "$(echo "$H" | head -1)"
has "served as video"   "content-type: video/mp4" "$(echo "$H" | tr 'A-Z' 'a-z')"
has "advertises ranges" "accept-ranges: bytes"    "$(echo "$H" | tr 'A-Z' 'a-z')"
SIZE=$(echo "$H" | tr 'A-Z' 'a-z' | grep '^content-length:' | awk '{print $2}')
check "streams the whole file" "$(stat -f%z "$SCRATCH/m7/hd.mp4")" "$SIZE"

echo
echo "=== 3. Range requests, which is what scrubbing is ==="
R1=$(hdr -H "Range: bytes=0-1023" "$URL" | tr 'A-Z' 'a-z')
has "206 for a head range" "206" "$(echo "$R1" | head -1)"
has "reports the range"    "content-range: bytes 0-1023/$SIZE" "$R1"
check "sends exactly 1024 bytes" "1024" "$(echo "$R1" | grep '^content-length:' | awk '{print $2}')"
MID=$((SIZE/2))
R2=$(hdr -H "Range: bytes=$MID-" "$URL" | tr 'A-Z' 'a-z')
has "206 for a mid-file seek" "206" "$(echo "$R2" | head -1)"
has "open-ended range resolves" "content-range: bytes $MID-$((SIZE-1))/$SIZE" "$R2"
# The bytes actually have to match, or playback is silent corruption.
curl -s -H "Range: bytes=0-4095" "$URL" -o "$SCRATCH/m7/head.bin"
dd if="$SCRATCH/m7/hd.mp4" of="$SCRATCH/m7/head.ref" bs=1 count=4096 >/dev/null 2>&1
check "ranged bytes match the file" \
  "$(shasum -a 256 "$SCRATCH/m7/head.ref" | awk '{print $1}')" \
  "$(shasum -a 256 "$SCRATCH/m7/head.bin" | awk '{print $1}')"

echo
echo "=== 4. the signature actually gates it ==="
check "tampered signature rejected" "404" "$(code "${URL%sig=*}sig=deadbeef")"
check "no signature rejected" "404" "$(code "$API/v1/stream/$V1080")"
EXPIRED=$(echo "$URL" | sed -E "s/exp=[0-9]+/exp=1000000000/")
check "expired link rejected" "404" "$(code "$EXPIRED")"
# Swapping in another user's id invalidates the signature rather than granting
# access, because the user is inside the signed message.
check "user substitution rejected" "404" "$(code "$(echo "$URL" | sed -E "s/u=[^&]+/u=$U2/")")"
check "unknown asset rejected" "404" \
  "$(code "$API/v1/stream/00000000-0000-0000-0000-000000000000?u=$U1&exp=99999999999&sig=x")"

echo
echo "=== 5. 4K direct play ==="
U4=$(curl -s "$API/v1/assets/$V4K/playback" -H "$A1" | jq '["url"]')
H4=$(hdr "$U4" | tr 'A-Z' 'a-z')
has "4K streams too" "200" "$(echo "$H4" | head -1)"
has "4K advertises ranges" "accept-ranges: bytes" "$H4"
check "stored dimensions preserved" "3840x2160" "$(q "select width||'x'||height from assets where id='$V4K';")"
check "no transcode — bytes are the original" \
  "$(shasum -a 256 "$SCRATCH/m7/uhd.mp4" | awk '{print $1}')" "$(q "select sha256 from assets where id='$V4K';")"

echo
echo "════════════════════════════════════"
echo "  passed: $PASS   failed: $FAIL"
echo "════════════════════════════════════"
[ "$FAIL" -eq 0 ]
