#!/bin/bash
# Two kinds of album: yours alone, which nobody else can see or learn exists,
# and family albums in a shared library, which every member sees. A family
# album holds only its library's photos; one added from your own library is
# shared in, original left where it was. Its creator or the library's owner
# renames and deletes it; viewers only look; outsiders get a 404.
#
#   FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-family-albums.sh
#
# Runs its own server against its own database and blob store.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"

DB=framestation_family_albums; PORT=8090; API="http://127.0.0.1:$PORT"
export FRAMESTATION_DATABASE_URL="postgres://framestation:x@127.0.0.1:55432/$DB?sslmode=disable"
ROOT="$SCRATCH/family-albums"; rm -rf "$ROOT"; mkdir -p "$ROOT/blobroot" "$ROOT/files"
ROOT=$(cd "$ROOT" && pwd -P)
export FRAMESTATION_BLOB_ROOT="$ROOT/blobroot"

PASS=0; FAIL=0
q(){ psql "$FRAMESTATION_DATABASE_URL" -tAqc "$1"; }
admin(){ psql -h 127.0.0.1 -p 55432 -U framestation -d postgres -tAqc "$1"; }
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; echo "      expected: $2"; echo "      actual:   $3"; FAIL=$((FAIL+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
has(){ case "$3" in *"$2"*) ok "$1";; *) bad "$1" "contains '$2'" "$3";; esac; }
lacks(){ case "$3" in *"$2"*) bad "$1" "no '$2'" "$3";; *) ok "$1";; esac; }
jq(){ python3 -c "import sys,json; print(json.load(sys.stdin)$1)" 2>/dev/null; }
code(){ curl -s -o /dev/null -w '%{http_code}' "$@"; }

(cd "$SERVER_DIR" && swift build >/dev/null 2>&1) || { echo "server build failed"; exit 1; }
BIN="$(cd "$SERVER_DIR" && swift build --show-bin-path)/FrameStationServer"
admin "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1; admin "CREATE DATABASE $DB" >/dev/null
"$BIN" serve --hostname 127.0.0.1 --port $PORT > "$ROOT/server.log" 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null; wait $SERVER 2>/dev/null; admin "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1' EXIT
for _ in $(seq 1 120); do curl -s -o /dev/null "$API/health" && break; sleep 0.5; done

# signin <name> → "token user-id personal-space-id"
signin(){
  local c R
  c=$(cd "$SERVER_DIR" && "$BIN" invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
  R=$(curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
    -d "{\"code\":\"$c\",\"displayName\":\"$1\",\"deviceName\":\"iPhone\",\"platform\":\"ios\"}")
  echo "$(echo "$R" | jq '["token"]') $(echo "$R" | jq '["user"]["id"]') $(echo "$R" | jq '["personalSpace"]["id"]')"
}
read -r OT O OP <<<"$(signin Owner)"; read -r MT M MP <<<"$(signin Member)"
read -r VT V VP <<<"$(signin Viewer)"; read -r XT X XP <<<"$(signin Outsider)"
AO="Authorization: Bearer $OT"; AM="Authorization: Bearer $MT"
AV="Authorization: Bearer $VT"; AX="Authorization: Bearer $XT"
[ -n "$OP" ] && [ -n "$XP" ] || { echo "setup failed"; exit 1; }

FAMILY=$(curl -s -X POST "$API/v1/spaces" -H "$AO" -H 'Content-Type: application/json' \
  -d "{\"name\":\"Family\",\"memberIDs\":[\"$M\"]}" | jq '["id"]')
curl -s -o /dev/null -X PUT "$API/v1/spaces/$FAMILY/members/$V" -H "$AO" \
  -H 'Content-Type: application/json' -d '{"role":"viewer"}'
[ -n "$FAMILY" ] || { echo "no shared library"; exit 1; }

# put <auth> <space> <name> → the placement's id
N=0
put(){
  N=$((N + 1))
  local f="$ROOT/files/$3.jpg" sha size up
  vips gaussnoise "$ROOT/files/n.v" $((64 + N)) 64 >/dev/null 2>&1
  vips copy "$ROOT/files/n.v" "$f" >/dev/null 2>&1
  sha=$(shasum -a 256 "$f" | awk '{print $1}'); size=$(stat -f%z "$f")
  up=$(curl -s -X POST "$API/v1/uploads/probe" -H "$1" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$2\",\"sha256\":\"$sha\",\"byteSize\":$size,\"filename\":\"$3.jpg\",\"isAutomaticBackup\":false}" | jq '["uploadID"]')
  curl -s -X PUT "$API/v1/uploads/$up/chunk/0" -H "$1" --data-binary "@$f" >/dev/null
  curl -s -X POST "$API/v1/uploads/$up/commit" -H "$1" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$2\",\"mediaType\":\"photo\",\"mime\":\"image/jpeg\",\"width\":$((64 + N)),\"height\":64,\"capturedAt\":\"2025-06-01T12:00:00Z\",\"capturedTZOffset\":0,\"isRaw\":false,\"burstPick\":false}" \
    | jq '["spaceAssetID"]'
}
OP1=$(put "$AO" "$OP" op1); OP2=$(put "$AO" "$OP" op2); MP1=$(put "$AM" "$MP" mp1)
F1=$(put "$AO" "$FAMILY" f1); F2=$(put "$AO" "$FAMILY" f2); F3=$(put "$AM" "$FAMILY" f3)
XP1=$(put "$AX" "$XP" xp1)
[ -n "$F3" ] && [ -n "$XP1" ] || { echo "uploads failed"; exit 1; }

# names <auth> [shared] → album names the person is shown, joined with |
names(){ curl -s "$API/v1/albums${2:+?shared=true}" -H "$1" | python3 -c "
import sys, json
print('|'.join(a['name'] for a in json.load(sys.stdin)['albums']))"; }
# field <auth> <album> <key> → that field of the album as the person sees it;
# None for one the server leaves out, as it does a personal album's library.
field(){ curl -s "$API/v1/albums/$2" -H "$1" | jq ".get(\"$3\")"; }
add(){ curl -s -o /dev/null -w '%{http_code}' -X POST "$API/v1/albums/$2/assets" -H "$1" \
  -H 'Content-Type: application/json' -d "{\"spaceAssetIDs\":[\"$3\"]}"; }
take(){ code -X DELETE "$API/v1/albums/$2/assets/$3" -H "$1"; }
rename(){ code -X PATCH "$API/v1/albums/$2" -H "$1" -H 'Content-Type: application/json' -d "{\"name\":\"$3\"}"; }
create(){ curl -s -X POST "$API/v1/albums" -H "$1" -H 'Content-Type: application/json' -d "$2"; }

echo "Yours alone"
MINE=$(create "$AO" "{\"name\":\"Mine\",\"spaceAssetIDs\":[\"$OP1\"]}" | jq '["id"]')
check "an album is yours alone unless you say otherwise" "None" "$(field "$AO" "$MINE" spaceID)"
lacks "a member of your library doesn't see it" "Mine" "$(names "$AM" shared)"
check "nor can they open it" "404" "$(code "$API/v1/albums/$MINE" -H "$AM")"
check "add to it" "404" "$(add "$AM" "$MINE" "$F1")"
check "or delete it" "404" "$(code -X DELETE "$API/v1/albums/$MINE" -H "$AM")"
check "it can still hold a family photo, privately" "200" "$(add "$AO" "$MINE" "$F2")"
check "two photos" "2" "$(field "$AO" "$MINE" itemCount)"

echo "A family album"
BEACH=$(create "$AO" "{\"name\":\"Beach Week\",\"spaceID\":\"$FAMILY\",\"spaceAssetIDs\":[\"$F1\"]}" | jq '["id"]')
check "belongs to its library" "$FAMILY" "$(field "$AO" "$BEACH" spaceID)"
has "every member sees it" "Beach Week" "$(names "$AM" shared)"
lacks "but not in an older app's list, which would call it theirs" "Beach Week" "$(names "$AM")"
check "a member can add to it" "True" "$(field "$AM" "$BEACH" canAdd)"
check "but not rename or delete it" "False" "$(field "$AM" "$BEACH" canManage)"
has "a viewer sees it" "Beach Week" "$(names "$AV" shared)"
check "and can't add" "False" "$(field "$AV" "$BEACH" canAdd)"
lacks "someone outside the library doesn't see it" "Beach Week" "$(names "$AX" shared)"
check "nor learn it exists" "404" "$(code "$API/v1/albums/$BEACH" -H "$AX")"
check "its photos aren't theirs to see" "404" "$(code "$API/v1/albums/$BEACH/items" -H "$AX")"
check "nor to add to" "404" "$(add "$AX" "$BEACH" "$XP1")"
check "nor to delete" "404" "$(code -X DELETE "$API/v1/albums/$BEACH" -H "$AX")"

echo "Shared libraries as album cards"
# cards <auth> [shared] → each library card as "name members items cover?", or
# none when the list carries no cards at all.
cards(){ curl -s "$API/v1/albums${2:+?shared=true}" -H "$1" | python3 -c "
import sys, json
libs = json.load(sys.stdin).get('libraries')
print('none' if libs is None else '|'.join('%s %d %d %s' % (
    l['name'], l['memberCount'], l['itemCount'], 'cover' if l.get('coverAssetID') else 'nocover')
    for l in libs))"; }
check "a member's list has the library as a card, with its cover" "Family 3 3 cover" "$(cards "$AM" shared)"
check "so does a viewer's" "Family 3 3 cover" "$(cards "$AV" shared)"
check "someone outside it gets no card for it" "" "$(cards "$AX" shared)"
check "and an older app's list has no cards" "none" "$(cards "$AM")"

echo "Adding"
check "a member adds a library photo" "200" "$(add "$AM" "$BEACH" "$F3")"
BEFORE=$(q "SELECT count(*) FROM space_assets WHERE space_id = '$FAMILY' AND deleted_at IS NULL")
TOLD=$(q "SELECT COALESCE(sum(photo_count), 0) FROM activity_sessions WHERE space_id = '$FAMILY' AND user_id = '$M'")
check "and one of their own" "200" "$(add "$AM" "$BEACH" "$MP1")"
check "which is shared into the library" "$((BEFORE + 1))" \
  "$(q "SELECT count(*) FROM space_assets WHERE space_id = '$FAMILY' AND deleted_at IS NULL")"
check "with the family told, as any share is" "$((TOLD + 1))" \
  "$(q "SELECT COALESCE(sum(photo_count), 0) FROM activity_sessions WHERE space_id = '$FAMILY' AND user_id = '$M'")"
check "and stays in their own library too" "f" \
  "$(q "SELECT deleted_at IS NOT NULL FROM space_assets WHERE id = '$MP1'")"
check "three photos" "3" "$(field "$AM" "$BEACH" itemCount)"
check "every one of them from the library" "0" "$(q "SELECT count(*) FROM album_assets aa
  JOIN space_assets sa ON sa.id = aa.space_asset_id WHERE aa.album_id = '$BEACH' AND sa.space_id <> '$FAMILY'")"
check "a viewer can't add" "403" "$(add "$AV" "$BEACH" "$F2")"
add "$AM" "$BEACH" "$XP1" >/dev/null; add "$AM" "$BEACH" "$OP2" >/dev/null
check "nor can anyone add a photo they can't see" "3" "$(field "$AM" "$BEACH" itemCount)"

echo "Sharing into the library, the other way in"
# share <placement> → the share route's answer for that photo, from the member's
# own library into the family's. The same path the album used above.
share(){ local asset; asset=$(q "SELECT asset_id FROM space_assets WHERE id = '$1'")
  curl -s -X POST "$API/v1/spaces/$MP/assets/share" -H "$AM" -H 'Content-Type: application/json' \
    -d "{\"assetIDs\":[\"$asset\"],\"destinationSpaceID\":\"$FAMILY\"}"; }
MP2=$(put "$AM" "$MP" mp2)
check "a photo shares in" "1" "$(share "$MP2" | jq '["shared"]')"
check "the album's share and this one are the same: no second copy" "0 1" \
  "$(share "$MP1" | python3 -c "import sys, json; d = json.load(sys.stdin); print(d['shared'], len(d['alreadySharedAssetIDs']))")"

echo "Taking photos out"
check "a viewer can't" "403" "$(take "$AV" "$BEACH" "$F1")"
check "nor a member, someone else's" "403" "$(take "$AM" "$BEACH" "$F1")"
check "a member takes out what they added" "204" "$(take "$AM" "$BEACH" "$F3")"
SHARED_IN=$(q "SELECT aa.space_asset_id FROM album_assets aa WHERE aa.album_id = '$BEACH' AND aa.added_by = '$M'")
check "the creator takes out anything" "204" "$(take "$AO" "$BEACH" "$SHARED_IN")"
check "and the photos stay in the library" "f" \
  "$(q "SELECT deleted_at IS NOT NULL FROM space_assets WHERE id = '$F3'")"

echo "Renaming and deleting"
check "a member can't rename someone else's" "403" "$(rename "$AM" "$BEACH" "Our Beach")"
POOL=$(create "$AM" "{\"name\":\"Pool Day\",\"spaceID\":\"$FAMILY\",\"spaceAssetIDs\":[\"$F2\"]}" | jq '["id"]')
check "their own, they can" "True" "$(field "$AM" "$POOL" canManage)"
check "and so can the library's owner" "200" "$(rename "$AO" "$POOL" "Pool Party")"
check "a viewer can't delete it" "403" "$(code -X DELETE "$API/v1/albums/$POOL" -H "$AV")"
LIBRARY=$(q "SELECT count(*) FROM space_assets WHERE space_id = '$FAMILY' AND deleted_at IS NULL")
check "the owner can" "204" "$(code -X DELETE "$API/v1/albums/$POOL" -H "$AO")"
lacks "it's gone for everyone" "Pool Party" "$(names "$AM" shared)"
check "and its photos aren't" "$LIBRARY" \
  "$(q "SELECT count(*) FROM space_assets WHERE space_id = '$FAMILY' AND deleted_at IS NULL")"

echo "Making one"
# attempt <auth> <library> → the status of making a family album there. The
# JSON is built here: escaped quotes inside "$(...)" make bash brace-expand it.
attempt(){ code -X POST "$API/v1/albums" -H "$1" -H 'Content-Type: application/json' \
  -d "{\"name\":\"Try\",\"spaceID\":\"$2\",\"spaceAssetIDs\":[]}"; }
check "a viewer can't make a family album" "403" "$(attempt "$AV" "$FAMILY")"
check "nobody can put one in a library they're not in" "404" "$(attempt "$AX" "$FAMILY")"
check "and a personal library has none" "400" "$(attempt "$AO" "$OP")"
check "a member can" "200" "$(attempt "$AM" "$FAMILY")"

echo "Leaving the library"
check "leaving" "204" "$(code -X DELETE "$API/v1/spaces/$FAMILY/members/$M" -H "$AM")"
lacks "takes its albums off your list" "Beach Week" "$(names "$AM" shared)"
check "and out of reach" "404" "$(code "$API/v1/albums/$BEACH" -H "$AM")"
has "they stay for everyone still in it" "Beach Week" "$(names "$AO" shared)"
check "the list says it includes family albums" "True" \
  "$(curl -s "$API/v1/albums?shared=true" -H "$AO" | jq '["includesFamilyAlbums"]')"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
