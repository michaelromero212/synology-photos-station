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
#   FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-items.sh
#
# Runs its own server against its own database and blob store, with photos of
# its own for every endpoint to find.
set -uo pipefail

SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"

DB=framestation_items; PORT=8081; API="http://127.0.0.1:$PORT"
export FRAMESTATION_DATABASE_URL="postgres://framestation:x@127.0.0.1:55432/$DB?sslmode=disable"
ROOT="$SCRATCH/items"; rm -rf "$ROOT"; mkdir -p "$ROOT/blobroot" "$ROOT/files"
ROOT=$(cd "$ROOT" && pwd -P)
export FRAMESTATION_BLOB_ROOT="$ROOT/blobroot"
PSQL="psql -h 127.0.0.1 -p 55432 -U framestation -d $DB -tAqc"
admin(){ psql -h 127.0.0.1 -p 55432 -U framestation -d postgres -tAqc "$1"; }

PASS=0; FAIL=0

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $1"; echo "      expected: $2"; echo "      actual:   $3"; FAIL=$((FAIL+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
jq_get() { python3 -c "import sys,json; d=json.load(sys.stdin); print($1)" 2>/dev/null; }

get() { curl -s -H "Authorization: Bearer $TOKEN" "$API$1"; }
status() { curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" "$API$1"; }

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

# -------------------------------------------------------------------- setup ---
echo "=== setup ==="
CODE=$(cd "$SERVER_DIR" && "$BIN" invite 2>/dev/null \
    | grep "Invite code:" | awk '{print $3}')
R=$(curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
    -d "{\"code\":\"$CODE\",\"displayName\":\"Smoke Items\",\"deviceName\":\"iPhone\",\"platform\":\"ios\"}")
TOKEN=$(echo "$R" | jq_get 'd["token"]')
SPACE=$(echo "$R" | jq_get 'd["personalSpace"]["id"]')
[ -n "$TOKEN" ] || { echo "  ✗ could not redeem an invite"; tail -20 "$ROOT/server.log"; exit 1; }

# upload <name> <width> <capturedAt> → asset id. The width keeps every file's
# bytes different, so nothing is deduplicated into another.
upload() {
    local f="$ROOT/files/$1" sha size up
    vips gaussnoise "$ROOT/files/n.v" "$2" 300 >/dev/null 2>&1
    vips copy "$ROOT/files/n.v" "$f" >/dev/null 2>&1
    sha=$(shasum -a 256 "$f" | awk '{print $1}'); size=$(stat -f%z "$f")
    up=$(curl -s -X POST "$API/v1/uploads/probe" -H "Authorization: Bearer $TOKEN" \
        -H 'Content-Type: application/json' \
        -d "{\"spaceID\":\"$SPACE\",\"sha256\":\"$sha\",\"byteSize\":$size,\"filename\":\"$1\",\"isAutomaticBackup\":false}" \
        | jq_get 'd["uploadID"]')
    curl -s -X PUT "$API/v1/uploads/$up/chunk/0" -H "Authorization: Bearer $TOKEN" \
        --data-binary "@$f" >/dev/null
    curl -s -X POST "$API/v1/uploads/$up/commit" -H "Authorization: Bearer $TOKEN" \
        -H 'Content-Type: application/json' \
        -d "{\"spaceID\":\"$SPACE\",\"mediaType\":\"photo\",\"mime\":\"image/jpeg\",\"width\":$2,\"height\":300,\"capturedAt\":\"$3\",\"capturedTZOffset\":0,\"isRaw\":false,\"burstPick\":false}" \
        | jq_get 'd["assetID"]'
}
A1=$(upload a1.jpg 401 2026-07-18T16:00:00Z)
A2=$(upload a2.jpg 402 2026-07-18T17:00:00Z)
A3=$(upload a3.jpg 403 2026-07-17T12:00:00Z)
A4=$(upload a4.jpg 404 2026-07-17T13:00:00Z)
[ -n "$A1" ] && [ -n "$A4" ] || { echo "  ✗ uploads failed"; tail -20 "$ROOT/server.log"; exit 1; }
# Named here rather than from GPS: the town dataset is smoke-geocode.sh's to
# test, and search only needs a place on the photos to match.
PLACE="Culpeper, Virginia"
$PSQL "UPDATE assets SET place_name = '$PLACE' WHERE id IN ('$A1','$A2');" >/dev/null
# One removed, so Recently Deleted has something in it.
curl -s -o /dev/null -X DELETE "$API/v1/spaces/$SPACE/assets/$A4" -H "Authorization: Bearer $TOKEN"
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
ASSET=$($PSQL "SELECT id FROM space_assets WHERE asset_id='$A1';")
ALBUM=$(curl -s -X POST "$API/v1/albums" -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' -H "X-FrameStation-Space: $SPACE" \
    -d "{\"name\":\"Smoke Items\",\"spaceAssetIDs\":[\"$ASSET\"]}" | jq_get 'd["id"]')
[ -n "$ALBUM" ] || { echo "  ✗ could not create an album"; exit 1; }
COUNT=$(get "/v1/albums/$ALBUM/items" | jq_get 'len(d["items"])')
check "an album with one photo returns one" "1" "${COUNT:-none}"

# ----------------------------------------------------------------- search ---
echo "=== search, which answered 400 for every query that matched ==="
NEEDLE=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$PLACE")
TOTAL=$(get "/v1/spaces/$SPACE/search?place=$NEEDLE&limit=5" | jq_get 'd["total"]')
[ "${TOTAL:-0}" -gt 0 ] && ok "searching \"$PLACE\" finds $TOTAL" \
    || bad "searching \"$PLACE\"" "> 0" "${TOTAL:-none}"
COUNT=$(get "/v1/spaces/$SPACE/search?place=$NEEDLE&limit=5" | jq_get 'len(d["items"])')
[ "${COUNT:-0}" -gt 0 ] && ok "and returns the items themselves ($COUNT)" \
    || bad "and returns the items themselves" "> 0" "${COUNT:-none}"
check "the places list answers" "200" "$(status "/v1/spaces/$SPACE/places")"

# ------------------------------------------------------------ collections ---
echo "=== collections, fixed once before in place ==="
check "the page answers" "200" "$(status "/v1/spaces/$SPACE/collections")"
COUNT=$(get "/v1/spaces/$SPACE/collections/items?kind=recentlyAdded&key=recentlyAdded&limit=5" \
    | jq_get 'len(d["items"])')
[ "${COUNT:-0}" -gt 0 ] && ok "a collection's items come back ($COUNT)" \
    || bad "a collection's items come back" "> 0" "${COUNT:-none}"
COUNT=$(get "/v1/spaces/$SPACE/collections/deleted" | jq_get 'len(d["items"])')
check "recently deleted returns the one removed" "1" "${COUNT:-none}"

# ---------------------------------------------------------------- summary ---
echo
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
