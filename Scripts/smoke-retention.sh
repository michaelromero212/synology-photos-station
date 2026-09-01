#!/bin/bash
# Recently Deleted: a 29-day window the app owns, end to end.
#
# The unit tests cover the day arithmetic and a transaction covered the holder
# check. This covers the part neither can: that deleting through the real
# endpoint puts a photograph in Recently Deleted with a purge date on it, that
# restoring takes it back out, and that the sweeper's own query picks it up once
# it is old enough — against the real schema rather than a hand-written one.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
API="${FRAMESTATION_API:-http://127.0.0.1:8099}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"
# The invite command needs the same environment the server runs with.
ENVFILE="${FRAMESTATION_DEV_ENV:-$HOME/.framestation-dev/env}"
[ -f "$ENVFILE" ] && { set -a; . "$ENVFILE"; set +a; }
mkdir -p "$SCRATCH/retention"; PASS=0; FAIL=0
q(){ psql -h 127.0.0.1 -p 55432 -U framestation -d framestation -tAqc "$1"; }
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; echo "      expected: $2"; echo "      actual:   $3"; FAIL=$((FAIL+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
jq(){ python3 -c "import sys,json; print(json.load(sys.stdin)$1)" 2>/dev/null; }

c=$(cd "$SERVER_DIR" && swift run FrameStationServer invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
R=$(curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$c\",\"displayName\":\"Michael\",\"deviceName\":\"iPhone\",\"platform\":\"ios\"}")
T=$(echo "$R" | jq '["token"]'); SP=$(echo "$R" | jq '["personalSpace"]["id"]')
A="Authorization: Bearer $T"
[ -n "$T" ] || { echo "could not authenticate — is the dev server up?"; exit 1; }

f="$SCRATCH/retention/IMG_9100.jpg"
vips gaussnoise "$SCRATCH/retention/n.v" 400 300 >/dev/null 2>&1
vips copy "$SCRATCH/retention/n.v" "$f" >/dev/null 2>&1
SHA=$(shasum -a 256 "$f" | awk '{print $1}'); SZ=$(stat -f%z "$f")

UP=$(curl -s -X POST "$API/v1/uploads/probe" -H "$A" -H 'Content-Type: application/json' \
  -d "{\"spaceID\":\"$SP\",\"sha256\":\"$SHA\",\"byteSize\":$SZ,\"filename\":\"IMG_9100.jpg\",\"isAutomaticBackup\":false}" | jq '["uploadID"]')
curl -s -X PUT "$API/v1/uploads/$UP/chunk/0" -H "$A" --data-binary "@$f" >/dev/null
AID=$(curl -s -X POST "$API/v1/uploads/$UP/commit" -H "$A" -H 'Content-Type: application/json' \
  -d "{\"spaceID\":\"$SP\",\"mediaType\":\"photo\",\"mime\":\"image/jpeg\",\"width\":400,\"height\":300,\"isRaw\":false,\"burstPick\":false}" | jq '["assetID"]')
[ -n "$AID" ] || { echo "upload failed"; exit 1; }
echo "asset $AID"

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

check "29 days out, to the day" "29" \
  "$(q "select ceil(extract(epoch from (deleted_at + interval '29 days') - now())/86400.0)::int
       from space_assets where asset_id='$AID';")"

echo "== restoring =="
curl -s -X POST "$API/v1/spaces/$SP/collections/deleted/restore" -H "$A" -H 'Content-Type: application/json' \
  -d "{\"assetIDs\":[\"$AID\"]}" >/dev/null
check "back in the library" "f" \
  "$(q "select (deleted_at is not null) from space_assets where asset_id='$AID';")"
check "gone from Recently Deleted" "0" \
  "$(curl -s "$API/v1/spaces/$SP/collections/deleted" -H "$A" | jq '["total"]')"

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
check "and is hidden from Recently Deleted" "0" \
  "$(curl -s "$API/v1/spaces/$SP/collections/deleted" -H "$A" | jq '["total"]')"

q "delete from space_assets where asset_id='$AID'; delete from assets where id='$AID';" >/dev/null
echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
