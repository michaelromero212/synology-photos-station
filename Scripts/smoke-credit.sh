#!/bin/bash
# credit-uploaders: photos imported into a shared library are credited to the
# people Synology says shared them. Someone without an account gets one, the
# way signing in would make it, without joining the library. A credit set by
# hand is kept, a photo already shown as the person's is left alone, and
# running it again changes nothing.
#
#   FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-credit.sh
#
# Runs its own server against its own database and blob store.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"

DB=framestation_credit; PORT=8093; API="http://127.0.0.1:$PORT"
export FRAMESTATION_DATABASE_URL="postgres://framestation:x@127.0.0.1:55432/$DB?sslmode=disable"
ROOT="$SCRATCH/credit"; rm -rf "$ROOT"; mkdir -p "$ROOT/blobroot" "$ROOT/lib"
ROOT=$(cd "$ROOT" && pwd -P)
export FRAMESTATION_BLOB_ROOT="$ROOT/blobroot"

PASS=0; FAIL=0
q(){ psql -h 127.0.0.1 -p 55432 -U framestation -d $DB -tAqc "$1"; }
admin(){ psql -h 127.0.0.1 -p 55432 -U framestation -d postgres -tAqc "$1"; }
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; echo "      expected: $2"; echo "      actual:   $3"; FAIL=$((FAIL+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
says(){ echo "$OUT" | grep -qF "$2" && ok "$1" || bad "$1" "$2" "$(echo "$OUT" | tr '\n' '|')"; }
jq(){ python3 -c "import sys,json; print(json.load(sys.stdin)$1)" 2>/dev/null; }

(cd "$SERVER_DIR" && swift build >/dev/null 2>&1) || { echo "server build failed"; exit 1; }
BIN="$(cd "$SERVER_DIR" && swift build --show-bin-path)/FrameStationServer"
admin "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1; admin "CREATE DATABASE $DB" >/dev/null
"$BIN" serve --hostname 127.0.0.1 --port $PORT > "$ROOT/server.log" 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null; wait $SERVER 2>/dev/null' EXIT
for _ in $(seq 1 120); do curl -s -o /dev/null "$API/health" && break; sleep 0.5; done
run(){ (cd "$SERVER_DIR" && "$BIN" "$@" 2>/dev/null); }
redeem(){ curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$(run invite | grep 'Invite code:' | awk '{print $3}')\",\"displayName\":\"$1\",\"deviceName\":\"iPhone\",\"platform\":\"ios\"}"; }

R=$(redeem Owner); TOKEN=$(echo "$R" | jq '["token"]'); OWNER=$(echo "$R" | jq '["user"]["id"]')
OTHER=$(redeem Other | jq '["user"]["id"]')
SHARED=$(curl -s -X POST "$API/v1/spaces" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"name\":\"Family Shared\",\"memberIDs\":[\"$OTHER\"]}" | jq '["id"]')
for p in p1 p2 p3 p4 p5; do
  vips gaussnoise "$ROOT/n.v" 64 64 >/dev/null 2>&1 && vips copy "$ROOT/n.v" "$ROOT/lib/$p.jpg" >/dev/null 2>&1
done
run import --path "$ROOT/lib" --space "$SHARED" >/dev/null
# The owner is "owner" on the NAS, and p4 was credited to Other by hand.
q "UPDATE users SET dsm_username = 'owner' WHERE id = '$OWNER'" >/dev/null
q "UPDATE space_assets SET credited_to_user_id = '$OTHER', credited_by_user_id = '$OWNER',
   credited_at = now() WHERE filename = 'p4.jpg'" >/dev/null
TAB=$(printf '\t')
{
  echo "$ROOT/lib/p1.jpg${TAB}2001${TAB}Jordan Test"
  echo "$ROOT/lib/p2.jpg${TAB}2001${TAB}Jordan Test"
  echo "$ROOT/lib/p3.jpg${TAB}2000${TAB}OWNER"
  echo "$ROOT/lib/p4.jpg${TAB}2001${TAB}Jordan Test"
  echo "$ROOT/lib/elsewhere.jpg${TAB}2001${TAB}Jordan Test"
  echo "not a line this understands"
} > "$ROOT/credits.tsv"
credit(){ q "SELECT coalesce(u.display_name, '-') FROM space_assets sa LEFT JOIN users u ON u.id = sa.credited_to_user_id
             WHERE sa.space_id = '$SHARED' AND sa.filename = '$1'"; }

echo "A dry run"
OUT=$(run credit-uploaders --from "$ROOT/credits.tsv" --space "$SHARED" --dry-run)
says "names who'd be credited, and that they're new" "Credit to Jordan Test: 2  (new account)"
says "a photo already shown as theirs needs nothing" "Already shown as theirs:   1"
says "a credit set by hand is kept" "Credited by hand, kept:    1"
says "a photo the import didn't bring here is left out" "Not imported here:         1"
says "and an unreadable line is counted" "Unreadable lines:          1"
check "and changes nothing" "2 -" "$(q "SELECT count(*) FROM users") $(credit p1.jpg)"

echo "The real run"
OUT=$(run credit-uploaders --from "$ROOT/credits.tsv" --space "$SHARED")
says "says what it did" "Credited 2 photos."
check "an account for the new person, tied to their Synology login" "Jordan Test|2001" \
  "$(q "SELECT display_name || '|' || dsm_uid FROM users WHERE dsm_username = 'Jordan Test'")"
NEWCOMER=$(q "SELECT id FROM users WHERE dsm_username = 'Jordan Test'")
check "with a personal library of their own, as signing in makes" "1" \
  "$(q "SELECT count(*) FROM spaces s JOIN space_members m ON m.space_id = s.id
        WHERE s.kind = 'personal' AND s.created_by = '$NEWCOMER' AND m.user_id = '$NEWCOMER' AND m.role = 'owner'")"
check "but not added to the shared library" "0" \
  "$(q "SELECT count(*) FROM space_members WHERE space_id = '$SHARED' AND user_id = '$NEWCOMER'")"
check "their photos are credited to them" "Jordan Test Jordan Test" "$(credit p1.jpg) $(credit p2.jpg)"
check "by the library's owner" "2" \
  "$(q "SELECT count(*) FROM space_assets WHERE credited_to_user_id = '$NEWCOMER' AND credited_by_user_id = '$OWNER'")"
check "the owner's own photo is left as it was" "-" "$(credit p3.jpg)"
check "the hand-set credit stands" "Other" "$(credit p4.jpg)"
check "a photo nobody matched is untouched" "-" "$(credit p5.jpg)"
check "phones are told" "2" \
  "$(q "SELECT count(DISTINCT c.entity_id) FROM change_log c JOIN space_assets sa ON sa.id = c.entity_id
        WHERE c.space_id = '$SHARED' AND c.op = 'update' AND sa.credited_to_user_id = '$NEWCOMER'")"
P1=$(q "SELECT asset_id FROM space_assets WHERE space_id = '$SHARED' AND filename = 'p1.jpg'")
check "and the Information panel says Added by them" "Jordan Test" \
  "$(curl -s "$API/v1/spaces/$SHARED/assets/$P1/detail" -H "Authorization: Bearer $TOKEN" | jq '["uploadedBy"]["displayName"]')"

echo "Again"
OUT=$(run credit-uploaders --from "$ROOT/credits.tsv" --space "$SHARED")
says "finds nothing left to do" "Nothing to do."
check "and makes no second account" "1" "$(q "SELECT count(*) FROM users WHERE dsm_username = 'Jordan Test'")"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
