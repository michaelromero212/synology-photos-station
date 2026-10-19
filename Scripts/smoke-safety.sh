#!/bin/bash
# Reporting a photo, blocking a member, deleting an account, and invite codes
# that join a library or admit more than one person: what App Review asks of an
# app where people make accounts and share with each other.
#
#   FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-safety.sh
#
# Runs its own server against its own database and blob store.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"

DB=framestation_safety; PORT=8087; API="http://127.0.0.1:$PORT"
export FRAMESTATION_DATABASE_URL="postgres://framestation:x@127.0.0.1:55432/$DB?sslmode=disable"
ROOT="$SCRATCH/safety"; rm -rf "$ROOT"; mkdir -p "$ROOT/blobroot" "$ROOT/files"
ROOT=$(cd "$ROOT" && pwd -P)
export FRAMESTATION_BLOB_ROOT="$ROOT/blobroot"
# So an upload's notification is sent, and its inbox entry made, in seconds.
export FRAMESTATION_ACTIVITY_IDLE_SECONDS=1 FRAMESTATION_ACTIVITY_SWEEP_SECONDS=1

PASS=0; FAIL=0
q(){ psql -h 127.0.0.1 -p 55432 -U framestation -d $DB -tAqc "$1"; }
admin(){ psql -h 127.0.0.1 -p 55432 -U framestation -d postgres -tAqc "$1"; }
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; echo "      expected: $2"; echo "      actual:   $3"; FAIL=$((FAIL+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
jq(){ python3 -c "import sys,json; print(json.load(sys.stdin)$1)" 2>/dev/null; }
py(){ python3 -c "import sys,json; d=json.load(sys.stdin); print($1)" 2>/dev/null; }

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

# invite [options] → a code, or nothing when the command refused
invite(){ (cd "$SERVER_DIR" && "$BIN" invite "$@" 2>/dev/null) | grep 'Invite code:' | awk '{print $3}'; }
redeem_with(){ curl -s -o "$ROOT/reply" -w '%{http_code}' -X POST "$API/v1/auth/redeem" \
  -H 'Content-Type: application/json' \
  -d "{\"code\":\"$1\",\"displayName\":\"$2\",\"deviceName\":\"iPhone\",\"platform\":\"ios\"}"; }
redeem(){ redeem_with "$(invite)" "$1" >/dev/null; cat "$ROOT/reply"; }
# call <token> <curl args…> → HTTP status, the body kept in $ROOT/reply
call(){ local token=$1; shift
  curl -s -o "$ROOT/reply" -w '%{http_code}' -H "Authorization: Bearer $token" "$@"; }
reply(){ cat "$ROOT/reply"; }
total(){ curl -s "$API/v1/spaces/$2/timeline?zoom=day" -H "Authorization: Bearer $1" | jq '["total"]'; }
# How many of the day's photos the day itself lists, which is what the grid draws.
day(){ curl -s "$API/v1/spaces/$2/timeline/2025-06-01?zoom=day" -H "Authorization: Bearer $1" \
  | py 'len(d["items"])'; }
pid(){ q "SELECT id FROM space_assets WHERE space_id = '$1' AND asset_id = '$2'"; }
report(){ call "$1" -X POST "$API/v1/spaces/$2/reports" -H 'Content-Type: application/json' \
  -d "{\"placementID\":\"$3\",\"reason\":\"${4:-inappropriate}\"}"; }
resolve(){ call "$1" -X POST "$API/v1/spaces/$2/reports/$3/resolve" \
  -H 'Content-Type: application/json' -d "{\"outcome\":\"$4\"}"; }

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

serve
# An owner, two members, and someone who shares no library with any of them.
R=$(redeem Owner); OT=$(echo "$R" | jq '["token"]'); OWNER=$(echo "$R" | jq '["user"]["id"]')
R=$(redeem Alice); AT=$(echo "$R" | jq '["token"]'); ALICE=$(echo "$R" | jq '["user"]["id"]')
AP=$(echo "$R" | jq '["personalSpace"]["id"]')
R=$(redeem Bob); BT=$(echo "$R" | jq '["token"]'); BOB=$(echo "$R" | jq '["user"]["id"]')
BP=$(echo "$R" | jq '["personalSpace"]["id"]')
R=$(redeem Carol); CT=$(echo "$R" | jq '["token"]'); CAROL=$(echo "$R" | jq '["user"]["id"]')
newspace(){ curl -s -X POST "$API/v1/spaces" -H "Authorization: Bearer $OT" -H 'Content-Type: application/json' \
  -d "{\"name\":\"$1\",\"memberIDs\":[$2]}" | jq '["id"]'; }
SHARED=$(newspace "Family Shared" "\"$ALICE\",\"$BOB\"")
SOLO=$(newspace "Just Mine" "")
[ -n "$SHARED" ] && [ -n "$SOLO" ] && [ -n "$CT" ] || { echo "setup failed"; exit 1; }

B1=$(upload "$BT" "$SHARED" b1.jpg 401); B2=$(upload "$BT" "$SHARED" b2.jpg 402)
B3=$(upload "$BT" "$SHARED" b3.jpg 403); A1=$(upload "$AT" "$SHARED" a1.jpg 411)
AP1=$(upload "$AT" "$AP" ap1.jpg 421); BP1=$(upload "$BT" "$BP" bp1.jpg 431)
S1=$(upload "$OT" "$SOLO" s1.jpg 441)
[ -n "$B1" ] && [ -n "$S1" ] || { echo "uploads failed"; tail -20 "$ROOT/server.log"; exit 1; }

echo "The server says what it can do"
HEALTH=$(curl -s "$API/health")
check "deleting an account" "True" "$(echo "$HEALTH" | py '"account-deletion" in d["capabilities"]')"
check "reporting and blocking" "True" "$(echo "$HEALTH" | py '"report-and-block" in d["capabilities"]')"

echo "Reporting a photo"
check "everyone starts with Bob's three and Alice's one" "4" "$(total "$AT" "$SHARED")"
check "Alice reports one of Bob's" "204" "$(report "$AT" "$SHARED" "$(pid "$SHARED" "$B1")")"
check "it's gone from her grid's count" "3" "$(total "$AT" "$SHARED")"
check "and from the day it was on" "3" "$(day "$AT" "$SHARED")"
check "but not from the owner's" "4" "$(total "$OT" "$SHARED")"
check "nor from Bob's" "4" "$(total "$BT" "$SHARED")"
check "she can't report one she added" "400" "$(report "$AT" "$SHARED" "$(pid "$SHARED" "$A1")")"
check "or one in her own library" "400" "$(report "$AT" "$AP" "$(pid "$AP" "$AP1")")"
check "and Carol can't report in a library she isn't in" "404" \
  "$(report "$CT" "$SHARED" "$(pid "$SHARED" "$B2")")"
check "the owner can report it too" "204" "$(report "$OT" "$SHARED" "$(pid "$SHARED" "$B1")" spam)"

echo "The owner reviews it"
check "a member can't read the reports" "403" "$(call "$AT" "$API/v1/spaces/$SHARED/reports")"
check "the owner can" "200" "$(call "$OT" "$API/v1/spaces/$SHARED/reports")"
check "one photo waiting, however many reported it" "1" "$(reply | py 'len(d["reports"])')"
check "reported twice" "2" "$(reply | py 'd["reports"][0]["reportCount"]')"
check "for both reasons, newest first" "spam,inappropriate" "$(reply | py '",".join(d["reports"][0]["reasons"])')"
check "added by Bob" "Bob" "$(reply | py 'd["reports"][0]["addedByName"]')"
check "and nobody says who reported it" "False" "$(reply | python3 -c 'import sys; print("Alice" in sys.stdin.read())')"
check "the owner keeps it" "204" "$(resolve "$OT" "$SHARED" "$(pid "$SHARED" "$B1")" kept)"
check "nothing left to review" "0" "$(call "$OT" "$API/v1/spaces/$SHARED/reports" >/dev/null; reply | py 'len(d["reports"])')"
check "and it stays hidden from Alice" "3" "$(total "$AT" "$SHARED")"
check "closing it again finds nothing" "404" "$(resolve "$OT" "$SHARED" "$(pid "$SHARED" "$B1")" kept)"
check "a member can't close one" "403" "$(report "$AT" "$SHARED" "$(pid "$SHARED" "$B2")" >/dev/null; resolve "$AT" "$SHARED" "$(pid "$SHARED" "$B2")" kept)"
check "the owner removes the next one" "204" "$(call "$OT" -X DELETE "$API/v1/spaces/$SHARED/assets/$B2")"
check "and closes it as removed" "204" "$(resolve "$OT" "$SHARED" "$(pid "$SHARED" "$B2")" removed)"
check "gone for everyone, Bob included" "3" "$(total "$BT" "$SHARED")"
deleted(){ curl -s "$API/v1/spaces/$2/collections/deleted" -H "Authorization: Bearer $1" | jq '["total"]'; }
check "it waits in the library's Recently Deleted for the owner" "1" "$(deleted "$OT" "$SHARED")"
check "but not for Alice, who reported it" "0" "$(deleted "$AT" "$SHARED")"

echo "Blocking"
check "Alice blocks Bob" "204" "$(call "$AT" -X PUT "$API/v1/blocks/$BOB")"
check "none of his photos are in her grid" "1" "$(total "$AT" "$SHARED")"
check "nor the day" "1" "$(day "$AT" "$SHARED")"
check "Bob's grid is just as it was" "3" "$(total "$BT" "$SHARED")"
check "her own library is untouched" "1" "$(total "$AT" "$AP")"
check "he's on her list" "Bob" "$(call "$AT" "$API/v1/blocks" >/dev/null; reply | py '",".join(u["displayName"] for u in d["users"])')"
check "she can't block herself" "400" "$(call "$AT" -X PUT "$API/v1/blocks/$ALICE")"
check "or someone she shares nothing with" "404" "$(call "$AT" -X PUT "$API/v1/blocks/$CAROL")"
# The uploads above are a burst each; give the sweeper a moment to close them.
for _ in $(seq 1 20); do
  [ "$(q "SELECT count(*) FROM activity_sessions WHERE closed_at IS NULL")" = "0" ] && break
  sleep 0.5
done
check "her inbox leaves him out" "0" \
  "$(call "$AT" "$API/v1/activity" >/dev/null; reply | py 'sum(1 for i in d["items"] if i["user"]["displayName"] == "Bob")')"
check "the owner's still has him" "1" \
  "$(call "$OT" "$API/v1/activity" >/dev/null; reply | py 'sum(1 for i in d["items"] if i["user"]["displayName"] == "Bob")')"
check "his library card's count leaves him out too" "1" \
  "$(call "$AT" "$API/v1/albums?shared=true" >/dev/null; reply | py '[l["itemCount"] for l in d["libraries"] if l["name"] == "Family Shared"][0]')"
check "unblocking him" "204" "$(call "$AT" -X DELETE "$API/v1/blocks/$BOB")"
check "brings back all but the one she reported" "2" "$(total "$AT" "$SHARED")"

echo "Invite codes"
CODE=$(invite --space "$SHARED")
check "a code made for a library" "200" "$(redeem_with "$CODE" Dana)"
DANA=$(reply | jq '["user"]["id"]')
check "puts its person in it" "contributor" "$(q "SELECT role FROM space_members WHERE space_id = '$SHARED' AND user_id = '$DANA'")"
check "and works once" "401" "$(redeem_with "$CODE" Dana2)"
MULTI=$(invite --uses 2)
check "a code for two lets in the first" "200" "$(redeem_with "$MULTI" Reviewer1)"
check "and the second" "200" "$(redeem_with "$MULTI" Reviewer2)"
check "but not a third" "401" "$(redeem_with "$MULTI" Reviewer3)"
check "and no one can make a code for more than fifty" "" "$(invite --uses 51)"

echo "Deleting an account"
check "Bob deletes his" "204" "$(call "$BT" -X DELETE "$API/v1/me")"
check "and is signed out" "401" "$(call "$BT" "$API/v1/me")"
check "his own library goes to Recently Deleted" "t" \
  "$(q "SELECT bool_and(deleted_at IS NOT NULL) FROM space_assets WHERE space_id = '$BP'")"
check "what he shared stays" "2" "$(total "$OT" "$SHARED")"
check "added by a former member" "Former member" "$(q "SELECT display_name FROM users WHERE id = '$BOB'")"
check "he's out of every library" "0" "$(q "SELECT count(*) FROM space_members WHERE user_id = '$BOB'")"
check "and off the household list" "False" \
  "$(call "$OT" "$API/v1/household" >/dev/null; reply | python3 -c "import sys; print('$BOB' in sys.stdin.read())")"
check "and can't be added back" "404" "$(call "$OT" -X PUT "$API/v1/spaces/$SHARED/members/$BOB" \
  -H 'Content-Type: application/json' -d '{}')"
check "his sign-ins are gone" "0" "$(q "SELECT count(*) FROM devices WHERE user_id = '$BOB'")"

echo "Deleting an owner's account"
newalbum(){ curl -s -X POST "$API/v1/albums" -H "Authorization: Bearer $OT" -H 'Content-Type: application/json' \
  -d "{\"name\":\"$1\",\"spaceAssetIDs\":[]$2}" | jq '["id"]'; }
MINE=$(newalbum "Mine" ""); OURS=$(newalbum "Ours" ",\"spaceID\":\"$SHARED\"")
[ -n "$MINE" ] && [ -n "$OURS" ] || bad "albums made" "two ids" "'$MINE' '$OURS'"
check "the owner deletes theirs" "204" "$(call "$OT" -X DELETE "$API/v1/me")"
check "Family Shared passes to Alice, there longest" "owner" \
  "$(q "SELECT role FROM space_members WHERE space_id = '$SHARED' AND user_id = '$ALICE'")"
check "their own album goes" "0" "$(q "SELECT count(*) FROM albums WHERE id = '$MINE'")"
check "the library's album stays with the library" "1" "$(q "SELECT count(*) FROM albums WHERE id = '$OURS'")"
check "a library no one else was in goes with them" "t" \
  "$(q "SELECT bool_and(deleted_at IS NOT NULL) FROM space_assets WHERE space_id = '$SOLO'")"
check "and their reports" "0" "$(q "SELECT count(*) FROM content_reports WHERE reporter_id = '$OWNER'")"
check "Alice can review reports now" "200" "$(call "$AT" "$API/v1/spaces/$SHARED/reports")"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
