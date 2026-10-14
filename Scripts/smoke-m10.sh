#!/bin/bash
# Removal: deleting a photo sticks, and automatic backup doesn't undo it.
#
#   FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-m10.sh
#
# Runs its own server against its own database and blob store.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"

DB=framestation_m10; PORT=8077; API="http://127.0.0.1:$PORT"
export FRAMESTATION_DATABASE_URL="postgres://framestation:x@127.0.0.1:55432/$DB?sslmode=disable"
ROOT="$SCRATCH/m10"; rm -rf "$ROOT"; mkdir -p "$ROOT/blobroot" "$ROOT/files"
ROOT=$(cd "$ROOT" && pwd -P)
export FRAMESTATION_BLOB_ROOT="$ROOT/blobroot"
PASS=0; FAIL=0
q(){ psql -h 127.0.0.1 -p 55432 -U framestation -d $DB -tAqc "$1"; }
admin(){ psql -h 127.0.0.1 -p 55432 -U framestation -d postgres -tAqc "$1"; }
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; echo "      expected: $2"; echo "      actual:   $3"; FAIL=$((FAIL+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
jq(){ python3 -c "import sys,json; print(json.load(sys.stdin)$1)" 2>/dev/null; }
code(){ curl -s -o /dev/null -w '%{http_code}' "$@"; }

(cd "$SERVER_DIR" && swift build >/dev/null 2>&1) || { echo "server build failed"; exit 1; }
BIN="$(cd "$SERVER_DIR" && swift build --show-bin-path)/FrameStationServer"
# Whatever already answers on this port would be tested in this server's place.
curl -s -o /dev/null "$API/health" && { echo "port $PORT is already in use"; exit 1; }
admin "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1; admin "CREATE DATABASE $DB" >/dev/null
"$BIN" serve --hostname 127.0.0.1 --port $PORT > "$ROOT/server.log" 2>&1 &
SERVER=$!
# The log stays for a look after a failure; the files made for the run go.
trap 'kill $SERVER 2>/dev/null; wait $SERVER 2>/dev/null; rm -rf "$ROOT/files" "$ROOT/blobroot"' EXIT
for _ in $(seq 1 120); do curl -s -o /dev/null "$API/health" && break; sleep 0.5; done
curl -s -o /dev/null "$API/health" || { echo "server didn't start:"; tail -20 "$ROOT/server.log"; exit 1; }

c=$(cd "$SERVER_DIR" && "$BIN" invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
R=$(curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$c\",\"displayName\":\"Michael\",\"deviceName\":\"iPhone\",\"platform\":\"ios\"}")
T=$(echo "$R" | jq '["token"]'); SP=$(echo "$R" | jq '["personalSpace"]["id"]')
A="Authorization: Bearer $T"

f="$ROOT/files/IMG_5000.jpg"
vips gaussnoise "$ROOT/files/n.v" 400 300 >/dev/null 2>&1
vips copy "$ROOT/files/n.v" "$f" >/dev/null 2>&1
SHA=$(shasum -a 256 "$f" | awk '{print $1}'); SZ=$(stat -f%z "$f")

probe(){ # auto?
  curl -s -X POST "$API/v1/uploads/probe" -H "$A" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$SP\",\"sha256\":\"$SHA\",\"byteSize\":$SZ,\"filename\":\"IMG_5000.jpg\",\"isAutomaticBackup\":$1}"
}
UP=$(probe false | jq '["uploadID"]')
curl -s -X PUT "$API/v1/uploads/$UP/chunk/0" -H "$A" --data-binary "@$f" >/dev/null
AID=$(curl -s -X POST "$API/v1/uploads/$UP/commit" -H "$A" -H 'Content-Type: application/json' \
  -d "{\"spaceID\":\"$SP\",\"mediaType\":\"photo\",\"mime\":\"image/jpeg\",\"width\":400,\"height\":300,\"isRaw\":false,\"burstPick\":false}" | jq '["assetID"]')

echo "=== 1. it's there ==="
check "visible in the library" "1" "$(q "select count(*) from space_assets where space_id='$SP' and deleted_at is null;")"
check "served" "200" "$(code -H "$A" "$API/v1/assets/$AID/original")"

echo
echo "=== 2. remove it ==="
check "delete returns 204" "204" "$(code -X DELETE "$API/v1/spaces/$SP/assets/$AID" -H "$A")"
check "gone from the library" "0" "$(q "select count(*) from space_assets where space_id='$SP' and deleted_at is null;")"
check "but the record is kept" "1" "$(q "select count(*) from space_assets where space_id='$SP' and deleted_at is not null;")"
check "and who did it" "1" "$(q "select count(*) from space_assets where space_id='$SP' and deleted_by is not null;")"
check "deleting twice is a no-op" "404" "$(code -X DELETE "$API/v1/spaces/$SP/assets/$AID" -H "$A")"

echo
echo "=== 3. automatic backup does not undo it ==="
# This is the requirement: the photo is still on the phone, backup runs again.
check "probe declines" "removed" "$(probe true | jq '["status"]')"
check "no upload session offered" "" "$(probe true | jq '["uploadID"]')"
check "still absent afterward" "0" "$(q "select count(*) from space_assets where space_id='$SP' and deleted_at is null;")"

echo
echo "=== 4. but a deliberate re-add works ==="
# Picking the photo yourself means you want it back.
P=$(probe false)
check "probe offers an upload" "need" "$(echo "$P" | jq '["status"]')"
UP2=$(echo "$P" | jq '["uploadID"]')
curl -s -X PUT "$API/v1/uploads/$UP2/chunk/0" -H "$A" --data-binary "@$f" >/dev/null
curl -s -X POST "$API/v1/uploads/$UP2/commit" -H "$A" -H 'Content-Type: application/json' \
  -d "{\"spaceID\":\"$SP\",\"mediaType\":\"photo\",\"mime\":\"image/jpeg\",\"width\":400,\"height\":300,\"isRaw\":false,\"burstPick\":false}" >/dev/null
check "back in the library" "1" "$(q "select count(*) from space_assets where space_id='$SP' and deleted_at is null;")"

echo
echo "=== 5. who may remove ==="
c2=$(cd "$SERVER_DIR" && "$BIN" invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
T2=$(curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$c2\",\"displayName\":\"Morgan\",\"deviceName\":\"m\",\"platform\":\"ios\"}" | jq '["token"]')
NEW=$(q "select asset_id from space_assets where space_id='$SP' and deleted_at is null limit 1;")
check "a stranger cannot remove it" "404" \
  "$(code -X DELETE "$API/v1/spaces/$SP/assets/$NEW" -H "Authorization: Bearer $T2")"
check "and it is still there" "1" "$(q "select count(*) from space_assets where space_id='$SP' and deleted_at is null;")"

echo
echo "════════════════════════════════════"
echo "  passed: $PASS   failed: $FAIL"
echo "════════════════════════════════════"
[ "$FAIL" -eq 0 ]
