#!/bin/bash
# M1b smoke test: EXIF extraction, thumbnails, ThumbHash, poster frames, serving.
#
# Same preconditions as smoke-m1a.sh — server running against a freshly
# migrated, empty database, started with
# FRAMESTATION_BLOB_ROOT="$FRAMESTATION_TEST_DIR/blobroot".
#
#   FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-m1b.sh
set -uo pipefail

SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
API="${FRAMESTATION_API:-http://127.0.0.1:8099}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
PSQL="psql -h 127.0.0.1 -p 55432 -U framestation -d framestation -tAqc"
export PATH="/opt/homebrew/bin:$PATH"

# The invite CLI is a second process and needs the same connection settings the
# running server was started with.
export FRAMESTATION_DATABASE_URL="${FRAMESTATION_DATABASE_URL:-postgres://framestation:x@127.0.0.1:55432/framestation?sslmode=disable}"
export FRAMESTATION_BLOB_ROOT="${FRAMESTATION_BLOB_ROOT:-$SCRATCH/blobroot}"
mkdir -p "$SCRATCH/media"
PASS=0; FAIL=0

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $1"; echo "      expected: $2"; echo "      actual:   $3"; FAIL=$((FAIL+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
approx(){ # label expected actual tolerance
  d=$(python3 -c "print(abs(float('$3')-float('$2'))<=float('$4'))" 2>/dev/null)
  [ "$d" = "True" ] && ok "$1" || bad "$1" "$2 (±$4)" "$3"
}
jq_get() { python3 -c "import sys,json; d=json.load(sys.stdin); print(d$1)" 2>/dev/null; }

# ---------------------------------------------------------------- fixtures ---
echo "=== fixtures ==="
cd "$SCRATCH/media"
vips gaussnoise g.v 1600 1200 >/dev/null 2>&1
vips copy g.v photo.jpg >/dev/null 2>&1
exiftool -q -overwrite_original \
  -Make="Apple" -Model="iPhone 16 Pro Max" \
  -LensModel="iPhone 16 Pro Max back camera 6.765mm f/1.78" \
  -ISO=64 -FNumber=1.78 -ExposureTime=1/268 -FocalLength=24 -ExposureCompensation=0 \
  -DateTimeOriginal="2026:07:04 15:55:00" -OffsetTimeOriginal="-04:00" \
  -GPSLatitude=38.3487 -GPSLatitudeRef=N -GPSLongitude=77.9797 -GPSLongitudeRef=W \
  photo.jpg >/dev/null 2>&1
# Portrait-rotated video: stored 640x480 with a 90° display matrix, so the
# server must report it as 480x640 or the timeline grid lays it out sideways.
# The rotation has to be applied via -display_rotation on a remux: the older
# "-metadata:s:v rotate=90" form is silently a no-op in current ffmpeg, which
# is exactly how a fixture ends up testing nothing.
ffmpeg -y -f lavfi -i testsrc=duration=4:size=640x480:rate=30 \
  -c:v libx264 -pix_fmt yuv420p flat.mov >/dev/null 2>&1
ffmpeg -y -display_rotation 90 -i flat.mov -c copy clip.mov >/dev/null 2>&1
echo "  photo.jpg $(stat -f%z photo.jpg) bytes, clip.mov $(stat -f%z clip.mov) bytes"

# -------------------------------------------------------------------- auth ---
CODE=$(cd "$SERVER_DIR" && swift run FrameStationServer invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
R=$(curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$CODE\",\"displayName\":\"Michael\",\"deviceName\":\"iPhone\",\"platform\":\"ios\"}")
TOKEN=$(echo "$R" | jq_get '["token"]'); SPACE=$(echo "$R" | jq_get '["personalSpace"]["id"]')
AUTH="Authorization: Bearer $TOKEN"

upload() { # file mime mediaType -> echoes assetID
  local f="$1" mime="$2" kind="$3"
  local sha size probe up
  sha=$(shasum -a 256 "$f" | awk '{print $1}'); size=$(stat -f%z "$f")
  probe=$(curl -s -X POST "$API/v1/uploads/probe" -H "$AUTH" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$SPACE\",\"sha256\":\"$sha\",\"byteSize\":$size,\"filename\":\"$(basename "$f")\"}")
  up=$(echo "$probe" | jq_get '["uploadID"]')
  curl -s -X PUT "$API/v1/uploads/$up/chunk/0" -H "$AUTH" --data-binary "@$f" >/dev/null
  curl -s -X POST "$API/v1/uploads/$up/commit" -H "$AUTH" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$SPACE\",\"mediaType\":\"$kind\",\"mime\":\"$mime\",\"isRaw\":false,\"burstPick\":false}" \
    | jq_get '["assetID"]'
}

# ------------------------------------------------------------ photo probe ---
echo
echo "=== 1. photo: EXIF extracted inline at commit ==="
PHOTO=$(upload photo.jpg image/jpeg photo)
echo "  assetID: $PHOTO"
row=$($PSQL "select coalesce(camera_make,'-')||'|'||coalesce(camera_model,'-')||'|'||coalesce(iso::text,'-')||'|'||coalesce(aperture::text,'-')||'|'||coalesce(shutter,'-')||'|'||coalesce(focal_len::text,'-') from assets where id='$PHOTO';")
check "camera make/model" "Apple|iPhone 16 Pro Max" "$(echo "$row" | cut -d'|' -f1-2)"
check "ISO"               "64"                      "$(echo "$row" | cut -d'|' -f3)"
check "aperture"          "1.78"                    "$(echo "$row" | cut -d'|' -f4)"
check "shutter"           "1/268 s"                 "$(echo "$row" | cut -d'|' -f5)"
check "focal length"      "24"                      "$(echo "$row" | cut -d'|' -f6)"
check "lens"              "1" "$($PSQL "select count(*) from assets where id='$PHOTO' and lens like '%6.765mm%';")"
check "dimensions"        "1600|1200" "$($PSQL "select width||'|'||height from assets where id='$PHOTO';")"
check "dynamic range"     "standard"  "$($PSQL "select coalesce(dynamic_range,'-') from assets where id='$PHOTO';")"

echo
echo "=== 2. GPS: west longitude sign applied from the Ref tag ==="
approx "latitude"  "38.3487"  "$($PSQL "select lat from assets where id='$PHOTO';")" "0.001"
approx "longitude" "-77.9797" "$($PSQL "select lon from assets where id='$PHOTO';")" "0.001"

echo
echo "=== 3. capture time honors OffsetTimeOriginal (-04:00) ==="
# 2026:07:04 15:55:00 -04:00  ==  19:55:00Z
check "captured_at in UTC" "2026-07-04 19:55:00+00" \
  "$($PSQL "select to_char(captured_at at time zone 'UTC','YYYY-MM-DD HH24:MI:SS')||'+00' from assets where id='$PHOTO';")"
check "tz offset seconds"  "-14400" "$($PSQL "select captured_tz_off from assets where id='$PHOTO';")"

# ------------------------------------------------------------------ video ---
echo
echo "=== 4. video: ffprobe duration + rotation-corrected dimensions ==="
VIDEO=$(upload clip.mov video/quicktime video)
echo "  assetID: $VIDEO"
approx "duration ~4000ms" "4000" "$($PSQL "select coalesce(duration_ms,0) from assets where id='$VIDEO';")" "300"
check "portrait after 90° rotation" "480|640" "$($PSQL "select width||'|'||height from assets where id='$VIDEO';")"

# ------------------------------------------------------------- derivations ---
echo
echo "=== 5. derivation queue drains ==="
for _ in $(seq 1 40); do
  done_count=$($PSQL "select count(*) from derivation_jobs where state='done';")
  [ "$done_count" = "2" ] && break
  sleep 1
done
check "both thumbnail jobs done" "2" "$($PSQL "select count(*) from derivation_jobs where state='done';")"
check "no failed jobs"           "0" "$($PSQL "select count(*) from derivation_jobs where state='failed';")"
check "assets marked derived"    "2" "$($PSQL "select count(*) from assets where derived_at is not null;")"

echo
echo "=== 6. thumbnails + ThumbHash on disk and in the database ==="
PSHA=$($PSQL "select sha256 from assets where id='$PHOTO';")
VSHA=$($PSQL "select sha256 from assets where id='$VIDEO';")
PDIR="$SCRATCH/blobroot/derivatives/${PSHA:0:2}/${PSHA:2:2}/$PSHA"
VDIR="$SCRATCH/blobroot/derivatives/${VSHA:0:2}/${VSHA:2:2}/$VSHA"
[ -f "$PDIR/thumb-256.jpg" ] && ok "photo thumb-256.jpg" || bad "photo thumb-256.jpg" exists missing
[ -f "$PDIR/thumb-512.jpg" ] && ok "photo thumb-512.jpg" || bad "photo thumb-512.jpg" exists missing
[ -f "$VDIR/poster.jpg" ]    && ok "video poster.jpg"    || bad "video poster.jpg" exists missing
[ -f "$VDIR/thumb-256.jpg" ] && ok "video thumb-256.jpg" || bad "video thumb-256.jpg" exists missing
check "no leftover .ppm scratch" "0" "$(find "$SCRATCH/blobroot/derivatives" -name '*.ppm' | wc -l | tr -d ' ')"
check "thumbhash stored, ~25 bytes" "2" \
  "$($PSQL "select count(*) from assets where octet_length(thumbhash) between 20 and 30;")"
check "thumb-256 is really 256 on its long edge" "256" \
  "$(vipsheader -f width "$PDIR/thumb-256.jpg" 2>/dev/null)"

# ---------------------------------------------------------------- serving ---
echo
echo "=== 7. serving endpoints ==="
ct=$(curl -s -o "$SCRATCH/media/dl-thumb.jpg" -w "%{content_type}" "$API/v1/assets/$PHOTO/thumb?size=256" -H "$AUTH")
check "thumb content-type" "image/jpeg" "$ct"
check "thumb decodes"      "256" "$(vipsheader -f width "$SCRATCH/media/dl-thumb.jpg" 2>/dev/null)"
check "bad size rejected"  "400" "$(curl -s -o /dev/null -w '%{http_code}' "$API/v1/assets/$PHOTO/thumb?size=999" -H "$AUTH")"

curl -s -o "$SCRATCH/media/dl-preview.jpg" "$API/v1/assets/$PHOTO/preview" -H "$AUTH"
check "preview generated lazily at 2048" "1600" "$(vipsheader -f width "$SCRATCH/media/dl-preview.jpg" 2>/dev/null)"
[ -f "$PDIR/preview-2048.jpg" ] && ok "preview cached on disk" || bad "preview cached" exists missing

curl -s -o "$SCRATCH/media/dl-original.jpg" "$API/v1/assets/$PHOTO/original" -H "$AUTH"
check "original is byte-exact" "$(shasum -a 256 photo.jpg | awk '{print $1}')" \
  "$(shasum -a 256 "$SCRATCH/media/dl-original.jpg" | awk '{print $1}')"

echo
echo "=== 8. access control ==="
CODE2=$(cd "$SERVER_DIR" && swift run FrameStationServer invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
T2=$(curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$CODE2\",\"displayName\":\"Morgan\",\"deviceName\":\"iPad\",\"platform\":\"ipados\"}" | jq_get '["token"]')
check "non-member gets 404 on thumb"    "404" "$(curl -s -o /dev/null -w '%{http_code}' "$API/v1/assets/$PHOTO/thumb" -H "Authorization: Bearer $T2")"
check "non-member gets 404 on original" "404" "$(curl -s -o /dev/null -w '%{http_code}' "$API/v1/assets/$PHOTO/original" -H "Authorization: Bearer $T2")"
check "unauthenticated gets 401"        "401" "$(curl -s -o /dev/null -w '%{http_code}' "$API/v1/assets/$PHOTO/thumb")"

echo
echo "════════════════════════════════════"
echo "  passed: $PASS   failed: $FAIL"
echo "════════════════════════════════════"
[ "$FAIL" -eq 0 ]
