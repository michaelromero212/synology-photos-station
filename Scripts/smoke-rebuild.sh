#!/bin/bash
# The claim in ARCHITECTURE.md §3a, tested: wipe the database and rebuild the
# whole library from the folders alone.
#
# Runs against its own database rather than the development one, so proving the
# claim doesn't sign every device out of the library you were just using.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"

PGHOST=127.0.0.1; PGPORT=55432; PGUSER=framestation; DB=framestation_rebuild
LIB="$SCRATCH/rebuild"
export FRAMESTATION_BLOB_ROOT="${FRAMESTATION_BLOB_ROOT:-$SCRATCH/blobroot}"
export FRAMESTATION_DATABASE_URL="postgres://$PGUSER:x@$PGHOST:$PGPORT/$DB?sslmode=disable"

PASS=0; FAIL=0
q(){ psql -h $PGHOST -p $PGPORT -U $PGUSER -d $DB -tAqc "$1"; }
admin(){ psql -h $PGHOST -p $PGPORT -U $PGUSER -d postgres -tAqc "$1"; }
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; echo "      expected: $2"; echo "      actual:   $3"; FAIL=$((FAIL+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
rebuild(){ (cd "$SERVER_DIR" && swift run FrameStationServer rebuild \
  --homes "$LIB/homes" --shared "$LIB/shared" "$@" 2>&1); }

# ---------------------------------------------------------------- the library
rm -rf "$LIB"; mkdir -p "$LIB"
# Resolved, because the directory walk resolves too: on macOS /tmp is a symlink
# to /private/tmp, so storage_path records the real path and comparing against
# the unresolved one fails on a difference that isn't there.
LIB=$(cd "$LIB" && pwd -P)
photo(){ # path
  mkdir -p "$(dirname "$1")"
  vips gaussnoise "$SCRATCH/rebuild-n.v" 640 480 >/dev/null 2>&1
  vips copy "$SCRATCH/rebuild-n.v" "$1" >/dev/null 2>&1
}

MB="$LIB/homes/michael/Photos/MobileBackup"
photo "$MB/iPhone/2026/07/IMG_7001.jpg"
photo "$MB/iPhone/2026/08/IMG_7002.jpg"
# The other half of Synology's split: uploaded through the browser, so no
# device folder. Both trees are one library — scanning only MobileBackup left
# these behind.
photo "$LIB/homes/michael/Photos/PhotoLibrary/2022/05/Screenshot (24).png"
# Already in the flattened layout the server now writes.
photo "$LIB/homes/michael/Photos/2026/09/IMG_7005.jpg"
photo "$LIB/homes/morgan/Photos/MobileBackup/iPad/2026/07/IMG_8001.jpg"
# Nothing but PhotoLibrary — invisible to a MobileBackup-only scan.
photo "$LIB/homes/greg/Photos/PhotoLibrary/2019/03/IMG_6001.jpg"
photo "$LIB/shared/Family Shared/2026/07/IMG_9001.jpg"

# A real capture date, so the rebuild can be checked against something it could
# only have got from the file itself.
exiftool -overwrite_original -DateTimeOriginal="2026:07:18 11:05:00" \
  "$MB/iPhone/2026/07/IMG_7001.jpg" >/dev/null 2>&1

# Things that must NOT come back.
photo "$LIB/homes/michael/Documents/receipt.jpg"                    # not a library file
photo "$MB/iPhone/2026/07/@eaDir/IMG_7001.jpg"                      # Synology's own thumbnail
photo "$MB/iPhone/2026/07/#recycle/IMG_7003.jpg"                    # deliberately deleted
touch "$MB/iPhone/2026/07/notes.txt"                                # not media

SHA7001=$(shasum -a 256 "$MB/iPhone/2026/07/IMG_7001.jpg" | awk '{print $1}')

# ------------------------------------------------------------- an empty world
admin "DROP DATABASE IF EXISTS $DB;" >/dev/null
admin "CREATE DATABASE $DB OWNER $PGUSER;" >/dev/null
echo "=== 0. nothing to start from ==="
check "no tables at all" "0" "$(q "select count(*) from information_schema.tables where table_schema='public';")"

echo
echo "=== 1. a dry run writes nothing ==="
OUT=$(rebuild --dry-run)
check "it sees seven files" "1" "$(echo "$OUT" | grep -c 'Found:         7 files')"
check "and all three people" "1" "$(echo "$OUT" | grep -c 'People:        greg, michael, morgan')"
check "and the shared library" "1" "$(echo "$OUT" | grep -c 'Shared:        Family Shared')"
check "but wrote no assets" "0" "$(q "select count(*) from assets;")"

echo
echo "=== 2. rebuild ==="
OUT=$(rebuild)
check "indexed seven" "1" "$(echo "$OUT" | grep -c 'Indexed: 7')"
check "failed none" "1" "$(echo "$OUT" | grep -c 'Failed:  0')"
check "seven assets" "7" "$(q "select count(*) from assets;")"
check "seven placements" "7" "$(q "select count(*) from space_assets;")"

echo
echo "=== 3. the people came back ==="
check "three accounts" "3" "$(q "select count(*) from users;")"
check "named after their homes" "greg,michael,morgan" "$(q "select string_agg(dsm_username,',' order by dsm_username) from users;")"
# uid and home come from DSM, not from a folder name; sign-in fills them in.
check "no invented DSM uid" "0" "$(q "select count(*) from users where dsm_uid is not null;")"
check "one personal library each" "3" "$(q "select count(*) from spaces where kind='personal';")"
check "each owned by its person" "3" "$(q "select count(*) from space_members m join spaces s on s.id=m.space_id where s.kind='personal' and m.role='owner' and s.created_by=m.user_id;")"

echo
echo "=== 4. the photos are in the right libraries ==="
mine(){ q "select count(*) from space_assets sa join spaces s on s.id=sa.space_id join users u on u.id=s.created_by where s.kind='personal' and u.dsm_username='$1';"; }
check "michael has four" "4" "$(mine michael)"
check "morgan has one" "1" "$(mine morgan)"
# Both of Synology's trees, and the flattened one, are a single library.
check "greg, who only ever used the browser" "1" "$(mine greg)"
check "the PhotoLibrary half came too" "2" "$(q "select count(*) from assets where storage_path like '%/PhotoLibrary/%';")"
check "and the flattened tree" "1" "$(q "select count(*) from assets where storage_path like '%/Photos/2026/09/%';")"
check "the shared library has one" "1" "$(q "select count(*) from space_assets sa join spaces s on s.id=sa.space_id where s.kind='shared' and s.name='Family Shared';")"
check "shared membership is not guessed" "1" "$(q "select count(*) from space_members m join spaces s on s.id=m.space_id where s.kind='shared';")"
check "and it says so" "1" "$(echo "$OUT" | grep -c 'came back with one member')"

echo
echo "=== 5. the file is the photo ==="
check "storage_path is the real file" "1" "$(q "select count(*) from assets where storage_path='$MB/iPhone/2026/07/IMG_7001.jpg';")"
check "every asset points at a file" "7" "$(q "select count(*) from assets where storage_path is not null;")"
check "hashed from the bytes on disk" "$SHA7001" "$(q "select sha256 from assets where storage_path like '%IMG_7001.jpg';")"
check "nothing was copied into the blob store" "0" "$(find "$FRAMESTATION_BLOB_ROOT/blobs" -newer "$LIB/homes" -type f 2>/dev/null | wc -l | tr -d ' ')"
check "browse_path is that same file" "7" "$(q "select count(*) from space_assets sa join assets a on a.id=sa.asset_id where sa.browse_path = a.storage_path;")"

echo
echo "=== 6. the metadata came from the files ==="
check "EXIF capture date recovered" "2026-07-18 11:05:00" "$(q "select to_char(captured_at at time zone 'UTC','YYYY-MM-DD HH24:MI:SS') from assets where storage_path like '%IMG_7001.jpg';")"
check "dimensions recovered" "640x480" "$(q "select width || 'x' || height from assets where storage_path like '%IMG_7001.jpg';")"
check "everything has a date to sort by" "7" "$(q "select count(*) from assets where captured_at is not null;")"
check "and a local time to bucket on" "7" "$(q "select count(*) from assets where local_captured_at is not null;")"
check "original filenames kept" "1" "$(q "select count(*) from space_assets where filename='IMG_9001.jpg';")"

echo
echo "=== 7. what must not come back ==="
check "no file from outside the library" "0" "$(q "select count(*) from assets where storage_path like '%/Documents/%';")"
check "no Synology thumbnails" "0" "$(q "select count(*) from assets where storage_path like '%@eaDir%';")"
check "nothing out of the recycle bin" "0" "$(q "select count(*) from assets where storage_path like '%#recycle%';")"
check "no non-media" "0" "$(q "select count(*) from assets where storage_path like '%.txt';")"

echo
echo "=== 8. the clients can pick it up ==="
check "one change per photo" "7" "$(q "select count(*) from change_log where op='insert';")"
check "thumbnails queued" "7" "$(q "select count(*) from derivation_jobs where kind='thumbnails';")"

echo
echo "=== 9. running it again changes nothing ==="
OUT2=$(rebuild)
check "it recognizes what it indexed" "1" "$(echo "$OUT2" | grep -c 'every file on disk is already indexed')"
check "still seven assets" "7" "$(q "select count(*) from assets;")"
check "still seven placements" "7" "$(q "select count(*) from space_assets;")"
check "still three people" "3" "$(q "select count(*) from users;")"

echo
echo "=== 10. a photo added on disk is picked up ==="
photo "$MB/iPhone/2026/09/IMG_7004.jpg"
OUT3=$(rebuild)
check "one new file indexed" "1" "$(echo "$OUT3" | grep -c 'Indexed: 1')"
check "eight assets now" "8" "$(q "select count(*) from assets;")"
check "michael has five" "5" "$(mine michael)"

admin "DROP DATABASE IF EXISTS $DB;" >/dev/null

echo
echo "════════════════════════════════════"
echo "  passed: $PASS   failed: $FAIL"
echo "════════════════════════════════════"
[ "$FAIL" -eq 0 ]
