#!/bin/bash
# A shared library's folder in File Station follows its name. Renaming it
# renames `Photos/Shared/<name>` in every member's home, in one move that keeps
# anything a member put there, and later photos land in the renamed folder
# rather than a second one. Where the new name is already a folder, photos move
# one by one. Leaving takes the folder away, not just the photos in it.
#
#   FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-browse-rename.sh
#
# Runs its own server against its own database and a fake homes root, because
# the tree is only written with FRAMESTATION_BROWSE_TREE=1.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"

DB=framestation_browse_rename; PORT=8086; API="http://127.0.0.1:$PORT"
ROOT="$SCRATCH/browse-rename"; rm -rf "$ROOT"; mkdir -p "$ROOT/blobroot" "$ROOT/files" "$ROOT/homes"
ROOT=$(cd "$ROOT" && pwd -P)
HOMES="$ROOT/homes"
export FRAMESTATION_BLOB_ROOT="$ROOT/blobroot"
export FRAMESTATION_HOMES_ROOT="$HOMES"
export FRAMESTATION_BROWSE_TREE=1
export FRAMESTATION_DATABASE_URL="postgres://framestation:x@127.0.0.1:55432/$DB?sslmode=disable"

PASS=0; FAIL=0
q(){ psql "$FRAMESTATION_DATABASE_URL" -tAqc "$1"; }
admin(){ psql -h 127.0.0.1 -p 55432 -U framestation -d postgres -tAqc "$1"; }
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; echo "      expected: $2"; echo "      actual:   $3"; FAIL=$((FAIL+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
exists(){ [ -e "$2" ] && ok "$1" || bad "$1" "exists: $2" "missing"; }
gone(){ [ -e "$2" ] && bad "$1" "gone: $2" "still there" || ok "$1"; }
jq(){ python3 -c "import sys,json; print(json.load(sys.stdin)$1)" 2>/dev/null; }
code(){ curl -s -o /dev/null -w '%{http_code}' "$@"; }
# until_there <path> [gone]: waits out a sweep or two for a path to appear, or
# with "gone", to disappear.
until_there(){ for _ in $(seq 1 90); do
  if [ "${2:-}" = gone ]; then [ -e "$1" ] || return 0; else [ -e "$1" ] && return 0; fi
  sleep 1; done; }

(cd "$SERVER_DIR" && swift build >/dev/null 2>&1) || { echo "server build failed"; exit 1; }
BIN="$(cd "$SERVER_DIR" && swift build --show-bin-path)/FrameStationServer"
admin "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1; admin "CREATE DATABASE $DB" >/dev/null
"$BIN" serve --hostname 127.0.0.1 --port $PORT > "$ROOT/server.log" 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null; wait $SERVER 2>/dev/null; admin "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1' EXIT
for _ in $(seq 1 120); do curl -s -o /dev/null "$API/health" && break; sleep 0.5; done

# signin <name> <dsm user> → "token user-id", with a DSM home to write into
signin(){
  local c R id
  c=$(cd "$SERVER_DIR" && "$BIN" invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
  R=$(curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
    -d "{\"code\":\"$c\",\"displayName\":\"$1\",\"deviceName\":\"iPhone\",\"platform\":\"ios\"}")
  id=$(echo "$R" | jq '["user"]["id"]')
  q "UPDATE users SET dsm_username = '$2' WHERE id = '$id'" >/dev/null
  echo "$(echo "$R" | jq '["token"]') $id"
}
read -r OT O <<<"$(signin Owner owner)"; read -r MT M <<<"$(signin Member member)"
read -r KT K <<<"$(signin Kid kid)"
AO="Authorization: Bearer $OT"; AK="Authorization: Bearer $KT"
LIB=$(curl -s -X POST "$API/v1/spaces" -H "$AO" -H 'Content-Type: application/json' \
  -d "{\"name\":\"Family Shared\",\"memberIDs\":[\"$M\",\"$K\"]}" | jq '["id"]')
[ -n "$LIB" ] || { echo "setup failed"; exit 1; }

N=0
# put <name> <capturedAt>: a photo into the shared library, as its owner
put(){
  N=$((N + 1))
  local f="$ROOT/files/$1" sha size up
  vips gaussnoise "$ROOT/files/n.v" $((200 + N)) 200 >/dev/null 2>&1
  vips copy "$ROOT/files/n.v" "$f" >/dev/null 2>&1
  sha=$(shasum -a 256 "$f" | awk '{print $1}'); size=$(stat -f%z "$f")
  up=$(curl -s -X POST "$API/v1/uploads/probe" -H "$AO" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$LIB\",\"sha256\":\"$sha\",\"byteSize\":$size,\"filename\":\"$1\",\"isAutomaticBackup\":false}" | jq '["uploadID"]')
  curl -s -X PUT "$API/v1/uploads/$up/chunk/0" -H "$AO" --data-binary "@$f" >/dev/null
  curl -s -X POST "$API/v1/uploads/$up/commit" -H "$AO" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$LIB\",\"mediaType\":\"photo\",\"mime\":\"image/jpeg\",\"width\":$((200 + N)),\"height\":200,\"capturedAt\":\"$2\",\"capturedTZOffset\":0,\"isRaw\":false,\"burstPick\":false}" >/dev/null
}
rename(){ code -X PATCH "$API/v1/spaces/$LIB" -H "$AO" -H 'Content-Type: application/json' -d "{\"name\":\"$1\"}"; }

echo "Placed under the library's name"
put IMG_1.jpg 2024-06-01T12:00:00Z; put IMG_2.jpg 2024-07-04T12:00:00Z
OLD="Photos/Shared/Family Shared"
until_there "$HOMES/kid/$OLD/2024/07/IMG_2.jpg"
exists "in the owner's home" "$HOMES/owner/$OLD/2024/06/IMG_1.jpg"
exists "the member's" "$HOMES/member/$OLD/2024/07/IMG_2.jpg"
exists "and the kid's" "$HOMES/kid/$OLD/2024/06/IMG_1.jpg"
echo "a note of my own" > "$HOMES/member/$OLD/notes.txt"

echo "Renamed"
check "the owner renames the library" "200" "$(rename "The Smiths")"
NEW="Photos/Shared/The Smiths"
until_there "$HOMES/member/$NEW/2024/07/IMG_2.jpg"
exists "the member's folder takes the new name" "$HOMES/member/$NEW/2024/07/IMG_2.jpg"
exists "so does the owner's" "$HOMES/owner/$NEW/2024/06/IMG_1.jpg"
until_there "$HOMES/kid/$NEW/2024/06/IMG_1.jpg"
exists "and the kid's" "$HOMES/kid/$NEW/2024/06/IMG_1.jpg"
gone "with no folder left under the old name" "$HOMES/owner/$OLD"
exists "what a member put there went with it" "$HOMES/member/$NEW/notes.txt"
check "the copies' recorded paths follow" "0" \
  "$(q "SELECT count(*) FROM browse_entries WHERE path LIKE '%/Family Shared/%'")"
put IMG_3.jpg 2024-08-09T12:00:00Z
until_there "$HOMES/owner/$NEW/2024/08/IMG_3.jpg"
exists "a photo added afterward lands in the renamed folder" "$HOMES/owner/$NEW/2024/08/IMG_3.jpg"
gone "not in a second one" "$HOMES/owner/$OLD"

echo "Renamed to a name that's already a folder"
mkdir -p "$HOMES/owner/$OLD/2024/06" && echo "kept" > "$HOMES/owner/$OLD/2024/06/mine.txt"
check "renamed back" "200" "$(rename "Family Shared")"
until_there "$HOMES/owner/$OLD/2024/06/IMG_1.jpg"
exists "photos move in one by one" "$HOMES/owner/$OLD/2024/06/IMG_1.jpg"
exists "beside what was already there" "$HOMES/owner/$OLD/2024/06/mine.txt"
until_there "$HOMES/owner/$NEW" gone
gone "and the folder they left, empty, goes" "$HOMES/owner/$NEW"

echo "Leaving"
until_there "$HOMES/kid/$OLD/2024/08/IMG_3.jpg"
check "the kid leaves" "204" "$(code -X DELETE "$API/v1/spaces/$LIB/members/$K" -H "$AK")"
until_there "$HOMES/kid/$OLD" gone
gone "and their folder for it goes, not just its photos" "$HOMES/kid/$OLD"
exists "while everyone else keeps theirs" "$HOMES/member/$OLD/2024/07/IMG_2.jpg"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
