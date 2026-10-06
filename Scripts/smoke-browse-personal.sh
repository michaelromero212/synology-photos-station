#!/bin/bash
# The File Station tree's Personal folder. New personal photos land in
# Photos/Personal/YYYY/MM. Copies placed loose in Photos/YYYY/MM before that
# move there by rename, and the folders they leave go once they're empty
# (Synology's @eaDir cache allowed for). A person's own files are never
# touched, and shared photos stay in Photos/Shared.
#
# Runs its own server against its own database and a fake homes root, because
# the tree is only written with FRAMESTATION_BROWSE_TREE=1 and this rearranges
# it.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"

PGHOST=127.0.0.1; PGPORT=55432; PGUSER=framestation; DB=framestation_browse
PORT=8097; API="http://127.0.0.1:$PORT"
ROOT="$SCRATCH/browse"; rm -rf "$ROOT"; mkdir -p "$ROOT/blobroot" "$ROOT/homes" "$ROOT/files"
# Resolved, because paths are compared as recorded: on macOS /tmp is a symlink.
ROOT=$(cd "$ROOT" && pwd -P)
HOMES="$ROOT/homes"
export FRAMESTATION_BLOB_ROOT="$ROOT/blobroot"
export FRAMESTATION_HOMES_ROOT="$HOMES"
export FRAMESTATION_DATABASE_URL="postgres://$PGUSER:x@$PGHOST:$PGPORT/$DB?sslmode=disable"

PASS=0; FAIL=0
q(){ psql -h $PGHOST -p $PGPORT -U $PGUSER -d $DB -tAqc "$1"; }
admin(){ psql -h $PGHOST -p $PGPORT -U $PGUSER -d postgres -tAqc "$1"; }
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; echo "      expected: $2"; echo "      actual:   $3"; FAIL=$((FAIL+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
exists(){ [ -e "$2" ] && ok "$1" || bad "$1" "exists: $2" "missing"; }
gone(){ [ -e "$2" ] && bad "$1" "gone: $2" "still there" || ok "$1"; }
jq(){ python3 -c "import sys,json; print(json.load(sys.stdin)$1)" 2>/dev/null; }

(cd "$SERVER_DIR" && swift build >/dev/null 2>&1) || { echo "server build failed"; exit 1; }
BIN="$(cd "$SERVER_DIR" && swift build --show-bin-path)/FrameStationServer"
admin "DROP DATABASE IF EXISTS $DB" >/dev/null; admin "CREATE DATABASE $DB" >/dev/null

SERVER=""
serve(){ # $1: browse tree 0 or 1
  FRAMESTATION_BROWSE_TREE=$1 "$BIN" serve --hostname 127.0.0.1 --port $PORT >> "$ROOT/server.log" 2>&1 &
  SERVER=$!
  for _ in $(seq 1 120); do curl -s -o /dev/null "$API/health" && return; sleep 0.5; done
  echo "server didn't start:"; tail -20 "$ROOT/server.log"; exit 1
}
stop(){ kill "$SERVER" 2>/dev/null; wait "$SERVER" 2>/dev/null; }
trap stop EXIT

# upload <space> <name> <width> <capturedAt> → asset id
upload(){
  local f="$ROOT/files/$2" SHA SZ UP
  vips gaussnoise "$ROOT/files/n.v" "$3" 200 >/dev/null 2>&1
  vips copy "$ROOT/files/n.v" "$f" >/dev/null 2>&1
  SHA=$(shasum -a 256 "$f" | awk '{print $1}'); SZ=$(stat -f%z "$f")
  UP=$(curl -s -X POST "$API/v1/uploads/probe" -H "$A" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$1\",\"sha256\":\"$SHA\",\"byteSize\":$SZ,\"filename\":\"$2\",\"isAutomaticBackup\":false}" | jq '["uploadID"]')
  curl -s -X PUT "$API/v1/uploads/$UP/chunk/0" -H "$A" --data-binary "@$f" >/dev/null
  curl -s -X POST "$API/v1/uploads/$UP/commit" -H "$A" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$1\",\"mediaType\":\"photo\",\"mime\":\"image/jpeg\",\"width\":$3,\"height\":200,\"capturedAt\":\"$4\",\"capturedTZOffset\":0,\"isRaw\":false,\"burstPick\":false}" | jq '["assetID"]'
}

echo "Before: photos placed in the old layout"
serve 0
c=$(cd "$SERVER_DIR" && "$BIN" invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
R=$(curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$c\",\"displayName\":\"Tester\",\"deviceName\":\"iPhone\",\"platform\":\"ios\"}")
T=$(echo "$R" | jq '["token"]'); SP=$(echo "$R" | jq '["personalSpace"]["id"]'); USER=$(echo "$R" | jq '["user"]["id"]')
A="Authorization: Bearer $T"
[ -n "$SP" ] || { echo "setup failed: no space"; exit 1; }
SHARED=$(curl -s -X POST "$API/v1/spaces" -H "$A" -H 'Content-Type: application/json' \
  -d '{"name":"Family Shared","memberIDs":[]}' | jq '["id"]')

PA=$(upload "$SP" IMG_A.jpg 301 2024-05-10T12:00:00Z)
PB=$(upload "$SP" IMG_B.jpg 302 2024-05-11T12:00:00Z)
PC=$(upload "$SP" IMG_C.jpg 303 2023-03-02T12:00:00Z)
PD=$(upload "$SP" IMG_D.jpg 304 2022-01-05T12:00:00Z)
PE=$(upload "$SP" IMG_E.jpg 305 2021-07-04T12:00:00Z)
PS=$(upload "$SHARED" IMG_S.jpg 306 2024-06-01T12:00:00Z)
for _ in $(seq 1 60); do [ "$(q "SELECT count(*) FROM assets WHERE derived_at IS NULL")" = "0" ] && break; sleep 1; done
stop

# A DSM account, so the tree has a home to write into.
q "UPDATE users SET dsm_username = 'tester' WHERE id = '$USER'" >/dev/null
P="$HOMES/tester/Photos"
legacy(){ # asset id, path the old layout gave it, write the file there or not
  [ "$3" = "file" ] && { mkdir -p "$(dirname "$2")"; cp "$ROOT/files/$(basename "$2")" "$2"; }
  q "INSERT INTO browse_entries (space_asset_id, user_id, path, link_kind)
     SELECT id, '$USER', '$2', 'reflink' FROM space_assets WHERE asset_id = '$1' AND space_id = '$SP'" >/dev/null
}
legacy "$PA" "$P/2024/05/IMG_A.jpg" file
legacy "$PB" "$P/2024/05/IMG_B.jpg" file
mkdir -p "$P/2024/05/@eaDir/IMG_B.jpg" && echo thumb > "$P/2024/05/@eaDir/IMG_B.jpg/SYNOPHOTO_THUMB_M.jpg"
legacy "$PC" "$P/2023/03/IMG_C.jpg" file
echo "not a photo the app placed" > "$P/2023/notes.txt"
# Moved by an earlier sweep that stopped before writing its row.
mkdir -p "$P/Personal/2022/01" && cp "$ROOT/files/IMG_D.jpg" "$P/Personal/2022/01/IMG_D.jpg"
legacy "$PD" "$P/2022/01/IMG_D.jpg" nofile

echo "After: the server with the tree on"
serve 1
for _ in $(seq 1 60); do
  [ -e "$P/Personal/2021/07/IMG_E.jpg" ] && [ -e "$P/Shared/Family Shared/2024/06/IMG_S.jpg" ] \
    && [ -e "$P/Personal/2024/05/IMG_A.jpg" ] && break
  sleep 1
done
sleep 1

exists "an old copy moves into Personal" "$P/Personal/2024/05/IMG_A.jpg"
gone "and isn't left behind" "$P/2024/05/IMG_A.jpg"
exists "its neighbor moves with it" "$P/Personal/2024/05/IMG_B.jpg"
gone "the emptied month goes, Synology's cache with it" "$P/2024/05"
gone "and so does the emptied year" "$P/2024"
exists "a photo from another year moves too" "$P/Personal/2023/03/IMG_C.jpg"
gone "its emptied month goes" "$P/2023/03"
exists "but a year holding somebody's own file stays" "$P/2023"
check "and the file is untouched" "not a photo the app placed" "$(cat "$P/2023/notes.txt")"
check "an interrupted move is finished in the database" "$P/Personal/2022/01/IMG_D.jpg" \
  "$(q "SELECT be.path FROM browse_entries be JOIN space_assets sa ON sa.id = be.space_asset_id WHERE sa.asset_id = '$PD'")"
exists "with the file where it already was" "$P/Personal/2022/01/IMG_D.jpg"
exists "a new photo lands in Personal" "$P/Personal/2021/07/IMG_E.jpg"
exists "a shared photo stays in Shared" "$P/Shared/Family Shared/2024/06/IMG_S.jpg"
check "every personal row points into Personal" "0" \
  "$(q "SELECT count(*) FROM browse_entries be JOIN space_assets sa ON sa.id = be.space_asset_id
        JOIN spaces s ON s.id = sa.space_id WHERE s.kind = 'personal' AND be.path NOT LIKE '%/Photos/Personal/%'")"
check "Photos holds Personal, Shared, and the folder with somebody's file" "2023 Personal Shared" \
  "$(ls "$P" | sort | tr '\n' ' ' | sed 's/ $//')"
check "the move is said in the log" "1" "$(grep -c 'moved 3 personal photos into Photos/Personal' "$ROOT/server.log")"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
