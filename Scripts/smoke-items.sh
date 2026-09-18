#!/bin/bash
# Smoke test: every endpoint that builds a timeline item actually answers.
#
# Five queries across four controllers hand rows to `TimelineController.ItemRow`,
# and each used to write its own column list. Swift's synthesised `Decodable`
# requires a key for every non-optional property — the `var isBurst: Bool = false`
# default notwithstanding — so a list that fell behind produced HTTP 400 the
# moment its query matched anything, and nothing short of real data revealed it.
#
# It happened twice. Collections and the media-type filter went first and were
# fixed in place; search and an album's contents went next and stayed broken,
# because the lesson had been applied to one file rather than to the shape of the
# problem. The column list is shared now — see `TimelineController.itemColumns` —
# and this is what makes that stay true.
#
# The trap is that an empty result is a 200. Every check here therefore runs
# against a space with photographs in it and asserts on the count, not just the
# status: a search that matches nothing and a search that is broken look
# identical from the outside.
#
#   FRAMESTATION_API=http://127.0.0.1:8099 ./Scripts/smoke-items.sh
set -uo pipefail

API="${FRAMESTATION_API:-http://127.0.0.1:8099}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"
export PGPASSWORD="${PGPASSWORD:-x}"
PSQL="psql -h 127.0.0.1 -p 55432 -U framestation -d framestation -tAqc"

SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
export FRAMESTATION_DATABASE_URL="${FRAMESTATION_DATABASE_URL:-postgres://framestation:x@127.0.0.1:55432/framestation?sslmode=disable}"
export FRAMESTATION_BLOB_ROOT="${FRAMESTATION_BLOB_ROOT:-$SCRATCH/blobroot}"
mkdir -p "$FRAMESTATION_BLOB_ROOT"

DEVICE_NAME="SmokeItems-$$"
ALBUM_NAME="Smoke Items $$"
PASS=0; FAIL=0

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $1"; echo "      expected: $2"; echo "      actual:   $3"; FAIL=$((FAIL+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
jq_get() { python3 -c "import sys,json; d=json.load(sys.stdin); print($1)" 2>/dev/null; }

get() { curl -s -H "Authorization: Bearer $TOKEN" "$API$1"; }
status() { curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" "$API$1"; }

cleanup() {
    [ -n "${ALBUM:-}" ] && $PSQL "DELETE FROM albums WHERE id='$ALBUM';" >/dev/null 2>&1
    [ -n "${USER_ID:-}" ] && $PSQL "DELETE FROM space_members WHERE user_id='$USER_ID';" >/dev/null 2>&1
    $PSQL "DELETE FROM devices WHERE name='$DEVICE_NAME';" >/dev/null 2>&1
}
trap cleanup EXIT

# -------------------------------------------------------------------- setup ---
echo "=== setup ==="
# The busiest space in the database, so every check below has something to find.
SPACE=$($PSQL "SELECT sa.space_id FROM space_assets sa
               WHERE sa.deleted_at IS NULL
               GROUP BY sa.space_id ORDER BY count(*) DESC LIMIT 1;")
[ -n "$SPACE" ] || { echo "  ✗ no space with photographs — upload something first"; exit 1; }

CODE=$(cd "$SERVER_DIR" && swift run FrameStationServer invite 2>/dev/null \
    | grep "Invite code:" | awk '{print $3}')
R=$(curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
    -d "{\"code\":\"$CODE\",\"displayName\":\"Smoke Items\",\"deviceName\":\"$DEVICE_NAME\",\"platform\":\"ios\"}")
TOKEN=$(echo "$R" | jq_get 'd["token"]')
[ -n "$TOKEN" ] || { echo "  ✗ could not redeem an invite — is the server up on $API?"; exit 1; }

USER_ID=$($PSQL "SELECT user_id FROM devices WHERE name='$DEVICE_NAME';")
$PSQL "INSERT INTO space_members (space_id, user_id, role)
       VALUES ('$SPACE','$USER_ID','viewer') ON CONFLICT DO NOTHING;" >/dev/null
echo "  space $SPACE with $($PSQL "SELECT count(*) FROM space_assets WHERE space_id='$SPACE' AND deleted_at IS NULL;") items"

# ------------------------------------------------------------ the timeline ---
echo "=== the timeline, which has never been the broken one ==="
BUCKET=$(get "/v1/spaces/$SPACE/timeline" | jq_get 'd["buckets"][0]["key"]')
check "manifest answers" "200" "$(status "/v1/spaces/$SPACE/timeline")"
COUNT=$(get "/v1/spaces/$SPACE/timeline/$BUCKET" | jq_get 'len(d["items"])')
[ "${COUNT:-0}" -gt 0 ] && ok "a bucket returns items ($COUNT)" \
    || bad "a bucket returns items" "> 0" "${COUNT:-none}"

# --------------------------------------------------------------- an album ---
echo "=== an album's contents, which answered 400 for every non-empty album ==="
ASSET=$($PSQL "SELECT id FROM space_assets
               WHERE space_id='$SPACE' AND deleted_at IS NULL LIMIT 1;")
ALBUM=$(curl -s -X POST "$API/v1/albums" -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' -H "X-FrameStation-Space: $SPACE" \
    -d "{\"name\":\"$ALBUM_NAME\",\"spaceAssetIDs\":[\"$ASSET\"]}" | jq_get 'd["id"]')
[ -n "$ALBUM" ] || { echo "  ✗ could not create an album"; exit 1; }
COUNT=$(get "/v1/albums/$ALBUM/items" | jq_get 'len(d["items"])')
check "an album with one photo returns one" "1" "${COUNT:-none}"

# ----------------------------------------------------------------- search ---
echo "=== search, which answered 400 for every query that matched ==="
# A place that genuinely exists in this library, so a zero here is a failure
# rather than a library without geotags.
PLACE=$($PSQL "SELECT a.place_name FROM space_assets sa
               JOIN assets a ON a.id = sa.asset_id
               WHERE sa.space_id='$SPACE' AND sa.deleted_at IS NULL
                 AND a.place_name IS NOT NULL
               GROUP BY a.place_name ORDER BY count(*) DESC LIMIT 1;")
if [ -n "$PLACE" ]; then
    NEEDLE=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$PLACE")
    TOTAL=$(get "/v1/spaces/$SPACE/search?place=$NEEDLE&limit=5" | jq_get 'd["total"]')
    [ "${TOTAL:-0}" -gt 0 ] && ok "searching \"$PLACE\" finds $TOTAL" \
        || bad "searching \"$PLACE\"" "> 0" "${TOTAL:-none}"
    COUNT=$(get "/v1/spaces/$SPACE/search?place=$NEEDLE&limit=5" | jq_get 'len(d["items"])')
    [ "${COUNT:-0}" -gt 0 ] && ok "and returns the items themselves ($COUNT)" \
        || bad "and returns the items themselves" "> 0" "${COUNT:-none}"
else
    echo "  — no geotagged photos in this space, search unchecked"
fi
check "the places list answers" "200" "$(status "/v1/spaces/$SPACE/places")"

# ------------------------------------------------------------ collections ---
echo "=== collections, fixed once before in place ==="
check "the page answers" "200" "$(status "/v1/spaces/$SPACE/collections")"
check "a collection's items answer" "200" \
    "$(status "/v1/spaces/$SPACE/collections/items?kind=recentlyAdded&key=recentlyAdded&limit=5")"
check "recently deleted answers" "200" "$(status "/v1/spaces/$SPACE/collections/deleted")"

# ---------------------------------------------------------------- summary ---
echo
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
