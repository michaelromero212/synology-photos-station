#!/bin/bash
# Removal: deleting a photo sticks, and automatic backup doesn't undo it.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
API="${FRAMESTATION_API:-http://127.0.0.1:8099}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"
mkdir -p "$SCRATCH/m10"; PASS=0; FAIL=0
q(){ psql -h 127.0.0.1 -p 55432 -U framestation -d framestation -tAqc "$1"; }
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; echo "      expected: $2"; echo "      actual:   $3"; FAIL=$((FAIL+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
jq(){ python3 -c "import sys,json; print(json.load(sys.stdin)$1)" 2>/dev/null; }
code(){ curl -s -o /dev/null -w '%{http_code}' "$@"; }

c=$(cd "$SERVER_DIR" && swift run FrameStationServer invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
R=$(curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$c\",\"displayName\":\"Michael\",\"deviceName\":\"iPhone\",\"platform\":\"ios\"}")
T=$(echo "$R" | jq '["token"]'); SP=$(echo "$R" | jq '["personalSpace"]["id"]')
A="Authorization: Bearer $T"

f="$SCRATCH/m10/IMG_5000.jpg"
vips gaussnoise "$SCRATCH/m10/n.v" 400 300 >/dev/null 2>&1
vips copy "$SCRATCH/m10/n.v" "$f" >/dev/null 2>&1
SHA=$(shasum -a 256 "$f" | awk '{print $1}'); SZ=$(stat -f%z "$f")

probe(){ # auto?
  curl -s -X POST "$API/v1/uploads/probe" -H "$A" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$SP\",\"sha256\":\"$SHA\",\"byteSize\":$SZ,\"filename\":\"IMG_5000.jpg\",\"isAutomaticBackup\":$1}"
}
UP=$(probe false | jq '["uploadID"]')
curl -s -X PUT "$API/v1/uploads/$UP/chunk/0" -H "$A" --data-binary "@$f" >/dev/null
AID=$(curl -s -X POST "$API/v1/uploads/$UP/commit" -H "$A" -H 'Content-Type: application/json' \
  -d "{\"spaceID\":\"$SP\",\"mediaType\":\"photo\",\"mime\":\"image/jpeg\",\"width\":400,\"height\":300,\"isRaw\":false,\"burstPick\":false}" | jq '["assetID"]')

echo "=== 1. it's there ==="
check "visible in the library" "1" "$(q "select count(*) from space_assets where space_id='$SP' and deleted_at is null;")"
check "served" "200" "$(code -H "$A" "$API/v1/assets/$AID/original")"

echo
echo "=== 2. remove it ==="
check "delete returns 204" "204" "$(code -X DELETE "$API/v1/spaces/$SP/assets/$AID" -H "$A")"
check "gone from the library" "0" "$(q "select count(*) from space_assets where space_id='$SP' and deleted_at is null;")"
check "but the record is kept" "1" "$(q "select count(*) from space_assets where space_id='$SP' and deleted_at is not null;")"
check "and who did it" "1" "$(q "select count(*) from space_assets where deleted_by is not null;")"
check "deleting twice is a no-op" "404" "$(code -X DELETE "$API/v1/spaces/$SP/assets/$AID" -H "$A")"

echo
echo "=== 3. automatic backup does not undo it ==="
# This is the requirement: the photo is still on the phone, backup runs again.
check "probe declines" "removed" "$(probe true | jq '["status"]')"
check "no upload session offered" "" "$(probe true | jq '["uploadID"]')"
check "still absent afterwards" "0" "$(q "select count(*) from space_assets where space_id='$SP' and deleted_at is null;")"

echo
echo "=== 4. but a deliberate re-add works ==="
# Picking the photo yourself means you want it back.
P=$(probe false)
check "probe offers an upload" "need" "$(echo "$P" | jq '["status"]')"
UP2=$(echo "$P" | jq '["uploadID"]')
curl -s -X PUT "$API/v1/uploads/$UP2/chunk/0" -H "$A" --data-binary "@$f" >/dev/null
curl -s -X POST "$API/v1/uploads/$UP2/commit" -H "$A" -H 'Content-Type: application/json' \
  -d "{\"spaceID\":\"$SP\",\"mediaType\":\"photo\",\"mime\":\"image/jpeg\",\"width\":400,\"height\":300,\"isRaw\":false,\"burstPick\":false}" >/dev/null
check "back in the library" "1" "$(q "select count(*) from space_assets where space_id='$SP' and deleted_at is null;")"

echo
echo "=== 5. who may remove ==="
c2=$(cd "$SERVER_DIR" && swift run FrameStationServer invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
T2=$(curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$c2\",\"displayName\":\"Morgan\",\"deviceName\":\"m\",\"platform\":\"ios\"}" | jq '["token"]')
NEW=$(q "select asset_id from space_assets where space_id='$SP' and deleted_at is null limit 1;")
check "a stranger cannot remove it" "404" \
  "$(code -X DELETE "$API/v1/spaces/$SP/assets/$NEW" -H "Authorization: Bearer $T2")"
check "and it is still there" "1" "$(q "select count(*) from space_assets where space_id='$SP' and deleted_at is null;")"

echo
echo "════════════════════════════════════"
echo "  passed: $PASS   failed: $FAIL"
echo "════════════════════════════════════"
[ "$FAIL" -eq 0 ]
