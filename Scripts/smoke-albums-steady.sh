#!/bin/bash
# The Albums page holds still where it should and moves where it should.
# Covers stay the ones an album was recognized by, on every day, every section
# and every visit: a cover that turned each morning made the whole page look
# unsettled (his word, 2026-11-24). The row the page opens on is the opposite:
# dealt from the date, so it's the same all day on every device and new
# tomorrow, and it has more to deal from than the four cards it once turned
# round by one each day.
#
#   FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-albums-steady.sh
#
# Runs its own server against its own database and blob store. Never changes
# the library once it's built: every check is a read of the page on some date.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"
export FRAMESTATION_GEONAMES_DIR="${FRAMESTATION_GEONAMES_DIR:-$(cd "$(dirname "$0")/.." && pwd)/Data/geonames}"
[ -f "$FRAMESTATION_GEONAMES_DIR/cities.tsv" ] || {
  echo "No town dataset at $FRAMESTATION_GEONAMES_DIR. Run Scripts/fetch-geonames.sh first."; exit 1; }

DB=framestation_steady; PORT=8107; API="http://127.0.0.1:$PORT"
export FRAMESTATION_DATABASE_URL="postgres://framestation:x@127.0.0.1:55432/$DB?sslmode=disable"
ROOT="$SCRATCH/steady"; rm -rf "$ROOT"; mkdir -p "$ROOT/blobroot" "$ROOT/files" "$ROOT/ids" "$ROOT/pages"
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
# Whatever already answers on this port would be tested in this server's place.
curl -s -o /dev/null "$API/health" && { echo "port $PORT is already in use"; exit 1; }
admin "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1; admin "CREATE DATABASE $DB" >/dev/null
"$BIN" serve --hostname 127.0.0.1 --port $PORT > "$ROOT/server.log" 2>&1 &
SERVER=$!
# The log stays for a look after a failure; the database, the blobs and the
# pages go.
trap 'kill $SERVER 2>/dev/null; wait $SERVER 2>/dev/null; rm -rf "$ROOT/blobroot" "$ROOT/files" "$ROOT/pages"; admin "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1' EXIT
for _ in $(seq 1 120); do curl -s -o /dev/null "$API/health" && break; sleep 0.5; done
curl -s -o /dev/null "$API/health" || { echo "server didn't start:"; tail -20 "$ROOT/server.log"; exit 1; }

redeem(){
  local c
  c=$(cd "$SERVER_DIR" && "$BIN" invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
  curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
    -d "{\"code\":\"$c\",\"displayName\":\"$1\",\"deviceName\":\"iPhone\",\"platform\":\"ios\"}"
}
R=$(redeem Steady)
TOKEN=$(echo "$R" | jq '["token"]'); SPACE=$(echo "$R" | jq '["personalSpace"]["id"]')
USER_ID=$(echo "$R" | jq '["user"]["id"]'); AUTH="Authorization: Bearer $TOKEN"
[ -n "$SPACE" ] || { echo "setup failed"; tail -20 "$ROOT/server.log"; exit 1; }

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
shoot(){ local i where=${!5}
  for i in $(seq 1 "$4"); do put "$1$i" "$2T$(printf %02d $(($3 + i))):00" $where; done; }
settle(){ for _ in $(seq 1 120); do
  [ "$(q "SELECT count(*) FROM derivation_jobs WHERE state IN ('pending', 'running')")" = "0" ] && break; sleep 1
done; }

CULPEPER="38.4716 -77.9967"; ASHEVILLE="35.5951 -82.5515"; MAGIC_KINGDOM="28.4194 -81.5812"
NAGS_HEAD="35.9577 -75.6244"; CHICAGO="41.8781 -87.6298"; NEW_YORK="40.7128 -74.0060"
# observe <photo> <labels> [aesthetic]: what their phone saw in it. An
# aesthetic over a tenth is what makes a photo worth featuring.
observe(){ curl -s -o /dev/null -X POST "$API/v1/spaces/$SPACE/curation/observations" -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d "{\"analysisVersion\":1,\"modelVersion\":\"smoke\",\"observations\":[{\"assetID\":\"$(cat "$ROOT/ids/$1")\",\"labels\":$2,\"aesthetic\":${3:-0.4},\"isUtility\":false,\"peopleCount\":0,\"animalCount\":0}]}"; }
CAKE='[{"id":"birthday_cake","confidence":0.92},{"id":"candle","confidence":0.6}]'
TREE='[{"id":"christmas_tree","confidence":0.88},{"id":"gift","confidence":0.5}]'
SKY='[{"id":"sky","confidence":0.9},{"id":"outdoor","confidence":0.8}]'

echo "Uploading"
# Home: Culpeper, most of the library, so everywhere else is away.
for d in $(seq -w 1 12); do shoot "h$d-" "2025-01-$d" 9 2 CULPEPER; done
# Five trips, a year or more apart, so the page has trips to deal from and
# places to go back to.
shoot a10 2024-09-10 9 4 ASHEVILLE; shoot a11 2024-09-11 9 4 ASHEVILLE; shoot a12 2024-09-12 9 4 ASHEVILLE
for d in 10 11 12; do shoot "d$d-" "2025-03-$d" 9 4 MAGIC_KINGDOM; done
for d in 08 09 10; do shoot "n$d-" "2023-07-$d" 9 4 NAGS_HEAD; done
for d in 14 15 16; do shoot "c$d-" "2022-10-$d" 9 4 CHICAGO; done
for d in 20 21 22; do shoot "y$d-" "2025-06-$d" 9 4 NEW_YORK; done
# Holidays at home, and August 14 three years running with a cake in the
# first two: a birthday. Two ordinary days get named, which makes them
# occasions too.
shoot x25 2024-12-25 9 6 CULPEPER; shoot t28 2024-11-28 9 4 CULPEPER
shoot b22 2022-08-14 9 4 CULPEPER; shoot b23 2023-08-14 9 4 CULPEPER; shoot b24 2024-08-14 6 16 CULPEPER
shoot f20 2025-02-20 9 5 CULPEPER; shoot r12 2025-04-12 9 5 CULPEPER
settle
for i in 1 2 3; do observe "b22$i" "$CAKE"; observe "b23$i" "$CAKE"; done
for i in 1 2 3 4 5 6; do observe "x25$i" "$TREE"; done
# Photos their phone rated well, from different days, all more than a month
# old: the ones the page features.
for p in h01-1 h03-1 h05-1 h07-1 h09-1 h11-1 a101 d10-1 n08-1 c14-1 y20-1 f201 r121; do observe "$p" "$SKY" 0.9; done
for day in "2025-02-20 Science fair" "2025-04-12 Piano recital"; do
  curl -s -o /dev/null -X PUT "$API/v1/spaces/$SPACE/collections/name" -H "$AUTH" -H 'Content-Type: application/json' \
    -d "{\"day\":\"${day% *}\",\"name\":\"${day#* }\",\"everyYear\":false}"
done

echo "Reading the page on 17 days"
# Fourteen in a row for the row's variety, and some far from them, so a
# cover that turned with the date or the season would show.
DATES="$(for d in $(seq 24 30); do echo 2026-11-$d; done; for d in $(seq 1 7); do printf '2026-12-%02d\n' $d; done) 2026-12-09 2027-03-15 2027-08-14"
ROW_DATES="$(for d in $(seq 24 30); do echo 2026-11-$d; done; for d in $(seq 1 7); do printf '2026-12-%02d\n' $d; done)"
for d in $DATES; do curl -s "$API/v1/spaces/$SPACE/collections?date=$d" -H "$AUTH" > "$ROOT/pages/$d.json"; done
# And two more of the first, to see the same day twice.
curl -s "$API/v1/spaces/$SPACE/collections?date=2026-11-24" -H "$AUTH" > "$ROOT/pages/again-2026-11-24.json"
curl -s "$API/v1/spaces/$SPACE/collections?date=2026-12-03" -H "$AUTH" > "$ROOT/pages/again-2026-12-03.json"

cat > "$ROOT/read.py" <<'PY'
import glob, json, os, sys
root = sys.argv[1]
row_dates = sys.argv[2:]
pages = {os.path.basename(p)[:-5]: json.load(open(p)) for p in glob.glob(root + '/pages/*.json')}
dates = sorted(pages)
SECTIONS = ['featured', 'hero', 'trips', 'days', 'revisits', 'mediaTypes', 'allTrips',
            'allOccasions', 'wideTrips', 'wideDays', 'recentlyAdded', 'favorites']
out = []
def say(name, expected, actual): out.append((name, str(expected), str(actual)))

def cards(page, date):
    """(where, id-for-matching, card) for every card on a page that isn't a featured photo.
    This day in an earlier year is keyed by its year, and which day of that year
    it shows is the request's: it's the one card meant to change with the date."""
    for sec in SECTIONS:
        v = page.get(sec)
        for c in ([v] if isinstance(v, dict) else v or []):
            if c.get('kicker') != 'FEATURED PHOTO':
                yield sec, (c['kind'], c['key'], date[-5:] if c['kind'] == 'onThisDay' else ''), c
    for t in page.get('traditions') or []:
        yield 'traditions', ('tradition', t['id']), t

seen, drift, within, total = {}, [], [], 0
for d in dates:
    here = {}
    for sec, ident, c in cards(pages[d], d.replace('again-', '')):
        total += 1
        cover = json.dumps(c.get('coverAssetIDs'))
        if ident in here and here[ident][0] != cover:
            within.append(f'{d} {ident}: {here[ident][1]} {here[ident][0]} vs {sec} {cover}')
        here.setdefault(ident, (cover, sec))
        if ident in seen and seen[ident][0] != cover:
            drift.append(f'{ident}: {seen[ident][1]} {seen[ident][0]} vs {d} {sec} {cover}')
        seen.setdefault(ident, (cover, f'{d} {sec}'))
say('the page has cards to compare', 'True', total > 40 and len(seen) > 15)
p0 = pages[dates[0]]
say('the library has trips and occasions to deal from', 'True',
    len(p0.get('allTrips') or []) >= 4 and len(p0.get('allOccasions') or []) >= 3)
say('a card keeps its cover on every day, in every section', '[]', drift[:3])
say('and its cards agree within one page', '[]', within[:3])

def feat(d): return pages[d].get('featured') or []
def rowkeys(d): return [c['kind'] + ':' + c['key'] for c in feat(d)]
for d in ('2026-11-24', '2026-12-03'):
    a, b = json.dumps(feat(d), sort_keys=True), json.dumps(pages['again-' + d].get('featured') or [], sort_keys=True)
    say(f'the row on {d} is the same the second time', 'True', a == b)
orders = {tuple(rowkeys(d)) for d in row_dates}
say('the row differs from day to day: at least 2 orders in 14 days', 'True', len(orders) >= 2)
albums = {c['kind'] + ':' + c['key'] for d in row_dates for c in feat(d) if c.get('kicker') != 'FEATURED PHOTO'}
say('and deals from more than the old four cards', 'True', len(albums) > 4)

trips = {c['key'] for d in row_dates for c in feat(d) if c['kind'] == 'trip'}
say('and from more than the latest trip: an older one comes up too', 'True', len(trips) >= 2)

def days_of(key):
    # A card's days, as the server reads a key: one day, or a run of them.
    import datetime
    ends = key.split('..')
    try:
        a, b = datetime.date.fromisoformat(ends[0]), datetime.date.fromisoformat(ends[-1])
    except ValueError:
        return {key}
    out = set()
    while a <= b and len(out) < 400:
        out.add(a.isoformat()); a += datetime.timedelta(days=1)
    return out

bad = {'size': [], 'unique': [], 'hero': [], 'first': [], 'adjacent': [], 'photo': [], 'inside': []}
for d in row_dates:
    row, page = feat(d), pages[d]
    keys = [c['key'] for c in row]
    photos = [c.get('kicker') == 'FEATURED PHOTO' for c in row]
    if not 1 <= len(row) <= 6: bad['size'].append((d, len(row)))
    if len(set(keys)) != len(keys): bad['unique'].append((d, keys))
    if not (row and page.get('hero') and page['hero']['key'] == row[0]['key']): bad['hero'].append(d)
    if row and photos[0] and not all(photos): bad['first'].append(d)
    if sum(photos) <= len(photos) - sum(photos) and any(a and b for a, b in zip(photos, photos[1:])):
        bad['adjacent'].append((d, photos))
    if not any(photos): bad['photo'].append(d)
    covered = set()
    for c, is_photo in zip(row, photos):
        if not is_photo: covered |= days_of(c['key'])
    if any(is_photo and c['key'] in covered for c, is_photo in zip(row, photos)):
        bad['inside'].append((d, keys))
say('the row is never longer than six, nor empty', '[]', bad['size'])
say('no card is in it twice', '[]', bad['unique'])
say('the hero is its first card', '[]', bad['hero'])
say('a photo never opens it while an album could', '[]', bad['first'])
say('no two photos sit side by side while albums can go between', '[]', bad['adjacent'])
say('a featured photo is among them every day', '[]', bad['photo'])
say('and never from a day an album in the row already holds', '[]', bad['inside'])
for d in (row_dates[0], row_dates[6], row_dates[13]):
    print('row ' + d + ': ' + ' | '.join(rowkeys(d)), file=sys.stderr)
for n, e, a in out: print(f'{n}\t{e}\t{a}')
PY
python3 "$ROOT/read.py" "$ROOT" $ROW_DATES 2> "$ROOT/rows.txt" > "$ROOT/results.tsv"
cat "$ROOT/rows.txt" >> "$ROOT/server.log"

echo "Covers hold across days"
while IFS=$'\t' read -r name expected actual; do
  case "$name" in
    "a card keeps"*|"and its cards"*) ;; *) continue;; esac
  check "$name" "$expected" "$actual"
done < "$ROOT/results.tsv"
echo "The row the page opens on"
while IFS=$'\t' read -r name expected actual; do
  case "$name" in
    "a card keeps"*|"and its cards"*) ;; *) check "$name" "$expected" "$actual";; esac
done < "$ROOT/results.tsv"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
