#!/bin/bash
# Geocoding smoke test: real coordinates -> real place names, plus the
# timeline day headers and asset detail that consume them.
#
#   FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-geocode.sh
#
# Runs its own server against its own database and blob store: the backfill
# command names every unnamed photo in whatever database it's given, so it gets
# one that holds nothing but this test's. Needs the town dataset
# (Scripts/fetch-geonames.sh).
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"
export FRAMESTATION_GEONAMES_DIR="${FRAMESTATION_GEONAMES_DIR:-$(cd "$(dirname "$0")/.." && pwd)/Data/geonames}"
[ -f "$FRAMESTATION_GEONAMES_DIR/cities.tsv" ] || {
  echo "No town dataset at $FRAMESTATION_GEONAMES_DIR. Run Scripts/fetch-geonames.sh first."; exit 1; }

DB=framestation_geocode; PORT=8080; API="http://127.0.0.1:$PORT"
export FRAMESTATION_DATABASE_URL="postgres://framestation:x@127.0.0.1:55432/$DB?sslmode=disable"
ROOT="$SCRATCH/geocode"; rm -rf "$ROOT"; mkdir -p "$ROOT/blobroot" "$ROOT/files"
ROOT=$(cd "$ROOT" && pwd -P)
export FRAMESTATION_BLOB_ROOT="$ROOT/blobroot"
PASS=0; FAIL=0
q(){ psql -h 127.0.0.1 -p 55432 -U framestation -d $DB -tAqc "$1"; }
admin(){ psql -h 127.0.0.1 -p 55432 -U framestation -d postgres -tAqc "$1"; }
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; echo "      expected: $2"; echo "      actual:   $3"; FAIL=$((FAIL+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
has(){ case "$3" in *"$2"*) ok "$1";; *) bad "$1" "contains '$2'" "$3";; esac }
jq_get(){ python3 -c "import sys,json; print(json.load(sys.stdin)$1)" 2>/dev/null; }

(cd "$SERVER_DIR" && swift build >/dev/null 2>&1) || { echo "server build failed"; exit 1; }
BIN="$(cd "$SERVER_DIR" && swift build --show-bin-path)/FrameStationServer"
# Whatever already answers on this port would be tested in this server's place.
curl -s -o /dev/null "$API/health" && { echo "port $PORT is already in use"; exit 1; }
admin "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1; admin "CREATE DATABASE $DB" >/dev/null
"$BIN" serve --hostname 127.0.0.1 --port $PORT > "$ROOT/server.log" 2>&1 &
SERVER=$!
# The log stays for a look after a failure; the files made for the run go.
trap 'kill $SERVER 2>/dev/null; wait $SERVER 2>/dev/null; rm -rf "$ROOT/files" "$ROOT/blobroot"' EXIT
# Longer than the others: the server loads the town dataset before it listens.
for _ in $(seq 1 240); do curl -s -o /dev/null "$API/health" && break; sleep 0.5; done
curl -s -o /dev/null "$API/health" || { echo "server didn't start:"; tail -20 "$ROOT/server.log"; exit 1; }

CODE=$(cd "$SERVER_DIR" && "$BIN" invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
R=$(curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$CODE\",\"displayName\":\"Michael\",\"deviceName\":\"iPhone\",\"platform\":\"ios\"}")
TOKEN=$(echo "$R" | jq_get '["token"]'); SPACE=$(echo "$R" | jq_get '["personalSpace"]["id"]')
AUTH="Authorization: Bearer $TOKEN"

# label lat lon capturedAt
put(){
  local label="$1" lat="$2" lon="$3" cap="$4"
  local f="$ROOT/files/$label.jpg"
  vips gaussnoise "$ROOT/files/$label.v" 800 600 >/dev/null 2>&1
  vips copy "$ROOT/files/$label.v" "$f" >/dev/null 2>&1
  local latref="N" lonref="E" alat="$lat" alon="$lon"
  case "$lat" in -*) latref="S"; alat="${lat#-}";; esac
  case "$lon" in -*) lonref="W"; alon="${lon#-}";; esac
  exiftool -q -overwrite_original -Make=Apple -Model="iPhone 16 Pro" \
    -GPSLatitude="$alat" -GPSLatitudeRef="$latref" -GPSLongitude="$alon" -GPSLongitudeRef="$lonref" "$f" >/dev/null 2>&1
  local sha size up
  sha=$(shasum -a 256 "$f" | awk '{print $1}'); size=$(stat -f%z "$f")
  up=$(curl -s -X POST "$API/v1/uploads/probe" -H "$AUTH" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$SPACE\",\"sha256\":\"$sha\",\"byteSize\":$size,\"filename\":\"$label.jpg\"}" | jq_get '["uploadID"]')
  curl -s -X PUT "$API/v1/uploads/$up/chunk/0" -H "$AUTH" --data-binary "@$f" >/dev/null
  curl -s -X POST "$API/v1/uploads/$up/commit" -H "$AUTH" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$SPACE\",\"mediaType\":\"photo\",\"mime\":\"image/jpeg\",\"width\":800,\"height\":600,\"capturedAt\":\"$cap\",\"capturedTZOffset\":0,\"isRaw\":false,\"burstPick\":false}" | jq_get '["assetID"]'
}

echo "=== 1. real coordinates resolve to real places ==="
A_CULP=$(put culpeper   38.3487   -77.9797  "2026-07-18T16:00:00Z")
A_NYC=$(put  manhattan  40.7580   -73.9855  "2026-07-17T16:00:00Z")
A_LON=$(put  london     51.5074    -0.1278  "2026-07-16T16:00:00Z")
A_TOK=$(put  tokyo      35.6762   139.6503  "2026-07-15T16:00:00Z")
A_SYD=$(put  sydney    -33.8688   151.2093  "2026-07-14T16:00:00Z")
A_SEA=$(put  midocean    0.5       -140.5   "2026-07-13T16:00:00Z")

has "Culpeper, Virginia"  "Virginia"   "$(q "select coalesce(place_name,'-') from assets where id='$A_CULP';")"
has "New York region"     "New York"   "$(q "select coalesce(place_name,'-') from assets where id='$A_NYC';")"
has "London, England"     "England"    "$(q "select coalesce(place_name,'-') from assets where id='$A_LON';")"
has "Tokyo"               "Tokyo"      "$(q "select coalesce(place_name,'-') from assets where id='$A_TOK';")"
has "Sydney, New South Wales" "New South Wales" "$(q "select coalesce(place_name,'-') from assets where id='$A_SYD';")"
check "mid-Pacific stays unnamed" "-" "$(q "select coalesce(place_name,'-') from assets where id='$A_SEA';")"

echo
echo "=== 2. day headers in the timeline manifest ==="
M=$(curl -s "$API/v1/spaces/$SPACE/timeline?zoom=day" -H "$AUTH")
has "header carries the place" "Virginia" \
  "$(echo "$M" | python3 -c 'import sys,json;b=json.load(sys.stdin)["buckets"];print(next((x["place"] or "-") for x in b if x["key"]=="2026-07-18"))')"

echo
echo "=== 3. asset detail exposes it ==="
has "detail placeName" "Culpeper" \
  "$(curl -s "$API/v1/spaces/$SPACE/assets/$A_CULP/detail" -H "$AUTH" | jq_get '["placeName"]')"

echo
echo "=== 4. backfill command ==="
# Only this test's photos. The library around them keeps its names.
MINE="'$A_CULP','$A_NYC','$A_LON','$A_TOK','$A_SYD','$A_SEA'"
q "UPDATE assets SET place_name = NULL WHERE id IN ($MINE);" >/dev/null
check "cleared" "0" "$(q "select count(place_name) from assets where id in ($MINE);")"
OUT=$(cd "$SERVER_DIR" && "$BIN" geocode 2>/dev/null)
echo "$OUT" | grep -E "Named:|No match:" | sed 's/^/  /'
check "5 of 6 named again" "5" "$(q "select count(place_name) from assets where id in ($MINE);")"
# The mid-ocean asset can never resolve, so it is re-examined every run —
# correct, and cheap. What must hold is that a second run changes nothing.
OUT2=$(cd "$SERVER_DIR" && "$BIN" geocode 2>/dev/null)
has "second run finds nothing new" "Named:     0" "$OUT2"
has "second run still sees the unnamable one" "No match:  1" "$OUT2"
check "count unchanged" "5" "$(q "select count(place_name) from assets where id in ($MINE);")"

echo
echo "════════════════════════════════════"
echo "  passed: $PASS   failed: $FAIL"
echo "════════════════════════════════════"
[ "$FAIL" -eq 0 ]
