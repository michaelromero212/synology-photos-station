#!/bin/bash
# Day and month headers name every area their photos came from. Places
# within about 15 miles count as one, named after where most of the photos
# were. Farther ones are all named: "Reston and Richmond", or "Reston,
# Richmond and 1 more". A day lists them in the order it visited them, and a
# month leads with where most of it was spent.
#
#   FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-day-places.sh
#
# Runs its own server against its own database and blob store.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"

DB=framestation_places; PORT=8094; API="http://127.0.0.1:$PORT"
export FRAMESTATION_DATABASE_URL="postgres://framestation:x@127.0.0.1:55432/$DB?sslmode=disable"
ROOT="$SCRATCH/places"; rm -rf "$ROOT"; mkdir -p "$ROOT/blobroot" "$ROOT/lib"
ROOT=$(cd "$ROOT" && pwd -P)
export FRAMESTATION_BLOB_ROOT="$ROOT/blobroot"

PASS=0; FAIL=0
q(){ psql -h 127.0.0.1 -p 55432 -U framestation -d $DB -tAqc "$1"; }
admin(){ psql -h 127.0.0.1 -p 55432 -U framestation -d postgres -tAqc "$1"; }
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; echo "      expected: $2"; echo "      actual:   $3"; FAIL=$((FAIL+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
jq(){ python3 -c "import sys,json; print(json.load(sys.stdin)$1)" 2>/dev/null; }

(cd "$SERVER_DIR" && swift build >/dev/null 2>&1) || { echo "server build failed"; exit 1; }
BIN="$(cd "$SERVER_DIR" && swift build --show-bin-path)/FrameStationServer"
admin "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1; admin "CREATE DATABASE $DB" >/dev/null
"$BIN" serve --hostname 127.0.0.1 --port $PORT > "$ROOT/server.log" 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null; wait $SERVER 2>/dev/null' EXIT
for _ in $(seq 1 120); do curl -s -o /dev/null "$API/health" && break; sleep 0.5; done

# Where each test photo was taken and when.
RESTON="38.9586 -77.3570 Reston, Virginia"
HERNDON="38.9696 -77.3861 Herndon, Virginia"
RICHMOND="37.5407 -77.4360 Richmond, Virginia"
PHILADELPHIA="39.9526 -75.1652 Philadelphia, Pennsylvania"
SPRINGFIELD_IL="39.7817 -89.6501 Springfield, Illinois"
SPRINGFIELD_MA="42.1015 -72.5898 Springfield, Massachusetts"
PLAN=(
  "a1 2026-05-01T10:00 RESTON"   "a2 2026-05-01T11:00 RESTON"   "a3 2026-05-01T12:00 RESTON"
  "b1 2026-05-02T09:00 RESTON"   "b2 2026-05-02T10:00 RESTON"   "b3 2026-05-02T11:00 RESTON"
  "b4 2026-05-02T12:00 HERNDON"  "b5 2026-05-02T13:00 HERNDON"
  "c1 2026-05-03T09:00 RESTON"   "c2 2026-05-03T10:00 RESTON"
  "c3 2026-05-03T14:00 RICHMOND" "c4 2026-05-03T15:00 RICHMOND" "c5 2026-05-03T16:00 RICHMOND"
  "d1 2026-05-04T08:00 RICHMOND" "d2 2026-05-04T09:00 RICHMOND"
  "d3 2026-05-04T18:00 RESTON"   "d4 2026-05-04T19:00 RESTON"   "d5 2026-05-04T20:00 RESTON"
  "e1 2026-05-05T08:00 RESTON"   "e2 2026-05-05T12:00 RICHMOND" "e3 2026-05-05T18:00 PHILADELPHIA"
  "f1 2026-05-06T10:00 NOWHERE"  "f2 2026-05-06T11:00 NOWHERE"
  "g1 2026-05-07T10:00 RESTON"   "g2 2026-05-07T11:00 NOWHERE"
  "h1 2026-05-08T09:00 SPRINGFIELD_IL" "h2 2026-05-08T15:00 SPRINGFIELD_MA"
)
for entry in "${PLAN[@]}"; do
  set -- $entry
  vips gaussnoise "$ROOT/n.v" 64 64 >/dev/null 2>&1 && vips copy "$ROOT/n.v" "$ROOT/lib/$1.jpg" >/dev/null 2>&1
done

CODE=$(cd "$SERVER_DIR" && "$BIN" invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
R=$(curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$CODE\",\"displayName\":\"Tester\",\"deviceName\":\"iPhone\",\"platform\":\"ios\"}")
TOKEN=$(echo "$R" | jq '["token"]'); SPACE=$(echo "$R" | jq '["personalSpace"]["id"]')
(cd "$SERVER_DIR" && "$BIN" import --path "$ROOT/lib" --space "$SPACE" >/dev/null 2>&1)
# Let the server's own metadata pass finish first, so nothing it writes lands
# on top of the places set below.
for _ in $(seq 1 120); do
  [ "$(q "SELECT count(*) FROM derivation_jobs WHERE state IN ('pending', 'running')")" = "0" ] && break; sleep 1
done

for entry in "${PLAN[@]}"; do
  set -- $entry
  name=$1; when=$2; where=$3
  if [ "$where" = "NOWHERE" ]; then
    lat=NULL; lon=NULL; place=NULL
  else
    set -- ${!where}
    lat=$1; lon=$2; shift 2; place="'$*'"
  fi
  q "UPDATE assets SET local_captured_at = '$when', lat = $lat, lon = $lon, place_name = $place
     WHERE id = (SELECT asset_id FROM space_assets WHERE filename = '$name.jpg')" >/dev/null
done

manifest(){ curl -s "$API/v1/spaces/$SPACE/timeline?zoom=$1" -H "Authorization: Bearer $TOKEN" \
  | python3 -c "import sys,json; [print(b['key'] + '|' + (b.get('place') or '-')) for b in json.load(sys.stdin)['buckets']]"; }
DAYS=$(manifest day)
day(){ echo "$DAYS" | grep "^$1|" | cut -d'|' -f2; }

echo "Days"
check "one place stays as it was" "Reston, Virginia" "$(day 2026-05-01)"
check "a nearby town folds into the bigger one" "Reston, Virginia" "$(day 2026-05-02)"
check "two cities are both named, in the order visited" "Reston and Richmond" "$(day 2026-05-03)"
check "the other way round when the day went the other way" "Richmond and Reston" "$(day 2026-05-04)"
check "three or more name the first two" "Reston, Richmond and 1 more" "$(day 2026-05-05)"
check "a day with no places has none" "-" "$(day 2026-05-06)"
check "photos without a place don't change the name" "Reston, Virginia" "$(day 2026-05-07)"
check "towns sharing a name keep their states" "Springfield, Illinois and Springfield, Massachusetts" "$(day 2026-05-08)"
check "every photo is still counted" "${#PLAN[@]}" \
  "$(curl -s "$API/v1/spaces/$SPACE/timeline?zoom=day" -H "Authorization: Bearer $TOKEN" | jq '["total"]')"

echo "Months"
check "a month leads with where most of it was spent" "Reston, Richmond and 3 more" \
  "$(manifest month | grep '^2026-05|' | cut -d'|' -f2)"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
