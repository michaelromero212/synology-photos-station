#!/bin/bash
# An imported library's files come together in grid items the way Synology
# Photos makes them: every file in a folder that carries the same Apple Live
# Photo identifier is one item. A Live Photo's photo is the tile and its video
# its motion; a JPEG exported from it, or an Instagram copy, is kept, stacked
# under it, off the grid, and removed, restored and purged with it. A photo
# whose edit dropped its Apple make, and a photo and video that share only a
# name, stay apart, as Synology keeps them. A copy in another folder is an item
# of its own. Given Synology's own items, a group is split where Synology
# split it, and joined where Synology made one item of files the identifiers
# keep apart. `regroup` does the same to a library imported before this, and
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

echo "Given Synology's items, a copy it kept apart (it reached the NAS first) is apart:"
(cd "$SERVER_DIR" && "$BIN" regroup --path "$L" --space "$FIRST" --synology "$ROOT/synology-apart.tsv" \
  > "$ROOT/regroup-apart.log" 2>&1)
check "the copy is a tile of its own, the rest as before" \
  "tile motion kept tile tile tile tile tile tile kept tile motion" "$(layout)"
APART=$(compare --synology "$ROOT/synology-apart.tsv")
check "and the grid has Synology's items again" "8 8 0 0" \
  "$(echo "$APART" | awk '/Grid items here:/ {h=$NF} /Grid items in Synology:/ {s=$NF} /Items split here:/ {p=$NF} /Items joined here:/ {j=$NF} END {print h, s, p, j}')"
(cd "$SERVER_DIR" && "$BIN" regroup --path "$L" --space "$FIRST" > /dev/null 2>&1)
check "without them, it's grouped by the files alone again" "$EXPECTED" "$(layout)"

echo "Given Synology's items, a Live Photo whose own photo lost its Make is one, as Synology shows it:"
J="$ROOT/joined/2020/03"; mkdir -p "$J"; F=66A97DF4-E8FC-4D9A-A3CA-9FEC8F2C275C
image "$J/IMG_2847.jpeg"; apple "$J/IMG_2847.jpeg" $F ""
video -metadata "com.apple.quicktime.content.identifier=$F" "$J/IMG_2847.MOV"
printf '%s\t2020-07-24 15:44:37\t90\n' "$J/IMG_2847.jpeg" "$J/IMG_2847.MOV" > "$ROOT/joined.tsv"
(cd "$SERVER_DIR" && "$BIN" import --path "$ROOT/joined" --space "$FIRST" --time-zone America/New_York \
  --keep-copies --synology "$ROOT/joined.tsv" > "$ROOT/joined.log" 2>&1)
check "its photo is the tile and its video the motion" "tile motion" \
  "$(shown "$J/IMG_2847.jpeg") $(shown "$J/IMG_2847.MOV")"
JOINED=$(cd "$SERVER_DIR" && "$BIN" compare-dates --path "$ROOT/joined" --synology "$ROOT/joined.tsv" \
  --space "$FIRST" --time-zone America/New_York 2>&1)
check "and compare-dates finds Synology's one item" "1 1 0 0" \
  "$(echo "$JOINED" | awk '/showing these files:/ {h=$NF} /Grid items in Synology:/ {s=$NF} /Items split here:/ {p=$NF} /Items joined here:/ {j=$NF} END {print h, s, p, j}')"
# A row another library shows too keeps its grouping, and so does what's
# grouped with it, or the item would change there as well: here the video is
# in a second library.
SECOND=$(redeem "Second" | jq '["personalSpace"]["id"]')
q "INSERT INTO space_assets (space_id, asset_id, uploaded_by_user_id)
   SELECT '$SECOND', '$(asset "$J/IMG_2847.MOV")', created_by FROM spaces WHERE id = '$SECOND'" >/dev/null
KEPT=$(cd "$SERVER_DIR" && "$BIN" regroup --path "$ROOT/joined" --space "$FIRST" 2>&1)
check "without Synology's items, a pair whose video another library shows stays one" "tile motion 2" \
  "$(shown "$J/IMG_2847.jpeg") $(shown "$J/IMG_2847.MOV") $(echo "$KEPT" | awk '/Left as they were, with a row another library shows:/ {print $NF}')"
q "DELETE FROM space_assets WHERE space_id = '$SECOND'" >/dev/null
DRY=$(cd "$SERVER_DIR" && "$BIN" regroup --path "$ROOT/joined" --space "$FIRST" --dry-run 2>&1)
check "a dry run says what would change, and changes nothing" "2 tile motion" \
  "$(echo "$DRY" | awk '/Files whose grouping changed:/ {print $NF}') $(shown "$J/IMG_2847.jpeg") $(shown "$J/IMG_2847.MOV")"
(cd "$SERVER_DIR" && "$BIN" regroup --path "$ROOT/joined" --space "$FIRST" > /dev/null 2>&1)
check "without them, the files alone keep the two apart" "tile tile" \
  "$(shown "$J/IMG_2847.jpeg") $(shown "$J/IMG_2847.MOV")"

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

echo "Another version of something the phone backed up is kept with the phone's:"
PHONE="$ROOT/phone"; MINE="$ROOT/mine/2024/10"; mkdir -p "$PHONE" "$MINE"
E=9C1D3A55-2E6B-4F3A-8D41-6A2B7C0E1F22
taken(){ exiftool -q -q -overwrite_original -DateTimeOriginal="2024:10:19 12:00:00" -OffsetTimeOriginal="-04:00" "$@"; }
# What the phone backed up through the app: a Live Photo, three photos and a
# burst frame, all in one second.
image "$PHONE/IMG_1322.HEIC"; apple "$PHONE/IMG_1322.HEIC" $E; taken "$PHONE/IMG_1322.HEIC"
video -metadata "com.apple.quicktime.content.identifier=$E" \
      -metadata "com.apple.quicktime.creationdate=2024-10-19T12:00:00-0400" "$PHONE/IMG_1322.MOV"
for f in IMG_1531.HEIC IMG_1319.HEIC IMG_5001.JPG IMG_2398.JPG; do image "$PHONE/$f"; taken "$PHONE/$f"; done
# Synology's: the Live Photo's photo in another version, its video byte for
# byte the phone's; the photo of the same name in another version; the photo
# as the phone backed it up beside a JPEG of it; one named otherwise; and the
# burst frame beside another.
image "$MINE/IMG_1322.HEIC"; apple "$MINE/IMG_1322.HEIC" $E; taken "$MINE/IMG_1322.HEIC"
cp -p "$PHONE/IMG_1322.MOV" "$PHONE/IMG_1319.HEIC" "$PHONE/IMG_2398.JPG" "$MINE/"
for f in IMG_1531.HEIC IMG_1319.jpeg IMG_5000.JPG IMG_2401.JPG; do image "$MINE/$f"; taken "$MINE/$f"; done
# The phone's, as the app would have put them: placed from the phone, with no
# import of their own.
(cd "$SERVER_DIR" && "$BIN" import --path "$PHONE" --space "$FIRST" --time-zone America/New_York > "$ROOT/phone.log" 2>&1)
P1322=$(asset "$PHONE/IMG_1322.HEIC"); P1531=$(asset "$PHONE/IMG_1531.HEIC")
q "UPDATE space_assets SET on_device = true WHERE space_id = '$FIRST' AND asset_id IN
     (SELECT asset_id FROM import_records WHERE starts_with(source_path, '$PHONE/'))" >/dev/null
q "DELETE FROM import_records WHERE starts_with(source_path, '$PHONE/')" >/dev/null
printf '%s\t2024-10-19 12:00:00\t%s\n' \
  "$MINE/IMG_1322.HEIC" 60 "$MINE/IMG_1322.MOV" 60 "$MINE/IMG_1531.HEIC" 61 "$MINE/IMG_1319.HEIC" 62 \
  "$MINE/IMG_1319.jpeg" 63 "$MINE/IMG_5000.JPG" 64 "$MINE/IMG_2401.JPG" 65 "$MINE/IMG_2398.JPG" 66 > "$ROOT/mine.tsv"
(cd "$SERVER_DIR" && "$BIN" import --path "$ROOT/mine" --space "$FIRST" --time-zone America/New_York \
  --keep-copies --synology "$ROOT/mine.tsv" > "$ROOT/mine.log" 2>&1)
mine(){ q "SELECT COALESCE(stacked_under::text, 'tile') FROM assets WHERE id = '$(asset "$MINE/$1")'"; }
check "the phone's own bytes are left out" "already in library|already in library|already in library" \
  "$(for f in IMG_1322.MOV IMG_1319.HEIC IMG_2398.JPG; do
       q "SELECT outcome FROM import_records WHERE source_path = '$MINE/$f'"; done | paste -sd'|' -)"
check "a Live Photo's other photo goes under the phone's, as Synology's item says" "$P1322" "$(mine IMG_1322.HEIC)"
check "a photo of the same name and second goes under the phone's version" "$P1531" "$(mine IMG_1531.HEIC)"
check "a JPEG of a photo Synology has as the phone does is an item of its own" "tile" "$(mine IMG_1319.jpeg)"
check "and so are one named otherwise, and a burst frame" "tile tile" "$(mine IMG_5000.JPG) $(mine IMG_2401.JPG)"
check "the import says how many" "2" "$(awk "/kept with the phone's version:/ {print \$NF}" "$ROOT/mine.log")"
MINED=$(cd "$SERVER_DIR" && "$BIN" compare-dates --path "$ROOT/mine" --synology "$ROOT/mine.tsv" \
  --space "$FIRST" --time-zone America/New_York 2>&1)
check "compare-dates finds each of Synology's items once" "7 7 0 0" \
  "$(echo "$MINED" | awk '/showing these files:/ {h=$NF} /Grid items in Synology:/ {s=$NF} /Items split here:/ {p=$NF} /Items joined here:/ {j=$NF} END {print h, s, p, j}')"
(cd "$SERVER_DIR" && "$BIN" regroup --path "$ROOT/mine" --space "$FIRST" --synology "$ROOT/mine.tsv" \
  > "$ROOT/mine-regroup.log" 2>&1)
check "and regrouping changes nothing" "0" "$(awk '/grouping changed:/ {print $NF}' "$ROOT/mine-regroup.log")"
# A photo the phone backed up, in two of the library's folders imported one
# at a time: the first file is the phone's, and the copy in the other is an
# item of its own in Synology, not another version of the phone's.
P2="$ROOT/phone2"; mkdir -p "$P2"; image "$P2/IMG_9000.JPG"; taken "$P2/IMG_9000.JPG"
(cd "$SERVER_DIR" && "$BIN" import --path "$P2" --space "$FIRST" --time-zone America/New_York > /dev/null 2>&1)
q "UPDATE space_assets SET on_device = true WHERE space_id = '$FIRST' AND asset_id = '$(asset "$P2/IMG_9000.JPG")'" >/dev/null
q "DELETE FROM import_records WHERE starts_with(source_path, '$P2/')" >/dev/null
TWO="$ROOT/two"; mkdir -p "$TWO/MobileBackup/2024/10" "$TWO/PhotoLibrary/2024/10"
cp -p "$P2/IMG_9000.JPG" "$TWO/MobileBackup/2024/10/"; cp -p "$P2/IMG_9000.JPG" "$TWO/PhotoLibrary/2024/10/"
printf '%s\t2024-10-19 12:00:00\t%s\n' "$TWO/MobileBackup/2024/10/IMG_9000.JPG" 70 \
  "$TWO/PhotoLibrary/2024/10/IMG_9000.JPG" 71 > "$ROOT/two.tsv"
for f in MobileBackup PhotoLibrary; do
  (cd "$SERVER_DIR" && "$BIN" import --path "$TWO/$f" --space "$FIRST" --time-zone America/New_York \
    --keep-copies --synology "$ROOT/two.tsv" > "$ROOT/two-$f.log" 2>&1)
done
check "a copy in a sibling folder of a photo the phone backed up stays an item of its own" "1 0 tile" \
  "$(awk '/Stored once already:/ {r=$4} /kept with the phone.s version:/ {k=$NF} END {print r, k}' "$ROOT/two-PhotoLibrary.log") $(q "SELECT COALESCE(stacked_under::text, 'tile') FROM assets WHERE id = '$(asset "$TWO/PhotoLibrary/2024/10/IMG_9000.JPG")'")"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
