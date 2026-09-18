#!/bin/bash
# M2 smoke test: library import — exclusions, Live Photo pairing, dedup,
# resumability, and metadata.
#
#   FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-m2.sh
#
# Needs a freshly migrated, empty database and a server started with
# FRAMESTATION_BLOB_ROOT="$FRAMESTATION_TEST_DIR/blobroot".
set -uo pipefail

SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
API="${FRAMESTATION_API:-http://127.0.0.1:8099}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"
export FRAMESTATION_DATABASE_URL="${FRAMESTATION_DATABASE_URL:-postgres://framestation:x@127.0.0.1:55432/framestation?sslmode=disable}"
export FRAMESTATION_BLOB_ROOT="${FRAMESTATION_BLOB_ROOT:-$SCRATCH/blobroot}"
LIB="$SCRATCH/fakelib"
PASS=0; FAIL=0

q() { psql -h 127.0.0.1 -p 55432 -U framestation -d framestation -tAqc "$1"; }
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $1"; echo "      expected: $2"; echo "      actual:   $3"; FAIL=$((FAIL+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
jq_get() { python3 -c "import sys,json; d=json.load(sys.stdin); print(d$1)" 2>/dev/null; }

mkimg() { vips gaussnoise "$SCRATCH/tmp.v" "$2" "$3" >/dev/null 2>&1; vips copy "$SCRATCH/tmp.v" "$1" >/dev/null 2>&1; }

# ------------------------------------------------------- fake Synology library ---
echo "=== building a fake library with the usual NAS traps ==="
rm -rf "$LIB"; mkdir -p "$LIB/2024" "$LIB/Trip" "$LIB/Dupes"
mkimg "$LIB/2024/IMG_001.jpg" 1200 900
mkimg "$LIB/2024/IMG_002.jpg" 900 1200
exiftool -q -overwrite_original -Make=Apple -Model="iPhone 15" \
  -DateTimeOriginal="2024:08:12 10:30:00" -OffsetTimeOriginal="-04:00" \
  "$LIB/2024/IMG_001.jpg" >/dev/null 2>&1

# Live Photo pair: same stem, one still and one movie, same folder.
mkimg "$LIB/Trip/IMG_100.jpg" 1000 1000
ffmpeg -y -f lavfi -i testsrc=duration=2:size=480x480:rate=30 \
  -c:v libx264 -pix_fmt yuv420p "$LIB/Trip/IMG_100.mov" >/dev/null 2>&1

# Byte-identical copy of IMG_001 in another folder — must dedup to one asset.
cp "$LIB/2024/IMG_001.jpg" "$LIB/Dupes/copy_of_001.jpg"

# Traps. @eaDir is Synology's own thumbnail cache and appears in every folder;
# importing it would add hundreds of thousands of junk duplicates.
mkdir -p "$LIB/2024/@eaDir/IMG_001.jpg" "$LIB/#recycle" "$LIB/2024/@eaDir/nested/deep"
mkimg "$LIB/2024/@eaDir/IMG_001.jpg/SYNOPHOTO_THUMB_M.jpg" 120 90
mkimg "$LIB/2024/@eaDir/nested/deep/SYNOPHOTO_THUMB_XL.jpg" 320 240
mkimg "$LIB/#recycle/deleted.jpg" 800 600
echo "not a photo" > "$LIB/2024/notes.txt"
touch "$LIB/2024/._IMG_001.jpg"

echo "  real media: 5 (4 photos + 1 video, one of which is a duplicate)"
echo "  traps:      2 @eaDir, 1 #recycle, 1 .txt, 1 AppleDouble"

# -------------------------------------------------------------------- account ---
CODE=$(cd "$SERVER_DIR" && swift run FrameStationServer invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
R=$(curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$CODE\",\"displayName\":\"Michael\",\"deviceName\":\"iPhone\",\"platform\":\"ios\"}")
TOKEN=$(echo "$R" | jq_get '["token"]'); SPACE=$(echo "$R" | jq_get '["personalSpace"]["id"]')

echo
echo "=== 1. spaces command lists the destination ==="
SP_OUT=$(cd "$SERVER_DIR" && swift run FrameStationServer spaces 2>/dev/null)
echo "$SP_OUT" | grep -q "$SPACE" && ok "space id listed" || bad "space id listed" "$SPACE" "not found"
echo "$SP_OUT" | grep -q "Personal Space" && ok "space name listed" || bad "space name" "Personal Space" "missing"

echo
echo "=== 2. dry run reports without writing ==="
DRY=$(cd "$SERVER_DIR" && swift run FrameStationServer import --path "$LIB" --space "$SPACE" --dry-run 2>/dev/null)
echo "$DRY" | grep -qE "To import: 5" && ok "counts 5 importable (traps excluded)" \
  || bad "importable count" "5" "$(echo "$DRY" | grep 'To import' | xargs)"
check "dry run wrote no assets" "0" "$(q 'select count(*) from assets;')"

echo
echo "=== 3. import ==="
OUT=$(cd "$SERVER_DIR" && swift run FrameStationServer import --path "$LIB" --space "$SPACE" 2>/dev/null)
echo "$OUT" | grep -E "Imported:|Deduplicated:|Failed:" | sed 's/^/  /'
check "4 unique assets"   "4" "$(q 'select count(*) from assets;')"
check "4 placements"      "4" "$(q "select count(*) from space_assets where space_id='$SPACE';")"
check "no failures"       "0" "$(q "select count(*) from import_records where outcome='failed';")"
check "5 import records"  "5" "$(q 'select count(*) from import_records;')"
check "1 deduplicated"    "1" "$(q "select count(*) from import_records where outcome='deduplicated';")"

echo
echo "=== 4. traps were excluded ==="
check "no SYNOPHOTO thumbnails" "0" "$(q "select count(*) from import_records where source_path like '%@eaDir%';")"
check "no #recycle contents"    "0" "$(q "select count(*) from import_records where source_path like '%#recycle%';")"
check "no .txt"                 "0" "$(q "select count(*) from import_records where source_path like '%.txt';")"
check "no AppleDouble"          "0" "$(q "select count(*) from import_records where source_path like '%/._%';")"
check "120px thumb not an asset" "0" "$(q 'select count(*) from assets where width = 120;')"

echo
echo "=== 5. Live Photo pairing ==="
check "still and movie share a live group" "1" \
  "$(q "select count(*) from (select live_group_id from assets where live_group_id is not null group by 1 having count(*)=2) g;")"
check "group has one photo and one video" "1|1" \
  "$(q "select count(*) filter (where media_type='photo')||'|'||count(*) filter (where media_type='video') from assets where live_group_id is not null;")"

echo
echo "=== 6. EXIF survived the batch probe ==="
check "camera model" "iPhone 15" "$(q "select coalesce(camera_model,'-') from assets where sha256=(select sha256 from import_records where source_path like '%IMG_001.jpg' limit 1);")"
check "capture time honors -04:00 offset" "2024-08-12 14:30:00" \
  "$(q "select to_char(captured_at at time zone 'UTC','YYYY-MM-DD HH24:MI:SS') from assets where camera_model='iPhone 15';")"
check "videos got a duration" "1" "$(q "select count(*) from assets where media_type='video' and duration_ms > 0;")"

echo
echo "=== 7. blobs on disk, one per unique file ==="
check "4 blobs" "4" "$(find "$SCRATCH/blobroot/blobs" -type f 2>/dev/null | wc -l | tr -d ' ')"

echo
echo "=== 8. re-run is idempotent ==="
OUT2=$(cd "$SERVER_DIR" && swift run FrameStationServer import --path "$LIB" --space "$SPACE" 2>/dev/null)
echo "$OUT2" | grep -q "Nothing to do" && ok "second run skips everything" \
  || bad "second run" "Nothing to do" "$(echo "$OUT2" | grep 'To import' | xargs)"
check "still 4 assets" "4" "$(q 'select count(*) from assets;')"

echo
echo "=== 9. a changed source file is re-imported ==="
mkimg "$LIB/2024/IMG_002.jpg" 640 480
OUT3=$(cd "$SERVER_DIR" && swift run FrameStationServer import --path "$LIB" --space "$SPACE" 2>/dev/null)
echo "$OUT3" | grep -qE "To import: 1" && ok "detects the modified file" \
  || bad "modified file detected" "To import: 1" "$(echo "$OUT3" | grep 'To import' | xargs)"
check "5 assets after re-import" "5" "$(q 'select count(*) from assets;')"

echo
echo "=== 10. thumbnails queued and drained ==="
for _ in $(seq 1 60); do
  [ "$(q "select count(*) from derivation_jobs where state='done';")" = "5" ] && break; sleep 1
done
check "5 derivation jobs done" "5" "$(q "select count(*) from derivation_jobs where state='done';")"
check "no failed jobs"         "0" "$(q "select count(*) from derivation_jobs where state='failed';")"
check "every asset has a ThumbHash" "5" "$(q 'select count(*) from assets where thumbhash is not null;')"

echo
echo "=== 11. it shows up in the timeline ==="
M=$(curl -s "$API/v1/spaces/$SPACE/timeline?zoom=day" -H "Authorization: Bearer $TOKEN")
check "timeline total is 5" "5" "$(echo "$M" | jq_get '["total"]')"
check "activity flagged as bulk" "t" "$(q 'select is_bulk from activity_sessions limit 1;')"

echo
echo "════════════════════════════════════"
echo "  passed: $PASS   failed: $FAIL"
echo "════════════════════════════════════"
[ "$FAIL" -eq 0 ]
