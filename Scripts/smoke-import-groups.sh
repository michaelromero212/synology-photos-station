#!/bin/bash
# An imported library's files come together in grid items the way Synology
# Photos makes them: every file in a folder that carries the same Apple Live
# Photo identifier is one item. A Live Photo's photo is the tile and its video
# its motion; a JPEG exported from it, or an Instagram copy, is kept, stacked
# under it, off the grid, and removed, restored and purged with it. A photo
# whose edit dropped its Apple make, and a photo and video that share only a
# name, stay apart, as Synology keeps them. A copy in another folder is an item
# of its own. `regroup` does the same to a library imported before this, and
# compare-dates says when the grid's items match Synology's.
#
#   FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-import-groups.sh
#
# Runs its own server against its own database and blob store. The test files
# are tiny ones it makes itself, with Apple's maker notes written by hand.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"

DB=framestation_import_groups; PORT=8067; API="http://127.0.0.1:$PORT"
export FRAMESTATION_DATABASE_URL="postgres://framestation:x@127.0.0.1:55432/$DB?sslmode=disable"
ROOT="$SCRATCH/import-groups"; rm -rf "$ROOT"; mkdir -p "$ROOT/blobroot" "$ROOT/lib/2020/07" "$ROOT/lib/2023/03"
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
# Shaped like ones in a real library (2026-10-24).
L="$ROOT/lib"; D="$L/2020/07"; LATER="$L/2023/03"
image(){ vips gaussnoise "$ROOT/n.v" 32 32 >/dev/null 2>&1 && vips copy "$ROOT/n.v" "$1" >/dev/null 2>&1; }
video(){ ffmpeg -v error -y -f lavfi -i testsrc=duration=1:size=64x48:rate=5 \
  -c:v libx264 -pix_fmt yuv420p -movflags use_metadata_tags "$@"; }
# Apple's maker notes holding a Live Photo identifier, as an iPhone writes
# them, and the Make that says an Apple camera took it (none: an app's edit).
apple(){  # file identifier [make]
  python3 - "$ROOT/notes.bin" "$2" <<'PY'
import struct, sys
ident = sys.argv[2].encode() + b"\0"
header = b"Apple iOS\0" + struct.pack(">H", 1) + b"MM"
ifd = struct.pack(">H", 1) + struct.pack(">HHII", 0x0011, 2, len(ident), 14 + 2 + 12 + 4) + struct.pack(">I", 0)
open(sys.argv[1], "wb").write(header + ifd + ident)
PY
  exiftool -q -q -overwrite_original "-MakerNotes<=$ROOT/notes.bin" -Make="${3-Apple}" \
    -DateTimeOriginal="2020:07:24 15:44:37" -OffsetTimeOriginal="-04:00" "$1"
}
A=E5E34ADC-8494-4BA2-A3F4-A91B96C9C9F8; B=FB9804FB-4D1A-4AFD-B9A0-96CCB067589D
C=3F3922C6-558A-427F-9F18-B5EEB3E3379D
# A Live Photo, a JPEG exported from it beside it, and an Instagram copy.
image "$D/IMG_8492.HEIC"; apple "$D/IMG_8492.HEIC" $A
video -metadata "com.apple.quicktime.content.identifier=$A" "$D/IMG_8492.MOV"
image "$D/IMG_8492.JPEG"; apple "$D/IMG_8492.JPEG" $A
EXPORT=22EADDE1-CC71-4352-95C8-BC73A8DF45F6.jpg
image "$D/$EXPORT"; apple "$D/$EXPORT" $A
# An edit that dropped its Apple make, and the video with its identifier.
image "$D/FullSizeRender.jpeg"; apple "$D/FullSizeRender.jpeg" $B ""
video -metadata "com.apple.quicktime.content.identifier=$B" "$D/FullSizeRender.MOV"
# A photo and a video that share only a name.
image "$D/IMG_0873.JPG"; video "$D/IMG_0873.mov"
# Two videos with one identifier and no photo.
video -metadata "com.apple.quicktime.content.identifier=$C" "$D/IMG_7862.MOV"
video -metadata "com.apple.quicktime.content.identifier=$C" -metadata comment=again "$D/IMG_7862_1.MOV"
# The Live Photo again, years later, in another folder.
cp "$D/IMG_8492.HEIC" "$D/IMG_8492.MOV" "$LATER/"
for f in "$D"/* "$LATER"/*; do TZ=UTC touch -t 202007241944.37 "$f"; done
TZ=UTC touch -t 202007241944.38 "$D/IMG_7862_1.MOV" "$D/IMG_8492.JPEG"
TZ=UTC touch -t 202303212233.37 "$LATER"/*

redeem(){
  CODE=$(cd "$SERVER_DIR" && "$BIN" invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
  curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
    -d "{\"code\":\"$CODE\",\"displayName\":\"$1\",\"deviceName\":\"iPhone\",\"platform\":\"ios\"}"
}
R=$(redeem "First"); FIRST=$(echo "$R" | jq '["personalSpace"]["id"]'); TOKEN=$(echo "$R" | jq '["token"]')
auth=(-H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json')

asset(){ q "SELECT asset_id FROM import_records WHERE source_path = '$1'"; }
# placement state of a file: live, removed or purged
state(){ q "SELECT CASE WHEN sa.purged_at IS NOT NULL THEN 'purged' WHEN sa.deleted_at IS NOT NULL THEN 'removed'
                       ELSE 'live' END
            FROM space_assets sa WHERE sa.space_id = '$FIRST' AND sa.asset_id = '$(asset "$1")'"; }
# how a file is shown: tile, motion (of a Live Photo) or kept (stacked)
shown(){ q "SELECT CASE WHEN stacked_under IS NOT NULL THEN 'kept'
                       WHEN media_type = 'video' AND live_group_id IS NOT NULL THEN 'motion' ELSE 'tile' END
            FROM assets WHERE id = '$(asset "$1")'"; }
layout(){ for f in "$D/IMG_8492.HEIC" "$D/IMG_8492.MOV" "$D/IMG_8492.JPEG" "$D/$EXPORT" \
                   "$D/FullSizeRender.jpeg" "$D/FullSizeRender.MOV" "$D/IMG_0873.JPG" "$D/IMG_0873.mov" \
                   "$D/IMG_7862.MOV" "$D/IMG_7862_1.MOV" "$LATER/IMG_8492.HEIC" "$LATER/IMG_8492.MOV"; do
            shown "$f"; done | paste -sd' ' -; }
EXPECTED="tile motion kept kept tile tile tile tile tile kept tile motion"

echo "Importing, grouped as Synology Photos groups them:"
(cd "$SERVER_DIR" && "$BIN" import --path "$L" --space "$FIRST" --time-zone America/New_York \
  --keep-copies > "$ROOT/import.log" 2>&1)
check "the import says what it grouped" "3 2 3" \
  "$(awk '/items of more than one file:/ {i=$NF} /of them Live Photos:/ {l=$NF} /files kept with another:/ {k=$NF} END {print i, l, k}' "$ROOT/import.log")"
check "each file shown as Synology shows it" "$EXPECTED" "$(layout)"
check "the Live Photo's motion is its own video" "$(q "SELECT live_group_id FROM assets WHERE id = '$(asset "$D/IMG_8492.HEIC")'")" \
  "$(q "SELECT live_group_id FROM assets WHERE id = '$(asset "$D/IMG_8492.MOV")'")"
check "the export and the copy are kept with its photo" "$(asset "$D/IMG_8492.HEIC") $(asset "$D/IMG_8492.HEIC")" \
  "$(q "SELECT stacked_under FROM assets WHERE id = '$(asset "$D/IMG_8492.JPEG")'") $(q "SELECT stacked_under FROM assets WHERE id = '$(asset "$D/$EXPORT")'")"
check "two videos with one identifier show the older" "$(asset "$D/IMG_7862.MOV")" \
  "$(q "SELECT stacked_under FROM assets WHERE id = '$(asset "$D/IMG_7862_1.MOV")'")"
check "the copy in another folder is a Live Photo of its own" "1" \
  "$(q "SELECT count(DISTINCT live_group_id) FROM assets WHERE id IN ('$(asset "$LATER/IMG_8492.HEIC")', '$(asset "$LATER/IMG_8492.MOV")')")"

# Synology's own items for the same files, with the times stored here.
SYNOLOGY="$ROOT/synology.tsv"
item(){ case "$1" in
  */2020/07/IMG_8492.*|*/2020/07/$EXPORT) echo 1 ;; */FullSizeRender.jpeg) echo 2 ;; */FullSizeRender.MOV) echo 3 ;;
  */IMG_0873.JPG) echo 4 ;; */IMG_0873.mov) echo 5 ;; */IMG_7862*) echo 6 ;; */2023/03/*) echo 7 ;; esac; }
q "SELECT r.source_path || '|' || to_char(a.local_captured_at, 'YYYY-MM-DD HH24:MI:SS')
   FROM import_records r JOIN assets a ON a.id = r.asset_id" \
  | while IFS='|' read -r path time; do printf '%s\t%s\t%s\n' "$path" "$time" "$(item "$path")"; done > "$SYNOLOGY"
compare(){ (cd "$SERVER_DIR" && "$BIN" compare-dates --path "$L" --time-zone America/New_York --space "$FIRST" "$@" 2>&1); }
SAME=$(compare --synology "$SYNOLOGY")
check "the grid has Synology's items" "7 7 0 0" \
  "$(echo "$SAME" | awk '/Grid items here:/ {h=$NF} /Grid items in Synology:/ {s=$NF} /Items split here:/ {p=$NF} /Items joined here:/ {j=$NF} END {print h, s, p, j}')"
check "and compare-dates says it all matches" "1" "$(echo "$SAME" | grep -c 'Every file matches Synology Photos to the second.')"
# Were the export its own item in Synology, compare-dates would say so.
awk -F'\t' -v OFS='\t' -v x="$EXPORT" 'index($1, x) {$3 = 8} {print}' "$SYNOLOGY" > "$ROOT/synology-apart.tsv"
APART=$(compare --synology "$ROOT/synology-apart.tsv")
check "an item that differs is named, with its files" "1 1" \
  "$(echo "$APART" | grep -cE 'Items joined here: +1$') $(echo "$APART" | grep -c "$EXPORT  +  2020/07/IMG_8492.HEIC  +  ")"

echo "A library imported before this, grouped by name, regrouped:"
q "UPDATE import_records SET live_identifier = NULL" >/dev/null
q "UPDATE assets SET live_group_id = NULL, stacked_under = NULL" >/dev/null
q "UPDATE assets SET live_group_id = '00000000-0000-4000-8000-000000000873'
   WHERE id IN ('$(asset "$D/IMG_0873.JPG")', '$(asset "$D/IMG_0873.mov")')" >/dev/null
(cd "$SERVER_DIR" && "$BIN" regroup --path "$L" --space "$FIRST" > "$ROOT/regroup.log" 2>&1)
check "it reads every file's identifier" "12" "$(awk '/Identifiers read from files:/ {print $NF}' "$ROOT/regroup.log")"
check "and shows each as Synology does" "$EXPECTED" "$(layout)"
(cd "$SERVER_DIR" && "$BIN" regroup --path "$L" --space "$FIRST" > "$ROOT/regroup-again.log" 2>&1)
check "a second run reads nothing and changes nothing" "0 0" \
  "$(awk '/Identifiers read from files:/ {r=$NF} /grouping changed:/ {c=$NF} END {print r, c}' "$ROOT/regroup-again.log")"

echo "Removing the Live Photo takes what's kept with it, and so does restoring:"
HEIC=$(asset "$D/IMG_8492.HEIC")
curl -s -o /dev/null -X DELETE "$API/v1/spaces/$FIRST/assets/$HEIC" "${auth[@]}"
item_states(){ for f in "$D/IMG_8492.HEIC" "$D/IMG_8492.MOV" "$D/IMG_8492.JPEG" "$D/$EXPORT" "$LATER/IMG_8492.HEIC"; do
                 state "$f"; done | paste -sd' ' -; }
check "removed together, the copy in the other folder left" "removed removed removed removed live" "$(item_states)"
check "Recently Deleted shows it once" "1" \
  "$(curl -s "$API/v1/spaces/$FIRST/collections/deleted" "${auth[@]}" | jq '["total"]')"
curl -s -o /dev/null -X POST "$API/v1/spaces/$FIRST/collections/deleted/restore" "${auth[@]}" \
  -d "{\"assetIDs\":[\"$HEIC\"]}"
check "restored together" "live live live live live" "$(item_states)"
curl -s -o /dev/null -X DELETE "$API/v1/spaces/$FIRST/assets/$HEIC" "${auth[@]}"
curl -s -o /dev/null -X POST "$API/v1/spaces/$FIRST/collections/deleted/purge" "${auth[@]}" \
  -d "{\"assetIDs\":[\"$HEIC\"]}"
check "and purged together" "purged purged purged purged live" "$(item_states)"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
