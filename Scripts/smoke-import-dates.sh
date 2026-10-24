#!/bin/bash
# The import reads each file's own date the way the file meant it, so an
# imported library lands in the same hours and on the same days as in the
# library it came from. An iPhone video by the local time and zone it records,
# not its UTC stamp (or, for a trimmed clip, the time it was trimmed). A photo
# by its EXIF date and zone, the zone also taken from the other two offset
# tags, or from XMP when that's the only date. And a time recorded with no
# zone, or a file with none, shown in the household's zone (--time-zone). The
# background metadata pass leaves all of it alone. A copy of bytes already in
# the store, from a row that came in with no zone, gets the file's reading.
#
#   FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-import-dates.sh
#
# Runs its own server against its own database and blob store. The test
# files are tiny ones it makes itself.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"

DB=framestation_import_dates; PORT=8068; API="http://127.0.0.1:$PORT"
export FRAMESTATION_DATABASE_URL="postgres://framestation:x@127.0.0.1:55432/$DB?sslmode=disable"
ROOT="$SCRATCH/import-dates"; rm -rf "$ROOT"; mkdir -p "$ROOT/blobroot" "$ROOT/lib" "$ROOT/again"
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
trap 'kill $SERVER 2>/dev/null; wait $SERVER 2>/dev/null; admin "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1' EXIT
for _ in $(seq 1 120); do curl -s -o /dev/null "$API/health" && break; sleep 0.5; done

# ---------------------------------------------------------------- the files
# Each is dated the way one kind of file in a real library was (2026-10-24
# audit). Expected: local time, the zone the file recorded, the household's
# zone where it recorded none. June 13, 2023 was daylight time in New York.
L="$ROOT/lib"
video(){ ffmpeg -v error -y -f lavfi -i testsrc=duration=1:size=64x48:rate=5 \
  -c:v libx264 -pix_fmt yuv420p -movflags use_metadata_tags "$@"; }
image(){ vips gaussnoise "$ROOT/n.v" 32 32 >/dev/null 2>&1 && vips copy "$ROOT/n.v" "$1" >/dev/null 2>&1; }
stamp(){ exiftool -q -q -overwrite_original "$@"; }

# An iPhone clip trimmed later: creation_time is the trim, minutes after.
video -metadata creation_time=2023-06-14T02:39:26Z \
      -metadata "com.apple.quicktime.creationdate=2023-06-13T22:31:13-0400" "$L/iphone.mov"
# A clip from another app, with only the UTC stamp.
video -metadata creation_time=2023-06-14T01:00:00Z "$L/other.mp4"
image "$L/zone.jpg";   stamp -DateTimeOriginal="2023:06:13 20:00:00" -OffsetTimeOriginal="-04:00" "$L/zone.jpg"
image "$L/clock.jpg";  stamp -DateTimeOriginal="2023:06:13 19:00:00" "$L/clock.jpg"
image "$L/offset.jpg"; stamp -DateTimeOriginal="2023:06:13 18:00:00" -OffsetTime="-04:00" "$L/offset.jpg"
image "$L/saved.png";  stamp -XMP:DateCreated="2023:06:13 17:00:00-04:00" "$L/saved.png"
image "$L/plain.png";  touch -t 202306140030.00 "$L/plain.png"
# The same bytes at another path, for the copy below.
cp -p "$L/iphone.mov" "$ROOT/again/iphone.mov"

redeem(){
  CODE=$(cd "$SERVER_DIR" && "$BIN" invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
  curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
    -d "{\"code\":\"$CODE\",\"displayName\":\"$1\",\"deviceName\":\"iPhone\",\"platform\":\"ios\"}" \
    | jq '["personalSpace"]["id"]'
}
FIRST=$(redeem "First"); SECOND=$(redeem "Second")

# What Synology Photos shows for each, as export-synology-dates.sh writes it.
SYNOLOGY="$ROOT/synology.tsv"
printf '%s\t%s\t%s\n' \
  "$L/iphone.mov" "2023-06-13 22:31:13" 1  "$L/other.mp4"  "2023-06-13 21:00:00" 2 \
  "$L/zone.jpg"   "2023-06-13 20:00:00" 3  "$L/clock.jpg"  "2023-06-13 19:00:00" 4 \
  "$L/offset.jpg" "2023-06-13 18:00:00" 5  "$L/saved.png"  "2023-06-13 17:00:00" 6 \
  "$L/plain.png"  "2023-06-13 20:30:00" 7 > "$SYNOLOGY"
# The same, but one file at the UTC time the old import kept for it.
sed 's/2023-06-13 20:30:00/2023-06-14 00:30:00/' "$SYNOLOGY" > "$ROOT/synology-off.tsv"
compare(){ (cd "$SERVER_DIR" && "$BIN" compare-dates --path "$L" --time-zone America/New_York "$@" 2>&1); }

# `plain.png`'s modification time is a moment: 00:30 UTC, 20:30 the evening
# before in New York. touch read it as this Mac's local time, so it's set
# again in UTC here.
TZ=UTC touch -t 202306140030.00 "$L/plain.png"

echo "Before importing, compare-dates reads the files and writes nothing:"
BEFORE=$(compare --synology "$SYNOLOGY")
check "every file would match Synology Photos" "1" \
  "$(echo "$BEFORE" | grep -c 'Every file matches Synology Photos to the second.')"
check "nothing was imported by looking" "0" "$(q "SELECT count(*) FROM assets")"
OFF=$(compare --synology "$ROOT/synology-off.tsv")
check "a file four hours off is reported" "1" "$(echo "$OFF" | grep -cE 'Different: +1$')"
check "and named, with both times" "1" \
  "$(echo "$OFF" | grep -c 'plain.png  2023-06-13 20:30:00 | 2023-06-14 00:30:00 | -4:00:00')"

(cd "$SERVER_DIR" && "$BIN" import --path "$L" --space "$FIRST" --time-zone America/New_York > "$ROOT/import.log" 2>&1)
grep -q "Dated by:" "$ROOT/import.log" && ok "the import summary says what dated each file" \
  || bad "the import summary says what dated each file" "a Dated by: section" "$(tail -5 "$ROOT/import.log")"

row(){ q "SELECT to_char(a.local_captured_at, 'YYYY-MM-DD HH24:MI:SS') || ' ' ||
                 COALESCE(a.captured_tz_off::text, '-') || ' ' || COALESCE(a.tz_off_fallback::text, '-') || ' ' ||
                 to_char(a.captured_at AT TIME ZONE 'UTC', 'HH24:MI:SS')
          FROM space_assets sa JOIN assets a ON a.id = sa.asset_id
          WHERE sa.space_id = '$1' AND sa.filename = '$2'"; }
expect(){
  # name | local | zone | fallback | UTC moment
  check "$2: $1" "$3 $4 $5 $6" "$(row "$FIRST" "$2")"
}

echo "As imported (local time, file's zone, household zone, UTC moment):"
expect "an iPhone video keeps the evening and zone it was filmed in" iphone.mov "2023-06-13 22:31:13" -14400 - 02:31:13
expect "a UTC-only video shows in the household's zone"             other.mp4  "2023-06-13 21:00:00" - -14400 01:00:00
expect "a photo with a zone keeps it"                                zone.jpg   "2023-06-13 20:00:00" -14400 - 00:00:00
expect "a photo with no zone keeps its clock"                        clock.jpg  "2023-06-13 19:00:00" - -14400 23:00:00
expect "a zone in OffsetTime counts"                                 offset.jpg "2023-06-13 18:00:00" -14400 - 22:00:00
expect "an XMP-only date and zone are read"                          saved.png  "2023-06-13 17:00:00" -14400 - 21:00:00
expect "a file with no date shows its modified time in the household's zone" plain.png "2023-06-13 20:30:00" - -14400 00:30:00

# The background metadata pass runs the same probe and must agree.
for _ in $(seq 1 120); do
  [ "$(q "SELECT count(*) FROM derivation_jobs WHERE state IN ('pending', 'running')")" = "0" ] && break; sleep 1
done
echo "After the metadata pass:"
check "every local time is unchanged" \
  "2023-06-13 22:31:13|2023-06-13 21:00:00|2023-06-13 20:00:00|2023-06-13 19:00:00|2023-06-13 18:00:00|2023-06-13 17:00:00|2023-06-13 20:30:00" \
  "$(for f in iphone.mov other.mp4 zone.jpg clock.jpg offset.jpg saved.png plain.png; do row "$FIRST" "$f" | cut -c1-19; done | paste -sd'|' -)"

echo "After importing, compare-dates checks what the library holds:"
AFTER=$(compare --synology "$SYNOLOGY" --space "$FIRST")
check "every stored time matches Synology Photos" "1" \
  "$(echo "$AFTER" | grep -c 'Every file matches Synology Photos to the second.')"
check "the grid has as many items as Synology's" "7 7" \
  "$(echo "$AFTER" | awk '/Grid items here:/ {h=$NF} /Grid items in Synology:/ {s=$NF} END {print h, s}')"

# A row from before this fix: same bytes, no zone, its UTC stamp kept as local.
q "UPDATE assets SET captured_tz_off = NULL, tz_off_fallback = NULL,
     captured_at = '2023-06-14T02:39:26Z', local_captured_at = '2023-06-14 02:39:26'
   WHERE id = (SELECT asset_id FROM space_assets WHERE space_id = '$FIRST' AND filename = 'iphone.mov')" >/dev/null
(cd "$SERVER_DIR" && "$BIN" import --path "$ROOT/again" --space "$SECOND" --time-zone America/New_York > "$ROOT/again.log" 2>&1)
echo "A copy of bytes the store already had:"
check "it's stored once already" "1" "$(grep -c 'Stored once already: 1' "$ROOT/again.log")"
check "it takes the file's own date, not the zone-less row's" \
  "2023-06-13 22:31:13 -14400 - 02:31:13" "$(row "$SECOND" iphone.mov)"
check "the row it copied is left as it was" \
  "2023-06-14 02:39:26 - - 02:39:26" "$(row "$FIRST" iphone.mov)"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
