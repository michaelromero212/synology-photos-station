#!/bin/bash
# A person's Synology Photos albums become their own albums here, after their
# library is imported: each album's items in its order, found by their files.
# A file the import skipped because the app had backed up the same bytes is the
# app's copy; a Live Photo is its photo, once; a copy kept with another is that
# other. One deleted here stays out, and one never imported is reported. The
# albums are personal, the library owner's, and nobody else sees them. An
# album of theirs with the same name gets only what it's missing, its cover
# kept, and a second run changes nothing.
#
#   FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-import-albums.sh
#
# Runs its own server against its own database and blob store. The test
# files are tiny ones it makes itself.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"

DB=framestation_import_albums; PORT=8066; API="http://127.0.0.1:$PORT"
export FRAMESTATION_DATABASE_URL="postgres://framestation:x@127.0.0.1:55432/$DB?sslmode=disable"
ROOT="$SCRATCH/import-albums"; rm -rf "$ROOT"; mkdir -p "$ROOT/blobroot" "$ROOT/lib" "$ROOT/app"
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

# signin <name> → "token user-id personal-space-id"
signin(){
  local c R
  c=$(cd "$SERVER_DIR" && "$BIN" invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
  R=$(curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
    -d "{\"code\":\"$c\",\"displayName\":\"$1\",\"deviceName\":\"iPhone\",\"platform\":\"ios\"}")
  echo "$(echo "$R" | jq '["token"]') $(echo "$R" | jq '["user"]["id"]') $(echo "$R" | jq '["personalSpace"]["id"]')"
}
read -r OT O OP <<<"$(signin Owner)"; read -r XT X XP <<<"$(signin Other)"
AO="Authorization: Bearer $OT"; AX="Authorization: Bearer $XT"
[ -n "$OP" ] && [ -n "$XP" ] || { echo "setup failed"; exit 1; }

# ---------------------------------------------------------------- the files
L="$ROOT/lib"
image(){ vips gaussnoise "$ROOT/n.v" 32 32 >/dev/null 2>&1 && vips copy "$ROOT/n.v" "$1" >/dev/null 2>&1; }
image "$L/live.jpg"; image "$L/plain.jpg"; image "$L/kept.jpg"; image "$L/gone.jpg"
ffmpeg -v error -y -f lavfi -i testsrc=duration=1:size=64x48:rate=5 -c:v libx264 -pix_fmt yuv420p "$L/live.mov"
# A photo the app backed up before the import: the same bytes, another name.
image "$ROOT/app/IMG_0001.jpg"; cp -p "$ROOT/app/IMG_0001.jpg" "$L/app-copy.jpg"

placement(){ q "SELECT id FROM space_assets WHERE space_id = '$OP' AND filename = '$1'"; }
asset(){ q "SELECT asset_id FROM space_assets WHERE space_id = '$OP' AND filename = '$1'"; }
(cd "$SERVER_DIR" && "$BIN" import --path "$ROOT/app" --space "$OP" > "$ROOT/app.log" 2>&1)
q "DELETE FROM import_records WHERE asset_id = '$(asset IMG_0001.jpg)'" >/dev/null
(cd "$SERVER_DIR" && "$BIN" import --path "$L" --space "$OP" --keep-copies > "$ROOT/import.log" 2>&1)
check "the app's photo was left out of the import" "already in library" \
  "$(q "SELECT outcome FROM import_records WHERE source_path = '$L/app-copy.jpg'")"
# A Live Photo; a copy kept with another, off the grid; and one deleted here.
GROUP=$(q "SELECT gen_random_uuid()")
q "UPDATE assets SET live_group_id = '$GROUP' WHERE id IN ('$(asset live.jpg)', '$(asset live.mov)')" >/dev/null
q "UPDATE assets SET stacked_under = '$(asset plain.jpg)' WHERE id = '$(asset kept.jpg)'" >/dev/null
q "UPDATE space_assets SET deleted_at = now() WHERE id = '$(placement gone.jpg)'" >/dev/null

# An album the owner already made here, named as one in Synology.
EXISTING=$(curl -s -X POST "$API/v1/albums" -H "$AO" -H 'Content-Type: application/json' \
  -d "{\"name\":\"Beach\",\"spaceAssetIDs\":[\"$(placement live.jpg)\"]}" | jq '["id"]')

# As export-synology-albums.sh writes them: album, name, made (UTC), place,
# item, file, cover. Out of order, as nothing promises they come in order.
ALBUMS="$ROOT/albums.tsv"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  7 "Trip" "2024-05-01 12:00:00" 2 102 "$L/kept.jpg" "" \
  7 "Trip" "2024-05-01 12:00:00" 0 100 "$L/live.jpg" "" \
  7 "Trip" "2024-05-01 12:00:00" 0 100 "$L/live.mov" "" \
  7 "Trip" "2024-05-01 12:00:00" 1 101 "$L/app-copy.jpg" cover \
  7 "Trip" "2024-05-01 12:00:00" 3 103 "$L/gone.jpg" "" \
  7 "Trip" "2024-05-01 12:00:00" 4 104 "$L/never.jpg" "" \
  7 "Trip" "2024-05-01 12:00:00" 5 105 "$L/plain.jpg" "" \
  8 "Beach" "2024-06-01 09:30:00" 0 105 "$L/plain.jpg" "" > "$ALBUMS"
run(){ (cd "$SERVER_DIR" && "$BIN" import-albums --from "$ALBUMS" --space "$OP" "$@" 2>&1); }
contents(){ q "SELECT string_agg(sa.filename, '|' ORDER BY aa.position, aa.added_at)
               FROM album_assets aa JOIN space_assets sa ON sa.id = aa.space_asset_id
               WHERE aa.album_id = '$1'"; }

echo "A dry run:"
DRY=$(run --dry-run)
check "says what each album would hold" "1" "$(echo "$DRY" | grep -c 'Trip: 6 items, 3 here, 2 files not found')"
check "and why a file isn't there: deleted here" "1" "$(echo "$DRY" | grep -c 'gone.jpg  (deleted here)')"
check "or never imported" "1" "$(echo "$DRY" | grep -c 'never.jpg  (never imported)')"
check "and makes nothing" "1" "$(q "SELECT count(*) FROM albums")"

echo "Imported:"
OUT=$(run)
TRIP=$(q "SELECT id FROM albums WHERE name = 'Trip'")
check "the album is made" "1" "$(q "SELECT count(*) FROM albums WHERE name = 'Trip'")"
check "in album order: a Live Photo once, the app's copy, the shown one for a kept copy" \
  "live.jpg|IMG_0001.jpg|plain.jpg" "$(contents "$TRIP")"
check "personal, the library owner's" "$O|$O|t" \
  "$(q "SELECT upper(owner_user_id::text) || '|' || upper(created_by::text) || '|' || CASE WHEN space_id IS NULL THEN 't' END
        FROM albums WHERE id = '$TRIP'")"
check "made when Synology says it was" "2024-05-01 12:00:00" \
  "$(q "SELECT to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') FROM albums WHERE id = '$TRIP'")"
check "with Synology's cover" "$(asset IMG_0001.jpg)" "$(q "SELECT cover_asset_id FROM albums WHERE id = '$TRIP'")"
check "an album of the same name gets what it's missing, not a twin" "1|live.jpg|plain.jpg" \
  "$(q "SELECT count(*) FROM albums WHERE name = 'Beach'")|$(contents "$EXISTING")"
check "and keeps its cover" "$(asset live.jpg)" "$(q "SELECT cover_asset_id FROM albums WHERE id = '$EXISTING'")"
check "the summary counts them" "1" "$(echo "$OUT" | grep -c 'Albums made: 1 of 2; items added: 4')"

echo "In the app:"
LIST=$(curl -s "$API/v1/albums" -H "$AO")
check "the owner sees it, with its count" "3" \
  "$(echo "$LIST" | python3 -c "import sys,json; print([a['itemCount'] for a in json.load(sys.stdin)['albums'] if a['name']=='Trip'][0])")"
check "and its photos" "3" "$(curl -s "$API/v1/albums/$TRIP/items" -H "$AO" | jq '["items"].__len__()')"
check "nobody else does" "404|" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$API/v1/albums/$TRIP" -H "$AX")|$(curl -s "$API/v1/albums" -H "$AX" | python3 -c "import sys,json; print('|'.join(a['name'] for a in json.load(sys.stdin)['albums']))")"

echo "Again:"
AGAIN=$(run)
check "a second run adds nothing" "1" "$(echo "$AGAIN" | grep -c 'Albums made: 0 of 2; items added: 0')"
check "and leaves every album as it was" "2|live.jpg|IMG_0001.jpg|plain.jpg" \
  "$(q "SELECT count(*) FROM albums")|$(contents "$TRIP")"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
