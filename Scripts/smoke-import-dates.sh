#!/bin/bash
# The import reads each file's dates the way Synology Photos does, so a
# library lands in the same hours and on the same days as it shows there. An
# iPhone video by the local time and zone it records, not its UTC stamp. A
# photo by its EXIF date and zone, the zone also taken from the other two
# offset tags. Another video by its UTC stamp, the one in its movie header,
# not the creation_time key a video editor writes too. Anything else by its
# modification time, which Synology's backup sets from the phone's library:
# an XMP date, and a stamp in a 64-bit (version 1) movie header, are passed
# over, as Synology passes them over. A time with no zone shows in the
# household's (--time-zone). The background metadata pass leaves all of it
# alone, and so does the startup pass that dates uploads from their names. A
# copy of bytes already in the store gets the file's reading, not the stored
# row's, and with --keep-copies a library's second copy of a file is an item
# of its own. Where a file and Synology differ, compare-dates says which date
# Synology went by.
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
# A clip saved from another app: only a UTC stamp, 31 seconds after the time
# the phone's library gave it (the file's modification time, set below).
video -metadata creation_time=2023-06-14T01:00:31Z "$L/other.mp4"
# A trim saved as a QuickTime movie, with only a UTC stamp: Synology goes by
# it, an hour and 17 minutes after the modification time.
video -metadata creation_time=2023-06-14T03:07:13Z "$L/trimmed.MOV"
# A clip Vimeo made: its movie header in the 64-bit form, whose stamp
# Synology doesn't read. ffmpeg writes the 32-bit one, so it's widened here;
# the header comes after the media, so nothing else moves.
video -metadata creation_time=2023-06-14T01:10:31Z "$L/vimeo.mp4"
python3 - "$L/vimeo.mp4" <<'PY'
import struct, sys
path = sys.argv[1]
data = bytearray(open(path, "rb").read())
def boxes(start, end):
    while start + 8 <= end:
        size, kind = struct.unpack(">I4s", data[start:start + 8])
        yield start, kind, size
        start += size
moov, _, moov_size = next(b for b in boxes(0, len(data)) if b[1] == b"moov")
mvhd, _, size = next(b for b in boxes(moov + 8, moov + moov_size) if b[1] == b"mvhd")
body = data[mvhd + 8:mvhd + size]
assert body[0] == 0
created, modified, scale, duration = struct.unpack(">IIII", body[4:20])
wide = bytes([1]) + body[1:4] + struct.pack(">QQIQ", created, modified, scale, duration) + body[20:]
data[mvhd:mvhd + size] = struct.pack(">I4s", 8 + len(wide), b"mvhd") + wide
struct.pack_into(">I", data, moov, moov_size + 8 + len(wide) - size)
open(path, "wb").write(data)
PY
# A clip CapCut exported: besides its movie header's stamp it writes a
# creation_time key of its own, six minutes earlier, which ffprobe reports.
# Synology goes by the header's.
video -metadata creation_time=2023-06-14T01:14:00Z "$L/capcut.mov"
python3 - "$L/capcut.mov" <<'PY'
import datetime, struct, sys
path = sys.argv[1]
data = bytearray(open(path, "rb").read())
def boxes(start, end):
    while start + 8 <= end:
        size, kind = struct.unpack(">I4s", data[start:start + 8])
        yield start, kind, size
        start += size
moov, _, moov_size = next(b for b in boxes(0, len(data)) if b[1] == b"moov")
mvhd, _, _ = next(b for b in boxes(moov + 8, moov + moov_size) if b[1] == b"mvhd")
assert data[mvhd + 8] == 0
moment = datetime.datetime(2023, 6, 14, 1, 20, 13, tzinfo=datetime.timezone.utc)
struct.pack_into(">I", data, mvhd + 12, int(moment.timestamp()) + 2082844800)
open(path, "wb").write(data)
PY
image "$L/zone.jpg";   stamp -DateTimeOriginal="2023:06:13 20:00:00" -OffsetTimeOriginal="-04:00" "$L/zone.jpg"
image "$L/clock.jpg";  stamp -DateTimeOriginal="2023:06:13 19:00:00" "$L/clock.jpg"
image "$L/offset.jpg"; stamp -DateTimeOriginal="2023:06:13 18:00:00" -OffsetTime="-04:00" "$L/offset.jpg"
# A screenshot whose only date is XMP's, written in Central time. And one
# whose XMP date carries that zone, which the metadata pass would otherwise
# apply to the modification time and move it an hour.
image "$L/saved.png";  stamp -XMP:DateCreated="2023:06:13 16:44:06" "$L/saved.png"
image "$L/zoned.png";  stamp -XMP:DateCreated="2023:06:13 16:44:06-05:00" "$L/zoned.png"
image "$L/plain.png"
# A screenshot whose name says 4:45 PM, half an hour before its modification
# time: Synology shows the modification time, and the startup backfill, which
# dates an upload from a name like it, must leave it there.
SHOT="Screenshot 2023-06-13 at 4.45.00 PM.png"
image "$L/$SHOT"
# A second copy of plain.png's bytes, in another folder and modified later:
# Synology shows it as an item of its own, at its own modification time.
mkdir -p "$L/later"; cp "$L/plain.png" "$L/later/plain-2.png"
# The same bytes at other paths, for the copies below.
cp -p "$L/iphone.mov" "$ROOT/again/iphone.mov"
cp -p "$L/zone.jpg" "$ROOT/again/zone.jpg"

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
  "$L/iphone.mov" "2023-06-13 22:31:13" 1  "$L/other.mp4"  "2023-06-13 21:00:31" 2 \
  "$L/zone.jpg"   "2023-06-13 20:00:00" 3  "$L/clock.jpg"  "2023-06-13 19:00:00" 4 \
  "$L/offset.jpg" "2023-06-13 18:00:00" 5  "$L/saved.png"  "2023-06-13 17:44:06" 6 \
  "$L/plain.png"  "2023-06-13 20:30:00" 7  "$L/zoned.png"  "2023-06-13 17:44:06" 8 \
  "$L/trimmed.MOV" "2023-06-13 23:07:13" 9 "$L/vimeo.mp4" "2023-06-13 21:10:00" 10 \
  "$L/$SHOT"      "2023-06-13 17:15:30" 11 "$L/later/plain-2.png" "2023-06-13 22:00:00" 12 \
  "$L/capcut.mov" "2023-06-13 21:20:13" 13 > "$SYNOLOGY"
# The same, but one file at the UTC time the old import kept for it, and the
# Vimeo clip at the stamp it carries.
sed -e 's/2023-06-13 20:30:00/2023-06-14 00:30:00/' -e 's/2023-06-13 21:10:00/2023-06-13 21:10:31/' \
  "$SYNOLOGY" > "$ROOT/synology-off.tsv"
compare(){ (cd "$SERVER_DIR" && "$BIN" compare-dates --path "$L" --time-zone America/New_York "$@" 2>&1); }

# Modification times are moments, set in UTC: 00:30 UTC is 20:30 the evening
# before in New York. Set last, since writing a file's tags changes it.
TZ=UTC touch -t 202306140030.00 "$L/plain.png"
TZ=UTC touch -t 202306140100.00 "$L/other.mp4"
TZ=UTC touch -t 202306140150.07 "$L/trimmed.MOV"
TZ=UTC touch -t 202306140110.00 "$L/vimeo.mp4"
TZ=UTC touch -t 202306140130.00 "$L/capcut.mov"
TZ=UTC touch -t 202306132115.30 "$L/$SHOT"
TZ=UTC touch -t 202306140200.00 "$L/later/plain-2.png"
TZ=UTC touch -t 202306132144.06 "$L/saved.png"
TZ=UTC touch -t 202306132144.06 "$L/zoned.png"

echo "Before importing, compare-dates reads the files and writes nothing:"
BEFORE=$(compare --synology "$SYNOLOGY")
check "every file would match Synology Photos" "1" \
  "$(echo "$BEFORE" | grep -c 'Every file matches Synology Photos to the second.')"
check "nothing was imported by looking" "0" "$(q "SELECT count(*) FROM assets")"
OFF=$(compare --synology "$ROOT/synology-off.tsv")
check "files that differ are reported" "1" "$(echo "$OFF" | grep -cE 'Different: +2$')"
check "and named, with both times" "1" \
  "$(echo "$OFF" | grep -c 'plain.png  2023-06-13 20:30:00 | 2023-06-14 00:30:00 | -4:00:00')"
check "with the date Synology went by instead" "1" \
  "$(echo "$OFF" | grep -c '1  .mp4  here: its modification time  Synology: its date, in UTC')"
check "and that file's own" "1" "$(echo "$OFF" | grep -c 'vimeo.mp4  2023-06-13 21:10:00 | 2023-06-13 21:10:31')"
check "or that it went by neither" "1" \
  "$(echo "$OFF" | grep -c '1  .png  here: its modification time  Synology: some other date')"

(cd "$SERVER_DIR" && "$BIN" import --path "$L" --space "$FIRST" --time-zone America/New_York \
  --keep-copies > "$ROOT/import.log" 2>&1)
grep -q "Dated by:" "$ROOT/import.log" && ok "the import summary says what dated each file" \
  || bad "the import summary says what dated each file" "a Dated by: section" "$(tail -5 "$ROOT/import.log")"
check "with --keep-copies, the copy came in, its bytes stored once" "1" \
  "$(grep -c 'Stored once already: 1' "$ROOT/import.log")"

row(){ q "SELECT to_char(a.local_captured_at, 'YYYY-MM-DD HH24:MI:SS') || ' ' ||
                 COALESCE(a.captured_tz_off::text, '-') || ' ' || COALESCE(a.tz_off_fallback::text, '-') || ' ' ||
                 to_char(a.captured_at AT TIME ZONE 'UTC', 'HH24:MI:SS')
          FROM space_assets sa JOIN assets a ON a.id = sa.asset_id
          WHERE sa.space_id = '$1' AND sa.filename = '$2'"; }
expect(){
  # name | local | zone | fallback | UTC moment
  check "$2: $1" "$3 $4 $5 $6" "$(row "$FIRST" "$2")"
}

echo "As imported (local time, zone stored, of which the household's, UTC moment):"
expect "an iPhone video keeps the evening and zone it was filmed in" iphone.mov "2023-06-13 22:31:13" -14400 - 02:31:13
expect "a video's UTC stamp shows in the household's zone"          other.mp4  "2023-06-13 21:00:31" -14400 -14400 01:00:31
expect "and a .mov's, minutes from its modified time"               trimmed.MOV "2023-06-13 23:07:13" -14400 -14400 03:07:13
expect "a stamp in a 64-bit header is passed over for the modified time" vimeo.mp4 "2023-06-13 21:10:00" -14400 -14400 01:10:00
expect "an editor's creation_time key is passed over for the header's stamp" capcut.mov "2023-06-13 21:20:13" -14400 -14400 01:20:13
expect "a photo with a zone keeps it"                                zone.jpg   "2023-06-13 20:00:00" -14400 - 00:00:00
expect "a photo with no zone keeps its clock"                        clock.jpg  "2023-06-13 19:00:00" -14400 -14400 23:00:00
expect "a zone in OffsetTime counts"                                 offset.jpg "2023-06-13 18:00:00" -14400 - 22:00:00
expect "an XMP date is passed over for the modified time"            saved.png  "2023-06-13 17:44:06" -14400 -14400 21:44:06
expect "and so is one with its own zone"                             zoned.png  "2023-06-13 17:44:06" -14400 -14400 21:44:06
expect "a file with no date shows its modified time in the household's zone" plain.png "2023-06-13 20:30:00" -14400 -14400 00:30:00
expect "and a screenshot its modified time, not its name's"         "$SHOT"    "2023-06-13 17:15:30" -14400 -14400 21:15:30
expect "a second copy is an item of its own, at its own modified time" plain-2.png "2023-06-13 22:00:00" -14400 -14400 02:00:00

# The background metadata pass runs the same probe and must agree.
for _ in $(seq 1 120); do
  [ "$(q "SELECT count(*) FROM derivation_jobs WHERE state IN ('pending', 'running')")" = "0" ] && break; sleep 1
done
echo "After the metadata pass:"
check "every local time is unchanged" \
  "2023-06-13 22:31:13|2023-06-13 21:00:31|2023-06-13 23:07:13|2023-06-13 21:10:00|2023-06-13 21:20:13|2023-06-13 20:00:00|2023-06-13 19:00:00|2023-06-13 18:00:00|2023-06-13 17:44:06|2023-06-13 17:44:06|2023-06-13 20:30:00|2023-06-13 22:00:00" \
  "$(for f in iphone.mov other.mp4 trimmed.MOV vimeo.mp4 capcut.mov zone.jpg clock.jpg offset.jpg saved.png zoned.png plain.png plain-2.png; do row "$FIRST" "$f" | cut -c1-19; done | paste -sd'|' -)"

echo "After importing, compare-dates checks what the library holds:"
AFTER=$(compare --synology "$SYNOLOGY" --space "$FIRST")
check "every stored time matches Synology Photos" "1" \
  "$(echo "$AFTER" | grep -c 'Every file matches Synology Photos to the second.')"
check "the grid has as many items as Synology's" "13 13" \
  "$(echo "$AFTER" | awk '/Grid items here:/ {h=$NF} /Grid items in Synology:/ {s=$NF} END {print h, s}')"

# A row from before this fix: same bytes, no zone, its UTC stamp kept as local.
q "UPDATE assets SET captured_tz_off = NULL, tz_off_fallback = NULL,
     captured_at = '2023-06-14T02:39:26Z', local_captured_at = '2023-06-14 02:39:26'
   WHERE id = (SELECT asset_id FROM space_assets WHERE space_id = '$FIRST' AND filename = 'iphone.mov')" >/dev/null
# And one dated otherwise, zone and all, the way another library may hold it.
q "UPDATE assets SET captured_tz_off = -18000, tz_off_fallback = NULL,
     captured_at = '2023-06-14T02:00:00Z', local_captured_at = '2023-06-13 21:00:00'
   WHERE id = (SELECT asset_id FROM space_assets WHERE space_id = '$FIRST' AND filename = 'zone.jpg')" >/dev/null
(cd "$SERVER_DIR" && "$BIN" import --path "$ROOT/again" --space "$SECOND" --time-zone America/New_York > "$ROOT/again.log" 2>&1)
echo "Copies of bytes the store already had:"
check "they're stored once already" "1" "$(grep -c 'Stored once already: 2' "$ROOT/again.log")"
check "each takes the file's own date, not a zone-less row's" \
  "2023-06-13 22:31:13 -14400 - 02:31:13" "$(row "$SECOND" iphone.mov)"
check "nor a row dated otherwise" \
  "2023-06-13 20:00:00 -14400 - 00:00:00" "$(row "$SECOND" zone.jpg)"
check "the rows they copied are left as they were" \
  "2023-06-14 02:39:26 - - 02:39:26|2023-06-13 21:00:00 -18000 - 02:00:00" \
  "$(row "$FIRST" iphone.mov)|$(row "$FIRST" zone.jpg)"

# Without --keep-copies, a file whose bytes the library already holds is left
# out, as it is when an upload or a share put them there.
mkdir -p "$ROOT/dupes"; image "$ROOT/dupes/a.png"; cp -p "$ROOT/dupes/a.png" "$ROOT/dupes/b.png"
(cd "$SERVER_DIR" && "$BIN" import --path "$ROOT/dupes" --space "$SECOND" --time-zone America/New_York > "$ROOT/dupes.log" 2>&1)
check "without --keep-copies, a second copy is left out" "1 1" \
  "$(awk '/Imported:/ {i=$NF} /Already in library:/ {a=$4} END {print i, a}' "$ROOT/dupes.log")"
# A phone's backup of a photo the NAS already had from another library's
# import reuses that import's row. With --keep-copies, the same photo in this
# library's own folders is still that photo, not a second copy.
mkdir -p "$ROOT/shared" "$ROOT/mine"; image "$ROOT/shared/s.png"; cp -p "$ROOT/shared/s.png" "$ROOT/mine/m.png"
(cd "$SERVER_DIR" && "$BIN" import --path "$ROOT/shared" --space "$SECOND" > "$ROOT/shared.log" 2>&1)
q "INSERT INTO space_assets (space_id, asset_id, uploaded_by_user_id)
   SELECT '$FIRST', sa.asset_id, (SELECT created_by FROM spaces WHERE id = '$FIRST')
   FROM space_assets sa WHERE sa.space_id = '$SECOND' AND sa.filename = 's.png'" >/dev/null
(cd "$SERVER_DIR" && "$BIN" import --path "$ROOT/mine" --space "$FIRST" --keep-copies > "$ROOT/mine.log" 2>&1)
check "with --keep-copies, a photo a phone put here over another library's row is left out" "0 1" \
  "$(awk '/Stored once already:/ {r=$4} /Already in library:/ {a=$4} END {print r, a}' "$ROOT/mine.log")"
# And compare-dates checks a file left out like that against the library's
# own copy, rather than calling it missing.
printf '%s\t%s\t%s\n' "$ROOT/mine/m.png" \
  "$(q "SELECT to_char(a.local_captured_at, 'YYYY-MM-DD HH24:MI:SS') FROM space_assets sa
        JOIN assets a ON a.id = sa.asset_id WHERE sa.space_id = '$SECOND' AND sa.filename = 's.png'")" 1 \
  > "$ROOT/mine.tsv"
HELD=$(cd "$SERVER_DIR" && "$BIN" compare-dates --path "$ROOT/mine" --synology "$ROOT/mine.tsv" \
  --space "$FIRST" --time-zone America/New_York 2>&1)
check "and compare-dates compares it with the library's copy, one grid item" "1 0 1" \
  "$(echo "$HELD" | awk '/Same local time:/ {s=$NF} /In Synology, not here:/ {n=$NF} /showing these files:/ {t=$NF} END {print s, n, t}')"
# But a photo the phone holds twice, byte for byte, is one row here and two
# items in Synology: the library's second file of it comes in as a copy. One in
# another of the library's folders too, given Synology's export.
cp -p "$ROOT/mine/m.png" "$ROOT/mine/m-again.png"
(cd "$SERVER_DIR" && "$BIN" import --path "$ROOT/mine" --space "$FIRST" --keep-copies > "$ROOT/mine-again.log" 2>&1)
check "with --keep-copies, a second file of a photo the phone put here comes in" "1 0" \
  "$(awk '/Stored once already:/ {r=$4} /Already in library:/ {a=$4} END {print r, a}' "$ROOT/mine-again.log")"
mkdir -p "$ROOT/mine-too"; cp -p "$ROOT/mine/m.png" "$ROOT/mine-too/m.png"
printf '%s\t%s\t%s\n' "$ROOT/mine/m.png" "2023-06-13 20:30:00" 1 "$ROOT/mine-too/m.png" "2023-06-13 20:30:00" 2 \
  > "$ROOT/mine-too.tsv"
(cd "$SERVER_DIR" && "$BIN" import --path "$ROOT/mine-too" --space "$FIRST" --keep-copies \
  --synology "$ROOT/mine-too.tsv" > "$ROOT/mine-too.log" 2>&1)
check "and so does one in another of its folders, given Synology's export" "1 0" \
  "$(awk '/Stored once already:/ {r=$4} /Already in library:/ {a=$4} END {print r, a}' "$ROOT/mine-too.log")"

# Given Synology's dates, a time Synology shows that the file doesn't carry,
# set there or on the phone, is the one the grid goes by: a download Synology
# shows in 2015. Where the two agree the file's reading stands, zone and all.
mkdir -p "$ROOT/edited"; image "$ROOT/edited/download.png"; TZ=UTC touch -t 202502201344.43 "$ROOT/edited/download.png"
image "$ROOT/edited/away.jpg"; stamp -DateTimeOriginal="2023:06:13 20:00:00" -OffsetTimeOriginal="-07:00" "$ROOT/edited/away.jpg"
printf '%s\t%s\t%s\n' "$ROOT/edited/download.png" "2015-03-05 02:20:43" 1 \
  "$ROOT/edited/away.jpg" "2023-06-13 20:00:00" 2 > "$ROOT/edited.tsv"
(cd "$SERVER_DIR" && "$BIN" import --path "$ROOT/edited" --space "$SECOND" --time-zone America/New_York \
  --synology "$ROOT/edited.tsv" > "$ROOT/edited.log" 2>&1)
check "a time Synology shows that the file doesn't carry is the grid's, in the household's zone" \
  "2015-03-05 02:20:43 -18000 -18000 07:20:43" "$(row "$SECOND" download.png)"
check "where they agree, the file's own zone stays" "2023-06-13 20:00:00 -25200 - 03:00:00" "$(row "$SECOND" away.jpg)"
check "and the import says which came from Synology" "1" "$(grep -c "Synology Photos' own date: 1" "$ROOT/edited.log")"

# The startup backfill dates files from names like 20230613_163000. One
# placement made to look like an upload, so that its new time shows the pass
# has run past the imported files it must leave alone.
q "UPDATE space_assets SET filename = '20230613_163000.jpg' WHERE space_id = '$SECOND' AND filename = 'zone.jpg'" >/dev/null
q "DELETE FROM import_records WHERE asset_id =
     (SELECT asset_id FROM space_assets WHERE space_id = '$SECOND' AND filename = '20230613_163000.jpg')" >/dev/null
kill $SERVER; wait $SERVER 2>/dev/null
"$BIN" serve --hostname 127.0.0.1 --port $PORT >> "$ROOT/server.log" 2>&1 &
SERVER=$!
for _ in $(seq 1 120); do
  [ "$(row "$SECOND" 20230613_163000.jpg | cut -c1-19)" = "2023-06-13 16:30:00" ] && break; sleep 0.5
done
echo "After a restart, when the backfill dates files from their names:"
check "an upload named for a time takes it" "2023-06-13 16:30:00 0 - 16:30:00" "$(row "$SECOND" 20230613_163000.jpg)"
check "an imported screenshot keeps the time Synology shows" \
  "2023-06-13 17:15:30 -14400 -14400 21:15:30" "$(row "$FIRST" "$SHOT")"
check "and is marked a screenshot all the same" "t" \
  "$(q "SELECT 'screenshot' = ANY(a.media_subtypes) FROM space_assets sa JOIN assets a ON a.id = sa.asset_id
        WHERE sa.space_id = '$FIRST' AND sa.filename = '$SHOT'")"
# Every stored time but the two rows changed by hand above.
AGAIN=$(compare --synology "$SYNOLOGY" --space "$FIRST")
for _ in $(seq 1 120); do
  [ "$(q "SELECT count(*) FROM derivation_jobs WHERE state IN ('pending', 'running')")" = "0" ] && break; sleep 1
done
check "a time taken from Synology stays through the server's passes" \
  "2015-03-05 02:20:43 -18000 -18000 07:20:43" "$(row "$SECOND" download.png)"
check "and nothing else moved" "11 2" \
  "$(echo "$AGAIN" | awk '/Same local time:/ {s=$NF} /Different:/ {d=$NF} END {print s, d}')"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
