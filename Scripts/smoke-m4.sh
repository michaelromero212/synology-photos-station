#!/bin/bash
# M4 smoke test: shared spaces, membership, roles, and cross-space linking.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
API="${FRAMESTATION_API:-http://127.0.0.1:8099}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"
export FRAMESTATION_DATABASE_URL="${FRAMESTATION_DATABASE_URL:-postgres://framestation:x@127.0.0.1:55432/framestation?sslmode=disable}"
export FRAMESTATION_BLOB_ROOT="${FRAMESTATION_BLOB_ROOT:-$SCRATCH/blobroot}"
mkdir -p "$SCRATCH/m4"; PASS=0; FAIL=0
q(){ psql -h 127.0.0.1 -p 55432 -U framestation -d framestation -tAqc "$1"; }
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; echo "      expected: $2"; echo "      actual:   $3"; FAIL=$((FAIL+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
jq(){ python3 -c "import sys,json; print(json.load(sys.stdin)$1)" 2>/dev/null; }
code(){ curl -s -o /dev/null -w '%{http_code}' "$@"; }

newuser(){ # displayName -> "token spaceID userID"
  local c
  c=$(cd "$SERVER_DIR" && swift run FrameStationServer invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
  curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
    -d "{\"code\":\"$c\",\"displayName\":\"$1\",\"deviceName\":\"$1-phone\",\"platform\":\"ios\"}" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["token"],d["personalSpace"]["id"],d["user"]["id"])'
}
read -r T1 P1 U1 <<< "$(newuser Michael)"
read -r T2 P2 U2 <<< "$(newuser Morgan)"
read -r T3 P3 U3 <<< "$(newuser Casey)"
A1="Authorization: Bearer $T1"; A2="Authorization: Bearer $T2"; A3="Authorization: Bearer $T3"

echo "=== 1. household directory ==="
H=$(curl -s "$API/v1/household" -H "$A1")
check "3 users listed" "3" "$(echo "$H" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["users"]))')"
check "sorted by name, Casey first" "Casey" "$(echo "$H" | jq '["users"][0]["displayName"]')"

echo
echo "=== 2. create a shared space with a member ==="
S=$(curl -s -X POST "$API/v1/spaces" -H "$A1" -H 'Content-Type: application/json' \
  -d "{\"name\":\"Family Shared\",\"memberIDs\":[\"$U2\"]}")
FAM=$(echo "$S" | jq '["id"]')
check "kind is shared"   "shared" "$(echo "$S" | jq '["kind"]')"
check "creator is owner" "owner"  "$(echo "$S" | jq '["role"]')"
check "2 members"        "2"      "$(echo "$S" | jq '["memberCount"]')"
check "appears in creator's /me" "1" \
  "$(curl -s "$API/v1/me" -H "$A1" | python3 -c 'import sys,json;print(sum(1 for s in json.load(sys.stdin)["spaces"] if s["kind"]=="shared"))')"
check "appears in the member's /me too" "1" \
  "$(curl -s "$API/v1/me" -H "$A2" | python3 -c 'import sys,json;print(sum(1 for s in json.load(sys.stdin)["spaces"] if s["kind"]=="shared"))')"
check "not in the non-member's /me" "0" \
  "$(curl -s "$API/v1/me" -H "$A3" | python3 -c 'import sys,json;print(sum(1 for s in json.load(sys.stdin)["spaces"] if s["kind"]=="shared"))')"

echo
echo "=== 3. members endpoint ==="
M=$(curl -s "$API/v1/spaces/$FAM/members" -H "$A1")
check "owner listed first" "owner" "$(echo "$M" | jq '["members"][0]["role"]')"
check "caller is owner"    "True"  "$(echo "$M" | jq '["callerIsOwner"]')"
check "member sees themselves as non-owner" "False" \
  "$(curl -s "$API/v1/spaces/$FAM/members" -H "$A2" | jq '["callerIsOwner"]')"
check "non-member gets 404" "404" "$(code "$API/v1/spaces/$FAM/members" -H "$A3")"

echo
echo "=== 4. roles are enforced ==="
check "non-owner can't add"        "403" "$(code -X PUT "$API/v1/spaces/$FAM/members/$U3" -H "$A2" -H 'Content-Type: application/json' -d '{"role":"contributor"}')"
check "owner can add"             "204" "$(code -X PUT "$API/v1/spaces/$FAM/members/$U3" -H "$A1" -H 'Content-Type: application/json' -d '{"role":"contributor"}')"
check "can't add a second owner"  "400" "$(code -X PUT "$API/v1/spaces/$FAM/members/$U3" -H "$A1" -H 'Content-Type: application/json' -d '{"role":"owner"}')"
check "owner can't be removed"    "403" "$(code -X DELETE "$API/v1/spaces/$FAM/members/$U1" -H "$A1")"
check "member can leave"          "204" "$(code -X DELETE "$API/v1/spaces/$FAM/members/$U3" -H "$A3")"
check "back to 2 members"         "2"   "$(q "select count(*) from space_members where space_id='$FAM';")"
check "personal space can't be shared" "403" \
  "$(code -X PUT "$API/v1/spaces/$P1/members/$U2" -H "$A1" -H 'Content-Type: application/json' -d '{"role":"contributor"}')"

echo
echo "=== 5. rename ==="
check "owner renames"      "Family Photos" "$(curl -s -X PATCH "$API/v1/spaces/$FAM" -H "$A1" -H 'Content-Type: application/json' -d '{"name":"Family Photos"}' | jq '["name"]')"
check "non-owner can't"    "403" "$(code -X PATCH "$API/v1/spaces/$FAM" -H "$A2" -H 'Content-Type: application/json' -d '{"name":"Nope"}')"
check "empty name rejected" "400" "$(code -X PATCH "$API/v1/spaces/$FAM" -H "$A1" -H 'Content-Type: application/json' -d '{"name":"   "}')"
check "personal can't be renamed" "403" \
  "$(code -X PATCH "$API/v1/spaces/$P1" -H "$A1" -H 'Content-Type: application/json' -d '{"name":"Mine"}')"

echo
echo "=== 6. linking a photo into the shared space — a row, not a copy ==="
f="$SCRATCH/m4/photo.jpg"
vips gaussnoise "$SCRATCH/m4/n.v" 900 600 >/dev/null 2>&1; vips copy "$SCRATCH/m4/n.v" "$f" >/dev/null 2>&1
sha=$(shasum -a 256 "$f" | awk '{print $1}'); size=$(stat -f%z "$f")
up=$(curl -s -X POST "$API/v1/uploads/probe" -H "$A1" -H 'Content-Type: application/json' \
  -d "{\"spaceID\":\"$P1\",\"sha256\":\"$sha\",\"byteSize\":$size,\"filename\":\"photo.jpg\"}" | jq '["uploadID"]')
curl -s -X PUT "$API/v1/uploads/$up/chunk/0" -H "$A1" --data-binary "@$f" >/dev/null
ASSET=$(curl -s -X POST "$API/v1/uploads/$up/commit" -H "$A1" -H 'Content-Type: application/json' \
  -d "{\"spaceID\":\"$P1\",\"mediaType\":\"photo\",\"mime\":\"image/jpeg\",\"width\":900,\"height\":600,\"capturedAt\":\"2026-07-20T12:00:00Z\",\"capturedTZOffset\":0,\"isRaw\":false,\"burstPick\":false}" | jq '["assetID"]')
check "linked into shared" "True" \
  "$(curl -s -X POST "$API/v1/spaces/$FAM/assets/$ASSET" -H "$A1" -H 'Content-Type: application/json' -d '{}' | jq '["deduplicated"]')"
check "2 placements, 1 asset" "2|1" "$(q "select (select count(*) from space_assets)||chr(124)||(select count(*) from assets);")"
check "still one file on disk" "1" "$(find "$SCRATCH/blobroot/blobs" -type f | wc -l | tr -d ' ')"
check "member can now see it" "1" \
  "$(curl -s "$API/v1/spaces/$FAM/timeline/2026-07-20?zoom=day" -H "$A2" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["items"]))')"

echo
echo "=== 7. attribution in the shared space ==="
D=$(curl -s "$API/v1/spaces/$FAM/assets/$ASSET/detail" -H "$A2")
check "shared space flagged"  "True"    "$(echo "$D" | jq '["isSharedSpace"]')"
check "attributed to Michael" "Michael" "$(echo "$D" | jq '["uploadedBy"]["displayName"]')"
check "personal copy suppresses it" "False" \
  "$(curl -s "$API/v1/spaces/$P1/assets/$ASSET/detail" -H "$A1" | jq '["isSharedSpace"]')"
check "contribution counted per member" "1" \
  "$(curl -s "$API/v1/spaces/$FAM/members" -H "$A1" | python3 -c 'import sys,json;print(next(m["contributedCount"] for m in json.load(sys.stdin)["members"] if m["user"]["displayName"]=="Michael"))')"

echo
echo "=== 8. a non-member is locked out entirely ==="
check "timeline 404"  "404" "$(code "$API/v1/spaces/$FAM/timeline" -H "$A3")"
check "detail 404"    "404" "$(code "$API/v1/spaces/$FAM/assets/$ASSET/detail" -H "$A3")"
check "can't link in" "404" "$(code -X POST "$API/v1/spaces/$FAM/assets/$ASSET" -H "$A3" -H 'Content-Type: application/json' -d '{}')"

echo
echo "════════════════════════════════════"
echo "  passed: $PASS   failed: $FAIL"
echo "════════════════════════════════════"
[ "$FAIL" -eq 0 ]
