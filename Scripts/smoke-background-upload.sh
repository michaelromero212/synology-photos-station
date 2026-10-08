#!/bin/bash
# Background uploads: a photo iOS sends on the app's behalf, in one request,
# while the app is closed. Stored like any upload, never twice, and never
# bringing back a photo removed on purpose. Also covers the guard that keeps
# the app's own upload and iOS's from both landing when they race.
#
#   FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-background-upload.sh
#
# Runs its own server against its own database and blob store.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"

DB=framestation_background; PORT=8089; API="http://127.0.0.1:$PORT"
export FRAMESTATION_DATABASE_URL="postgres://framestation:x@127.0.0.1:55432/$DB?sslmode=disable"
ROOT="$SCRATCH/background"; rm -rf "$ROOT"; mkdir -p "$ROOT/blobroot" "$ROOT/files"
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
trap 'kill $SERVER 2>/dev/null; wait $SERVER 2>/dev/null' EXIT
for _ in $(seq 1 120); do curl -s -o /dev/null "$API/health" && break; sleep 0.5; done

redeem(){ curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$(cd "$SERVER_DIR" && "$BIN" invite 2>/dev/null | grep 'Invite code:' | awk '{print $3}')\",\"displayName\":\"$1\",\"deviceName\":\"iPhone\",\"platform\":\"ios\"}"; }
R=$(redeem Owner); TOKEN=$(echo "$R" | jq '["token"]'); SPACE=$(echo "$R" | jq '["personalSpace"]["id"]')
OWNER=$(echo "$R" | jq '["user"]["id"]'); AUTH="Authorization: Bearer $TOKEN"
R2=$(redeem Member); MEMBER=$(echo "$R2" | jq '["user"]["id"]')
SHARED=$(curl -s -X POST "$API/v1/spaces" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"name\":\"Family Shared\",\"memberIDs\":[\"$MEMBER\"]}" | jq '["id"]')
[ -n "$SPACE" ] && [ -n "$SHARED" ] || { echo "setup failed"; exit 1; }

# photo <name> <width>: a JPEG of its own.
photo(){ vips gaussnoise "$ROOT/files/n.v" "$2" 300 >/dev/null 2>&1
         vips copy "$ROOT/files/n.v" "$ROOT/files/$1" >/dev/null 2>&1; }
# header <file> <space> [automatic] [byteSize] [live group]: what the extension sends.
header(){ python3 - "$@" <<'PY'
import base64, json, os, sys
path, space = sys.argv[1], sys.argv[2]
automatic = sys.argv[3] != "manual" if len(sys.argv) > 3 else True
size = int(sys.argv[4]) if len(sys.argv) > 4 and sys.argv[4] else os.path.getsize(path)
live = sys.argv[5] if len(sys.argv) > 5 else None
name = os.path.basename(path)
video = name.endswith(".mov")
body = {"filename": name, "byteSize": size, "isAutomaticBackup": automatic, "commit": {
    "spaceID": space, "mediaType": "video" if video else "photo",
    "mime": "video/quicktime" if video else "image/jpeg",
    "capturedAt": "2026-10-07T14:30:00Z", "capturedAtMs": 1791383400000, "capturedTZOffset": -14400,
    "latitude": 38.4716, "longitude": -77.9967, "isRaw": False, "burstPick": False,
    "mediaSubtypes": [], "sourceLocalID": f"LOCAL-{name}", "liveGroupID": live}}
print(base64.urlsafe_b64encode(json.dumps(body).encode()).decode().rstrip("="))
PY
}
# send <file> <space> [header args…] → "status result asset", the body kept in $ROOT/reply
send(){ local file=$1 h; h=$(header "$@")
  curl -s -o "$ROOT/reply" -D "$ROOT/headers" -w '%{http_code}' -X POST "$API/v1/uploads/background" \
    -H "$AUTH" -H "X-FrameStation-Upload: $h" --data-binary "@$file" > "$ROOT/status"
  echo "$(cat "$ROOT/status") $(grep -i '^x-framestation-result:' "$ROOT/headers" | awk '{print $2}' | tr -d '\r') $(grep -i '^x-framestation-asset-id:' "$ROOT/headers" | awk '{print $2}' | tr -d '\r')"; }
placed(){ q "SELECT count(*) FROM space_assets sa JOIN assets a ON a.id = sa.asset_id
             WHERE sa.space_id = '$1' AND sa.deleted_at IS NULL AND a.sha256 = '$(shasum -a 256 "$2" | awk '{print $1}')'"; }

echo "Asking first"
check "iOS's capability question gets a 501, so it sends files whole" "501" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X OPTIONS "$API/v1/uploads/background")"
check "health lists the capability" "True" \
  "$(curl -s "$API/health" | python3 -c "import sys,json; print('background-upload' in (json.load(sys.stdin).get('capabilities') or []))")"

echo "Refused"
photo a.jpg 401
check "without a token" "401" "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API/v1/uploads/background" --data-binary "@$ROOT/files/a.jpg")"
check "without the header" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API/v1/uploads/background" -H "$AUTH" --data-binary "@$ROOT/files/a.jpg")"
check "a body of the wrong length" "400" "$(send "$ROOT/files/a.jpg" "$SPACE" auto 12 | cut -d' ' -f1)"
check "and nothing is kept of it" "0" "$(placed "$SPACE" "$ROOT/files/a.jpg")"
check "not even its staging" "0" "$(find "$ROOT/blobroot/incoming" -type f 2>/dev/null | wc -l | tr -d ' ')"

echo "A new photo"
OUT=$(send "$ROOT/files/a.jpg" "$SPACE"); read -r STATUS RESULT ASSET <<<"$OUT"
check "is stored" "201 stored" "$STATUS $RESULT"
check "and says which asset it became" "$ASSET" "$(jq '["assetID"]' < "$ROOT/reply")"
check "once" "1" "$(placed "$SPACE" "$ROOT/files/a.jpg")"
check "with when it was taken" "2026-10-07 10:30:00" "$(q "SELECT to_char(local_captured_at, 'YYYY-MM-DD HH24:MI:SS') FROM assets WHERE id = '$ASSET'")"
check "where" "38.4716,-77.9967" "$(q "SELECT lat || ',' || lon FROM assets WHERE id = '$ASSET'")"
check "and which photo on the phone it was" "LOCAL-a.jpg" "$(q "SELECT source_local_id FROM space_assets WHERE asset_id = '$ASSET'")"
check "and its thumbnails are on the way" "1" "$(q "SELECT count(*) FROM derivation_jobs WHERE asset_id = '$ASSET' AND kind = 'thumbnails'")"
check "byte for byte" "$(shasum -a 256 "$ROOT/files/a.jpg" | awk '{print $1}')" "$(q "SELECT sha256 FROM assets WHERE id = '$ASSET'")"

echo "Again"
OUT=$(send "$ROOT/files/a.jpg" "$SPACE"); read -r STATUS RESULT AGAIN <<<"$OUT"
check "the same photo sent twice is the one already here" "200 have $ASSET" "$STATUS $RESULT $AGAIN"
check "still once" "1" "$(placed "$SPACE" "$ROOT/files/a.jpg")"

echo "Already in another library"
OUT=$(send "$ROOT/files/a.jpg" "$SHARED"); read -r STATUS RESULT SHARED_ASSET <<<"$OUT"
check "is linked rather than sent again" "200 have" "$STATUS $RESULT"
check "into the shared library" "1" "$(placed "$SHARED" "$ROOT/files/a.jpg")"

echo "Removed on purpose"
photo b.jpg 402
read -r _ _ B <<<"$(send "$ROOT/files/b.jpg" "$SPACE")"
check "a photo can be removed" "204" "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "$API/v1/spaces/$SPACE/assets/$B" -H "$AUTH")"
check "and the backup doesn't bring it back" "200 removed" "$(send "$ROOT/files/b.jpg" "$SPACE" | cut -d' ' -f1,2)"
check "it stays removed" "0" "$(placed "$SPACE" "$ROOT/files/b.jpg")"
check "though someone adding it by hand can" "201 stored" "$(send "$ROOT/files/b.jpg" "$SPACE" manual | cut -d' ' -f1,2)"

echo "Two at once"
photo c.jpg 403
H=$(header "$ROOT/files/c.jpg" "$SPACE"); RACERS=()
for i in 1 2 3; do
  curl -s -o /dev/null -X POST "$API/v1/uploads/background" -H "$AUTH" -H "X-FrameStation-Upload: $H" \
    --data-binary "@$ROOT/files/c.jpg" &
  RACERS+=($!)
done
# Only the uploads: a bare `wait` would wait for the server too, and never return.
wait "${RACERS[@]}"
check "three copies racing land once" "1" "$(placed "$SPACE" "$ROOT/files/c.jpg")"

echo "Racing the app's own upload"
photo d.jpg 404
SHA=$(shasum -a 256 "$ROOT/files/d.jpg" | awk '{print $1}'); SZ=$(stat -f%z "$ROOT/files/d.jpg")
UP=$(curl -s -X POST "$API/v1/uploads/probe" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"spaceID\":\"$SPACE\",\"sha256\":\"$SHA\",\"byteSize\":$SZ,\"filename\":\"d.jpg\",\"isAutomaticBackup\":true}" | jq '["uploadID"]')
curl -s -o /dev/null -X PUT "$API/v1/uploads/$UP/chunk/0" -H "$AUTH" --data-binary "@$ROOT/files/d.jpg"
check "iOS's copy lands first" "201 stored" "$(send "$ROOT/files/d.jpg" "$SPACE" | cut -d' ' -f1,2)"
COMMIT=$(curl -s -X POST "$API/v1/uploads/$UP/commit" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"spaceID\":\"$SPACE\",\"mediaType\":\"photo\",\"mime\":\"image/jpeg\",\"isRaw\":false,\"burstPick\":false}")
check "and the app's commit joins it" "True" "$(echo "$COMMIT" | jq '["deduplicated"]')"
check "rather than adding it twice" "1" "$(placed "$SPACE" "$ROOT/files/d.jpg")"

echo "A long video"
head -c 31457280 /dev/urandom > "$ROOT/files/long.mov"
read -r STATUS RESULT VIDEO <<<"$(send "$ROOT/files/long.mov" "$SPACE")"
check "arrives whole" "201 stored" "$STATUS $RESULT"
check "every byte of it" "$(shasum -a 256 "$ROOT/files/long.mov" | awk '{print $1}')" "$(q "SELECT sha256 FROM assets WHERE id = '$VIDEO'")"
check "as a video" "video" "$(q "SELECT media_type FROM assets WHERE id = '$VIDEO'")"

echo "A Live Photo"
photo live.jpg 405; head -c 200000 /dev/urandom > "$ROOT/files/live.mov"
GROUP=$(uuidgen | tr 'A-Z' 'a-z')
read -r _ _ STILL <<<"$(send "$ROOT/files/live.jpg" "$SPACE" auto "" "$GROUP")"
read -r _ _ MOTION <<<"$(send "$ROOT/files/live.mov" "$SPACE" auto "" "$GROUP")"
check "keeps its two halves together" "$GROUP $GROUP" \
  "$(q "SELECT live_group_id FROM assets WHERE id = '$STILL'") $(q "SELECT live_group_id FROM assets WHERE id = '$MOTION'")"

check "nothing is left staged" "0" "$(find "$ROOT/blobroot/incoming" -type f 2>/dev/null | wc -l | tr -d ' ')"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
