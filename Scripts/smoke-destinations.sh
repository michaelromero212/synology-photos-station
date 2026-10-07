#!/bin/bash
# Places people call by their own names. A photo taken at Walt Disney World or
# on the Outer Banks goes by that name on its day's header, in Places, in
# search and in the Information panel, and a trip there is named for it:
# "Four days at Walt Disney World", where it used to be "Four days in Florida"
# because the parks sit nearest three different suburbs. A trip between the
# parks and a rental in Kissimmee is "Five days in Orlando".
#
#   FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-destinations.sh
#
# Runs its own server against its own database and blob store. Needs the town
# dataset (Scripts/fetch-geonames.sh): half of what it checks is the difference
# between a town and the name a place goes by.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"
export FRAMESTATION_GEONAMES_DIR="${FRAMESTATION_GEONAMES_DIR:-$(cd "$(dirname "$0")/.." && pwd)/Data/geonames}"
[ -f "$FRAMESTATION_GEONAMES_DIR/cities.tsv" ] || {
  echo "No town dataset at $FRAMESTATION_GEONAMES_DIR. Run Scripts/fetch-geonames.sh first."; exit 1; }

DB=framestation_destinations; PORT=8091; API="http://127.0.0.1:$PORT"
export FRAMESTATION_DATABASE_URL="postgres://framestation:x@127.0.0.1:55432/$DB?sslmode=disable"
ROOT="$SCRATCH/destinations"; rm -rf "$ROOT"; mkdir -p "$ROOT/blobroot" "$ROOT/files" "$ROOT/ids"
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

(cd "$SERVER_DIR" && swift build >/dev/null 2>&1) || { echo "server build failed"; exit 1; }
BIN="$(cd "$SERVER_DIR" && swift build --show-bin-path)/FrameStationServer"
admin "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1; admin "CREATE DATABASE $DB" >/dev/null

SERVER=""
serve(){
  "$BIN" serve --hostname 127.0.0.1 --port $PORT >> "$ROOT/server.log" 2>&1 &
  SERVER=$!
  for _ in $(seq 1 120); do curl -s -o /dev/null "$API/health" && return; sleep 0.5; done
  echo "server didn't start:"; tail -20 "$ROOT/server.log"; exit 1
}
stop(){ kill "$SERVER" 2>/dev/null; wait "$SERVER" 2>/dev/null; }
trap stop EXIT
serve

CODE=$(cd "$SERVER_DIR" && "$BIN" invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
R=$(curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$CODE\",\"displayName\":\"Traveler\",\"deviceName\":\"iPhone\",\"platform\":\"ios\"}")
TOKEN=$(echo "$R" | jq '["token"]'); SPACE=$(echo "$R" | jq '["personalSpace"]["id"]')
AUTH="Authorization: Bearer $TOKEN"
[ -n "$SPACE" ] || { echo "setup failed"; exit 1; }

# put <name> <local time> <lat> <lon>: uploads a photo taken there and then,
# keeping its asset id in $ROOT/ids/<name>. Each file is a different width, so
# none is deduplicated into another.
N=0
put(){
  N=$((N + 1))
  local f="$ROOT/files/$1.jpg" sha size up
  vips gaussnoise "$ROOT/files/n.v" $((64 + N)) 64 >/dev/null 2>&1
  vips copy "$ROOT/files/n.v" "$f" >/dev/null 2>&1
  sha=$(shasum -a 256 "$f" | awk '{print $1}'); size=$(stat -f%z "$f")
  up=$(curl -s -X POST "$API/v1/uploads/probe" -H "$AUTH" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$SPACE\",\"sha256\":\"$sha\",\"byteSize\":$size,\"filename\":\"$1.jpg\",\"isAutomaticBackup\":false}" | jq '["uploadID"]')
  curl -s -X PUT "$API/v1/uploads/$up/chunk/0" -H "$AUTH" --data-binary "@$f" >/dev/null
  curl -s -X POST "$API/v1/uploads/$up/commit" -H "$AUTH" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$SPACE\",\"mediaType\":\"photo\",\"mime\":\"image/jpeg\",\"width\":$((64 + N)),\"height\":64,\"capturedAt\":\"$2:00Z\",\"capturedTZOffset\":0,\"latitude\":$3,\"longitude\":$4,\"isRaw\":false,\"burstPick\":false}" \
    | jq '["assetID"]' > "$ROOT/ids/$1"
}
id(){ cat "$ROOT/ids/$1"; }

CULPEPER="38.4716 -77.9967"
MAGIC_KINGDOM="28.4194 -81.5812"; EPCOT="28.3753 -81.5494"; STUDIOS="28.3575 -81.5583"
ANIMAL_KINGDOM="28.3576 -81.5902"; SPRINGS="28.3709 -81.5194"; KISSIMMEE="28.2920 -81.4076"
UNIVERSAL="28.4744 -81.4678"; SEAWORLD="28.4114 -81.4612"
DUCK="36.1696 -75.7552"; COROLLA="36.3766 -75.8306"
ASHEVILLE="35.5951 -82.5515"; WYTHEVILLE="36.9485 -81.0848"

# shoot <prefix> <day> <hour before the first> <count> <place>
shoot(){
  local i where=${!5}
  for i in $(seq 1 "$4"); do put "$1$i" "$2T$(printf %02d $(($3 + i))):00" $where; done
}

echo "Uploading"
# Home, where most of the library is.
for d in $(seq -w 1 25); do shoot "h$d-" "2025-01-$d" 9 2 CULPEPER; done
# Four days at the parks, with a hotel in Kissimmee.
shoot a1m 2025-03-10 9 5 MAGIC_KINGDOM; shoot a1k 2025-03-10 18 2 KISSIMMEE
shoot a2e 2025-03-11 9 5 EPCOT
shoot a3s 2025-03-12 9 3 STUDIOS; shoot a3a 2025-03-12 13 3 ANIMAL_KINGDOM
shoot a4d 2025-03-13 9 3 SPRINGS
# A week in Duck, too small to be in the town dataset, and a trip to Corolla.
for d in 12 13 14 15 16 17 18; do shoot "b$d-" "2025-07-$d" 9 3 DUCK; done
shoot b14c 2025-07-14 15 2 COROLLA
# Universal, Disney World and SeaWorld from a rental in Kissimmee.
shoot c3u 2024-06-03 9 3 UNIVERSAL;      shoot c3k 2024-06-03 18 2 KISSIMMEE
shoot c4u 2024-06-04 9 3 UNIVERSAL;      shoot c4k 2024-06-04 18 2 KISSIMMEE
shoot c5m 2024-06-05 9 3 MAGIC_KINGDOM;  shoot c5k 2024-06-05 18 2 KISSIMMEE
shoot c6e 2024-06-06 9 3 EPCOT;          shoot c6k 2024-06-06 18 2 KISSIMMEE
shoot c7s 2024-06-07 9 3 SEAWORLD;       shoot c7k 2024-06-07 18 2 KISSIMMEE
# Christmas at the parks.
shoot d23 2023-12-23 9 3 MAGIC_KINGDOM; shoot d24 2023-12-24 9 3 EPCOT
shoot d25 2023-12-25 9 5 MAGIC_KINGDOM; shoot d26 2023-12-26 9 3 ANIMAL_KINGDOM
# Three days in Asheville, with lunch in Virginia on the drive down.
shoot e10w 2024-09-10 9 2 WYTHEVILLE; shoot e10a 2024-09-10 15 4 ASHEVILLE
shoot e11 2024-09-11 9 5 ASHEVILLE;   shoot e12 2024-09-12 9 5 ASHEVILLE
check "every photo arrived" "149" "$(q "SELECT count(*) FROM assets")"

DISNEY=39; OBX=23; ORLANDO=60   # Photos at Disney World, on the Outer Banks, around Orlando

echo "Filing"
check "a photo at Epcot is filed under Walt Disney World" "Walt Disney World, Florida" \
  "$(q "SELECT destination FROM assets WHERE id = '$(id a2e1)'")"
check "beside its town, which stays for search" "Celebration, Florida" \
  "$(q "SELECT place_name FROM assets WHERE id = '$(id a2e1)'")"
check "a photo in Duck is filed under the Outer Banks" "Outer Banks, North Carolina" \
  "$(q "SELECT destination FROM assets WHERE id = '$(id b15-1)'")"
check "every photo at the parks is" "$DISNEY" \
  "$(q "SELECT count(*) FROM assets WHERE destination = 'Walt Disney World, Florida'")"
check "a photo at home is filed under nothing" "" \
  "$(q "SELECT destination FROM assets WHERE id = '$(id h05-1)'")"
check "nor is one in Kissimmee, a town people name" "" \
  "$(q "SELECT destination FROM assets WHERE id = '$(id a1k1)'")"

echo "Day headers"
manifest(){ curl -s "$API/v1/spaces/$SPACE/timeline?zoom=day" -H "$AUTH" \
  | python3 -c "import sys,json; [print(b['key'] + '|' + (b.get('place') or '-')) for b in json.load(sys.stdin)['buckets']]"; }
DAYS=$(manifest)
day(){ echo "$DAYS" | grep "^$1|" | cut -d'|' -f2; }
check "a day at Epcot is headed Walt Disney World" "Walt Disney World, Florida" "$(day 2025-03-11)"
check "a day in Duck is headed the Outer Banks" "Outer Banks, North Carolina" "$(day 2025-07-15)"
check "a day at Universal, the rental folded into it" "Universal Orlando, Florida" "$(day 2024-06-03)"
check "home is still its town" "Culpeper, Virginia" "$(day 2025-01-05)"
check "the Information panel says the same" "Walt Disney World, Florida" \
  "$(curl -s "$API/v1/spaces/$SPACE/assets/$(id a2e1)/detail" -H "$AUTH" | jq '["placeName"]')"

echo "Trips"
trips(){ curl -s "$API/v1/spaces/$SPACE/collections?date=$1" -H "$AUTH" \
  | python3 -c "import sys,json; print('|'.join(c['title'] for c in json.load(sys.stdin).get('allTrips') or []))"; }
hero(){ curl -s "$API/v1/spaces/$SPACE/collections?date=$1" -H "$AUTH" | jq '["hero"]["title"]'; }
T=$(trips 2026-10-12)
has "four days at the parks are named for them" "Four days at Walt Disney World" "$T"
has "a week in Duck is a week in the Outer Banks" "Seven days in the Outer Banks" "$T"
has "Universal, Disney World and SeaWorld from Kissimmee is Orlando" "Five days in Orlando" "$T"
has "Christmas there is named for both" "Christmas 2023 at Walt Disney World" "$T"
has "a town most of a trip was in names it, the drive down and all" "Three days in Asheville" "$T"
lacks "no trip is named for a state it was more particular than" "in Florida" "$T"
lacks "nor for a suburb" "Celebration" "$T"
check "a year on, the trip comes back" "A year ago you were at Walt Disney World" "$(hero 2026-03-13)"

echo "What the photos showed"
# observe <labels> <names...>: what the devices saw in these photos.
observe(){
  local labels=$1 body="" name; shift
  for name in "$@"; do
    body="$body${body:+,}{\"assetID\":\"$(id "$name")\",\"labels\":$labels,\"aesthetic\":0.4,\"isUtility\":false,\"peopleCount\":0,\"animalCount\":0}"
  done
  curl -s -X POST "$API/v1/spaces/$SPACE/curation/observations" -H "$AUTH" -H 'Content-Type: application/json' \
    -d "{\"analysisVersion\":1,\"modelVersion\":\"smoke\",\"observations\":[$body]}" | jq '["accepted"]'
}
names(){ ls "$ROOT/ids" | grep "^$1" | tr '\n' ' '; }
check "the beach week is seen as beach" "$OBX" "$(observe '[{"id":"beach","confidence":0.9}]' $(names b))"
check "the parks as a theme park" "21" "$(observe '[{"id":"amusement_park","confidence":0.9}]' $(names a))"
T=$(trips 2026-10-12)
has "a beach trip goes to the Outer Banks" "Beach trip to the Outer Banks" "$T"
has "a theme park trip to Walt Disney World is a trip to Walt Disney World" "Four days at Walt Disney World" "$T"
lacks "and isn't called a theme park trip" "Theme park trip" "$T"
check "a year after the beach trip, you were in the Outer Banks" "A year ago you were in the Outer Banks" \
  "$(hero 2026-07-15)"

echo "Search"
search(){ curl -s -G "$API/v1/spaces/$SPACE/search" --data-urlencode "$1" -H "$AUTH" | jq '["total"]'; }
check "disney finds every photo at the parks" "$DISNEY" "$(search q=disney)"
check "obx finds the Outer Banks" "$OBX" "$(search q=obx)"
check "so does outer banks" "$OBX" "$(search 'q=outer banks')"
check "orlando finds the parks and the towns around them" "$ORLANDO" "$(search q=orlando)"
check "the town still finds its photos" "$(q "SELECT count(*) FROM assets WHERE place_name ILIKE '%celebration%'")" \
  "$(search q=celebration)"
check "picking it in Places finds them all" "$DISNEY" "$(search 'place=Walt Disney World, Florida')"
PLACES=$(curl -s "$API/v1/spaces/$SPACE/places?limit=50" -H "$AUTH" \
  | python3 -c "import sys,json; print('|'.join(f\"{p['name']}:{p['count']}\" for p in json.load(sys.stdin)['places']))")
has "Places lists Walt Disney World" "Walt Disney World, Florida:$DISNEY" "$PLACES"
has "and the Outer Banks" "Outer Banks, North Carolina:$OBX" "$PLACES"
lacks "not the suburbs its photos are nearest" "Horizon West" "$PLACES"

echo "Moving a photo"
locate(){ curl -s -X PUT "$API/v1/spaces/$SPACE/assets/$1/location" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"latitude\":$2,\"longitude\":$3}" | jq '["placeName"]'; }
H=$(id h05-1)
check "moved to the Magic Kingdom, it is at Walt Disney World" "Walt Disney World, Florida" "$(locate "$H" $MAGIC_KINGDOM)"
check "and filed there" "Walt Disney World, Florida" "$(q "SELECT destination FROM assets WHERE id = '$H'")"
check "moved home, it is in its town again" "Culpeper, Virginia" "$(locate "$H" $CULPEPER)"
check "and filed under nothing" "" "$(q "SELECT destination FROM assets WHERE id = '$H'")"

echo "Filing an older library"
q "UPDATE assets SET destination = NULL, destination_version = 0 WHERE destination IS NOT NULL" >/dev/null
stop; serve
for _ in $(seq 1 60); do
  [ "$(q "SELECT count(*) FROM assets WHERE destination_version = 0 AND lat IS NOT NULL")" = "0" ] && break; sleep 0.5
done
check "a restart files the Outer Banks again" "$OBX" \
  "$(q "SELECT count(*) FROM assets WHERE destination = 'Outer Banks, North Carolina'")"
check "and Walt Disney World" "$DISNEY" \
  "$(q "SELECT count(*) FROM assets WHERE destination = 'Walt Disney World, Florida'")"
has "and says so" "destinations: filed" "$(cat "$ROOT/server.log")"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
