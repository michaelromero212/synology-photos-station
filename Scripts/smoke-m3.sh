#!/bin/bash
# M3 smoke test: timeline manifest, bucket items, delta sync, asset detail.
#
#   FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-m3.sh
#
# Needs a freshly migrated, empty database and a server started with
# FRAMESTATION_BLOB_ROOT="$FRAMESTATION_TEST_DIR/blobroot".
set -uo pipefail

SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
API="${FRAMESTATION_API:-http://127.0.0.1:8099}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
PSQL="psql -h 127.0.0.1 -p 55432 -U framestation -d framestation -tAqc"
export PATH="/opt/homebrew/bin:$PATH"
export FRAMESTATION_DATABASE_URL="${FRAMESTATION_DATABASE_URL:-postgres://framestation:x@127.0.0.1:55432/framestation?sslmode=disable}"
export FRAMESTATION_BLOB_ROOT="${FRAMESTATION_BLOB_ROOT:-$SCRATCH/blobroot}"
mkdir -p "$SCRATCH/tl"
PASS=0; FAIL=0

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $1"; echo "      expected: $2"; echo "      actual:   $3"; FAIL=$((FAIL+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
jq_get() { python3 -c "import sys,json; d=json.load(sys.stdin); print(d$1)" 2>/dev/null; }

# --------------------------------------------------------------------- auth ---
new_user() { # displayName deviceName -> token
  local code
  code=$(cd "$SERVER_DIR" && swift run FrameStationServer invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
  curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
    -d "{\"code\":\"$code\",\"displayName\":\"$1\",\"deviceName\":\"$2\",\"platform\":\"ios\"}"
}
R=$(new_user Michael iPhone)
TOKEN=$(echo "$R" | jq_get '["token"]')
SPACE=$(echo "$R" | jq_get '["personalSpace"]["id"]')
UID1=$(echo "$R" | jq_get '["user"]["id"]')
AUTH="Authorization: Bearer $TOKEN"

R2=$(new_user Morgan iPad)
TOKEN2=$(echo "$R2" | jq_get '["token"]')
UID2=$(echo "$R2" | jq_get '["user"]["id"]')
AUTH2="Authorization: Bearer $TOKEN2"

# A shared space both belong to — this is where attribution has to work.
FAMILY=$($PSQL "INSERT INTO spaces (kind,name,created_by) VALUES ('shared','Family Shared','$UID1') RETURNING id;")
$PSQL "INSERT INTO space_members (space_id,user_id,role) VALUES ('$FAMILY','$UID1','owner'),('$FAMILY','$UID2','contributor');" >/dev/null

# ------------------------------------------------------------------ upload ---
# args: index space token width height capturedAt tzOffset  -> echoes assetID
put() {
  local i="$1" space="$2" tok="$3" w="$4" h="$5" cap="$6" tz="$7"
  local f="$SCRATCH/tl/img$i.jpg"
  vips gaussnoise "$SCRATCH/tl/n$i.v" "$w" "$h" >/dev/null 2>&1
  vips copy "$SCRATCH/tl/n$i.v" "$f" >/dev/null 2>&1
  local sha size up
  sha=$(shasum -a 256 "$f" | awk '{print $1}'); size=$(stat -f%z "$f")
  up=$(curl -s -X POST "$API/v1/uploads/probe" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$space\",\"sha256\":\"$sha\",\"byteSize\":$size,\"filename\":\"img$i.jpg\"}" | jq_get '["uploadID"]')
  curl -s -X PUT "$API/v1/uploads/$up/chunk/0" -H "Authorization: Bearer $tok" --data-binary "@$f" >/dev/null
  curl -s -X POST "$API/v1/uploads/$up/commit" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$space\",\"mediaType\":\"photo\",\"mime\":\"image/jpeg\",\"width\":$w,\"height\":$h,\"capturedAt\":\"$cap\",\"capturedTZOffset\":$tz,\"isRaw\":false,\"burstPick\":false}" \
    | jq_get '["assetID"]'
}

echo "=== uploading a spread across days, months, and years ==="
# Three on 2026-07-18 (local), one on 2026-07-04, one in June, one in 2025.
A1=$(put 1 "$SPACE" "$TOKEN" 800 600  "2026-07-18T16:00:00Z" 0)
A2=$(put 2 "$SPACE" "$TOKEN" 600 800  "2026-07-18T18:30:00Z" 0)
# 23:30 local on the 4th in New York == 03:30Z on the 5th. Must bucket to the 4th.
A3=$(put 3 "$SPACE" "$TOKEN" 900 600  "2026-07-05T03:30:00Z" -14400)
A4=$(put 4 "$SPACE" "$TOKEN" 1000 1000 "2026-06-11T12:00:00Z" 0)
A5=$(put 5 "$SPACE" "$TOKEN" 640 480  "2025-12-25T09:00:00Z" 0)
A6=$(put 6 "$SPACE" "$TOKEN" 800 600  "2026-07-18T20:00:00Z" 0)
echo "  6 uploaded"

# ---------------------------------------------------------------- manifest ---
echo
echo "=== 1. day manifest ==="
M=$(curl -s "$API/v1/spaces/$SPACE/timeline?zoom=day" -H "$AUTH")
check "total is 6"        "6" "$(echo "$M" | jq_get '["total"]')"
check "4 day buckets"     "4" "$(echo "$M" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["buckets"]))')"
check "newest bucket first" "2026-07-18" "$(echo "$M" | jq_get '["buckets"][0]["key"]')"
check "2026-07-18 has 3"  "3" "$(echo "$M" | jq_get '["buckets"][0]["count"]')"

echo
echo "=== 2. local-time bucketing (23:30 -04:00 stays on its own day) ==="
# If this bucketed in UTC it would land on 2026-07-05 instead.
check "bucket 2026-07-04 exists" "True" \
  "$(echo "$M" | python3 -c 'import sys,json;print(any(b["key"]=="2026-07-04" for b in json.load(sys.stdin)["buckets"]))')"
check "no 2026-07-05 bucket"     "False" \
  "$(echo "$M" | python3 -c 'import sys,json;print(any(b["key"]=="2026-07-05" for b in json.load(sys.stdin)["buckets"]))')"

echo
echo "=== 3. month and year zoom ==="
MM=$(curl -s "$API/v1/spaces/$SPACE/timeline?zoom=month" -H "$AUTH")
check "3 month buckets"   "3" "$(echo "$MM" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["buckets"]))')"
check "2026-07 has 4"     "4" "$(echo "$MM" | jq_get '["buckets"][0]["count"]')"
MY=$(curl -s "$API/v1/spaces/$SPACE/timeline?zoom=year" -H "$AUTH")
check "2 year buckets"    "2" "$(echo "$MY" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["buckets"]))')"
check "2026 has 5"        "5" "$(echo "$MY" | jq_get '["buckets"][0]["count"]')"

# ------------------------------------------------------------------ bucket ---
echo
echo "=== 4. bucket items carry layout geometry ==="
B=$(curl -s "$API/v1/spaces/$SPACE/timeline/2026-07-18?zoom=day" -H "$AUTH")
check "3 items"           "3" "$(echo "$B" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["items"]))')"
check "newest first"      "True" \
  "$(echo "$B" | python3 -c 'import sys,json;i=json.load(sys.stdin)["items"];print(i[0]["capturedAt"]>i[-1]["capturedAt"])')"
check "landscape ratio"   "1.3333" \
  "$(echo "$B" | python3 -c 'import sys,json;i=json.load(sys.stdin)["items"];print(round([x for x in i if x["assetID"]=="'"$A1"'"][0]["aspectRatio"],4))')"
check "portrait ratio"    "0.75" \
  "$(echo "$B" | python3 -c 'import sys,json;i=json.load(sys.stdin)["items"];print(round([x for x in i if x["assetID"]=="'"$A2"'"][0]["aspectRatio"],4))')"
check "every item has both ids" "True" \
  "$(echo "$B" | python3 -c 'import sys,json;i=json.load(sys.stdin)["items"];print(all(x["id"] and x["assetID"] for x in i))')"

echo
echo "=== 5. ThumbHash lands in the manifest once derived ==="
for _ in $(seq 1 45); do
  [ "$($PSQL "select count(*) from assets where thumbhash is not null;")" = "6" ] && break
  sleep 1
done
B2=$(curl -s "$API/v1/spaces/$SPACE/timeline/2026-07-18?zoom=day" -H "$AUTH")
check "all items report derived" "True" \
  "$(echo "$B2" | python3 -c 'import sys,json;print(all(x["isDerived"] for x in json.load(sys.stdin)["items"]))')"
check "thumbHash present, decodes to ~25 bytes" "True" \
  "$(echo "$B2" | python3 -c '
import sys,json,base64
i=json.load(sys.stdin)["items"]
print(all(x["thumbHash"] and 20<=len(base64.b64decode(x["thumbHash"]))<=30 for x in i))')"

# ------------------------------------------------------------- delta sync ---
echo
echo "=== 6. delta sync ==="
CUR=$(echo "$M" | jq_get '["cursor"]')
A7=$(put 7 "$SPACE" "$TOKEN" 800 600 "2026-07-19T10:00:00Z" 0)
D=$(curl -s "$API/v1/spaces/$SPACE/changes?since=$CUR" -H "$AUTH")
check "one change since cursor" "1" "$(echo "$D" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["changes"]))')"
check "op is insert"            "insert" "$(echo "$D" | jq_get '["changes"][0]["op"]')"
check "change is hydrated"      "$A7" "$(echo "$D" | jq_get '["changes"][0]["item"]["assetID"]')"
check "cursor advanced"         "True" \
  "$(python3 -c "print($(echo "$D" | jq_get '["cursor"]') > $CUR)")"
check "no changes at head"      "0" \
  "$(curl -s "$API/v1/spaces/$SPACE/changes?since=$(echo "$D" | jq_get '["cursor"]')" -H "$AUTH" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["changes"]))')"

# ---------------------------------------------------------------- detail ---
echo
echo "=== 7. asset detail: camera card + attribution ==="
DET=$(curl -s "$API/v1/spaces/$SPACE/assets/$A1/detail" -H "$AUTH")
check "dimensions"        "800" "$(echo "$DET" | jq_get '["width"]')"
check "byte size present" "True" "$(python3 -c "print($(echo "$DET" | jq_get '["byteSize"]') > 0)")"
check "uploader name"     "Michael" "$(echo "$DET" | jq_get '["uploadedBy"]["displayName"]')"
check "personal space suppresses attribution" "False" "$(echo "$DET" | jq_get '["isSharedSpace"]')"
check "tags empty"        "0" "$(echo "$DET" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["tags"]))')"

echo
echo "=== 8. shared space attribution — the feature the reference apps lack ==="
S1=$(put 8 "$FAMILY" "$TOKEN"  800 600 "2026-07-20T10:00:00Z" 0)
S2=$(put 9 "$FAMILY" "$TOKEN2" 800 600 "2026-07-20T11:00:00Z" 0)
D1=$(curl -s "$API/v1/spaces/$FAMILY/assets/$S1/detail" -H "$AUTH")
D2=$(curl -s "$API/v1/spaces/$FAMILY/assets/$S2/detail" -H "$AUTH")
check "shared space flagged"      "True"    "$(echo "$D1" | jq_get '["isSharedSpace"]')"
check "Michael's upload attributed" "Michael" "$(echo "$D1" | jq_get '["uploadedBy"]["displayName"]')"
check "Morgan's upload attributed"  "Morgan"  "$(echo "$D2" | jq_get '["uploadedBy"]["displayName"]')"
check "Morgan sees both in shared"  "2" \
  "$(curl -s "$API/v1/spaces/$FAMILY/timeline/2026-07-20?zoom=day" -H "$AUTH2" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["items"]))')"

echo
echo "=== 9. access control ==="
check "non-member manifest 404" "404" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$API/v1/spaces/$SPACE/timeline" -H "$AUTH2")"
check "non-member detail 404"   "404" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$API/v1/spaces/$SPACE/assets/$A1/detail" -H "$AUTH2")"
check "unauthenticated 401"     "401" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$API/v1/spaces/$SPACE/timeline")"

echo
echo "════════════════════════════════════"
echo "  passed: $PASS   failed: $FAIL"
echo "════════════════════════════════════"
[ "$FAIL" -eq 0 ]
