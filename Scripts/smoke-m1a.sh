#!/bin/bash
# M1a smoke test: chunked resumable upload, dedup, hash verification, access control.
#
#   FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-m1a.sh
#
# Runs its own server against its own database and blob store, because every
# count here is a count of the whole database.
#
# Scripts/smoke-image.sh runs this same script against a built container image,
# which is how CI checks an image before publishing it. It hands over the
# container's server, a CLI and a psql that reach the container's database, and
# a blob root at "$FRAMESTATION_TEST_DIR/blobroot", since the checks below look
# at files on disk:
#
#   FRAMESTATION_API=http://127.0.0.1:8085 \
#   FRAMESTATION_CLI="docker exec <server container> ./FrameStationServer" \
#   FRAMESTATION_PSQL="docker exec <database container> psql … -tAqc" ./Scripts/smoke-m1a.sh
set -uo pipefail

SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
export PATH="/opt/homebrew/bin:$PATH"
PASS=0; FAIL=0

if [ -n "${FRAMESTATION_API:-}" ]; then
  # All three or none. A server given without the other two left the invite
  # and the queries in whatever database this shell reaches by default, which
  # on a Mac is the dev library.
  [ -n "${FRAMESTATION_CLI:-}" ] && [ -n "${FRAMESTATION_PSQL:-}" ] || {
    echo "FRAMESTATION_API needs FRAMESTATION_CLI and FRAMESTATION_PSQL beside it"; exit 1; }
  API="$FRAMESTATION_API"; PSQL="$FRAMESTATION_PSQL"
  BLOBS="$SCRATCH/blobroot"; FILES="$SCRATCH"
  # Unquoted on purpose: it's a command line, `docker exec <container> ./FrameStationServer`.
  invite(){ $FRAMESTATION_CLI invite 2>/dev/null | grep "Invite code:" | awk '{print $3}'; }
else
  SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
  DB=framestation_m1a; PORT=8070; API="http://127.0.0.1:$PORT"
  export FRAMESTATION_DATABASE_URL="postgres://framestation:x@127.0.0.1:55432/$DB?sslmode=disable"
  ROOT="$SCRATCH/m1a"; rm -rf "$ROOT"; mkdir -p "$ROOT/blobroot" "$ROOT/files"
  ROOT=$(cd "$ROOT" && pwd -P)
  export FRAMESTATION_BLOB_ROOT="$ROOT/blobroot"
  BLOBS="$FRAMESTATION_BLOB_ROOT"; FILES="$ROOT/files"
  PSQL="psql -h 127.0.0.1 -p 55432 -U framestation -d $DB -tAqc"
  admin(){ psql -h 127.0.0.1 -p 55432 -U framestation -d postgres -tAqc "$1"; }

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
  invite(){ (cd "$SERVER_DIR" && "$BIN" invite 2>/dev/null) | grep "Invite code:" | awk '{print $3}'; }
fi
mkdir -p "$FILES/chunks"

# Size and hash the same way on macOS and Linux: `stat -f%z` and `shasum` are
# BSD and Perl respectively, and CI runs this on Ubuntu.
size_of()   { wc -c < "$1" | tr -d ' '; }
sha256_of() {
  if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi \
    | awk '{print $1}'
}

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $1"; echo "      expected: $2"; echo "      actual:   $3"; FAIL=$((FAIL+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }

jq_get() { python3 -c "import sys,json; d=json.load(sys.stdin); print(d$1)" 2>/dev/null; }

echo "=== setup: invite + redeem ==="
CODE=$(invite)
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
SRC="$FILES/testvideo.mov"
dd if=/dev/urandom of="$SRC" bs=1048576 count=40 2>/dev/null
SHA=$(sha256_of "$SRC")
SIZE=$(size_of "$SRC")
rm -rf "$FILES/chunks"; mkdir -p "$FILES/chunks"
dd if="$SRC" of="$FILES/chunks/0" bs=1048576 skip=0  count=16 2>/dev/null
dd if="$SRC" of="$FILES/chunks/1" bs=1048576 skip=16 count=16 2>/dev/null
dd if="$SRC" of="$FILES/chunks/2" bs=1048576 skip=32 count=8  2>/dev/null
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
      -H 'Content-Type: application/octet-stream' --data-binary "@$FILES/chunks/$i")
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
head -c 1000 "$FILES/chunks/1" > "$FILES/chunks/1.short"
C=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$API/v1/uploads/$UPLOAD/chunk/1" -H "$AUTH" \
  --data-binary "@$FILES/chunks/1.short")
check "HTTP 400 on truncated chunk" "400" "$C"

echo
echo "=== 6. upload the real chunk 1, then commit ==="
curl -s -X PUT "$API/v1/uploads/$UPLOAD/chunk/1" -H "$AUTH" --data-binary "@$FILES/chunks/1" >/dev/null
COMMIT=$(curl -s -X POST "$API/v1/uploads/$UPLOAD/commit" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"spaceID\":\"$SPACE\",\"mediaType\":\"video\",\"mime\":\"video/quicktime\",\"width\":3840,\"height\":2160,\"durationMs\":12500,\"capturedAt\":\"2026-07-24T19:28:00Z\",\"isRaw\":false,\"burstPick\":false,\"sourceLocalID\":\"ABC-123/L0/001\"}")
ASSET=$(echo "$COMMIT" | jq_get '["assetID"]')
check "not flagged as dedup"  "False" "$(echo "$COMMIT" | jq_get '["deduplicated"]')"
check "changeSeq assigned"    "1"     "$(echo "$COMMIT" | jq_get '["changeSeq"]')"
echo "  assetID: $ASSET"

echo
echo "=== 7. bytes landed correctly on disk ==="
SHARD="$BLOBS/blobs/${SHA:0:2}/${SHA:2:2}/$SHA.mov"
[ -f "$SHARD" ] && ok "blob at sharded path blobs/${SHA:0:2}/${SHA:2:2}/" || bad "blob at sharded path" "exists" "missing"
check "stored size matches"   "$SIZE" "$(size_of "$SHARD" 2>/dev/null)"
check "stored hash matches"   "$SHA"  "$(sha256_of "$SHARD" 2>/dev/null)"
check "staging cleaned up"    "0"     "$(ls "$BLOBS/incoming" 2>/dev/null | wc -l | tr -d ' ')"

echo
echo "=== 8. no legacy browse/ tree under the blob root ==="
# Uploads used to hardlink every blob into blobroot/browse/<user>/YYYY/MM, and
# nothing ever removed those links — so purging a photo unlinked its blob while
# the bytes stayed on disk under the old tree's name. The home tree replaced it
# (BrowseTreeWorker); an upload must not write here at all.
[ ! -e "$BLOBS/browse" ] && ok "no browse/ tree written" || bad "browse/ tree" "absent" "present"

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
check "still one file on disk" "1"    "$(find "$BLOBS/blobs" -type f | wc -l | tr -d ' ')"
check "change_log has 2 rows"  "2"    "$($PSQL 'select count(*) from change_log;')"

echo
echo "=== 11b. the video plays: a link, then ranges through it ==="
# What a player does: ask for a link, then fetch the file through it a piece
# at a time. In October 2026 the stream's query stopped selecting a column its
# row needed and failed on every request — no video anywhere would play while
# everything else answered — and this is the check CI runs before an image can
# reach the NAS, so that can't ship again.
LINK=$(curl -s "$API/v1/assets/$ASSET/playback" -H "$AUTH" | jq_get '["url"]')
check "a playback link is issued" "1" "$([ -n "$LINK" ] && echo 1 || echo 0)"
check "the first bytes come back as a range" "206" \
  "$(curl -s -o /dev/null -w '%{http_code}' -H 'Range: bytes=0-99' "$LINK")"
check "and are the file's own" "$(head -c 100 "$SRC" | od -An -tx1 | tr -d ' \n')" \
  "$(curl -s -H 'Range: bytes=0-99' "$LINK" | od -An -tx1 | tr -d ' \n')"
check "a range from the middle is the file's own too" \
  "$(tail -c +20000001 "$SRC" | head -c 100 | od -An -tx1 | tr -d ' \n')" \
  "$(curl -s -H 'Range: bytes=20000000-20000099' "$LINK" | od -An -tx1 | tr -d ' \n')"
check "a link with a forged signature is refused" "404" \
  "$(curl -s -o /dev/null -w '%{http_code}' -H 'Range: bytes=0-99' \
     "$(echo "$LINK" | sed -E 's/sig=[^&]*/sig=AAAA/')")"

echo
echo "=== 12. hash mismatch is caught and rejected ==="
LIE=$(python3 -c "print('a'*64)")
dd if=/dev/urandom of="$FILES/lie.bin" bs=1024 count=64 2>/dev/null
P4=$(curl -s -X POST "$API/v1/uploads/probe" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"spaceID\":\"$SPACE\",\"sha256\":\"$LIE\",\"byteSize\":65536,\"filename\":\"lie.bin\"}")
U4=$(echo "$P4" | jq_get '["uploadID"]')
curl -s -X PUT "$API/v1/uploads/$U4/chunk/0" -H "$AUTH" --data-binary "@$FILES/lie.bin" >/dev/null
C4=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/v1/uploads/$U4/commit" -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d "{\"spaceID\":\"$SPACE\",\"mediaType\":\"photo\",\"mime\":\"image/heic\",\"isRaw\":false,\"burstPick\":false}")
check "HTTP 422 on hash mismatch" "422" "$C4"
check "no asset created"          "1"   "$($PSQL 'select count(*) from assets;')"
check "staging discarded"         "0"   "$(ls "$BLOBS/incoming" 2>/dev/null | wc -l | tr -d ' ')"

echo
echo "=== 13. another user cannot touch this session ==="
CODE2=$(invite)
T2=$(curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$CODE2\",\"displayName\":\"Morgan\",\"deviceName\":\"iPad\",\"platform\":\"ipados\"}" | jq_get '["token"]')
C5=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$API/v1/uploads/$UPLOAD/chunk/0" \
  -H "Authorization: Bearer $T2" --data-binary "@$FILES/chunks/0")
check "HTTP 404 on foreign session" "404" "$C5"
C6=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/v1/spaces/$SPACE/assets/$ASSET" \
  -H "Authorization: Bearer $T2" -H 'Content-Type: application/json' -d '{}')
check "HTTP 404 linking into a space you're not in" "404" "$C6"
C7=$(curl -s -o /dev/null -w "%{http_code}" "$API/v1/assets/$ASSET/playback" \
  -H "Authorization: Bearer $T2")
check "HTTP 404 asking to play a video you can't see" "404" "$C7"

echo
echo "════════════════════════════════════"
echo "  passed: $PASS   failed: $FAIL"
echo "════════════════════════════════════"
[ "$FAIL" -eq 0 ]
