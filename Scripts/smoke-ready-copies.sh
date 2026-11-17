#!/bin/bash
# Copies of a photo are ready when the photo is.
#
# A photo shared into a shared library or an album shared with people is
# copied, and the copy keeps the photo's "thumbnail ready" mark as it was at
# that moment. Copied before the NAS had made the thumbnail, it stayed "not
# ready" for good — a gray tile on every device but the one that took it.
# Here a copy is put in that state by hand (the race is too quick to catch on
# a fast Mac) and each way a photo becomes ready has to carry its copies:
# the device's own thumbnail, the NAS's queue, and migration 0042 for the
# copies already stuck.
#
#   FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-ready-copies.sh
#
# Runs its own server against its own database and blob store.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"

DB=framestation_readycopies; PORT=8106; API="http://127.0.0.1:$PORT"
export FRAMESTATION_DATABASE_URL="postgres://framestation:x@127.0.0.1:55432/$DB?sslmode=disable"
ROOT="$SCRATCH/readycopies"; rm -rf "$ROOT"; mkdir -p "$ROOT/blobroot" "$ROOT/files"
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
curl -s -o /dev/null "$API/health" && { echo "port $PORT already answers; stop that first"; exit 1; }
admin "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1; admin "CREATE DATABASE $DB" >/dev/null

SERVER=""
serve(){
  "$BIN" serve --hostname 127.0.0.1 --port $PORT >> "$ROOT/server.log" 2>&1 &
  SERVER=$!
  for _ in $(seq 1 120); do curl -s -o /dev/null "$API/health" && return; sleep 0.5; done
  echo "server didn't start:"; tail -20 "$ROOT/server.log"; exit 1
}
stop(){ kill $SERVER 2>/dev/null; wait $SERVER 2>/dev/null; SERVER=""; }
trap 'stop; rm -rf "$ROOT/files" "$ROOT/blobroot"; admin "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1' EXIT

invite(){ (cd "$SERVER_DIR" && "$BIN" invite "$@" 2>/dev/null) | grep 'Invite code:' | awk '{print $3}'; }
redeem(){ curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$(invite)\",\"displayName\":\"$1\",\"deviceName\":\"iPhone\",\"platform\":\"ios\"}"; }

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
# waits for a condition that the query answers "t" to, up to 30 seconds
until_true(){ for _ in $(seq 1 60); do [ "$(q "$1")" = "t" ] && return 0; sleep 0.5; done; return 1; }

# A copy of <asset> the way `copyIntoSpace` makes one, caught before the
# photo was ready, placed in <space>. Prints the copy's placement id.
stuck_copy(){
  local copy
  copy=$(q "INSERT INTO assets
      (sha256, byte_size, media_type, mime, blob_ext, width, height, captured_at, thumb_version)
    SELECT sha256, byte_size, media_type, mime, blob_ext, width, height, captured_at, 0
    FROM assets WHERE id = '$1' RETURNING id" | head -1)
  q "INSERT INTO space_assets (space_id, asset_id, uploaded_by_user_id)
     VALUES ('$2', '$copy', '$3') RETURNING id" | head -1
}
ready(){ q "SELECT a.derived_at IS NOT NULL AND a.thumbhash IS NOT NULL
            FROM space_assets sa JOIN assets a ON a.id = sa.asset_id WHERE sa.id = '$1'"; }
seq_now(){ q "SELECT COALESCE(max(seq), 0) FROM change_log"; }
told(){ q "SELECT count(*) FROM change_log WHERE seq > $2 AND space_id = '$3'
           AND entity = 'space_asset' AND entity_id = '$1' AND op = 'update'"; }

serve
R=$(redeem Ann); AT=$(echo "$R" | jq '["token"]'); ANN=$(echo "$R" | jq '["user"]["id"]'); AP=$(echo "$R" | jq '["personalSpace"]["id"]')
R=$(redeem Ben); BP=$(echo "$R" | jq '["personalSpace"]["id"]')
[ -n "$AT" ] && [ -n "$BP" ] || { echo "setup failed"; exit 1; }
P1=$(upload "$AT" "$AP" p1.jpg 301)
[ -n "$P1" ] || { echo "upload failed"; tail -20 "$ROOT/server.log"; exit 1; }
until_true "SELECT derived_at IS NOT NULL FROM assets WHERE id = '$P1'" \
  || { echo "the photo was never made ready"; tail -20 "$ROOT/server.log"; exit 1; }
# Somewhere a copy can be: Ben's library stands in for a shared one.
ANNS=$(q "INSERT INTO space_members (space_id, user_id, role) VALUES ('$BP', '$ANN', 'contributor') RETURNING space_id")
[ -n "$ANNS" ] || { echo "couldn't share Ben's library with Ann"; exit 1; }

echo "The device's own thumbnail arrives"
C1=$(stuck_copy "$P1" "$BP" "$ANN"); S=$(seq_now)
check "the copy starts out not ready" "f" "$(ready "$C1")"
vips copy "$ROOT/files/n.v" "$ROOT/files/t.jpg" >/dev/null 2>&1
B64=$(base64 -i "$ROOT/files/t.jpg" | tr -d '\n')
printf '{"jpeg":"%s","size":512}' "$B64" > "$ROOT/files/thumb.json"
check "the phone sends its thumbnail" "204" "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  "$API/v1/assets/$P1/thumb" -H "Authorization: Bearer $AT" -H 'Content-Type: application/json' \
  --data-binary "@$ROOT/files/thumb.json")"
check "and the copy is ready with it" "t" "$(ready "$C1")"
check "and its library is told" "1" "$(told "$C1" "$S" "$BP")"

echo "The NAS's queue finishes the photo"
C2=$(stuck_copy "$P1" "$BP" "$ANN")
q "UPDATE assets SET derived_at = NULL WHERE id = '$P1'" >/dev/null
S=$(seq_now)
q "INSERT INTO derivation_jobs (asset_id, kind) VALUES ('$P1', 'thumbnails')
   ON CONFLICT (asset_id, kind) DO UPDATE SET state = 'pending', attempts = 0, last_error = NULL" >/dev/null
until_true "SELECT derived_at IS NOT NULL FROM assets WHERE id = '$P1'" || true
check "the photo is ready again" "t" "$(q "SELECT derived_at IS NOT NULL FROM assets WHERE id = '$P1'")"
check "and the copy with it" "t" "$(ready "$C2")"
check "and its library is told" "1" "$(told "$C2" "$S" "$BP")"

echo "Copies already stuck when the NAS updates"
C3=$(stuck_copy "$P1" "$BP" "$ANN")
LONE=$(q "INSERT INTO assets (sha256, byte_size, media_type, mime, blob_ext, thumb_version)
          VALUES (repeat('0', 64), 1, 'photo', 'image/jpeg', 'jpg', 0) RETURNING id" | head -1)
LONEP=$(q "INSERT INTO space_assets (space_id, asset_id, uploaded_by_user_id)
           VALUES ('$BP', '$LONE', '$ANN') RETURNING id" | head -1)
stop
S=$(seq_now)
q "DELETE FROM schema_migrations WHERE name LIKE '0042%'" >/dev/null
serve
check "the stuck copy is ready" "t" "$(ready "$C3")"
check "and its library is told" "1" "$(told "$C3" "$S" "$BP")"
check "a photo with nothing ready to go by stays as it was" "f" "$(ready "$LONEP")"
check "and nobody is told about it" "0" "$(told "$LONEP" "$S" "$BP")"
check "nor about the copies that were fine" "0" "$(told "$C1" "$S" "$BP")"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
