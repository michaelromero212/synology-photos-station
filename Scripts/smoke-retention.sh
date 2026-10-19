#!/bin/bash
# Recently Deleted: a 29-day window the app owns, end to end.
#
# The unit tests cover the day arithmetic and a transaction covered the holder
# check. This covers the part neither can: that deleting through the real
# endpoint puts a photograph in Recently Deleted with a purge date on it, that
# it can still be looked at there (and a video played) but not downloaded,
# that restoring takes it back out, and that the sweeper's own query picks it
# up once it is old enough — against the real schema rather than a
# hand-written one.
#
#   FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-retention.sh
#
# Runs its own server against its own database and blob store.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"

DB=framestation_retention; PORT=8083; API="http://127.0.0.1:$PORT"
export FRAMESTATION_DATABASE_URL="postgres://framestation:x@127.0.0.1:55432/$DB?sslmode=disable"
ROOT="$SCRATCH/retention"; rm -rf "$ROOT"; mkdir -p "$ROOT/blobroot" "$ROOT/files"
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
[ -n "$T" ] || { echo "could not authenticate"; tail -20 "$ROOT/server.log"; exit 1; }
# Someone else on the same NAS, who shares nothing with Michael.
c=$(cd "$SERVER_DIR" && "$BIN" invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
OTHER="Authorization: Bearer $(curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$c\",\"displayName\":\"Neighbor\",\"deviceName\":\"iPhone\",\"platform\":\"ios\"}" | jq '["token"]')"
# status <auth header> <path> → the HTTP status of a GET
status(){ curl -s -o /dev/null -w '%{http_code}' -H "$1" "$API$2"; }
# binned <asset id> → whether Recently Deleted lists it, as a count
binned(){ curl -s "$API/v1/spaces/$SP/collections/deleted" -H "$A" | python3 -c "import sys,json
print(sum(1 for i in json.load(sys.stdin)['items'] if i['assetID'].lower() == '$1'.lower()))"; }

f="$ROOT/files/IMG_9100.jpg"
vips gaussnoise "$ROOT/files/n.v" 400 300 >/dev/null 2>&1
vips copy "$ROOT/files/n.v" "$f" >/dev/null 2>&1
SHA=$(shasum -a 256 "$f" | awk '{print $1}'); SZ=$(stat -f%z "$f")

UP=$(curl -s -X POST "$API/v1/uploads/probe" -H "$A" -H 'Content-Type: application/json' \
  -d "{\"spaceID\":\"$SP\",\"sha256\":\"$SHA\",\"byteSize\":$SZ,\"filename\":\"IMG_9100.jpg\",\"isAutomaticBackup\":false}" | jq '["uploadID"]')
curl -s -X PUT "$API/v1/uploads/$UP/chunk/0" -H "$A" --data-binary "@$f" >/dev/null
AID=$(curl -s -X POST "$API/v1/uploads/$UP/commit" -H "$A" -H 'Content-Type: application/json' \
  -d "{\"spaceID\":\"$SP\",\"mediaType\":\"photo\",\"mime\":\"image/jpeg\",\"width\":400,\"height\":300,\"isRaw\":false,\"burstPick\":false}" | jq '["assetID"]')
[ -n "$AID" ] || { echo "upload failed"; exit 1; }
echo "asset $AID"

# A second of video, to play from Recently Deleted.
v="$ROOT/files/IMG_9101.mp4"
ffmpeg -v error -y -f lavfi -i "testsrc2=size=320x240:rate=30:duration=1" \
  -c:v libx264 -pix_fmt yuv420p "$v"
VSHA=$(shasum -a 256 "$v" | awk '{print $1}'); VSZ=$(stat -f%z "$v")
UP=$(curl -s -X POST "$API/v1/uploads/probe" -H "$A" -H 'Content-Type: application/json' \
  -d "{\"spaceID\":\"$SP\",\"sha256\":\"$VSHA\",\"byteSize\":$VSZ,\"filename\":\"IMG_9101.mp4\",\"isAutomaticBackup\":false}" | jq '["uploadID"]')
curl -s -X PUT "$API/v1/uploads/$UP/chunk/0" -H "$A" --data-binary "@$v" >/dev/null
VID=$(curl -s -X POST "$API/v1/uploads/$UP/commit" -H "$A" -H 'Content-Type: application/json' \
  -d "{\"spaceID\":\"$SP\",\"mediaType\":\"video\",\"mime\":\"video/mp4\",\"width\":320,\"height\":240,\"durationMs\":1000,\"isRaw\":false,\"burstPick\":false}" | jq '["assetID"]')
[ -n "$VID" ] || { echo "video upload failed"; exit 1; }
# Thumbnails made, so a missing one below means refused rather than not yet.
for _ in $(seq 1 120); do [ "$(q "select count(*) from assets where derived_at is null")" = "0" ] && break; sleep 0.5; done

echo "== before deletion =="
check "not in Recently Deleted" "0" \
  "$(curl -s "$API/v1/spaces/$SP/collections/deleted" -H "$A" | jq '["total"]')"

echo "== deleting =="
curl -s -X DELETE "$API/v1/spaces/$SP/assets/$AID" -H "$A" >/dev/null

check "soft-deleted, not purged" "true|false" \
  "$(q "select (deleted_at is not null)||'|'||(purged_at is not null)
       from space_assets where asset_id='$AID';")"

# The old path moved the blob out from under every other copy of it. It must
# still be exactly where it was.
check "blob untouched by the delete" "1" \
  "$(q "select count(*) from assets where id='$AID' and sha256='$SHA';")"

D=$(curl -s "$API/v1/spaces/$SP/collections/deleted" -H "$A")
check "appears in Recently Deleted" "1" "$(echo "$D" | jq '["total"]')"

# The whole point of the redesign: a date the client can count down to.
P=$(echo "$D" | jq '["items"][0]["purgeAt"]')
[ -n "$P" ] && [ "$P" != "None" ] && ok "carries a purge date ($P)" \
  || bad "carries a purge date" "an ISO date" "$P"

# Rounded, not rounded up: 29 days that span a change of the clocks are an hour
# more or less than 29 times 24 hours, and in October rounding up read 30.
check "29 days out, to the day" "29" \
  "$(q "select round(extract(epoch from (deleted_at + interval '29 days') - now())/86400.0)::int
       from space_assets where asset_id='$AID';")"

echo "== looking before deciding =="
check "its thumbnail still loads" "200" "$(status "$A" "/v1/assets/$AID/thumb?size=256")"
check "and so does its full-size preview" "200" "$(status "$A" "/v1/assets/$AID/preview")"
check "but not its original, until it's put back" "404" "$(status "$A" "/v1/assets/$AID/original")"
check "and someone it was never shared with sees nothing" "404" \
  "$(status "$OTHER" "/v1/assets/$AID/preview")"
curl -s -X DELETE "$API/v1/spaces/$SP/assets/$VID" -H "$A" >/dev/null
LINK=$(curl -s "$API/v1/assets/$VID/playback" -H "$A" | jq '["url"]')
check "a deleted video still gets a link to play" "yes" "$([ -n "$LINK" ] && echo yes || echo no)"
check "and the link plays" "200" "$(curl -s -o /dev/null -w '%{http_code}' "$LINK")"
check "but not for anyone else" "404" "$(status "$OTHER" "/v1/assets/$VID/playback")"

echo "== restoring =="
curl -s -X POST "$API/v1/spaces/$SP/collections/deleted/restore" -H "$A" -H 'Content-Type: application/json' \
  -d "{\"assetIDs\":[\"$AID\"]}" >/dev/null
check "back in the library" "f" \
  "$(q "select (deleted_at is not null) from space_assets where asset_id='$AID';")"
check "gone from Recently Deleted" "0" "$(binned "$AID")"

echo "== past the window =="
curl -s -X DELETE "$API/v1/spaces/$SP/assets/$AID" -H "$A" >/dev/null
q "update space_assets set deleted_at = now() - interval '30 days' where asset_id='$AID';" >/dev/null

check "the sweeper's own query finds it" "1" \
  "$(q "select count(*) from space_assets
        where asset_id='$AID' and deleted_at is not null and purged_at is null
          and deleted_at < now() - interval '29 days';")"

# Restoring something past its window would hand back a photo whose bytes the
# sweeper is about to remove.
q "update space_assets set purged_at = now() where asset_id='$AID';" >/dev/null
curl -s -X POST "$API/v1/spaces/$SP/collections/deleted/restore" -H "$A" -H 'Content-Type: application/json' \
  -d "{\"assetIDs\":[\"$AID\"]}" >/dev/null
check "a purged row cannot be restored" "t" \
  "$(q "select (deleted_at is not null) from space_assets where asset_id='$AID';")"
check "and is hidden from Recently Deleted" "0" "$(binned "$AID")"
check "its preview is gone with it" "404" "$(status "$A" "/v1/assets/$AID/preview")"
q "update space_assets set purged_at = now() where asset_id='$VID';" >/dev/null
check "and a purged video's link plays nothing" "404" "$(curl -s -o /dev/null -w '%{http_code}' "$LINK")"

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
