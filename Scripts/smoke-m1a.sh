#!/bin/bash
# M1a smoke test: chunked resumable upload, dedup, hash verification, access control.
#
# The server must already be running AND started with the same blob root this
# script inspects, since it asserts against files on disk:
#
#   export FRAMESTATION_TEST_DIR=/tmp/framestation-test
#   mkdir -p "$FRAMESTATION_TEST_DIR/blobroot"
#   cd Server && FRAMESTATION_DATABASE_URL=... \
#     FRAMESTATION_BLOB_ROOT="$FRAMESTATION_TEST_DIR/blobroot" \
#     swift run FrameStationServer serve --hostname 127.0.0.1 --port 8099
#
#   ./Scripts/smoke-m1a.sh
#
# Expects a freshly migrated, empty database.
set -uo pipefail

SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
API="${FRAMESTATION_API:-http://127.0.0.1:8099}"
PSQL="psql -h 127.0.0.1 -p 55432 -U framestation -d framestation -tAqc"
mkdir -p "$SCRATCH/chunks"
PASS=0; FAIL=0

# The invite CLI is a second process and needs the same connection settings the
# running server was started with.
export FRAMESTATION_DATABASE_URL="${FRAMESTATION_DATABASE_URL:-postgres://framestation:x@127.0.0.1:55432/framestation?sslmode=disable}"
export FRAMESTATION_BLOB_ROOT="${FRAMESTATION_BLOB_ROOT:-$SCRATCH/blobroot}"

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $1"; echo "      expected: $2"; echo "      actual:   $3"; FAIL=$((FAIL+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }

jq_get() { python3 -c "import sys,json; d=json.load(sys.stdin); print(d$1)" 2>/dev/null; }

echo "=== setup: invite + redeem ==="
CODE=$(cd "${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}" && \
  FRAMESTATION_DATABASE_URL="postgres://framestation:x@127.0.0.1:55432/framestation?sslmode=disable" \
  FRAMESTATION_BLOB_ROOT="$SCRATCH/blobroot" \
  swift run FrameStationServer invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
echo "  invite: $CODE"

REDEEM=$(curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$CODE\",\"displayName\":\"Michael\",\"deviceName\":\"iPhone\",\"platform\":\"ios\"}")
TOKEN=$(echo "$REDEEM" | jq_get '["token"]')
SPACE=$(echo "$REDEEM"  | jq_get '["personalSpace"]["id"]')
USERID=$(echo "$REDEEM" | jq_get '["user"]["id"]')
AUTH="Authorization: Bearer $TOKEN"
echo "  personal space: $SPACE"

# A second space to prove Personal -> Family Shared is a row, not a copy.
FAMILY=$($PSQL "INSERT INTO spaces (kind,name,created_by) VALUES ('shared','Family Shared','$USERID') RETURNING id;" | tr -d ' ')
$PSQL "INSERT INTO space_members (space_id,user_id,role) VALUES ('$FAMILY','$USERID','owner');" >/dev/null
echo "  family space:   $FAMILY"

echo
echo "=== build a 40 MB test file (3 chunks: 16+16+8) ==="
SRC="$SCRATCH/testvideo.mov"
dd if=/dev/urandom of="$SRC" bs=1048576 count=40 2>/dev/null
SHA=$(shasum -a 256 "$SRC" | awk '{print $1}')
SIZE=$(stat -f%z "$SRC")
rm -rf "$SCRATCH/chunks"; mkdir -p "$SCRATCH/chunks"
dd if="$SRC" of="$SCRATCH/chunks/0" bs=1048576 skip=0  count=16 2>/dev/null
dd if="$SRC" of="$SCRATCH/chunks/1" bs=1048576 skip=16 count=16 2>/dev/null
dd if="$SRC" of="$SCRATCH/chunks/2" bs=1048576 skip=32 count=8  2>/dev/null
echo "  sha256: $SHA  size: $SIZE"

echo
echo "=== 1. probe (fresh file) ==="
P=$(curl -s -X POST "$API/v1/uploads/probe" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"spaceID\":\"$SPACE\",\"sha256\":\"$SHA\",\"byteSize\":$SIZE,\"filename\":\"testvideo.mov\"}")
check "status is 'need'"      "need" "$(echo "$P" | jq_get '["status"]')"
check "chunkCount is 3"       "3"    "$(echo "$P" | jq_get '["chunkCount"]')"
check "all 3 chunks missing"  "[0, 1, 2]" "$(echo "$P" | jq_get '["missingChunks"]')"
UPLOAD=$(echo "$P" | jq_get '["uploadID"]')

echo
echo "=== 2. upload chunks 0 and 2, deliberately skipping 1 ==="
for i in 0 2; do
  R=$(curl -s -X PUT "$API/v1/uploads/$UPLOAD/chunk/$i" -H "$AUTH" \
      -H 'Content-Type: application/octet-stream' --data-binary "@$SCRATCH/chunks/$i")
  echo "  chunk $i -> received $(echo "$R" | jq_get '["receivedChunks"]')/3"
done
check "chunk 1 still outstanding" "[1]" "$(echo "$R" | jq_get '["missingChunks"]')"

echo
echo "=== 3. re-probe resumes instead of restarting ==="
P2=$(curl -s -X POST "$API/v1/uploads/probe" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"spaceID\":\"$SPACE\",\"sha256\":\"$SHA\",\"byteSize\":$SIZE,\"filename\":\"testvideo.mov\"}")
check "status is 'partial'"       "partial" "$(echo "$P2" | jq_get '["status"]')"
check "only chunk 1 missing"      "[1]"     "$(echo "$P2" | jq_get '["missingChunks"]')"
check "same session reused"       "$UPLOAD" "$(echo "$P2" | jq_get '["uploadID"]')"

echo
echo "=== 4. commit with a hole is refused ==="
C=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/v1/uploads/$UPLOAD/commit" -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d "{\"spaceID\":\"$SPACE\",\"mediaType\":\"video\",\"mime\":\"video/quicktime\",\"isRaw\":false,\"burstPick\":false}")
check "HTTP 400 on incomplete commit" "400" "$C"

echo
echo "=== 5. wrong-size chunk is rejected ==="
head -c 1000 "$SCRATCH/chunks/1" > "$SCRATCH/chunks/1.short"
C=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$API/v1/uploads/$UPLOAD/chunk/1" -H "$AUTH" \
  --data-binary "@$SCRATCH/chunks/1.short")
check "HTTP 400 on truncated chunk" "400" "$C"

echo
echo "=== 6. upload the real chunk 1, then commit ==="
curl -s -X PUT "$API/v1/uploads/$UPLOAD/chunk/1" -H "$AUTH" --data-binary "@$SCRATCH/chunks/1" >/dev/null
COMMIT=$(curl -s -X POST "$API/v1/uploads/$UPLOAD/commit" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"spaceID\":\"$SPACE\",\"mediaType\":\"video\",\"mime\":\"video/quicktime\",\"width\":3840,\"height\":2160,\"durationMs\":12500,\"capturedAt\":\"2026-07-24T19:28:00Z\",\"isRaw\":false,\"burstPick\":false,\"sourceLocalID\":\"ABC-123/L0/001\"}")
ASSET=$(echo "$COMMIT" | jq_get '["assetID"]')
check "not flagged as dedup"  "False" "$(echo "$COMMIT" | jq_get '["deduplicated"]')"
check "changeSeq assigned"    "1"     "$(echo "$COMMIT" | jq_get '["changeSeq"]')"
echo "  assetID: $ASSET"

echo
echo "=== 7. bytes landed correctly on disk ==="
SHARD="$SCRATCH/blobroot/blobs/${SHA:0:2}/${SHA:2:2}/$SHA.mov"
[ -f "$SHARD" ] && ok "blob at sharded path blobs/${SHA:0:2}/${SHA:2:2}/" || bad "blob at sharded path" "exists" "missing"
check "stored size matches"   "$SIZE" "$(stat -f%z "$SHARD" 2>/dev/null)"
check "stored hash matches"   "$SHA"  "$(shasum -a 256 "$SHARD" 2>/dev/null | awk '{print $1}')"
check "staging cleaned up"    "0"     "$(ls "$SCRATCH/blobroot/incoming" 2>/dev/null | wc -l | tr -d ' ')"

echo
echo "=== 8. browse tree hardlink shares the inode (zero extra space) ==="
BROWSE=$(find "$SCRATCH/blobroot/browse" -name '*.mov' 2>/dev/null | head -1)
[ -n "$BROWSE" ] && ok "browse link created: ${BROWSE#$SCRATCH/blobroot/}" || bad "browse link" "exists" "missing"
INO_BLOB=$(stat -f%i "$SHARD" 2>/dev/null)
INO_LINK=$(stat -f%i "$BROWSE" 2>/dev/null)
check "same inode as blob"    "$INO_BLOB" "$INO_LINK"

echo
echo "=== 9. database state ==="
check "1 asset row"           "1" "$($PSQL 'select count(*) from assets;')"
check "1 placement row"       "1" "$($PSQL 'select count(*) from space_assets;')"
check "attributed to uploader" "1" "$($PSQL "select count(*) from space_assets where uploaded_by_user_id='$USERID';")"
check "activity: 0 photo/1 video" "0|1" "$($PSQL 'select photo_count||chr(124)||video_count from activity_sessions;')"
check "session marked committed" "1" "$($PSQL 'select count(*) from upload_sessions where committed_at is not null;')"

echo
echo "=== 10. re-probe same content -> 'have', no transfer needed ==="
P3=$(curl -s -X POST "$API/v1/uploads/probe" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"spaceID\":\"$SPACE\",\"sha256\":\"$SHA\",\"byteSize\":$SIZE,\"filename\":\"testvideo.mov\"}")
check "status is 'have'"      "have"   "$(echo "$P3" | jq_get '["status"]')"
check "returns existing asset" "$ASSET" "$(echo "$P3" | jq_get '["assetID"]')"

echo
echo "=== 11. link into Family Shared: a row, not a copy ==="
L=$(curl -s -X POST "$API/v1/spaces/$FAMILY/assets/$ASSET" -H "$AUTH" \
  -H 'Content-Type: application/json' -d '{}')
check "flagged dedup"          "True" "$(echo "$L" | jq_get '["deduplicated"]')"
check "2 placements, 1 asset"  "2|1"  "$($PSQL 'select (select count(*) from space_assets)||chr(124)||(select count(*) from assets);')"
check "still one file on disk" "1"    "$(find "$SCRATCH/blobroot/blobs" -type f | wc -l | tr -d ' ')"
check "change_log has 2 rows"  "2"    "$($PSQL 'select count(*) from change_log;')"

echo
echo "=== 12. hash mismatch is caught and rejected ==="
LIE=$(python3 -c "print('a'*64)")
dd if=/dev/urandom of="$SCRATCH/lie.bin" bs=1024 count=64 2>/dev/null
P4=$(curl -s -X POST "$API/v1/uploads/probe" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"spaceID\":\"$SPACE\",\"sha256\":\"$LIE\",\"byteSize\":65536,\"filename\":\"lie.bin\"}")
U4=$(echo "$P4" | jq_get '["uploadID"]')
curl -s -X PUT "$API/v1/uploads/$U4/chunk/0" -H "$AUTH" --data-binary "@$SCRATCH/lie.bin" >/dev/null
C4=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/v1/uploads/$U4/commit" -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d "{\"spaceID\":\"$SPACE\",\"mediaType\":\"photo\",\"mime\":\"image/heic\",\"isRaw\":false,\"burstPick\":false}")
check "HTTP 422 on hash mismatch" "422" "$C4"
check "no asset created"          "1"   "$($PSQL 'select count(*) from assets;')"
check "staging discarded"         "0"   "$(ls "$SCRATCH/blobroot/incoming" 2>/dev/null | wc -l | tr -d ' ')"

echo
echo "=== 13. another user cannot touch this session ==="
CODE2=$(cd "${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}" && \
  FRAMESTATION_DATABASE_URL="postgres://framestation:x@127.0.0.1:55432/framestation?sslmode=disable" \
  FRAMESTATION_BLOB_ROOT="$SCRATCH/blobroot" \
  swift run FrameStationServer invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
T2=$(curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$CODE2\",\"displayName\":\"Morgan\",\"deviceName\":\"iPad\",\"platform\":\"ipados\"}" | jq_get '["token"]')
C5=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$API/v1/uploads/$UPLOAD/chunk/0" \
  -H "Authorization: Bearer $T2" --data-binary "@$SCRATCH/chunks/0")
check "HTTP 404 on foreign session" "404" "$C5"
C6=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/v1/spaces/$SPACE/assets/$ASSET" \
  -H "Authorization: Bearer $T2" -H 'Content-Type: application/json' -d '{}')
check "HTTP 404 linking into a space you're not in" "404" "$C6"

echo
echo "════════════════════════════════════"
echo "  passed: $PASS   failed: $FAIL"
echo "════════════════════════════════════"
[ "$FAIL" -eq 0 ]
