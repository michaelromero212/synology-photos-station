#!/bin/bash
# Curation: what a person's devices saw in their own photographs stays theirs,
# and the Albums page turns it into occasions, holidays that look like
# themselves, and nothing at all when it's switched off.
#
# Runs against the dev stack (Scripts/devstack.sh), like the other smoke tests.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
API="${FRAMESTATION_API:-http://127.0.0.1:8099}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"
# The `invite` command below is a second server process and reads both of these.
export FRAMESTATION_DATABASE_URL="${FRAMESTATION_DATABASE_URL:-postgres://framestation:x@127.0.0.1:55432/framestation?sslmode=disable}"
export FRAMESTATION_BLOB_ROOT="${FRAMESTATION_BLOB_ROOT:-$SCRATCH/blobroot}"
mkdir -p "$SCRATCH/curation" "$FRAMESTATION_BLOB_ROOT"; PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; echo "      expected: $2"; echo "      actual:   $3"; FAIL=$((FAIL+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
has(){ case "$3" in *"$2"*) ok "$1";; *) bad "$1" "contains '$2'" "$3";; esac; }
lacks(){ case "$3" in *"$2"*) bad "$1" "no '$2'" "$3";; *) ok "$1";; esac; }
jq(){ python3 -c "import sys,json; print(json.load(sys.stdin)$1)" 2>/dev/null; }
code(){ curl -s -o /dev/null -w '%{http_code}' "$@"; }
# Every title on the Albums page, See All included, joined with |.
titles(){ curl -s "$API/v1/spaces/$1/collections?date=2026-10-12" -H "$2" | python3 -c "
import sys, json
d = json.load(sys.stdin)
cards = (d.get('allOccasions') or []) + (d.get('allTrips') or []) + d.get('days', [])
print('|'.join(c['title'] for c in cards))"; }

signin(){
  local c R
  c=$(cd "$SERVER_DIR" && swift run FrameStationServer invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
  R=$(curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
    -d "{\"code\":\"$c\",\"displayName\":\"$1\",\"deviceName\":\"iPhone\",\"platform\":\"ios\"}")
  echo "$(echo "$R" | jq '["token"]') $(echo "$R" | jq '["personalSpace"]["id"]')"
}
read -r T SP <<<"$(signin Curator)"; A="Authorization: Bearer $T"
read -r T2 SP2 <<<"$(signin Neighbor)"; A2="Authorization: Bearer $T2"
# Fail loudly here rather than reporting thirty confusing 404s downstream.
[ -n "$SP" ] && [ -n "$SP2" ] || { echo "setup failed: no space. Is the server up at $API?"; exit 1; }

# upload <space> <auth> <name> <width> <capturedAt> → asset id. The width keeps
# every file's bytes different, so nothing is deduplicated into another.
upload(){
  local f="$SCRATCH/curation/$3.jpg" SHA SZ UP
  vips gaussnoise "$SCRATCH/curation/n.v" "$4" 240 >/dev/null 2>&1
  vips copy "$SCRATCH/curation/n.v" "$f" >/dev/null 2>&1
  SHA=$(shasum -a 256 "$f" | awk '{print $1}'); SZ=$(stat -f%z "$f")
  UP=$(curl -s -X POST "$API/v1/uploads/probe" -H "$2" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$1\",\"sha256\":\"$SHA\",\"byteSize\":$SZ,\"filename\":\"$3.jpg\",\"isAutomaticBackup\":false}" | jq '["uploadID"]')
  curl -s -X PUT "$API/v1/uploads/$UP/chunk/0" -H "$2" --data-binary "@$f" >/dev/null
  curl -s -X POST "$API/v1/uploads/$UP/commit" -H "$2" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$1\",\"mediaType\":\"photo\",\"mime\":\"image/jpeg\",\"width\":$4,\"height\":240,\"capturedAt\":\"$5\",\"capturedTZOffset\":0,\"isRaw\":false,\"burstPick\":false}" | jq '["assetID"]'
}
# observe <space> <auth> <asset> <labels json> [version] [people] → accepted
observe(){
  curl -s -X POST "$API/v1/spaces/$1/curation/observations" -H "$2" -H 'Content-Type: application/json' \
    -d "{\"analysisVersion\":${5:-1},\"modelVersion\":\"smoke\",\"observations\":[{\"assetID\":\"$3\",\"labels\":$4,\"aesthetic\":0.4,\"isUtility\":false,\"peopleCount\":${6:-0},\"animalCount\":0}]}" | jq '["accepted"]'
}
CAKE='[{"id":"birthday_cake","confidence":0.92},{"id":"candle","confidence":0.6}]'
SKY='[{"id":"sky","confidence":0.9},{"id":"outdoor","confidence":0.8}]'
TREE='[{"id":"christmas_tree","confidence":0.88},{"id":"gift","confidence":0.5}]'

echo "Settings and status"
S=$(curl -s "$API/v1/curation" -H "$A")
check "on by default" "True" "$(echo "$S" | jq '["settings"]["enabled"]')"
check "holidays on by default" "True" "$(echo "$S" | jq '["settings"]["holidays"]')"
check "nothing analyzed yet" "0" "$(echo "$S" | jq '["analyzed"]')"

echo "A day of birthday photos"
B=(); for i in 1 2 3 4; do B+=("$(upload "$SP" "$A" "bday$i" $((300 + i)) "2023-05-20T1${i}:00:00Z")"); done
# Pending lists only photos the NAS has thumbnailed; give the worker a moment.
for _ in $(seq 1 30); do
  P=$(curl -s "$API/v1/spaces/$SP/curation/pending?limit=50" -H "$A")
  [ "$(echo "$P" | jq '["remaining"]')" = "4" ] && break; sleep 1
done
check "four waiting once thumbnailed" "4" "$(echo "$P" | jq '["remaining"]')"
has "the photo is offered for analysis" "${B[0]}" "$P"

check "an observation is stored" "1" "$(observe "$SP" "$A" "${B[0]}" "$CAKE")"
check "the same version again changes nothing" "0" "$(observe "$SP" "$A" "${B[0]}" "$SKY")"
D=$(curl -s "$API/v1/spaces/$SP/assets/${B[0]}/observation" -H "$A")
has "the first answer stands" "birthday" "$(echo "$D" | jq '["tags"]')"
check "a newer version replaces it" "1" "$(observe "$SP" "$A" "${B[0]}" "$CAKE" 2)"
lacks "an analyzed photo is no longer offered" "${B[0]}" \
  "$(curl -s "$API/v1/spaces/$SP/curation/pending?limit=50&analysisVersion=2" -H "$A")"

echo "Privacy"
check "someone else's photo can't be reported on" "0" "$(observe "$SP2" "$A2" "${B[1]}" "$CAKE")"
check "someone else's library is a 404" "404" \
  "$(code "$API/v1/spaces/$SP/curation/pending" -H "$A2")"
check "nor can they write to it" "404" "$(code -X POST "$API/v1/spaces/$SP/curation/observations" \
  -H "$A2" -H 'Content-Type: application/json' \
  -d '{"analysisVersion":1,"modelVersion":"x","observations":[]}')"
check "nor read what was seen" "404" "$(code "$API/v1/spaces/$SP/assets/${B[0]}/observation" -H "$A2")"
SHARED=$(curl -s -X POST "$API/v1/spaces" -H "$A" -H 'Content-Type: application/json' \
  -d '{"name":"Curation smoke","memberIDs":[]}' | jq '["id"]')
check "a shared library isn't curated" "404" "$(code "$API/v1/spaces/$SHARED/curation/pending" -H "$A")"

echo "The Albums page"
for b in "${B[@]:1}"; do observe "$SP" "$A" "$b" "$CAKE" >/dev/null; done
has "a day of cake and candles is a birthday party" "Birthday party" "$(titles "$SP" "$A")"

C=(); for i in 1 2 3 4; do C+=("$(upload "$SP" "$A" "xmas$i" $((400 + i)) "2022-12-25T1${i}:00:00Z")"); done
has "an unanalyzed Christmas keeps the date-only rule" "Christmas 2022" "$(titles "$SP" "$A")"
for c in "${C[@]}"; do observe "$SP" "$A" "$c" "$SKY" >/dev/null; done
lacks "an analyzed Christmas with no tree isn't one" "Christmas 2022" "$(titles "$SP" "$A")"
for c in "${C[@]}"; do observe "$SP" "$A" "$c" "$TREE" 2 >/dev/null; done
has "a tree makes it Christmas" "Christmas 2022" "$(titles "$SP" "$A")"

echo "Switches"
curl -s -X PUT "$API/v1/curation/settings" -H "$A" -H 'Content-Type: application/json' -d '{"holidays":false}' >/dev/null
lacks "holidays off: no Christmas, tree or not" "Christmas 2022" "$(titles "$SP" "$A")"
check "holidays off leaves curation on" "True" "$(curl -s "$API/v1/curation" -H "$A" | jq '["settings"]["enabled"]')"
curl -s -X PUT "$API/v1/curation/settings" -H "$A" -H 'Content-Type: application/json' -d '{"holidays":true,"enabled":false}' >/dev/null
lacks "curation off: no birthday party" "Birthday party" "$(titles "$SP" "$A")"
has "curation off: holidays by date again" "Christmas 2022" "$(titles "$SP" "$A")"
check "curation off: nothing to analyze" "0" \
  "$(curl -s "$API/v1/spaces/$SP/curation/pending" -H "$A" | jq '["remaining"]')"
check "curation off: nothing stored" "0" "$(observe "$SP" "$A" "${C[0]}" "$CAKE" 3)"
curl -s -X PUT "$API/v1/curation/settings" -H "$A" -H 'Content-Type: application/json' -d '{"enabled":true}' >/dev/null
has "back on: the birthday party is back" "Birthday party" "$(titles "$SP" "$A")"

echo "Deleting the AI data"
check "delete answers 204" "204" "$(code -X DELETE "$API/v1/curation/data" -H "$A")"
check "nothing is left" "404" "$(code "$API/v1/spaces/$SP/assets/${B[0]}/observation" -H "$A")"
check "status counts none" "0" "$(curl -s "$API/v1/curation" -H "$A" | jq '["analyzed"]')"
check "the photos themselves are untouched" "200" "$(code "$API/v1/assets/${B[0]}/thumb?size=256" -H "$A")"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
