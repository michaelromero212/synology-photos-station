#!/bin/bash
# Over the Years: what comes round every year, with each year of it. Every
# Christmas as one card, home or away. A date photographed most years, called a
# birthday when its photos show one. The birthday party held about the same week
# every spring. A day somebody named for every year. And what isn't one: a
# holiday from a single year, a date that was busy a few times by coincidence.
# Next year's Christmas joins on its own, the Albums page around it stays as it
# was, and an older app's fields are all still there.
#
#   FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-traditions.sh
#
# Runs its own server against its own database. The library is written straight
# into the database, nine years of it, as seed-dev-collections.sh writes the dev
# library: what's tested is arithmetic over dates and counts, not uploads.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"
export FRAMESTATION_GEONAMES_DIR="${FRAMESTATION_GEONAMES_DIR:-$(cd "$(dirname "$0")/.." && pwd)/Data/geonames}"

DB=framestation_traditions; PORT=8100; API="http://127.0.0.1:$PORT"
export FRAMESTATION_DATABASE_URL="postgres://framestation:x@127.0.0.1:55432/$DB?sslmode=disable"
ROOT="$SCRATCH/traditions"; rm -rf "$ROOT"; mkdir -p "$ROOT/blobroot"
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
# Whatever already answers on this port would be tested in this server's place.
curl -s -o /dev/null "$API/health" && { echo "port $PORT is already in use"; exit 1; }
admin "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1; admin "CREATE DATABASE $DB" >/dev/null
"$BIN" serve --hostname 127.0.0.1 --port $PORT > "$ROOT/server.log" 2>&1 &
SERVER=$!
# The log stays for a look after a failure, and the database goes.
trap 'kill $SERVER 2>/dev/null; wait $SERVER 2>/dev/null; rm -rf "$ROOT/blobroot"; admin "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1' EXIT
for _ in $(seq 1 120); do curl -s -o /dev/null "$API/health" && break; sleep 0.5; done
curl -s -o /dev/null "$API/health" || { echo "server didn't start:"; tail -20 "$ROOT/server.log"; exit 1; }

redeem(){
  local c
  c=$(cd "$SERVER_DIR" && "$BIN" invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
  curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
    -d "{\"code\":\"$c\",\"displayName\":\"$1\",\"deviceName\":\"iPhone\",\"platform\":\"ios\"}"
}
R=$(redeem Traditions)
TOKEN=$(echo "$R" | jq '["token"]'); SPACE=$(echo "$R" | jq '["personalSpace"]["id"]')
USER_ID=$(echo "$R" | jq '["user"]["id"]'); AUTH="Authorization: Bearer $TOKEN"
[ -n "$SPACE" ] || { echo "setup failed"; tail -20 "$ROOT/server.log"; exit 1; }

CULPEPER="'Culpeper, Virginia', 38.4716, -77.9967"
ASHEVILLE="'Asheville, North Carolina', 35.5951, -82.5515"
# photos <day> <how many> [place]: straight into the library, from 9am on.
photos(){ q "WITH made AS (
    INSERT INTO assets (sha256, byte_size, media_type, mime, blob_ext, local_captured_at, place_name, lat, lon)
    SELECT 'TRAD' || md5('$1' || g || clock_timestamp()::text), 1000, 'photo', 'image/jpeg', 'jpg',
           '$1'::date + make_interval(hours => 9 + (g % 10)), ${3:-$CULPEPER}
    FROM generate_series(1, $2) g RETURNING id)
  INSERT INTO space_assets (space_id, asset_id, uploaded_by_user_id)
  SELECT '$SPACE', id, '$USER_ID' FROM made" >/dev/null; }
# observe <day> <how many show it> [what] [people]: what the person's phone saw
# in that day's photos, the first few a birthday cake (or `what`, with
# `people` in frame) and the rest sky.
CAKE='[{"id":"birthday_cake","confidence":0.92},{"id":"candle","confidence":0.6}]'
CONCERT='[{"id":"concert","confidence":0.9},{"id":"crowd","confidence":0.6}]'
CAPGOWN='[{"id":"graduation","confidence":0.7},{"id":"gown","confidence":0.6},{"id":"ceremony","confidence":0.5}]'
BASEBALL='[{"id":"baseball","confidence":0.9},{"id":"crowd","confidence":0.5}]'
SKY='[{"id":"sky","confidence":0.9},{"id":"outdoor","confidence":0.8}]'
observe(){
  local ids body
  ids=$(q "SELECT a.id FROM assets a JOIN space_assets sa ON sa.asset_id = a.id
           WHERE sa.space_id = '$SPACE' AND a.local_captured_at::date = '$1' ORDER BY a.local_captured_at, a.id")
  body=$(echo "$ids" | python3 -c "
import sys, json
ids = [l.strip() for l in sys.stdin if l.strip()]
seen, sky = json.loads('${3:-$CAKE}'), json.loads('$SKY')
print(json.dumps({'analysisVersion': 1, 'modelVersion': 'smoke', 'observations': [
    {'assetID': i, 'labels': seen if n < $2 else sky, 'aesthetic': 0.4, 'isUtility': False,
     'peopleCount': ${4:-0} if n < $2 else 0, 'animalCount': 0} for n, i in enumerate(ids)]}))")
  curl -s -o /dev/null -X POST "$API/v1/spaces/$SPACE/curation/observations" -H "$AUTH" \
    -H 'Content-Type: application/json' -d "$body"
}
settings(){ curl -s -o /dev/null -X PUT "$API/v1/curation/settings" -H "$AUTH" \
  -H 'Content-Type: application/json' -d "$1"; }
name(){ code -X PUT "$API/v1/spaces/$SPACE/collections/name" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"day\":\"$1\",\"name\":\"$2\",\"everyYear\":true}"; }

# page [date] [space] [auth]: the Albums page as of that day, kept for `T`.
page(){ curl -s "$API/v1/spaces/${2:-$SPACE}/collections?date=${1:-2026-11-03}" -H "${3:-$AUTH}" > "$ROOT/page.json"; }
cat > "$ROOT/read.py" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
what, args = sys.argv[2], sys.argv[3:]
ts = d.get('traditions')
by = {t['id']: t for t in (ts or [])}
if what == 'present': print(ts is not None)
elif what == 'titles': print('|'.join(t['title'] for t in ts or []))
elif what == 'field': print(by.get(args[0], {}).get(args[1]))
elif what == 'years': print('|'.join(y['title'] for y in by.get(args[0], {}).get('years', [])))
elif what == 'keys': print('|'.join(y['key'] for y in by.get(args[0], {}).get('years', [])))
elif what == 'newest': print(all(a['key'] > b['key'] for a, b in zip(by[args[0]]['years'], by[args[0]]['years'][1:])))
elif what == 'naming':
    n = by.get(args[0], {}).get('naming')
    print(None if n is None else f"{n['key']} {n['title']} {n['isNamed']} {n['recursAnnually']}")
elif what == 'occasions': print('|'.join(c['title'] for c in d.get('allOccasions') or []))
elif what == 'days': print('|'.join(c['title'] for c in d.get('days') or []))
elif what == 'daysyearly': print(len(d.get('days') or []) == 3 and any(c.get('tradition') for c in d.get('days') or []))
elif what == 'trips': print('|'.join(c['title'] for c in d.get('allTrips') or []))
elif what == 'shape': print('|'.join(k for k in ['hero', 'trips', 'days', 'revisits', 'mediaTypes',
                                                 'allTrips', 'allOccasions', 'featured'] if k in d))
elif what == 'wide':
    wide = d.get('wideDays') or []
    print(len(d.get('days') or []) == 3 and 3 < len(wide) <= 12 and all(c.get('tradition') is None for c in wide))
elif what == 'widetitles': print('|'.join(c['title'] for c in d.get('wideDays') or []))
elif what == 'marked':
    print('|'.join(f"{c['title']}={c.get('tradition')}" for c in d.get('allOccasions') or [] if c['title'] == args[0]))
PY
T(){ python3 "$ROOT/read.py" "$ROOT/page.json" "$@"; }

echo "A library of nine years"
# A quiet baseline: a photo every other day. Without it the median day rises
# until nothing is busy, and every date looks like every other.
q "WITH made AS (
    INSERT INTO assets (sha256, byte_size, media_type, mime, blob_ext, local_captured_at, place_name, lat, lon)
    SELECT 'TRADQ' || g, 1000, 'photo', 'image/jpeg', 'jpg', ('2018-01-01'::date + g * 2) + time '13:00',
           $CULPEPER
    FROM generate_series(0, 1610) g RETURNING id)
  INSERT INTO space_assets (space_id, asset_id, uploaded_by_user_id)
  SELECT '$SPACE', id, '$USER_ID' FROM made" >/dev/null
# Christmas: Christmas Eve only in 2021, then the day itself, and one spent away.
photos 2021-12-24 5; photos 2022-12-25 6; photos 2024-12-25 6; photos 2025-12-25 6
for d in 23 24 25 26; do photos "2023-12-$d" 5 "$ASHEVILLE"; done
# Two Thanksgivings, and one Halloween.
photos 2024-11-28 6; photos 2025-11-27 6; photos 2025-10-31 6
# April 5 most years, busy all but one, with a cake in the photos twice.
for y in 2019 2021 2022 2023 2024 2025; do photos "$y-04-05" 10; done; photos 2020-04-05 5
# A birthday party the Saturday nearest the middle of May, four years running.
for d in 2022-05-14 2023-05-20 2024-05-18 2025-05-17; do photos "$d" 6; done
# August 14 three years running, quietly.
for y in 2023 2024 2025; do photos "$y-08-14" 5; done
# June 10, three years, busy once, in Junes photographed every other day: a
# coincidence the page used to ask to name.
photos 2021-06-10 4; photos 2022-06-10 4; photos 2023-06-10 12
for y in 2021 2022 2023; do for d in 01 03 05 07 09 11 13 15 17 19 21 23 25; do photos "$y-06-$d" 5; done; done
# Memorial Day twice among those Junes: a few photos on a day off, not a
# holiday this family keeps.
photos 2021-05-31 5; photos 2023-05-29 5
# March 10 every year, and a concert near it most years but never on it: the
# date isn't a concert.
for y in 2021 2022 2023 2024 2025; do photos "$y-03-10" 5; done
for d in 2021-03-07 2022-03-12 2023-03-08 2024-03-11; do photos "$d" 6; done
# September 20 every year, and a birthday party a week before it most years:
# the date isn't that birthday.
for y in 2021 2022 2023 2024 2025; do photos "$y-09-20" 5; done
for d in 2021-09-12 2022-09-13 2023-09-11 2024-09-14; do photos "$d" 6; done
# October 20 every year with cake twice, and in 2024 a graduation that fell on
# it: a year of something else, not of the birthday.
for y in 2020 2021 2022 2023 2024 2025; do photos "$y-10-20" 6; done
# Father's Day three years among those busy Junes, each a ball game with a
# crowd: the crowd is the game's, and the day isn't kept as Father's Day.
for d in 2021-06-20 2022-06-19 2023-06-18; do photos "$d" 6; done
# The baseline out of the way of the days it's a baseline for.
BASELINE_IN_THE_WAY="SELECT q.id FROM assets q WHERE q.sha256 LIKE 'TRADQ%' AND q.local_captured_at::date IN (
     SELECT local_captured_at::date FROM assets WHERE sha256 LIKE 'TRAD%' AND sha256 NOT LIKE 'TRADQ%')"
q "DELETE FROM space_assets WHERE asset_id IN ($BASELINE_IN_THE_WAY)" >/dev/null
q "DELETE FROM assets WHERE id IN ($BASELINE_IN_THE_WAY)" >/dev/null
for d in 2022-04-05 2024-04-05; do observe "$d" 3; done
for d in 2019-04-05 2020-04-05 2021-04-05 2023-04-05 2025-04-05; do observe "$d" 0; done
for d in 2022-05-14 2023-05-20 2024-05-18 2025-05-17; do observe "$d" 3; done
for d in 2021-03-07 2022-03-12 2023-03-08 2024-03-11; do observe "$d" 4 "$CONCERT"; done
for d in 2021-09-12 2022-09-13 2023-09-11 2024-09-14; do observe "$d" 3; done
for d in 2021-10-20 2023-10-20; do observe "$d" 3; done
for d in 2020-10-20 2022-10-20 2025-10-20; do observe "$d" 0; done
observe 2024-10-20 4 "$CAPGOWN"
for d in 2021-06-20 2022-06-19 2023-06-18; do observe "$d" 6 "$BASEBALL" 4; done

echo "Over the Years"
page
check "the page carries them" "True" "$(T present)"
check "the soonest first: Thanksgiving, then Christmas" "Thanksgiving|Christmas" "$(T titles | cut -d'|' -f1-2)"
check "then the rest by date" "Birthday on April 5|Birthday party in Culpeper|Every year on August 14" \
  "$(T titles | tr '|' '\n' | grep -E '^(Birthday on April 5|Birthday party in Culpeper|Every year on August 14)$' | head -3 | paste -sd'|' -)"
check "every Christmas, home or away, Christmas Eve 2021 among them" "5 years · 2021–2025" \
  "$(T field holiday:Christmas subtitle)"
check "each by the name Holidays & Occasions gives it" \
  "Christmas 2025|Christmas 2024|Christmas 2023|Christmas 2022|Christmas Eve 2021" "$(T years holiday:Christmas)"
check "with all its photos" "33" "$(T field holiday:Christmas count)"
check "newest first" "True" "$(T newest holiday:Christmas)"
check "the one away is just its holiday's days" "2023-12-24..2023-12-25" \
  "$(T keys holiday:Christmas | tr '|' '\n' | grep 2023)"
check "which open on their photos" "10" \
  "$(curl -s "$API/v1/spaces/$SPACE/collections/items?kind=day&key=2023-12-24..2023-12-25" -H "$AUTH" | jq '["total"]')"
has "while the trip keeps its own name" "Christmas 2023 in Asheville" "$(T trips)"
lacks "and Holidays & Occasions still doesn't list its days twice" "Christmas 2023|" "$(T occasions)|"
check "two Thanksgivings are a tradition" "2 years · 2024–2025" "$(T field holiday:Thanksgiving subtitle)"
lacks "one Halloween isn't" "Halloween" "$(T titles)"
lacks "nor a holiday that only happened to have photos, twice" "Memorial Day" "$(T titles)"
has "though Holidays & Occasions still lists it, as it did" "Memorial Day 2023" "$(T occasions)"
check "a date with cake in its photos is a birthday" "7 years · 2019–2025" "$(T field date:04-05 subtitle)"
check "every year of it, the quiet one too" \
  "April 5, 2025|April 5, 2024|April 5, 2023|April 5, 2022|April 5, 2021|April 5, 2020|April 5, 2019" \
  "$(T years date:04-05)"
check "which can be named, every year" "2025-04-05 Birthday on April 5 False True" "$(T naming date:04-05)"
check "Holidays & Occasions asks about it by the same name, once" "1" \
  "$(T occasions | tr '|' '\n' | grep -c '^Birthday on April 5$')"
lacks "and no longer as just a date" "Every year on April 5" "$(T occasions)"
check "a party the same week every year is one tradition" "Every May · 4 years · 2022–2025" \
  "$(T field event:birthday:05 subtitle)"
check "each year by its date" "May 17, 2025|May 18, 2024|May 20, 2023|May 14, 2022" \
  "$(T years event:birthday:05)"
check "an event isn't named from here" "None" "$(T naming event:birthday:05)"
check "a date photographed every year, quietly, is one too" "3 years · 2023–2025" \
  "$(T field date:08-14 subtitle)"
lacks "a date busy three times among busy Junes isn't" "June" "$(T titles)"
check "concerts around a date don't name it" "Every year on March 10" "$(T field date:03-10 title)"
check "they're their own tradition" "Every March · 4 years · 2021–2024" "$(T field event:concert:03 subtitle)"
check "nor do a week-earlier birthday's parties" "Every year on September 20" "$(T field date:09-20 title)"
check "which are that birthday's own" "Every September · 4 years · 2021–2024" \
  "$(T field event:birthday:09 subtitle)"
check "a graduation on a birthday's date isn't a year of it" "5 years · 2020–2025" \
  "$(T field date:10-20 subtitle)"
lacks "nor one of its cards" "October 20, 2024" "$(T years date:10-20)"
check "it's still a birthday" "Birthday on October 20" "$(T field date:10-20 title)"
has "and the graduation is a graduation" "Graduation" "$(T occasions)"
lacks "a Father's Day that was a ball game isn't kept as Father's Day" "Father's Day" "$(T titles)"
has "though Holidays & Occasions still calls the day that" "Father's Day 2023" "$(T occasions)"
check "a card that's a year of a tradition says which" "Christmas 2024=holiday:Christmas" \
  "$(T marked 'Christmas 2024')"
check "Holidays & Occasions for an app with Over the Years: what happened once, a row of it" "True" "$(T wide)"
has "the graduation among it" "Graduation" "$(T widetitles)"
lacks "and no year of a tradition" "Christmas" "$(T widetitles)"
check "while an older app's three still hold years of a tradition, as they always did" "True" "$(T daysyearly)"
lacks "nor asked about any more" "June 10" "$(T occasions)"
check "an older app finds everything it reads" "hero|trips|days|revisits|mediaTypes|allTrips|allOccasions|featured" \
  "$(T shape)"

echo "Kept albums"
BEFORE=$(q "SELECT count(*) || ' ' || max(updated_at) FROM curated_albums")
page >/dev/null
check "a second visit writes nothing" "$BEFORE" "$(q "SELECT count(*) || ' ' || max(updated_at) FROM curated_albums")"
check "and the question is never saved" "0" "$(q "SELECT count(*) FROM curated_albums WHERE title LIKE 'Birthday on%'")"

echo "Named by the person"
check "naming August 14 for every year" "204" "$(name 2025-08-14 "Mom's birthday")"
page
check "keeps the tradition where it was" "Mom's birthday" "$(T field date:08-14 title)"
check "says which day it is" "August 14 · 3 years · 2023–2025" "$(T field date:08-14 subtitle)"
check "and each year carries its year" "Mom's birthday 2025|Mom's birthday 2024|Mom's birthday 2023" \
  "$(T years date:08-14)"
check "renaming it renames every year" "2025-08-14 Mom's birthday True True" "$(T naming date:08-14)"

echo "Next year"
photos 2026-12-25 5; photos 2026-04-05 5
page 2026-12-27
check "this Christmas joins the moment its photos do" "6 years · 2021–2026" "$(T field holiday:Christmas subtitle)"
check "at the top" "Christmas 2026" "$(T years holiday:Christmas | cut -d'|' -f1)"
check "and this April 5, quiet as it was" "8 years · 2019–2026" "$(T field date:04-05 subtitle)"
has "though it fell on Easter Sunday" "Easter 2026" "$(T occasions)"

echo "Switched off"
settings '{"holidays":false}'
page
lacks "holidays off: no Christmas" "Christmas" "$(T titles)"
lacks "nor Thanksgiving" "Thanksgiving" "$(T titles)"
has "the birthday stays" "Birthday on April 5" "$(T titles)"
settings '{"holidays":true}'
settings '{"enabled":false}'
page
check "curation off: the date is only a date" "Every year on April 5" "$(T field date:04-05 title)"
lacks "and no party is seen" "Birthday party" "$(T titles)"
has "the question is asked by the date" "Every year on April 5" "$(T occasions)"
settings '{"enabled":true}'
page
check "back on, it's a birthday again" "Birthday on April 5" "$(T field date:04-05 title)"

echo "Someone else"
R=$(redeem Neighbor); OTHER_AUTH="Authorization: Bearer $(echo "$R" | jq '["token"]')"
OTHER_SPACE=$(echo "$R" | jq '["personalSpace"]["id"]')
page 2026-11-03 "$OTHER_SPACE" "$OTHER_AUTH"
check "a library with nothing that comes round has none" "" "$(T titles)"
check "and the first library's page isn't theirs to read" "404" \
  "$(code "$API/v1/spaces/$SPACE/collections?date=2026-11-03" -H "$OTHER_AUTH")"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
