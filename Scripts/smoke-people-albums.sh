#!/bin/bash
# Albums shared with the people you pick: the family for one, two cousins for
# another, your partner for a third. Only the people in an album see it, add to
# it, or hear about it; leave everyone out and it's yours alone. Older apps
# never see one.
#
#   FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-people-albums.sh
#
# Runs its own server against its own database and blob store.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"

DB=framestation_peoplealbums; PORT=8069; API="http://127.0.0.1:$PORT"
export FRAMESTATION_DATABASE_URL="postgres://framestation:x@127.0.0.1:55432/$DB?sslmode=disable"
ROOT="$SCRATCH/peoplealbums"; rm -rf "$ROOT"; mkdir -p "$ROOT/blobroot" "$ROOT/files"
ROOT=$(cd "$ROOT" && pwd -P)
export FRAMESTATION_BLOB_ROOT="$ROOT/blobroot"
export FRAMESTATION_ACTIVITY_IDLE_SECONDS=1 FRAMESTATION_ACTIVITY_SWEEP_SECONDS=1

PASS=0; FAIL=0
q(){ psql -h 127.0.0.1 -p 55432 -U framestation -d $DB -tAqc "$1"; }
admin(){ psql -h 127.0.0.1 -p 55432 -U framestation -d postgres -tAqc "$1"; }
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; echo "      expected: $2"; echo "      actual:   $3"; FAIL=$((FAIL+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
jq(){ python3 -c "import sys,json; print(json.load(sys.stdin)$1)" 2>/dev/null; }
py(){ python3 -c "import sys,json; d=json.load(sys.stdin); print($1)" 2>/dev/null; }

(cd "$SERVER_DIR" && swift build >/dev/null 2>&1) || { echo "server build failed"; exit 1; }
BIN="$(cd "$SERVER_DIR" && swift build --show-bin-path)/FrameStationServer"
curl -s -o /dev/null "$API/health" && { echo "port $PORT already answers; stop that first"; exit 1; }
admin "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1; admin "CREATE DATABASE $DB" >/dev/null

SERVER=""
serve(){
  "$BIN" serve --hostname 127.0.0.1 --port $PORT >> "$ROOT/server.log" 2>&1 &
  SERVER=$!
  for _ in $(seq 1 120); do curl -s -o /dev/null "$API/health" && return; sleep 0.5; done
  echo "server didn't start:"; tail -20 "$ROOT/server.log"; exit 1
}
trap 'kill $SERVER 2>/dev/null; wait $SERVER 2>/dev/null; rm -rf "$ROOT/files" "$ROOT/blobroot"' EXIT

invite(){ (cd "$SERVER_DIR" && "$BIN" invite "$@" 2>/dev/null) | grep 'Invite code:' | awk '{print $3}'; }
redeem(){ curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$(invite)\",\"displayName\":\"$1\",\"deviceName\":\"iPhone\",\"platform\":\"ios\"}"; }
# call <token> <curl args…> → HTTP status, the body kept in $ROOT/reply
call(){ local token=$1; shift
  curl -s -o "$ROOT/reply" -w '%{http_code}' -H "Authorization: Bearer $token" "$@"; }
reply(){ cat "$ROOT/reply"; }
json(){ call "$1" -X "$2" "$API$3" -H 'Content-Type: application/json' -d "$4"; }
# JSON is built in these, never at a call site: macOS's bash 3.2 splits an
# escaped-quote body inside "$( )" at its commas.
ids(){ local out="" x; for x in "$@"; do out="$out${out:+,}\"$x\""; done; echo "$out"; }
newalbum(){ json "$1" POST /v1/albums "{\"name\":\"$2\",\"spaceAssetIDs\":[$3],\"memberIDs\":[$4]}"; }
libalbum(){ json "$1" POST /v1/albums "{\"name\":\"$2\",\"spaceAssetIDs\":[],\"spaceID\":\"$3\"}"; }
setpeople(){ json "$1" PUT "/v1/albums/$2/people" "{\"memberIDs\":[$3]}"; }
addto(){ json "$1" POST "/v1/albums/$2/assets" "{\"spaceAssetIDs\":[$3]}"; }
rename(){ json "$1" PATCH "/v1/albums/$2" "{\"name\":\"$3\"}"; }
report(){ json "$1" POST "/v1/spaces/$2/reports" "{\"placementID\":\"$3\",\"reason\":\"spam\"}"; }
resolve(){ json "$1" POST "/v1/spaces/$2/reports/$3/resolve" "{\"outcome\":\"$4\"}"; }
newlibrary(){ curl -s -X POST "$API/v1/spaces" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' \
  -d "{\"name\":\"$2\",\"memberIDs\":[$3]}" | jq '["id"]'; }

# upload <token> <space> <name> <width> → asset id
upload(){
  local f="$ROOT/files/$3" SHA SZ UP
  vips gaussnoise "$ROOT/files/n.v" "$4" 200 >/dev/null 2>&1
  vips copy "$ROOT/files/n.v" "$f" >/dev/null 2>&1
  SHA=$(shasum -a 256 "$f" | awk '{print $1}'); SZ=$(stat -f%z "$f")
  UP=$(curl -s -X POST "$API/v1/uploads/probe" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$2\",\"sha256\":\"$SHA\",\"byteSize\":$SZ,\"filename\":\"$3\",\"isAutomaticBackup\":false}" | jq '["uploadID"]')
  curl -s -X PUT "$API/v1/uploads/$UP/chunk/0" -H "Authorization: Bearer $1" --data-binary "@$f" >/dev/null
  curl -s -X POST "$API/v1/uploads/$UP/commit" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$2\",\"mediaType\":\"photo\",\"mime\":\"image/jpeg\",\"width\":$4,\"height\":200,\"capturedAt\":\"2025-06-01T12:00:00Z\",\"isRaw\":false,\"burstPick\":false}" | jq '["assetID"]'
}
pid(){ q "SELECT id FROM space_assets WHERE space_id = '$1' AND asset_id = '$2'"; }
# Names of the albums someone sees, as a new app asks (or an old one, with "old").
albums(){ local query="shared=true&people=true"; [ "${2:-}" = old ] && query="shared=true"
  curl -s "$API/v1/albums?$query" -H "Authorization: Bearer $1" \
    | py '",".join(sorted(a["name"] for a in d["albums"]))'; }
album(){ call "$1" "$API/v1/albums/$2" >/dev/null; reply; }
count(){ curl -s "$API/v1/albums/$2/items" -H "Authorization: Bearer $1" | py 'len(d["items"])'; }

serve
R=$(redeem Ann); AT=$(echo "$R" | jq '["token"]'); ANN=$(echo "$R" | jq '["user"]["id"]'); AP=$(echo "$R" | jq '["personalSpace"]["id"]')
R=$(redeem Ben); BT=$(echo "$R" | jq '["token"]'); BEN=$(echo "$R" | jq '["user"]["id"]'); BP=$(echo "$R" | jq '["personalSpace"]["id"]')
R=$(redeem Cat); CT=$(echo "$R" | jq '["token"]'); CAT=$(echo "$R" | jq '["user"]["id"]')
R=$(redeem Dee); DT=$(echo "$R" | jq '["token"]'); DEE=$(echo "$R" | jq '["user"]["id"]')
[ -n "$AT" ] && [ -n "$DT" ] || { echo "setup failed"; exit 1; }
P1=$(upload "$AT" "$AP" p1.jpg 301); P2=$(upload "$AT" "$AP" p2.jpg 302)
P3=$(upload "$AT" "$AP" p3.jpg 303); B1=$(upload "$BT" "$BP" b1.jpg 311)
[ -n "$P1" ] && [ -n "$B1" ] || { echo "uploads failed"; tail -20 "$ROOT/server.log"; exit 1; }

echo "The server says it can"
check "people albums are a capability" "True" "$(curl -s "$API/health" | py '"people-albums" in d["capabilities"]')"

echo "Sharing an album with someone"
check "Ann makes Iceland with Ben in it" "200" \
  "$(newalbum "$AT" Iceland "$(ids "$(pid "$AP" "$P1")")" "$(ids "$BEN")")"
ICE=$(reply | jq '["id"]'); ICESPACE=$(reply | jq '["spaceID"]')
check "it's shared with Ben" "Ben" "$(reply | py '",".join(p["displayName"] for p in d["people"])')"
check "and it's Ann's" "Ann" "$(reply | py 'd["owner"]["displayName"]')"
check "Ben sees it" "Iceland" "$(albums "$BT")"
check "to him it's shared with Ann" "Ann" "$(album "$BT" "$ICE" | py '",".join(p["displayName"] for p in d["people"])')"
check "and from Ann" "Ann" "$(album "$BT" "$ICE" | py 'd["owner"]["displayName"]')"
check "he can add to it" "True" "$(album "$BT" "$ICE" | py 'd["canAdd"]')"
check "but not change it" "False" "$(album "$BT" "$ICE" | py 'd["canManage"]')"
check "and sees its photo" "1" "$(count "$BT" "$ICE")"
check "Cat doesn't see it" "" "$(albums "$CT")"
check "or get it by its id" "404" "$(call "$CT" "$API/v1/albums/$ICE")"
check "or its photos" "404" "$(call "$CT" "$API/v1/albums/$ICE/items")"
ICEPHOTO=$(curl -s "$API/v1/albums/$ICE/items" -H "Authorization: Bearer $BT" | py 'd["items"][0]["assetID"]')
check "Ben can open the photo" "200" "$(call "$BT" "$API/v1/assets/$ICEPHOTO/original")"
check "Cat can't" "404" "$(call "$CT" "$API/v1/assets/$ICEPHOTO/original")"
check "an older app doesn't list it" "" "$(albums "$BT" old)"
check "and its space isn't a library anywhere" "0" \
  "$(call "$BT" "$API/v1/me" >/dev/null; reply | py 'sum(1 for s in d["spaces"] if s["id"] == "'"$ICESPACE"'")')"

echo "Adding to it"
check "Ben adds one of his own" "200" "$(addto "$BT" "$ICE" "$(ids "$(pid "$BP" "$B1")")")"
check "Ann sees both" "2" "$(count "$AT" "$ICE")"
for _ in $(seq 1 20); do
  [ "$(q "SELECT count(*) FROM activity_sessions WHERE closed_at IS NULL")" = "0" ] && break; sleep 0.5
done
check "and her inbox says Ben added to Iceland" "Iceland" \
  "$(call "$AT" "$API/v1/activity" >/dev/null; reply | py '",".join(i["spaceName"] for i in d["items"] if i["user"]["displayName"] == "Ben")')"

echo "Changing who's in it"
check "Ann adds Cat" "200" "$(setpeople "$AT" "$ICE" "$(ids "$BEN" "$CAT")")"
check "Cat sees it now" "Iceland" "$(albums "$CT")"
check "with both photos" "2" "$(count "$CT" "$ICE")"
check "Ann drops Ben" "200" "$(setpeople "$AT" "$ICE" "$(ids "$CAT")")"
check "Ben doesn't see it anymore" "" "$(albums "$BT")"
check "or get it" "404" "$(call "$BT" "$API/v1/albums/$ICE")"
check "what he added stays for the others" "2" "$(count "$CT" "$ICE")"
check "Cat can't change who's in it" "403" "$(setpeople "$CT" "$ICE" "$(ids "$DEE")")"
check "or rename it" "403" "$(rename "$CT" "$ICE" Mine)"
check "Ann can't leave her own" "400" "$(call "$AT" -X DELETE "$API/v1/albums/$ICE/people/me")"
check "Cat leaves" "204" "$(call "$CT" -X DELETE "$API/v1/albums/$ICE/people/me")"
check "and doesn't see it" "" "$(albums "$CT")"
check "nobody left: it's Ann's alone" "None" "$(album "$AT" "$ICE" | py 'd.get("spaceID")')"
check "with every photo still in it" "2" "$(count "$AT" "$ICE")"

echo "Sharing one that was yours alone"
check "Ann makes Trip, just hers" "200" \
  "$(newalbum "$AT" Trip "$(ids "$(pid "$AP" "$P2")" "$(pid "$AP" "$P3")")" "")"
TRIP=$(reply | jq '["id"]')
check "nobody else in it" "None" "$(reply | py 'd.get("people")')"
check "Dee doesn't see it" "" "$(albums "$DT")"
check "Ann shares it with Dee" "200" "$(setpeople "$AT" "$TRIP" "$(ids "$DEE")")"
TRIPSPACE=$(reply | jq '["spaceID"]')
check "Dee sees it" "Trip" "$(albums "$DT")"
check "with both its photos" "2" "$(count "$DT" "$TRIP")"
check "renaming it renames what its notifications say" "Big Trip" \
  "$(rename "$AT" "$TRIP" "Big Trip" >/dev/null; q "SELECT name FROM spaces WHERE id = '$TRIPSPACE'")"
check "a name nobody has is passed over" "None" \
  "$(newalbum "$AT" Solo "" "$(ids 00000000-0000-0000-0000-000000000001)" >/dev/null; reply | py 'd.get("spaceID")')"

echo "Reporting and blocking in one"
TP=$(curl -s "$API/v1/albums/$TRIP/items" -H "Authorization: Bearer $DT" | py 'd["items"][0]["id"]')
check "Dee can report a photo in it" "204" "$(report "$DT" "$TRIPSPACE" "$TP")"
check "and it's hidden from her" "1" "$(count "$DT" "$TRIP")"
check "not from Ann" "2" "$(count "$AT" "$TRIP")"
check "Dee blocks Ann" "204" "$(call "$DT" -X PUT "$API/v1/blocks/$ANN")"
check "and sees none of Ann's" "0" "$(count "$DT" "$TRIP")"
check "unblocking" "204" "$(call "$DT" -X DELETE "$API/v1/blocks/$ANN")"
check "Ann has it to review, in the album's Edit" "1" \
  "$(call "$AT" "$API/v1/spaces/$TRIPSPACE/reports" >/dev/null; reply | py 'len(d["reports"])')"
check "Dee can't read what's reported" "403" "$(call "$DT" "$API/v1/spaces/$TRIPSPACE/reports")"
TPASSET=$(q "SELECT asset_id FROM space_assets WHERE id = '$TP'")
check "Ann takes it out" "204" "$(call "$AT" -X DELETE "$API/v1/spaces/$TRIPSPACE/assets/$TPASSET")"
check "and closes its report" "204" "$(resolve "$AT" "$TRIPSPACE" "$TP" removed)"
check "it's out of the album" "1" "$(count "$AT" "$TRIP")"
check "nothing left to review" "0" \
  "$(call "$AT" "$API/v1/spaces/$TRIPSPACE/reports" >/dev/null; reply | py 'len(d["reports"])')"

echo "Taking photos out, and deleting"
TRIP2=$(curl -s "$API/v1/albums/$TRIP/items" -H "Authorization: Bearer $AT" | py 'd["items"][0]["id"]')
check "Ann takes a photo out" "204" "$(call "$AT" -X DELETE "$API/v1/albums/$TRIP/assets/$TRIP2")"
check "the album's copy goes the way a removed photo does" "t" \
  "$(q "SELECT deleted_at IS NOT NULL FROM space_assets WHERE id = '$TRIP2'")"
check "the original stays in her library" "f" \
  "$(q "SELECT deleted_at IS NOT NULL FROM space_assets WHERE space_id = '$AP' AND asset_id = '$P2'")"
check "Ann deletes it" "204" "$(call "$AT" -X DELETE "$API/v1/albums/$TRIP")"
check "it's gone for Dee" "" "$(albums "$DT")"
check "its copies are on the clock" "0" \
  "$(q "SELECT count(*) FROM space_assets WHERE space_id = '$TRIPSPACE' AND deleted_at IS NULL")"
check "and nobody is left in its space" "0" "$(q "SELECT count(*) FROM space_members WHERE space_id = '$TRIPSPACE'")"
check "Ann's own photos are untouched" "3" \
  "$(q "SELECT count(*) FROM space_assets WHERE space_id = '$AP' AND deleted_at IS NULL")"

echo "A library's albums stay the library's"
LIB=$(newlibrary "$AT" "Family Shared" "$(ids "$BEN")")
check "Ann makes an album in Family Shared" "200" "$(libalbum "$AT" Ours "$LIB")"
OURS=$(reply | jq '["id"]')
check "it isn't shared with people" "None" "$(reply | py 'd.get("people")')"
check "so who's in it isn't the album's to change" "400" "$(setpeople "$AT" "$OURS" "$(ids "$DEE")")"
check "an older app still lists it" "Ours" "$(albums "$BT" old)"

echo "When the owner deletes their account"
check "Ann shares Beach with Ben" "200" \
  "$(newalbum "$AT" Beach "$(ids "$(pid "$AP" "$P1")")" "$(ids "$BEN")")"
BEACH=$(reply | jq '["id"]')
check "Ann deletes her account" "204" "$(call "$AT" -X DELETE "$API/v1/me")"
check "Beach passes to Ben" "True" "$(album "$BT" "$BEACH" | py 'd["canManage"]')"
check "with its photo" "1" "$(count "$BT" "$BEACH")"
check "Iceland, hers alone, goes with her" "0" "$(q "SELECT count(*) FROM albums WHERE id = '$ICE'")"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
