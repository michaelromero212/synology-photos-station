#!/bin/bash
# Removing from a shared album. What somebody added is theirs to remove, and the
# album's owner may remove anything. Nobody else can take another member's
# photos, and nobody can credit a photo to themselves to get around that.
#
#   FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-shared-remove.sh
#
# Runs its own server against its own database and blob store.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"

DB=framestation_sharedremove; PORT=8092; API="http://127.0.0.1:$PORT"
export FRAMESTATION_DATABASE_URL="postgres://framestation:x@127.0.0.1:55432/$DB?sslmode=disable"
ROOT="$SCRATCH/sharedremove"; rm -rf "$ROOT"; mkdir -p "$ROOT/blobroot" "$ROOT/files"
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

SERVER=""
serve(){
  "$BIN" serve --hostname 127.0.0.1 --port $PORT >> "$ROOT/server.log" 2>&1 &
  SERVER=$!
  for _ in $(seq 1 120); do curl -s -o /dev/null "$API/health" && return; sleep 0.5; done
  echo "server didn't start:"; tail -20 "$ROOT/server.log"; exit 1
}
stop(){ kill "$SERVER" 2>/dev/null; wait "$SERVER" 2>/dev/null; }
trap stop EXIT

redeem(){ curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$(cd "$SERVER_DIR" && "$BIN" invite 2>/dev/null | grep 'Invite code:' | awk '{print $3}')\",\"displayName\":\"$1\",\"deviceName\":\"iPhone\",\"platform\":\"ios\"}"; }

# upload <token> <space> <name> <width> → asset id
upload(){
  local f="$ROOT/files/$3" SHA SZ UP
  vips gaussnoise "$ROOT/files/n.v" "$4" 200 >/dev/null 2>&1
  vips copy "$ROOT/files/n.v" "$f" >/dev/null 2>&1
  SHA=$(shasum -a 256 "$f" | awk '{print $1}'); SZ=$(stat -f%z "$f")
  UP=$(curl -s -X POST "$API/v1/uploads/probe" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$2\",\"sha256\":\"$SHA\",\"byteSize\":$SZ,\"filename\":\"$3\",\"isAutomaticBackup\":false}" | jq '["uploadID"]')
  curl -s -X PUT "$API/v1/uploads/$UP/chunk/0" -H "Authorization: Bearer $1" --data-binary "@$f" >/dev/null
  curl -s -X POST "$API/v1/uploads/$UP/commit" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$2\",\"mediaType\":\"photo\",\"mime\":\"image/jpeg\",\"width\":$4,\"height\":200,\"capturedAt\":\"2025-06-01T12:00:00Z\",\"isRaw\":false,\"burstPick\":false}" | jq '["assetID"]'
}

# remove <token> <space> <asset> → HTTP status, the body kept in $ROOT/reply
remove(){ curl -s -o "$ROOT/reply" -w '%{http_code}' -X DELETE "$API/v1/spaces/$2/assets/$3" \
  -H "Authorization: Bearer $1"; }
gone(){ q "SELECT deleted_at IS NOT NULL FROM space_assets WHERE space_id = '$1' AND asset_id = '$2'"; }

# credit <token> <space> <asset> <user> → how many the server changed
credit(){ curl -s -X POST "$API/v1/spaces/$2/assets/credit" -H "Authorization: Bearer $1" \
  -H 'Content-Type: application/json' -d "{\"assetIDs\":[\"$3\"],\"creditedTo\":\"$4\"}" | jq '["updated"]'; }

serve
R=$(redeem Owner); OT=$(echo "$R" | jq '["token"]'); OWNER=$(echo "$R" | jq '["user"]["id"]')
R=$(redeem Member); MT=$(echo "$R" | jq '["token"]'); MEMBER=$(echo "$R" | jq '["user"]["id"]')
MINE=$(echo "$R" | jq '["personalSpace"]["id"]')
SHARED=$(curl -s -X POST "$API/v1/spaces" -H "Authorization: Bearer $OT" -H 'Content-Type: application/json' \
  -d "{\"name\":\"Family Shared\",\"memberIDs\":[\"$MEMBER\"]}" | jq '["id"]')
[ -n "$SHARED" ] && [ -n "$MT" ] || { echo "setup failed"; exit 1; }

O1=$(upload "$OT" "$SHARED" o1.jpg 301); O2=$(upload "$OT" "$SHARED" o2.jpg 302)
O3=$(upload "$OT" "$SHARED" o3.jpg 303); O4=$(upload "$OT" "$SHARED" o4.jpg 304)
M1=$(upload "$MT" "$SHARED" m1.jpg 311); M2=$(upload "$MT" "$SHARED" m2.jpg 312)
P1=$(upload "$MT" "$MINE" p1.jpg 321)

echo "A member of the shared album"
check "can't remove a photo someone else added" "403" "$(remove "$MT" "$SHARED" "$O1")"
check "and is told why" "Only the person who added this, or the shared album's owner, can remove it." \
  "$(jq '["reason"]' < "$ROOT/reply")"
check "and the photo is still there" "f" "$(gone "$SHARED" "$O1")"
check "can remove one they added" "204" "$(remove "$MT" "$SHARED" "$M1")"
check "which goes to Recently Deleted" "t" "$(gone "$SHARED" "$M1")"
check "can remove anything in their own library" "204" "$(remove "$MT" "$MINE" "$P1")"

echo "The album's owner"
check "can remove a photo the member added" "204" "$(remove "$OT" "$SHARED" "$M2")"
check "and their own" "204" "$(remove "$OT" "$SHARED" "$O2")"

echo "Credits"
check "a member can't credit someone else's photo to themselves" "0" "$(credit "$MT" "$SHARED" "$O3" "$MEMBER")"
check "so it's still the owner's to remove" "403" "$(remove "$MT" "$SHARED" "$O3")"
check "the owner can credit a photo to the member" "1" "$(credit "$OT" "$SHARED" "$O4" "$MEMBER")"
check "and then the member counts as having added it" "204" "$(remove "$MT" "$SHARED" "$O4")"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
