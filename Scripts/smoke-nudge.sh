#!/bin/bash
# Smoke test: the silent push that wakes a stalled backup.
#
# What this is really testing is restraint. Sending the push is the easy half;
# the half that matters is not sending it — to a device that is already
# uploading, to one that never answers, to a Mac, to a phone with nothing left
# to do. Apple meters background pushes per device and quietly deprioritizes
# apps that spend them on nothing, so every gate in `BackupNudger` is checked
# here individually.
#
# APNs itself is out of reach: the server this starts has no key, and by design
# `APNsClient` then logs the push it would have sent and reports success. That
# log line is the observable — it proves the query selected the device *and*
# that what it built was a silent push rather than a banner.
#
#   FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-nudge.sh
#
# Runs its own server against its own database and blob store, with short
# windows, or this would wait fifteen minutes to see anything.
set -uo pipefail

SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"

DB=framestation_nudge; PORT=8082; API="http://127.0.0.1:$PORT"
export FRAMESTATION_DATABASE_URL="postgres://framestation:x@127.0.0.1:55432/$DB?sslmode=disable"
# Nothing here touches a blob, but the boot check refuses to start without a
# root that exists, so it gets one.
ROOT="$SCRATCH/nudge"; rm -rf "$ROOT"; mkdir -p "$ROOT/blobroot"
ROOT=$(cd "$ROOT" && pwd -P)
export FRAMESTATION_BLOB_ROOT="$ROOT/blobroot"
PSQL="psql -h 127.0.0.1 -p 55432 -U framestation -d $DB -tAqc"
admin(){ psql -h 127.0.0.1 -p 55432 -U framestation -d postgres -tAqc "$1"; }

export FRAMESTATION_BACKUP_QUIET_SECONDS="${FRAMESTATION_BACKUP_QUIET_SECONDS:-20}"
export FRAMESTATION_BACKUP_NUDGE_COOLDOWN_SECONDS="${FRAMESTATION_BACKUP_NUDGE_COOLDOWN_SECONDS:-3}"
export FRAMESTATION_BACKUP_NUDGE_LIMIT="${FRAMESTATION_BACKUP_NUDGE_LIMIT:-3}"
export FRAMESTATION_BACKUP_NUDGE_SECONDS="${FRAMESTATION_BACKUP_NUDGE_SECONDS:-1}"
# A fresh blob root has no key in it; these would bring one in from the shell.
unset FRAMESTATION_APNS_KEY FRAMESTATION_APNS_KEY_PATH FRAMESTATION_APNS_KEY_ID

# The server's own knobs, from above. The waits below are derived from these rather
# than written out, so changing one doesn't quietly turn a check into a coin toss.
COOLDOWN="$FRAMESTATION_BACKUP_NUDGE_COOLDOWN_SECONDS"
LIMIT="$FRAMESTATION_BACKUP_NUDGE_LIMIT"
TICK="$FRAMESTATION_BACKUP_NUDGE_SECONDS"
# Two waits, and the difference between them is the point.
#
# ONE is long enough for the sweep to come round once and short enough that the
# cooldown has not expired — so a check that follows it is asserting about
# exactly one nudge. Getting this wrong is silent: with a wait longer than the
# cooldown, "nudged once" reads two and looks like a bug in the server.
ONE=$((TICK + 1))
AGAIN=$((COOLDOWN + TICK + 1))

DEVICE_NAME="SmokeNudgePhone-$$"
PASS=0; FAIL=0

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $1"; echo "      expected: $2"; echo "      actual:   $3"; FAIL=$((FAIL+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
jq_get() { python3 -c "import sys,json; d=json.load(sys.stdin); print(d$1)" 2>/dev/null; }

nudges() { $PSQL "SELECT backup_nudges FROM devices WHERE name='$DEVICE_NAME';"; }
device()  { $PSQL "SELECT id FROM devices WHERE name='$DEVICE_NAME';"; }
# Backdates the two freshness marks, which is how the script says "this phone
# has gone quiet" without sleeping out a real quiet window.
gone_quiet() {
    $PSQL "UPDATE devices
           SET backup_reported_at = now() - interval '1 hour',
               last_seen_at = now() - interval '1 hour'
           WHERE name='$DEVICE_NAME';" >/dev/null
}
report() {
    curl -s -o /dev/null -w "%{http_code}" -X PUT "$API/v1/devices/backup-state" \
        -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
        -d "{\"pending\":$1}"
}

(cd "$SERVER_DIR" && swift build >/dev/null 2>&1) || { echo "server build failed"; exit 1; }
BIN="$(cd "$SERVER_DIR" && swift build --show-bin-path)/FrameStationServer"
# Whatever already answers on this port would be tested in this server's place.
curl -s -o /dev/null "$API/health" && { echo "port $PORT is already in use"; exit 1; }
admin "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1; admin "CREATE DATABASE $DB" >/dev/null
"$BIN" serve --hostname 127.0.0.1 --port $PORT > "$ROOT/server.log" 2>&1 &
SERVER=$!
# The log stays for a look after a failure.
trap 'kill $SERVER 2>/dev/null; wait $SERVER 2>/dev/null; rm -rf "$ROOT/blobroot"' EXIT
for _ in $(seq 1 120); do curl -s -o /dev/null "$API/health" && break; sleep 0.5; done
curl -s -o /dev/null "$API/health" || { echo "server didn't start:"; tail -20 "$ROOT/server.log"; exit 1; }

# -------------------------------------------------------------------- auth ---
echo "=== setup ==="
CODE=$(cd "$SERVER_DIR" && "$BIN" invite 2>/dev/null \
    | grep "Invite code:" | awk '{print $3}')
R=$(curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
    -d "{\"code\":\"$CODE\",\"displayName\":\"Smoke Nudge\",\"deviceName\":\"$DEVICE_NAME\",\"platform\":\"ios\"}")
TOKEN=$(echo "$R" | jq_get '["token"]')
[ -n "$TOKEN" ] || { echo "  ✗ could not redeem an invite"; tail -20 "$ROOT/server.log"; exit 1; }
DEV=$(device)
echo "  device $DEV"

# A token is what makes a device reachable at all; without one it is never a
# candidate, whatever else is true of it.
curl -s -o /dev/null -X PUT "$API/v1/devices/push-token" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d '{"apnsToken":"smoke0000000000000000000000000000","environment":"sandbox"}'

# ------------------------------------------------------- nothing to wake for ---
echo "=== a device with nothing outstanding is never woken ==="
check "report accepted" "204" "$(report 0)"
gone_quiet
sleep "$AGAIN"
check "no nudge for an empty queue" "0" "$(nudges)"

# ------------------------------------------------------------ still working ---
echo "=== a device that is still talking to us is left alone ==="
check "report accepted" "204" "$(report 200)"
# Freshly reported and freshly seen: this is a phone mid-backup, and
# interrupting it to tell it to back up is the one thing worth never doing.
sleep "$AGAIN"
check "no nudge while the report is fresh" "0" "$(nudges)"

# ------------------------------------------------------------- gone quiet ---
echo "=== a device that has gone quiet with work left is woken ==="
gone_quiet
sleep "$ONE"
check "nudged once" "1" "$(nudges)"

echo "=== and not again until the cooldown is up ==="
# Quiet again, but the cooldown has not passed, so the count must hold.
$PSQL "UPDATE devices SET last_seen_at = now() - interval '1 hour' WHERE name='$DEVICE_NAME';" >/dev/null
sleep 1
check "cooldown holds" "1" "$(nudges)"

# ------------------------------------------------------- an upload arriving ---
echo "=== an upload in flight suppresses the nudge ==="
USER=$($PSQL "SELECT user_id FROM devices WHERE id='$DEV';")
SPACE=$($PSQL "SELECT id FROM spaces WHERE created_by='$USER' AND kind='personal' LIMIT 1;")
$PSQL "INSERT INTO upload_sessions
         (user_id, space_id, device_id, sha256, byte_size, filename,
          chunk_size, chunk_count, received_mask, updated_at)
       VALUES ('$USER', '$SPACE', '$DEV', 'smoke-in-flight', 1024, 'clip.mov',
               1024, 1, '\\x00', now());" >/dev/null
gone_quiet
sleep "$AGAIN"
check "no nudge while bytes are arriving" "1" "$(nudges)"

echo "=== and resumes once that upload is finished or abandoned ==="
$PSQL "UPDATE upload_sessions SET committed_at = now() WHERE device_id='$DEV';" >/dev/null
gone_quiet
sleep "$ONE"
check "nudged again" "2" "$(nudges)"

# ------------------------------------------------------------- the budget ---
echo "=== a device that never answers runs out of nudges ==="
# Keep it quiet and keep waiting; the count must stop at the limit rather than
# climb for ever.
for _ in $(seq 1 4); do
    gone_quiet
    sleep "$AGAIN"
done
check "stops at the limit" "$LIMIT" "$(nudges)"

echo "=== answering re-arms it ==="
check "report accepted" "204" "$(report 150)"
check "budget reset" "0" "$(nudges)"
gone_quiet
sleep "$ONE"
check "nudged again after reporting" "1" "$(nudges)"

# ----------------------------------------------------------------- a Mac ---
echo "=== a Mac has no background windows to be rescued from ==="
$PSQL "UPDATE devices SET platform='macos', backup_nudges=0, backup_nudged_at=NULL
       WHERE name='$DEVICE_NAME';" >/dev/null
gone_quiet
sleep "$AGAIN"
check "never nudged" "0" "$(nudges)"

# ---------------------------------------------------------------- summary ---
echo
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
