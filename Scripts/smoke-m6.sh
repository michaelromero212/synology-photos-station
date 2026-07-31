#!/bin/bash
# M6 smoke test: activity batching, message wording, and push fan-out.
#
# Runs against a server started with a short idle window
# (FRAMESTATION_ACTIVITY_IDLE_SECONDS) so a burst closes in seconds rather than
# five minutes. APNs itself is unconfigured, so the client logs what it would
# have sent — which is exactly what proves the wording and the recipient list.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
API="${FRAMESTATION_API:-http://127.0.0.1:8099}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
LOG="${FRAMESTATION_SERVER_LOG:-$SCRATCH/srv.log}"
IDLE="${FRAMESTATION_ACTIVITY_IDLE_SECONDS:-2}"
export PATH="/opt/homebrew/bin:$PATH"
export FRAMESTATION_DATABASE_URL="${FRAMESTATION_DATABASE_URL:-postgres://framestation:x@127.0.0.1:55432/framestation?sslmode=disable}"
export FRAMESTATION_BLOB_ROOT="${FRAMESTATION_BLOB_ROOT:-$SCRATCH/blobroot}"
mkdir -p "$SCRATCH/m6"; PASS=0; FAIL=0
q(){ psql -h 127.0.0.1 -p 55432 -U framestation -d framestation -tAqc "$1"; }
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; echo "      expected: $2"; echo "      actual:   $3"; FAIL=$((FAIL+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
has(){ case "$3" in *"$2"*) ok "$1";; *) bad "$1" "contains '$2'" "$3";; esac }
jq(){ python3 -c "import sys,json; print(json.load(sys.stdin)$1)" 2>/dev/null; }
code(){ curl -s -o /dev/null -w '%{http_code}' "$@"; }
# wc -l pads with spaces on macOS; tail -n + refuses a padded offset.
mark(){ wc -l < "$LOG" 2>/dev/null | tr -d " " || echo 0; }

newuser(){
  local c
  c=$(cd "$SERVER_DIR" && swift run FrameStationServer invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
  curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
    -d "{\"code\":\"$c\",\"displayName\":\"$1\",\"deviceName\":\"$1-phone\",\"platform\":\"ios\"}" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["token"],d["personalSpace"]["id"],d["user"]["id"])'
}
read -r T1 P1 U1 <<< "$(newuser Michael)"
read -r T2 P2 U2 <<< "$(newuser Morgan)"
read -r T3 P3 U3 <<< "$(newuser Casey)"
A1="Authorization: Bearer $T1"; A2="Authorization: Bearer $T2"; A3="Authorization: Bearer $T3"

FAM=$(curl -s -X POST "$API/v1/spaces" -H "$A1" -H 'Content-Type: application/json' \
  -d "{\"name\":\"Family Shared\",\"memberIDs\":[\"$U2\"]}" | jq '["id"]')

# label spaceID auth mediaType -> uploads one file
put(){
  local label="$1" space="$2" auth="$3" kind="$4"
  local f="$SCRATCH/m6/$label"
  if [ "$kind" = video ]; then
    f="$f.mp4"
    ffmpeg -y -f lavfi -i "testsrc=size=320x240:rate=15:duration=1" -c:v libx264 \
      -pix_fmt yuv420p -metadata comment="$label" "$f" >/dev/null 2>&1
  else
    f="$f.jpg"
    vips gaussnoise "$SCRATCH/m6/$label.v" 320 240 >/dev/null 2>&1
    vips copy "$SCRATCH/m6/$label.v" "$f" >/dev/null 2>&1
  fi
  local sha size up
  sha=$(shasum -a 256 "$f" | awk '{print $1}'); size=$(stat -f%z "$f")
  up=$(curl -s -X POST "$API/v1/uploads/probe" -H "$auth" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$space\",\"sha256\":\"$sha\",\"byteSize\":$size,\"filename\":\"$(basename "$f")\"}" | jq '["uploadID"]')
  curl -s -X PUT "$API/v1/uploads/$up/chunk/0" -H "$auth" --data-binary "@$f" >/dev/null
  curl -s -X POST "$API/v1/uploads/$up/commit" -H "$auth" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$space\",\"mediaType\":\"$kind\",\"mime\":\"$([ "$kind" = video ] && echo video/mp4 || echo image/jpeg)\",\"width\":320,\"height\":240,\"isRaw\":false,\"burstPick\":false}" >/dev/null
}

echo "=== 1. token registration ==="
check "register returns 204" "204" \
  "$(code -X PUT "$API/v1/devices/push-token" -H "$A2" -H 'Content-Type: application/json' \
      -d '{"apnsToken":"morgan-token-aaaa","environment":"sandbox"}')"
check "stored on the device row" "morgan-token-aaaa" \
  "$(q "select apns_token from devices where user_id='$U2';")"
check "environment stored" "sandbox" "$(q "select apns_env from devices where user_id='$U2';")"
check "empty token rejected" "400" \
  "$(code -X PUT "$API/v1/devices/push-token" -H "$A2" -H 'Content-Type: application/json' \
      -d '{"apnsToken":"  ","environment":"sandbox"}')"
check "unauthenticated rejected" "401" \
  "$(code -X PUT "$API/v1/devices/push-token" -H 'Content-Type: application/json' \
      -d '{"apnsToken":"x","environment":"sandbox"}')"

# The same token moving to another install must not leave two rows claiming it,
# or that phone gets every notification twice.
curl -s -X PUT "$API/v1/devices/push-token" -H "$A3" -H 'Content-Type: application/json' \
  -d '{"apnsToken":"morgan-token-aaaa","environment":"sandbox"}' >/dev/null
check "token moves, not duplicates" "1" \
  "$(q "select count(*) from devices where apns_token='morgan-token-aaaa';")"
check "now owned by the new device" "$(echo "$U3" | tr "A-Z" "a-z")" \
  "$(q "select user_id from devices where apns_token='morgan-token-aaaa';")"
# Put things back: Morgan holds a token, Casey does not.
curl -s -X DELETE "$API/v1/devices/push-token" -H "$A3" >/dev/null
curl -s -X PUT "$API/v1/devices/push-token" -H "$A2" -H 'Content-Type: application/json' \
  -d '{"apnsToken":"morgan-token-bbbb","environment":"sandbox"}' >/dev/null
check "unregister clears it" "0" "$(q "select count(*) from devices where user_id='$U3' and apns_token is not null;")"

echo
echo "=== 2. a burst batches into one session ==="
MARK=$(mark)
put a "$FAM" "$A1" photo
put b "$FAM" "$A1" photo
put c "$FAM" "$A1" photo
put d "$FAM" "$A1" video
put e "$FAM" "$A1" video
check "one open session, not five" "1" \
  "$(q "select count(*) from activity_sessions where space_id='$FAM' and closed_at is null;")"
check "counts accumulated" "3|2" \
  "$(q "select photo_count||'|'||video_count from activity_sessions where space_id='$FAM' and closed_at is null;")"

echo
echo "=== 3. the sweeper closes and notifies ==="
for i in $(seq 40); do
  [ "$(q "select count(*) from activity_sessions where space_id='$FAM' and notified_at is not null;")" = "1" ] && break
  sleep 1
done
check "session closed"   "1" "$(q "select count(*) from activity_sessions where space_id='$FAM' and closed_at is not null;")"
check "session notified" "1" "$(q "select count(*) from activity_sessions where space_id='$FAM' and notified_at is not null;")"
check "no delivery error" "" "$(q "select coalesce(notify_error,'') from activity_sessions where space_id='$FAM';")"

TAIL=$(tail -n +"$MARK" "$LOG" 2>/dev/null)
has "message names the uploader and counts" "Michael added 3 photos and 2 videos" "$TAIL"
has "title is the space" "Family Shared" "$TAIL"
has "sent to the member's token" "morgan-t" "$TAIL"

echo
echo "=== 4. who does *not* get told ==="
# Michael uploaded, so Michael must not be notified; Casey isn't a member.
check "uploader has no token registered anyway" "0" \
  "$(q "select count(*) from devices where user_id='$U1' and apns_token is not null;")"
check "exactly one push logged for the burst" "1" \
  "$(echo "$TAIL" | grep -c 'would have sent')"

MARK2=$(mark)
put p "$P1" "$A1" photo
for i in $(seq 25); do
  [ "$(q "select count(*) from activity_sessions where space_id='$P1' and notified_at is not null;")" = "1" ] && break
  sleep 1
done
check "personal-space session still closes" "1" \
  "$(q "select count(*) from activity_sessions where space_id='$P1' and closed_at is not null;")"
check "but sends nothing" "0" \
  "$(tail -n +"$MARK2" "$LOG" 2>/dev/null | grep -c 'would have sent')"

echo
echo "=== 5. wording ==="
# Composition is a pure function; exercise the shapes the family will actually
# see rather than only the one this run happened to produce.
MARK3=$(mark)
put solo "$FAM" "$A1" photo
for i in $(seq 30); do
  [ "$(q "select count(*) from activity_sessions where space_id='$FAM' and notified_at is not null;")" = "2" ] && break
  sleep 1
done
has "singular reads correctly" "Michael added 1 photo" "$(tail -n +"$MARK3" "$LOG" 2>/dev/null)"

MARK4=$(mark)
put v1 "$FAM" "$A1" video
for i in $(seq 30); do
  [ "$(q "select count(*) from activity_sessions where space_id='$FAM' and notified_at is not null;")" = "3" ] && break
  sleep 1
done
V=$(tail -n +"$MARK4" "$LOG" 2>/dev/null)
has "videos-only omits photos" "Michael added 1 video" "$V"
case "$V" in *"0 photos"*) bad "no zero counts in the text" "no '0 photos'" "$V";; *) ok "no zero counts in the text";; esac

echo
echo "=== 6. bulk collapses an initial backup ==="
curl -s -X PUT "$API/v1/devices/push-token" -H "$A1" -H 'Content-Type: application/json' \
  -d '{"apnsToken":"michael-token-cccc","environment":"production"}' >/dev/null
q "insert into activity_sessions (space_id, user_id, photo_count, video_count, is_bulk, last_at)
   values ('$FAM','$U2',8240,0,true, now() - interval '1 hour');" >/dev/null
MARK5=$(mark)
for i in $(seq 30); do
  [ "$(q "select count(*) from activity_sessions where space_id='$FAM' and notified_at is not null;")" = "4" ] && break
  sleep 1
done
B=$(tail -n +"$MARK5" "$LOG" 2>/dev/null)
has "bulk says items, not a photo tally" "backed up 8,240 items" "$B"
has "names the bulk uploader" "Morgan backed up" "$B"
# Morgan uploaded this one, so it goes to Michael and not back to Morgan.
check "one recipient" "1" "$(echo "$B" | grep -c 'would have sent')"
has "delivered to the other member" "michael-" "$B"
case "$B" in *"morgan-t"*) bad "uploader not notified" "no 'morgan-t'" "$B";; *) ok "uploader not notified";; esac

echo
echo "=== 7. in-app activity feed ==="
# Morgan is a member of Family Shared; Michael did most of the uploading.
F=$(curl -s "$API/v1/activity" -H "$A2")
check "feed lists Michael's bursts" "3" "$(echo "$F" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["items"]))')"
check "all unread at first" "3" "$(echo "$F" | jq '["unreadCount"]')"
has "same wording as the push" "Michael added 3 photos and 2 videos" \
  "$(echo "$F" | python3 -c 'import sys,json;print(" | ".join(i["summary"] for i in json.load(sys.stdin)["items"]))')"
check "newest first" "Michael added 1 video" \
  "$(echo "$F" | python3 -c 'import sys,json;print(json.load(sys.stdin)["items"][0]["summary"])')"
check "names the space" "Family Shared" "$(echo "$F" | jq '["items"][0]["spaceName"]')"

# Morgan's own bulk session must not appear in Morgan's own inbox.
case "$(echo "$F" | python3 -c 'import sys,json;print(" ".join(i["user"]["displayName"] for i in json.load(sys.stdin)["items"]))')" in
  *Morgan*) bad "own uploads excluded" "no 'Morgan'" "present";;
  *) ok "own uploads excluded";;
esac

# Michael sees Morgan's bulk burst, and not his own.
FM=$(curl -s "$API/v1/activity" -H "$A1")
check "Michael sees only Morgan's" "1" "$(echo "$FM" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["items"]))')"
has "bulk wording carries through" "backed up 8,240 items" "$(echo "$FM" | jq '["items"][0]["summary"]')"

# Casey is in no shared space.
check "non-member sees nothing" "0" \
  "$(curl -s "$API/v1/activity" -H "$A3" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["items"]))')"

echo
echo "=== 8. clear all ==="
check "mark-read returns 204" "204" "$(code -X POST "$API/v1/activity/read" -H "$A2")"
F2=$(curl -s "$API/v1/activity" -H "$A2")
check "badge clears" "0" "$(echo "$F2" | jq '["unreadCount"]')"
check "items stay, only the dots go" "3" \
  "$(echo "$F2" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["items"]))')"
check "other users unaffected" "1" "$(curl -s "$API/v1/activity" -H "$A1" | jq '["unreadCount"]')"
check "unauthenticated feed rejected" "401" "$(code "$API/v1/activity")"

# Anything arriving after the watermark is unread again.
q "insert into activity_sessions (space_id, user_id, photo_count, video_count, closed_at, notified_at)
   values ('$FAM','$U1',2,0, now(), now());" >/dev/null
check "new activity is unread again" "1" "$(curl -s "$API/v1/activity" -H "$A2" | jq '["unreadCount"]')"

echo
echo "════════════════════════════════════"
echo "  passed: $PASS   failed: $FAIL"
echo "════════════════════════════════════"
[ "$FAIL" -eq 0 ]
