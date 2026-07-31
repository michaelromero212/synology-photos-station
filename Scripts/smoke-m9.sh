#!/bin/bash
# M9: albums — CRUD, ordering, covers, and the space boundary they must respect.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
API="${FRAMESTATION_API:-http://127.0.0.1:8099}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"
mkdir -p "$SCRATCH/m9"; PASS=0; FAIL=0
q(){ psql -h 127.0.0.1 -p 55432 -U framestation -d framestation -tAqc "$1"; }
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; echo "      expected: $2"; echo "      actual:   $3"; FAIL=$((FAIL+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
denied(){ case "$2" in 400|401|403|404) ok "$1";; *) bad "$1" "denied (4xx)" "$2";; esac }
jq(){ python3 -c "import sys,json; print(json.load(sys.stdin)$1)" 2>/dev/null; }
code(){ curl -s -o /dev/null -w '%{http_code}' "$@"; }

newuser(){ local c; c=$(cd "$SERVER_DIR" && swift run FrameStationServer invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
  curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
   -d "{\"code\":\"$c\",\"displayName\":\"$1\",\"deviceName\":\"$1-phone\",\"platform\":\"ios\"}" \
   | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["token"],d["personalSpace"]["id"],d["user"]["id"])'; }
read -r T1 P1 U1 <<< "$(newuser Michael)"
read -r T2 P2 U2 <<< "$(newuser Morgan)"
read -r T3 P3 U3 <<< "$(newuser Casey)"
A1="Authorization: Bearer $T1"; A2="Authorization: Bearer $T2"; A3="Authorization: Bearer $T3"

upload(){ # token space label -> spaceAssetID
  local f="$SCRATCH/m9/$3.jpg"
  vips gaussnoise "$SCRATCH/m9/$3.v" 320 240 >/dev/null 2>&1
  vips copy "$SCRATCH/m9/$3.v" "$f" >/dev/null 2>&1
  local sha size up
  sha=$(shasum -a 256 "$f" | awk '{print $1}'); size=$(stat -f%z "$f")
  up=$(curl -s -X POST "$API/v1/uploads/probe" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$2\",\"sha256\":\"$sha\",\"byteSize\":$size,\"filename\":\"$3.jpg\"}" | jq '["uploadID"]')
  curl -s -X PUT "$API/v1/uploads/$up/chunk/0" -H "Authorization: Bearer $1" --data-binary "@$f" >/dev/null
  curl -s -X POST "$API/v1/uploads/$up/commit" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$2\",\"mediaType\":\"photo\",\"mime\":\"image/jpeg\",\"width\":320,\"height\":240,\"isRaw\":false,\"burstPick\":false}" | jq '["spaceAssetID"]'
}

M1=$(upload "$T1" "$P1" mine-1)
M2=$(upload "$T1" "$P1" mine-2)
M3=$(upload "$T1" "$P1" mine-3)
FAM=$(curl -s -X POST "$API/v1/spaces" -H "$A1" -H 'Content-Type: application/json' \
  -d "{\"name\":\"Family Shared\",\"memberIDs\":[\"$U2\"]}" | jq '["id"]')
S1=$(upload "$T1" "$FAM" shared-1)

echo "=== 1. create ==="
R=$(curl -s -X POST "$API/v1/albums" -H "$A1" -H 'Content-Type: application/json' \
  -d "{\"spaceID\":\"$P1\",\"name\":\"  Iceland 2012  \",\"spaceAssetIDs\":[\"$M1\",\"$M2\"]}")
ALB=$(echo "$R" | jq '["id"]')
check "name is trimmed"   "Iceland 2012"  "$(echo "$R" | jq '["name"]')"
check "counts its photos" "2"             "$(echo "$R" | jq '["itemCount"]')"
check "knows its space"   "Personal Space" "$(echo "$R" | jq '["spaceName"]')"
check "picks a cover"     "True"          "$(python3 -c "import json;print(json.load(open('/dev/stdin'))['coverAssetID'] is not None)" <<< "$R")"
check "blank name refused" "400" \
  "$(code -X POST "$API/v1/albums" -H "$A1" -H 'Content-Type: application/json' \
      -d "{\"spaceID\":\"$P1\",\"name\":\"   \",\"spaceAssetIDs\":[]}")"
denied "cannot create in a space you're not in" \
  "$(code -X POST "$API/v1/albums" -H "$A3" -H 'Content-Type: application/json' \
      -d "{\"spaceID\":\"$P1\",\"name\":\"Theirs\",\"spaceAssetIDs\":[]}")"

echo
echo "=== 2. add and remove ==="
check "adding grows it" "3" \
  "$(curl -s -X POST "$API/v1/albums/$ALB/assets" -H "$A1" -H 'Content-Type: application/json' \
      -d "{\"spaceAssetIDs\":[\"$M3\"]}" | jq '["itemCount"]')"
check "adding twice is idempotent" "3" \
  "$(curl -s -X POST "$API/v1/albums/$ALB/assets" -H "$A1" -H 'Content-Type: application/json' \
      -d "{\"spaceAssetIDs\":[\"$M3\"]}" | jq '["itemCount"]')"
check "removing shrinks it" "204" \
  "$(code -X DELETE "$API/v1/albums/$ALB/assets/$M3" -H "$A1")"
check "count reflects removal" "2" "$(curl -s "$API/v1/albums/$ALB" -H "$A1" | jq '["itemCount"]')"

echo
echo "=== 3. an album cannot cross a space boundary ==="
# S1 lives in Family Shared; this album lives in Michael's personal space.
check "a photo from another space is ignored" "2" \
  "$(curl -s -X POST "$API/v1/albums/$ALB/assets" -H "$A1" -H 'Content-Type: application/json' \
      -d "{\"spaceAssetIDs\":[\"$S1\"]}" | jq '["itemCount"]')"
check "and is not recorded" "0" \
  "$(q "select count(*) from album_assets where album_id='$ALB' and space_asset_id='$S1';")"
# Morgan is in Family Shared but not Michael's personal space.
check "a member of one space can't see the other's album" "404" \
  "$(code "$API/v1/albums/$ALB" -H "$A2")"
check "nor add to it" "404" \
  "$(code -X POST "$API/v1/albums/$ALB/assets" -H "$A2" -H 'Content-Type: application/json' \
      -d "{\"spaceAssetIDs\":[\"$S1\"]}")"
check "nor delete it" "404" "$(code -X DELETE "$API/v1/albums/$ALB" -H "$A2")"

echo
echo "=== 4. shared albums follow shared membership ==="
SALB=$(curl -s -X POST "$API/v1/albums" -H "$A1" -H 'Content-Type: application/json' \
  -d "{\"spaceID\":\"$FAM\",\"name\":\"Birthday\",\"spaceAssetIDs\":[\"$S1\"]}" | jq '["id"]')
check "a fellow member sees it" "Birthday" "$(curl -s "$API/v1/albums/$SALB" -H "$A2" | jq '["name"]')"
check "a fellow member can add to it" "200" \
  "$(code -X POST "$API/v1/albums/$SALB/assets" -H "$A2" -H 'Content-Type: application/json' \
      -d "{\"spaceAssetIDs\":[\"$S1\"]}")"
check "a non-member cannot see it" "404" "$(code "$API/v1/albums/$SALB" -H "$A3")"
curl -s -X DELETE "$API/v1/spaces/$FAM/members/$U2" -H "$A1" >/dev/null
check "removal from the space removes the album too" "404" \
  "$(code "$API/v1/albums/$SALB" -H "$A2")"

echo
echo "=== 5. listing ==="
check "lists only your albums" "2" \
  "$(curl -s "$API/v1/albums" -H "$A1" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["albums"]))')"
check "a stranger sees none" "0" \
  "$(curl -s "$API/v1/albums" -H "$A3" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["albums"]))')"
check "unauthenticated is rejected" "401" "$(code "$API/v1/albums")"

echo
echo "=== 6. rename, cover, delete ==="
check "rename" "Iceland" \
  "$(curl -s -X PATCH "$API/v1/albums/$ALB" -H "$A1" -H 'Content-Type: application/json' \
      -d '{"name":"Iceland"}' | jq '["name"]')"
COVER=$(q "select sa.asset_id from album_assets aa join space_assets sa on sa.id=aa.space_asset_id where aa.album_id='$ALB' order by aa.position desc limit 1;")
check "cover can be set to a photo in the album" "$COVER" \
  "$(curl -s -X PATCH "$API/v1/albums/$ALB" -H "$A1" -H 'Content-Type: application/json' \
      -d "{\"coverAssetID\":\"$COVER\"}" | jq '["coverAssetID"]' | tr 'A-Z' 'a-z')"
OUTSIDE=$(q "select asset_id from space_assets where id='$S1';")
check "cover cannot be a photo outside the album" "400" \
  "$(code -X PATCH "$API/v1/albums/$ALB" -H "$A1" -H 'Content-Type: application/json' \
      -d "{\"coverAssetID\":\"$OUTSIDE\"}")"
BEFORE=$(q "select count(*) from space_assets where deleted_at is null;")
check "delete the album" "204" "$(code -X DELETE "$API/v1/albums/$ALB" -H "$A1")"
check "the photos survive it" "$BEFORE" "$(q "select count(*) from space_assets where deleted_at is null;")"
check "its rows are gone" "0" "$(q "select count(*) from album_assets where album_id='$ALB';")"

echo
echo "════════════════════════════════════"
echo "  passed: $PASS   failed: $FAIL"
echo "════════════════════════════════════"
[ "$FAIL" -eq 0 ]
