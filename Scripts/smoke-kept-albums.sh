#!/bin/bash
# Curated albums are kept once shown. Improving the rules can rename an album
# or refine its dates, and add new ones, but never make one disappear: as Apple
# keeps its memories across iOS updates. Only its photos all being deleted
# removes one, and one from a feature switched off waits until it's back.
#
#   FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-kept-albums.sh
#
# Runs its own server against its own database and blob store. Changes the
# library in the database to stand in for a rule change, which moves what the
# rules find the same way.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"
export FRAMESTATION_GEONAMES_DIR="${FRAMESTATION_GEONAMES_DIR:-$(cd "$(dirname "$0")/.." && pwd)/Data/geonames}"
[ -f "$FRAMESTATION_GEONAMES_DIR/cities.tsv" ] || {
  echo "No town dataset at $FRAMESTATION_GEONAMES_DIR. Run Scripts/fetch-geonames.sh first."; exit 1; }

DB=framestation_kept; PORT=8088; API="http://127.0.0.1:$PORT"
export FRAMESTATION_DATABASE_URL="postgres://framestation:x@127.0.0.1:55432/$DB?sslmode=disable"
ROOT="$SCRATCH/kept"; rm -rf "$ROOT"; mkdir -p "$ROOT/blobroot" "$ROOT/files" "$ROOT/ids"
ROOT=$(cd "$ROOT" && pwd -P)
export FRAMESTATION_BLOB_ROOT="$ROOT/blobroot"

PASS=0; FAIL=0
q(){ psql -h 127.0.0.1 -p 55432 -U framestation -d $DB -tAqc "$1"; }
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
trap 'kill $SERVER 2>/dev/null; wait $SERVER 2>/dev/null' EXIT
for _ in $(seq 1 120); do curl -s -o /dev/null "$API/health" && break; sleep 0.5; done

redeem(){
  local code
  code=$(cd "$SERVER_DIR" && "$BIN" invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
  curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
    -d "{\"code\":\"$code\",\"displayName\":\"$1\",\"deviceName\":\"iPhone\",\"platform\":\"ios\"}"
}
R=$(redeem Keeper)
TOKEN=$(echo "$R" | jq '["token"]'); SPACE=$(echo "$R" | jq '["personalSpace"]["id"]')
USER_ID=$(echo "$R" | jq '["user"]["id"]'); AUTH="Authorization: Bearer $TOKEN"
[ -n "$SPACE" ] || { echo "setup failed"; exit 1; }

# Uploads go to INTO, as BY: the personal library unless they're set.
N=0; INTO=""; BY=""
put(){
  N=$((N + 1))
  local f="$ROOT/files/$1.jpg" sha size up space="${INTO:-$SPACE}" auth="${BY:-$AUTH}"
  vips gaussnoise "$ROOT/files/n.v" $((64 + N)) 64 >/dev/null 2>&1
  vips copy "$ROOT/files/n.v" "$f" >/dev/null 2>&1
  sha=$(shasum -a 256 "$f" | awk '{print $1}'); size=$(stat -f%z "$f")
  up=$(curl -s -X POST "$API/v1/uploads/probe" -H "$auth" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$space\",\"sha256\":\"$sha\",\"byteSize\":$size,\"filename\":\"$1.jpg\",\"isAutomaticBackup\":false}" | jq '["uploadID"]')
  curl -s -X PUT "$API/v1/uploads/$up/chunk/0" -H "$auth" --data-binary "@$f" >/dev/null
  curl -s -X POST "$API/v1/uploads/$up/commit" -H "$auth" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$space\",\"mediaType\":\"photo\",\"mime\":\"image/jpeg\",\"width\":$((64 + N)),\"height\":64,\"capturedAt\":\"$2:00Z\",\"capturedTZOffset\":0,\"latitude\":$3,\"longitude\":$4,\"isRaw\":false,\"burstPick\":false}" \
    | jq '["assetID"]' > "$ROOT/ids/$1"
}
shoot(){ local i where=${!5}
  for i in $(seq 1 "$4"); do put "$1$i" "$2T$(printf %02d $(($3 + i))):00" $where; done; }
# The NAS files each photo's place as it derives it, so an edit made before
# that would be put back.
settle(){ for _ in $(seq 1 120); do
  [ "$(q "SELECT count(*) FROM derivation_jobs WHERE state IN ('pending', 'running')")" = "0" ] && break; sleep 1
done; }

CULPEPER="38.4716 -77.9967"; ASHEVILLE="35.5951 -82.5515"; MAGIC_KINGDOM="28.4194 -81.5812"

echo "Uploading"
for d in $(seq -w 1 15); do shoot "h$d-" "2025-01-$d" 9 2 CULPEPER; done
shoot x25 2024-12-25 9 6 CULPEPER; shoot t28 2024-11-28 9 4 CULPEPER
shoot a10 2024-09-10 9 5 ASHEVILLE; shoot a11 2024-09-11 9 5 ASHEVILLE; shoot a12 2024-09-12 9 5 ASHEVILLE
for d in 10 11 12 13; do shoot "d$d-" "2025-03-$d" 9 5 MAGIC_KINGDOM; done
# August 14 three years running, busiest last: a date the page asks to name.
shoot y22 2022-08-14 9 4 CULPEPER; shoot y23 2023-08-14 9 4 CULPEPER; shoot y24 2024-08-14 6 16 CULPEPER
# An ordinary day, until somebody names it.
shoot f20 2025-02-20 9 5 CULPEPER
settle

titles_of(){ curl -s "$API/v1/spaces/$1/collections?date=2026-10-12" -H "$2" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print('|'.join(c['title'] for c in (d.get('allTrips') or []) + (d.get('allOccasions') or [])))"; }
titles(){ titles_of "$SPACE" "$AUTH"; }
card(){ curl -s "$API/v1/spaces/$SPACE/collections?date=2026-10-12" -H "$AUTH" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for c in (d.get('allTrips') or []) + (d.get('allOccasions') or []):
    if c['title'].startswith('$1'): print(c['key'] + ' ' + str(c['count']))"; }
saved(){ q "SELECT count(*) FROM curated_albums WHERE user_id = '$USER_ID' AND $1"; }
settings(){ curl -s -o /dev/null -X PUT "$API/v1/curation/settings" -H "$AUTH" \
  -H 'Content-Type: application/json' -d "$1"; }

echo "First shown"
T=$(titles)
has "a trip" "Three days in Asheville" "$T"
has "another" "Four days at Walt Disney World" "$T"
has "a holiday" "Christmas 2024" "$T"
has "and another" "Thanksgiving 2024" "$T"
has "a date to name" "Every year on August 14" "$T"
check "both trips are kept" "2" "$(saved "kind = 'trip'")"
check "and the holidays" "2" "$(saved "kind = 'day' AND is_holiday")"
check "but not the question" "0" "$(saved "key = '2024-08-14'")"
ASHEVILLE_ID=$(q "SELECT id FROM curated_albums WHERE title = 'Three days in Asheville'")
BEFORE=$(q "SELECT count(*) || ' ' || max(updated_at) FROM curated_albums")
titles >/dev/null
check "a visit that finds the same writes nothing" "$BEFORE" \
  "$(q "SELECT count(*) || ' ' || max(updated_at) FROM curated_albums")"

echo "A better name"
q "UPDATE assets SET place_name = 'Biltmore Forest, North Carolina' WHERE id IN (
     SELECT asset_id FROM space_assets WHERE filename LIKE 'a1%')" >/dev/null
has "the rules rename the trip" "Three days in Biltmore Forest" "$(titles)"
check "and the kept album takes the name" "Three days in Biltmore Forest" \
  "$(q "SELECT title FROM curated_albums WHERE id = '$ASHEVILLE_ID'")"
check "it's still the one album" "2" "$(saved "kind = 'trip'")"

echo "Refined dates"
shoot a09 2024-09-09 15 3 ASHEVILLE; settle
q "UPDATE assets SET place_name = 'Biltmore Forest, North Carolina' WHERE id IN (
     SELECT asset_id FROM space_assets WHERE filename LIKE 'a09%')" >/dev/null
has "a day more makes the trip longer" "Four days in Biltmore Forest" "$(titles)"
check "as the same album, with its new dates" "2024-09-09..2024-09-12" \
  "$(q "SELECT key FROM curated_albums WHERE id = '$ASHEVILLE_ID'")"
check "not a second one" "2" "$(saved "kind = 'trip'")"

echo "No longer found"
q "UPDATE assets SET lat = 38.4716, lon = -77.9967, destination = NULL, place_name = 'Culpeper, Virginia'
   WHERE id IN (SELECT asset_id FROM space_assets WHERE filename LIKE 'd1%')" >/dev/null
check "the rules no longer find the Disney trip, and it stays" "2025-03-10..2025-03-13 20" \
  "$(card "Four days at Walt Disney World")"
check "its photos still open" "20" "$(curl -s "$API/v1/spaces/$SPACE/collections/items?kind=trip&key=2025-03-10..2025-03-13" -H "$AUTH" | jq '["total"]')"

echo "Switched off"
settings '{"holidays":false}'
lacks "holidays off hides the kept holiday" "Christmas 2024" "$(titles)"
check "without forgetting it" "2" "$(saved "kind = 'day' AND is_holiday")"
settings '{"holidays":true}'
has "and it's back with them" "Christmas 2024" "$(titles)"

echo "A question where a kept album is"
# As if an earlier version had seen a day at the beach in that day's photos.
q "INSERT INTO curated_albums (space_id, user_id, kind, key, title, occasion, is_event, recurs_annually)
   VALUES ('$SPACE', '$USER_ID', 'day', '2024-08-14', 'A day at the beach', 'A day at the beach', true, true)" >/dev/null
T=$(titles)
has "the kept album shows" "A day at the beach" "$T"
lacks "not the question" "Every year on August 14" "$T"
settings '{"enabled":false}'
T=$(titles)
has "with curation off, the question is back" "Every year on August 14" "$T"
lacks "and the album waits" "A day at the beach" "$T"
check "without being forgotten" "1" "$(saved "key = '2024-08-14'")"
settings '{"enabled":true}'
has "until curation is on again" "A day at the beach" "$(titles)"

echo "Holidays and the person's own analysis"
# observe <photo> <analysis version> <labels>: what their phone saw in it.
observe(){ curl -s -o /dev/null -X POST "$API/v1/spaces/$SPACE/curation/observations" -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d "{\"analysisVersion\":$2,\"modelVersion\":\"smoke\",\"observations\":[{\"assetID\":\"$(cat "$ROOT/ids/$1")\",\"labels\":$3,\"aesthetic\":0.4,\"isUtility\":false,\"peopleCount\":0,\"animalCount\":0}]}"; }
TREE='[{"id":"christmas_tree","confidence":0.88},{"id":"gift","confidence":0.5}]'
SKY='[{"id":"sky","confidence":0.9},{"id":"outdoor","confidence":0.8}]'
check "holidays shown on their dates alone are provisional" "2" "$(saved "is_holiday AND provisional")"
for i in 1 2 3 4; do observe "t28$i" 1 "$SKY"; done
lacks "a Thanksgiving their photos say wasn't one goes" "Thanksgiving 2024" "$(titles)"
check "and is let go" "0" "$(saved "title LIKE 'Thanksgiving%'")"
for i in 1 2 3 4 5 6; do observe "x25$i" 1 "$TREE"; done
has "a tree confirms Christmas" "Christmas 2024" "$(titles)"
check "for good" "0" "$(saved "title = 'Christmas 2024' AND provisional")"
for i in 1 2 3 4 5 6; do observe "x25$i" 2 "$SKY"; done
has "so a later reading that disagrees can't take it away" "Christmas 2024" "$(titles)"

echo "Named by the person"
name(){ code -X PUT "$API/v1/spaces/$SPACE/collections/name" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"day\":\"2025-02-20\",\"name\":\"$1\",\"everyYear\":false}"; }
lacks "an ordinary day isn't an album" "Science fair" "$(titles)"
check "naming it" "204" "$(name "Science fair")"
has "makes it one" "Science fair" "$(titles)"
check "kept as theirs" "1" "$(saved "key = '2025-02-20' AND is_named")"
NAMED_ID=$(q "SELECT id FROM curated_albums WHERE key = '2025-02-20'")
name "Science fair finals" >/dev/null
has "a new name follows" "Science fair finals" "$(titles)"
check "on the same album" "$NAMED_ID" \
  "$(q "SELECT id FROM curated_albums WHERE key = '2025-02-20' AND title LIKE 'Science fair finals%'")"
name "" >/dev/null
lacks "taking the name back takes the album" "Science fair" "$(titles)"
check "for good" "0" "$(saved "key = '2025-02-20'")"

echo "Removed by its owner"
q "UPDATE curated_albums SET hidden = true WHERE id = '$ASHEVILLE_ID'" >/dev/null
lacks "a removed album isn't shown" "Biltmore Forest" "$(titles)"
check "nor found again" "1" "$(q "SELECT count(*) FROM curated_albums WHERE key LIKE '2024-09-%'")"

echo "Recently Deleted"
DISNEY=$(cat "$ROOT"/ids/d1*)
PICKED=$(echo "$DISNEY" | python3 -c "import sys, json; print(json.dumps(sys.stdin.read().split()))")
for id in $DISNEY; do curl -s -o /dev/null -X DELETE "$API/v1/spaces/$SPACE/assets/$id" -H "$AUTH"; done
lacks "an album whose photos are all deleted isn't shown" "Walt Disney World" "$(titles)"
check "but waits in case they come back" "1" "$(saved "title LIKE '%Disney%'")"
check "putting them back" "20" "$(curl -s -X POST "$API/v1/spaces/$SPACE/collections/deleted/restore" -H "$AUTH" \
  -H 'Content-Type: application/json' -d "{\"assetIDs\":$PICKED}" | jq '["updated"]')"
check "brings it back as it was" "2025-03-10..2025-03-13 20" "$(card "Four days at Walt Disney World")"
for id in $DISNEY; do curl -s -o /dev/null -X DELETE "$API/v1/spaces/$SPACE/assets/$id" -H "$AUTH"; done
check "deleting them for good" "20" "$(curl -s -X POST "$API/v1/spaces/$SPACE/collections/deleted/purge" -H "$AUTH" \
  -H 'Content-Type: application/json' -d "{\"assetIDs\":$PICKED}" | jq '["updated"]')"
lacks "lets the album go" "Walt Disney World" "$(titles)"
check "and its record" "0" "$(saved "title LIKE '%Disney%'")"

echo "Leaving a shared library"
R=$(redeem Member); MEMBER_AUTH="Authorization: Bearer $(echo "$R" | jq '["token"]')"
MEMBER=$(echo "$R" | jq '["user"]["id"]')
SHARED=$(curl -s -X POST "$API/v1/spaces" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"name\":\"Family\",\"memberIDs\":[\"$MEMBER\"]}" | jq '["id"]')
INTO=$SHARED; BY=$MEMBER_AUTH
for d in $(seq -w 1 10); do shoot "s$d-" "2025-05-$d" 9 2 CULPEPER; done
shoot sa1 2025-06-01 9 4 ASHEVILLE; shoot sa2 2025-06-02 9 4 ASHEVILLE; shoot sa3 2025-06-03 9 4 ASHEVILLE
INTO=""; BY=""; settle
has "a member's trip in the shared library" "A long weekend in Asheville" "$(titles_of "$SHARED" "$MEMBER_AUTH")"
has "which its owner sees too" "A long weekend in Asheville" "$(titles_of "$SHARED" "$AUTH")"
check "each keeping their own" "2" "$(q "SELECT count(*) FROM curated_albums WHERE space_id = '$SHARED'")"
check "leaving" "204" "$(code -X DELETE "$API/v1/spaces/$SHARED/members/$MEMBER" -H "$MEMBER_AUTH")"
check "takes the member's kept albums with them" "0" \
  "$(q "SELECT count(*) FROM curated_albums WHERE space_id = '$SHARED' AND user_id = '$MEMBER'")"
check "and leaves the owner's" "1" \
  "$(q "SELECT count(*) FROM curated_albums WHERE space_id = '$SHARED' AND user_id = '$USER_ID'")"
check "whose albums the member can no longer open" "404" \
  "$(code "$API/v1/spaces/$SHARED/collections?date=2026-10-12" -H "$MEMBER_AUTH")"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
