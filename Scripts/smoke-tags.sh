#!/bin/bash
# Ratings and tags: stars stick, tags are one name however you spell it, and
# only someone who can contribute may change either.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
API="${FRAMESTATION_API:-http://127.0.0.1:8099}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"
# The `invite` command below is a second server process, and it reads both of
# these. Without them it exits before printing a code, the redeem gets an empty
# token, and every check fails as a 404 that looks like a permissions bug.
export FRAMESTATION_DATABASE_URL="${FRAMESTATION_DATABASE_URL:-postgres://framestation:x@127.0.0.1:55432/framestation?sslmode=disable}"
export FRAMESTATION_BLOB_ROOT="${FRAMESTATION_BLOB_ROOT:-$SCRATCH/blobroot}"
mkdir -p "$SCRATCH/tags"; PASS=0; FAIL=0
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
UID1=$(echo "$R" | jq '["user"]["id"]')
A="Authorization: Bearer $T"
# Fail loudly here rather than reporting thirty confusing 404s downstream.
[ -n "$SP" ] || { echo "setup failed: no space. Is the server up at $API?"; exit 1; }

f="$SCRATCH/tags/IMG_6100.jpg"
vips gaussnoise "$SCRATCH/tags/n.v" 400 300 >/dev/null 2>&1
vips copy "$SCRATCH/tags/n.v" "$f" >/dev/null 2>&1
SHA=$(shasum -a 256 "$f" | awk '{print $1}'); SZ=$(stat -f%z "$f")
UP=$(curl -s -X POST "$API/v1/uploads/probe" -H "$A" -H 'Content-Type: application/json' \
  -d "{\"spaceID\":\"$SP\",\"sha256\":\"$SHA\",\"byteSize\":$SZ,\"filename\":\"IMG_6100.jpg\",\"isAutomaticBackup\":false}" | jq '["uploadID"]')
curl -s -X PUT "$API/v1/uploads/$UP/chunk/0" -H "$A" --data-binary "@$f" >/dev/null
AID=$(curl -s -X POST "$API/v1/uploads/$UP/commit" -H "$A" -H 'Content-Type: application/json' \
  -d "{\"spaceID\":\"$SP\",\"mediaType\":\"photo\",\"mime\":\"image/jpeg\",\"width\":400,\"height\":300,\"isRaw\":false,\"burstPick\":false}" | jq '["assetID"]')
PID=$(q "select id from space_assets where space_id='$SP' and asset_id='$AID';")

rate(){ curl -s -o /dev/null -w '%{http_code}' -X PUT "$API/v1/spaces/$SP/assets/$AID/rating" \
  -H "$A" -H 'Content-Type: application/json' -d "{\"rating\":$1}"; }
tag(){ curl -s -X POST "$API/v1/spaces/$SP/assets/$AID/tags" \
  -H "$A" -H 'Content-Type: application/json' -d "$1"; }
detail(){ curl -s "$API/v1/spaces/$SP/assets/$AID/detail" -H "$A"; }

echo "=== 1. stars ==="
check "unrated to begin with" "" "$(q "select rating from space_assets where id='$PID';")"
check "four stars accepted" "204" "$(rate 4)"
check "and stored" "4" "$(q "select rating from space_assets where id='$PID';")"
check "the panel reads it back" "4" "$(detail | jq '["rating"]')"
check "re-rating replaces rather than stacks" "204" "$(rate 2)"
check "now two" "2" "$(q "select rating from space_assets where id='$PID';")"

echo
echo "=== 2. zero means unrated, not a zero ==="
check "zero accepted" "204" "$(rate 0)"
check "stored as NULL" "" "$(q "select rating from space_assets where id='$PID';")"
# Absent from the JSON, not null: a synthesized Codable omits nil Optionals,
# and the client's `rating: Int?` reads that as no rating either way.
check "and reads back as none" "None" "$(detail | jq '.get("rating")')"

echo
echo "=== 3. out of range is refused ==="
check "six stars" "400" "$(rate 6)"
check "negative" "400" "$(rate -1)"
check "and nothing was written" "" "$(q "select rating from space_assets where id='$PID';")"
_=$(rate 5)

echo
echo "=== 4. tags ==="
check "adding two returns both" "['Beach', 'Sunset']" "$(tag '{"add":["Beach","Sunset"],"remove":[]}' | jq '["tags"]')"
check "two rows in space_asset_tags" "2" "$(q "select count(*) from space_asset_tags where space_asset_id='$PID';")"
check "the panel shows them" "['Beach', 'Sunset']" "$(detail | jq '["tags"]')"

echo
echo "=== 5. one name, however it is spelled ==="
# The library ends up with Beach, beach and BEACH otherwise, meaning one thing.
_=$(tag '{"add":["BEACH"],"remove":[]}')
check "no second tag created" "1" "$(q "select count(*) from tags where space_id='$SP' and lower(name)='beach';")"
check "first spelling kept" "Beach" "$(q "select name from tags where space_id='$SP' and lower(name)='beach';")"
check "still two on the photo" "2" "$(q "select count(*) from space_asset_tags where space_asset_id='$PID';")"
# Sorted case-insensitively, so a lowercase tag doesn't file after every
# capitalised one.
check "whitespace collapses" "['Beach', 'beach day', 'Sunset']" "$(tag '{"add":["  beach   day "],"remove":[]}' | jq '["tags"]')"

echo
echo "=== 6. removing ==="
check "removes case-insensitively" "['Beach', 'Sunset']" "$(tag '{"add":[],"remove":["BEACH DAY"]}' | jq '["tags"]')"
check "and the unused tag row goes too" "0" "$(q "select count(*) from tags where space_id='$SP' and lower(name)='beach day';")"
check "an empty edit is refused" "400" \
  "$(code -X POST "$API/v1/spaces/$SP/assets/$AID/tags" -H "$A" -H 'Content-Type: application/json' -d '{"add":[],"remove":[]}')"
check "removing what isn't there is a no-op" "['Beach', 'Sunset']" "$(tag '{"add":[],"remove":["Mountains"]}' | jq '["tags"]')"

echo
echo "=== 7. the space's tag list ==="
check "lists what is in use" "['Beach', 'Sunset']" "$(curl -s "$API/v1/spaces/$SP/tags" -H "$A" | jq '["tags"]')"

echo
echo "=== 8. every change syncs ==="
BEFORE=$(q "select count(*) from change_log where space_id='$SP' and entity='space_asset' and op='update';")
_=$(rate 3); _=$(tag '{"add":["Trip"],"remove":[]}')
check "two more change_log rows" "$((BEFORE + 2))" \
  "$(q "select count(*) from change_log where space_id='$SP' and entity='space_asset' and op='update';")"

echo
echo "=== 9. who may change them ==="
c2=$(cd "$SERVER_DIR" && swift run FrameStationServer invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
R2=$(curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$c2\",\"displayName\":\"Morgan\",\"deviceName\":\"m\",\"platform\":\"ios\"}")
T2=$(echo "$R2" | jq '["token"]'); UID2=$(echo "$R2" | jq '["user"]["id"]')
A2="Authorization: Bearer $T2"
check "a stranger cannot rate it" "404" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X PUT "$API/v1/spaces/$SP/assets/$AID/rating" -H "$A2" -H 'Content-Type: application/json' -d '{"rating":1}')"
check "nor tag it" "404" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API/v1/spaces/$SP/assets/$AID/tags" -H "$A2" -H 'Content-Type: application/json' -d '{"add":["Mine"],"remove":[]}')"
check "nor read the tag list" "404" "$(code "$API/v1/spaces/$SP/tags" -H "$A2")"
check "and nothing changed" "3" "$(q "select rating from space_assets where id='$PID';")"

# A viewer is a member, so this is 403 — the photo's existence is not a secret
# from them, only writing to it is refused.
SH=$(curl -s -X POST "$API/v1/spaces" -H "$A" -H 'Content-Type: application/json' \
  -d "{\"name\":\"Family Shared\",\"memberIDs\":[]}" | jq '["id"]')
curl -s -X PUT "$API/v1/spaces/$SH/members/$UID2" -H "$A" -H 'Content-Type: application/json' \
  -d '{"role":"viewer"}' >/dev/null
curl -s -X POST "$API/v1/spaces/$SH/assets/$AID" -H "$A" -H 'Content-Type: application/json' -d '{}' >/dev/null
check "a viewer is refused" "403" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X PUT "$API/v1/spaces/$SH/assets/$AID/rating" -H "$A2" -H 'Content-Type: application/json' -d '{"rating":1}')"
check "but may read the tag list" "200" "$(code "$API/v1/spaces/$SH/tags" -H "$A2")"

echo
echo "=== 10. tags belong to the placement, not the file ==="
# The same photo, now in two libraries. Tagging it in one must not tag it in
# the other: a tag is what this library calls the photo.
SPID=$(q "select id from space_assets where space_id='$SH' and asset_id='$AID';")
curl -s -X POST "$API/v1/spaces/$SH/assets/$AID/tags" -H "$A" -H 'Content-Type: application/json' \
  -d '{"add":["Shared Only"],"remove":[]}' >/dev/null
check "the shared copy has its own tag" "1" "$(q "select count(*) from space_asset_tags where space_asset_id='$SPID';")"
check "the personal one is untouched" "3" "$(q "select count(*) from space_asset_tags where space_asset_id='$PID';")"

echo
echo "=== 11. a removed photo cannot be tagged ==="
curl -s -X DELETE "$API/v1/spaces/$SP/assets/$AID" -H "$A" >/dev/null
check "rating 404s" "404" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X PUT "$API/v1/spaces/$SP/assets/$AID/rating" -H "$A" -H 'Content-Type: application/json' -d '{"rating":1}')"
check "tagging 404s" "404" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API/v1/spaces/$SP/assets/$AID/tags" -H "$A" -H 'Content-Type: application/json' -d '{"add":["Gone"],"remove":[]}')"

echo
echo "════════════════════════════════════"
echo "  passed: $PASS   failed: $FAIL"
echo "════════════════════════════════════"
[ "$FAIL" -eq 0 ]
