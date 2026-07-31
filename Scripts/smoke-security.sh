#!/bin/bash
# Cross-user isolation: what one family member must not be able to reach.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
API="${FRAMESTATION_API:-http://127.0.0.1:8099}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"
mkdir -p "$SCRATCH/sec"; PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; echo "      expected: $2"; echo "      actual:   $3"; FAIL=$((FAIL+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
# Denied is what matters. The server answers 404 rather than 403 for a space
# you're not in, so the response can't be used to confirm it exists — asserting
# one exact code would lock in the weaker behaviour.
denied(){ case "$2" in 400|401|403|404) ok "$1";; *) bad "$1" "denied (4xx)" "$2";; esac }
jq(){ python3 -c "import sys,json; print(json.load(sys.stdin)$1)" 2>/dev/null; }
code(){ curl -s -o /dev/null -w '%{http_code}' "$@"; }

newuser(){ local c; c=$(cd "$SERVER_DIR" && swift run FrameStationServer invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
  curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
   -d "{\"code\":\"$c\",\"displayName\":\"$1\",\"deviceName\":\"$1-phone\",\"platform\":\"ios\"}" \
   | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["token"],d["personalSpace"]["id"],d["user"]["id"])'; }
read -r TA PA UA <<< "$(newuser Alice)"
read -r TB PB UB <<< "$(newuser Mallory)"
read -r TC PC UC <<< "$(newuser Carol)"

upload(){ # token space label -> assetID
  local f="$SCRATCH/sec/$3.jpg"
  vips gaussnoise "$SCRATCH/sec/$3.v" 400 300 >/dev/null 2>&1
  vips copy "$SCRATCH/sec/$3.v" "$f" >/dev/null 2>&1
  local sha size up
  sha=$(shasum -a 256 "$f" | awk '{print $1}'); size=$(stat -f%z "$f")
  up=$(curl -s -X POST "$API/v1/uploads/probe" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$2\",\"sha256\":\"$sha\",\"byteSize\":$size,\"filename\":\"$3.jpg\"}" | jq '["uploadID"]')
  curl -s -X PUT "$API/v1/uploads/$up/chunk/0" -H "Authorization: Bearer $1" --data-binary "@$f" >/dev/null
  curl -s -X POST "$API/v1/uploads/$up/commit" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$2\",\"mediaType\":\"photo\",\"mime\":\"image/jpeg\",\"width\":400,\"height\":300,\"isRaw\":false,\"burstPick\":false}" | jq '["assetID"]'
}

APRIV=$(upload "$TA" "$PA" alice-private)
ASHA=$(shasum -a 256 "$SCRATCH/sec/alice-private.jpg" | awk '{print $1}')
ASZ=$(stat -f%z "$SCRATCH/sec/alice-private.jpg")

echo "=== 1. another user's personal photo is unreachable ==="
check "original"  "404" "$(code -H "Authorization: Bearer $TB" "$API/v1/assets/$APRIV/original")"
check "preview"   "404" "$(code -H "Authorization: Bearer $TB" "$API/v1/assets/$APRIV/preview")"
check "thumbnail" "404" "$(code -H "Authorization: Bearer $TB" "$API/v1/assets/$APRIV/thumb")"
check "playback"  "404" "$(code -H "Authorization: Bearer $TB" "$API/v1/assets/$APRIV/playback")"
check "favourite" "404" "$(code -X PUT -H "Authorization: Bearer $TB" "$API/v1/spaces/$PA/assets/$APRIV/favorite")"
check "no token at all" "401" "$(code "$API/v1/assets/$APRIV/original")"

echo
echo "=== 2. the hash is not an existence oracle ==="
# Mallory holds a copy of the same file and asks whether the NAS has it.
P=$(curl -s -X POST "$API/v1/uploads/probe" -H "Authorization: Bearer $TB" -H 'Content-Type: application/json' \
  -d "{\"spaceID\":\"$PB\",\"sha256\":\"$ASHA\",\"byteSize\":$ASZ,\"filename\":\"guess.jpg\"}")
check "probe does not answer 'have'" "need" "$(echo "$P" | jq '["status"]')"
check "probe leaks no asset id" "" "$(echo "$P" | jq '["assetID"]')"

echo
echo "=== 3. an asset id is not a capability ==="
check "cannot link another user's asset" "404" \
  "$(code -X POST "$API/v1/spaces/$PB/assets/$APRIV" -H "Authorization: Bearer $TB" \
      -H 'Content-Type: application/json' -d '{}')"
check "still unreadable afterwards" "404" \
  "$(code -H "Authorization: Bearer $TB" "$API/v1/assets/$APRIV/original")"
denied "cannot link into someone else's space" \
  "$(code -X POST "$API/v1/spaces/$PA/assets/$APRIV" -H "Authorization: Bearer $TB" \
      -H 'Content-Type: application/json' -d '{}')"

echo
echo "=== 4. own library still dedups ==="
D=$(curl -s -X POST "$API/v1/uploads/probe" -H "Authorization: Bearer $TA" -H 'Content-Type: application/json' \
  -d "{\"spaceID\":\"$PA\",\"sha256\":\"$ASHA\",\"byteSize\":$ASZ,\"filename\":\"again.jpg\"}")
check "re-upload of your own file is free" "have" "$(echo "$D" | jq '["status"]')"
check "and returns the same asset" "$APRIV" "$(echo "$D" | jq '["assetID"]')"

echo
echo "=== 5. shared spaces are limited to members ==="
FAM=$(curl -s -X POST "$API/v1/spaces" -H "Authorization: Bearer $TA" -H 'Content-Type: application/json' \
  -d "{\"name\":\"Family Shared\",\"memberIDs\":[\"$UB\"]}" | jq '["id"]')
ASHARED=$(upload "$TA" "$FAM" alice-shared)
check "a member can read it"      "200" "$(code -H "Authorization: Bearer $TB" "$API/v1/assets/$ASHARED/original")"
check "a non-member cannot"       "404" "$(code -H "Authorization: Bearer $TC" "$API/v1/assets/$ASHARED/original")"
denied "non-member sees no timeline" \
  "$(code -H "Authorization: Bearer $TC" "$API/v1/spaces/$FAM/timeline")"
denied "non-member cannot upload to it" \
  "$(code -X POST "$API/v1/uploads/probe" -H "Authorization: Bearer $TC" -H 'Content-Type: application/json' \
      -d "{\"spaceID\":\"$FAM\",\"sha256\":\"$ASHA\",\"byteSize\":$ASZ,\"filename\":\"x.jpg\"}")"
denied "non-member cannot rename it" \
  "$(code -X PATCH "$API/v1/spaces/$FAM" -H "Authorization: Bearer $TC" -H 'Content-Type: application/json' \
      -d '{"name":"Hijacked"}')"
denied "a member who is not owner cannot rename it" \
  "$(code -X PATCH "$API/v1/spaces/$FAM" -H "Authorization: Bearer $TB" -H 'Content-Type: application/json' \
      -d '{"name":"Hijacked"}')"

echo
echo "=== 6. leaving a shared space ends access ==="
curl -s -X DELETE "$API/v1/spaces/$FAM/members/$UB" -H "Authorization: Bearer $TA" >/dev/null
check "removed member loses the photo" "404" \
  "$(code -H "Authorization: Bearer $TB" "$API/v1/assets/$ASHARED/original")"

echo
echo "=== 7. tokens ==="
check "a forged bearer token is rejected" "401" \
  "$(code -H "Authorization: Bearer notarealtoken" "$API/v1/me")"
check "tokens are stored hashed, never in the clear" "0" \
  "$(psql -h 127.0.0.1 -p 55432 -U framestation -d framestation -tAqc \
      "select count(*) from devices where token_hash = '$TA';")"

echo
echo "════════════════════════════════════"
echo "  passed: $PASS   failed: $FAIL"
echo "════════════════════════════════════"
[ "$FAIL" -eq 0 ]
