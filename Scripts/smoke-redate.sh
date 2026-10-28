#!/bin/bash
# redate puts a library's rows at the times Synology Photos shows its files,
# where they hold another: a row an earlier import kept a video's UTC stamp in
# as local time (the Shared Space's, four or five hours late), and a phone's
# own backup of a photo whose time was set in Synology. Each takes Synology's
# time in the household's zone, every library showing it hears of the change,
# and a file in the library layout moves to its new month's folder. A row
# another library shows too is left alone unless asked, and so is a row two of
# Synology's files share at different times. A dry run changes nothing, and a
# second run finds nothing to do.
#
#   FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-redate.sh
#
# Runs its own server against its own database and blob store. The test files
# are tiny ones it makes itself.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"

DB=framestation_redate; PORT=8065; API="http://127.0.0.1:$PORT"
export FRAMESTATION_DATABASE_URL="postgres://framestation:x@127.0.0.1:55432/$DB?sslmode=disable"
ROOT="$SCRATCH/redate"; rm -rf "$ROOT"; mkdir -p "$ROOT/blobroot" "$ROOT/lib" "$ROOT/phone" "$ROOT/layout/2023/11"
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
# Shaped like the second library's (2026-10-27). July 5, 2024 was daylight
# time in New York, September 12, 2023 too.
L="$ROOT/lib"
video(){ ffmpeg -v error -y -f lavfi -i testsrc=duration=1:size=64x48:rate=5 \
  -c:v libx264 -pix_fmt yuv420p -movflags use_metadata_tags "$@"; }
image(){ vips gaussnoise "$ROOT/n.v" 32 32 >/dev/null 2>&1 && vips copy "$ROOT/n.v" "$1" >/dev/null 2>&1; }
stamp(){ exiftool -q -q -overwrite_original "$@"; }
# Two clips dated by a UTC stamp alone, a photo already at Synology's time, a
# photo whose time was set in Synology, and the same bytes twice.
video -metadata creation_time=2024-07-05T18:10:06Z "$L/late.mov"
video -metadata creation_time=2024-07-05T18:12:30Z "$L/shared.mov"
image "$L/right.jpg"; stamp -DateTimeOriginal="2024:07:05 12:00:00" -OffsetTimeOriginal="-04:00" "$L/right.jpg"
image "$L/IMG_7495.jpg"; stamp -DateTimeOriginal="2023:11:20 03:46:37" -OffsetTimeOriginal="-05:00" "$L/IMG_7495.jpg"
image "$L/twice.png"; cp -p "$L/twice.png" "$L/twice-2.png"
cp -p "$L/IMG_7495.jpg" "$ROOT/phone/IMG_7495.jpg"

redeem(){
  CODE=$(cd "$SERVER_DIR" && "$BIN" invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
  curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
    -d "{\"code\":\"$CODE\",\"displayName\":\"$1\",\"deviceName\":\"iPhone\",\"platform\":\"ios\"}" \
    | jq '["personalSpace"]["id"]'
}
FIRST=$(redeem "First"); SECOND=$(redeem "Second")
import(){ (cd "$SERVER_DIR" && "$BIN" import --space "$FIRST" --time-zone America/New_York --path "$@" > /dev/null 2>&1); }
# The row a file is placed as; the twice-held bytes are placed under either name.
asset(){ q "SELECT asset_id FROM space_assets WHERE space_id = '$FIRST' AND filename LIKE '$1' LIMIT 1"; }
row(){ q "SELECT to_char(a.local_captured_at, 'YYYY-MM-DD HH24:MI:SS') || ' ' ||
                 COALESCE(a.captured_tz_off::text, '-') || ' ' || COALESCE(a.tz_off_fallback::text, '-') || ' ' ||
                 to_char(a.captured_at AT TIME ZONE 'UTC', 'HH24:MI:SS')
          FROM assets a WHERE a.id = '$(asset "$1")'"; }
heard(){ q "SELECT count(*) FROM change_log c JOIN space_assets sa ON sa.id = c.entity_id
            WHERE sa.asset_id = '$(asset "$1")' AND c.space_id = '$2' AND c.op = 'update'"; }

# The phone's backup of the photo, in the library layout: a row with no import
# of its own, placed from the phone, its file in its month's folder.
import "$ROOT/phone"
q "DELETE FROM import_records WHERE starts_with(source_path, '$ROOT/phone/')" >/dev/null
q "UPDATE space_assets SET on_device = true WHERE asset_id = '$(asset IMG_7495.jpg)'" >/dev/null
cp -p "$L/IMG_7495.jpg" "$ROOT/layout/2023/11/IMG_7495.jpg"
q "UPDATE assets SET storage_path = '$ROOT/layout/2023/11/IMG_7495.jpg' WHERE id = '$(asset IMG_7495.jpg)'" >/dev/null
# The library: its copy of the photo left out for the phone's, and of the
# twice-held bytes one row.
import "$L"
# Two rows the way the Shared Space's import left its videos: the UTC stamp
# kept as the local time, no zone. One of them in a second library as well.
for f in late.mov shared.mov; do
  q "UPDATE assets SET captured_tz_off = NULL, tz_off_fallback = NULL,
       local_captured_at = (captured_at AT TIME ZONE 'UTC') WHERE id = '$(asset $f)'" >/dev/null
done
q "INSERT INTO space_assets (space_id, asset_id, uploaded_by_user_id)
   SELECT '$SECOND', '$(asset shared.mov)', created_by FROM spaces WHERE id = '$SECOND'" >/dev/null

# What Synology Photos shows for each: the clips at their stamps in New York,
# the photo where it was set, and the twice-held bytes at two times.
TWICE=$(row 'twice%' | cut -c1-19)
SYNOLOGY="$ROOT/synology.tsv"
printf '%s\t%s\t%s\n' \
  "$L/late.mov" "2024-07-05 14:10:06" 1  "$L/shared.mov" "2024-07-05 14:12:30" 2 \
  "$L/right.jpg" "2024-07-05 12:00:00" 3  "$L/IMG_7495.jpg" "2023-09-12 06:46:37" 4 \
  "$L/twice.png" "$TWICE" 5  "$L/twice-2.png" "2024-07-06 09:00:00" 6 > "$SYNOLOGY"
redate(){ (cd "$SERVER_DIR" && "$BIN" redate --path "$L" --space "$FIRST" --synology "$SYNOLOGY" \
  --time-zone America/New_York "$@" 2>&1); }
compare(){ (cd "$SERVER_DIR" && "$BIN" compare-dates --path "$L" --synology "$SYNOLOGY" --space "$FIRST" \
  --time-zone America/New_York 2>&1); }
BEFORE="$(row late.mov)|$(row shared.mov)|$(row IMG_7495.jpg)|$(row 'twice%')"

echo "A dry run says what it would change, and changes nothing:"
DRY=$(redate --dry-run)
check "five rows hold Synology's files, one at its time already" "5 1" \
  "$(echo "$DRY" | awk '/Rows holding files Synology lists:/ {r=$NF} /At Synology.s time already:/ {s=$NF} END {print r, s}')"
check "two to change: one an import made, one the phone's" "2 1 1" \
  "$(echo "$DRY" | awk '/To put at Synology.s time:/ {c=$NF} /imported from here:/ {i=$NF} /backed up from a phone:/ {p=$NF} END {print c, i, p}')"
check "one shown in another library too, left alone" "1" \
  "$(echo "$DRY" | awk '/Shown in another library too, left alone:/ {print $NF}')"
check "and one held for two files at different times, named" "1 1" \
  "$(echo "$DRY" | awk '/at different times, left alone:/ {print $NF}') $(echo "$DRY" | grep -c 'twice-2.png  +  twice.png')"
check "nothing moved" "$BEFORE" "$(row late.mov)|$(row shared.mov)|$(row IMG_7495.jpg)|$(row 'twice%')"

echo "Run, each row takes Synology's time in the household's zone:"
RUN=$(redate)
check "it says what it did" "1" "$(echo "$RUN" | grep -c "Put 2 rows at Synology's time; 1 files moved")"
check "the clip kept four hours late is at its stamp in New York" \
  "2024-07-05 14:10:06 -14400 -14400 18:10:06" "$(row late.mov)"
check "the phone's photo is where Synology shows it" \
  "2023-09-12 06:46:37 -14400 -14400 10:46:37" "$(row IMG_7495.jpg)"
check "its file moved to that month's folder" "$ROOT/layout/2023/09/IMG_7495.jpg yes no" \
  "$(q "SELECT storage_path FROM assets WHERE id = '$(asset IMG_7495.jpg)'") \
$([ -f "$ROOT/layout/2023/09/IMG_7495.jpg" ] && echo yes || echo no) \
$([ -f "$ROOT/layout/2023/11/IMG_7495.jpg" ] && echo yes || echo no)"
check "and the library hears of both" "1 1" "$(heard late.mov "$FIRST") $(heard IMG_7495.jpg "$FIRST")"
check "the row another library shows is as it was" "$(echo "$BEFORE" | cut -d'|' -f2)" "$(row shared.mov)"
check "and so is the one held for two times" "$(echo "$BEFORE" | cut -d'|' -f4)" "$(row 'twice%')"

echo "With --with-other-libraries, the shared row too, in both:"
redate --with-other-libraries > /dev/null
check "it's at its stamp in New York" "2024-07-05 14:12:30 -14400 -14400 18:12:30" "$(row shared.mov)"
check "and both libraries hear of it" "1 1" "$(heard shared.mov "$FIRST") $(heard shared.mov "$SECOND")"
AFTER=$(compare)
check "compare-dates finds all but the twice-held file at Synology's time" "5 1" \
  "$(echo "$AFTER" | awk '/Same local time:/ {s=$NF} /Different:/ {d=$NF} END {print s, d}')"
check "and a second run finds nothing to do" "1" "$(redate --with-other-libraries | grep -c 'Nothing to change.')"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
