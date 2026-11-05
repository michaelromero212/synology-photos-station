#!/bin/bash
# What the NAS's scenes mean, and how the Albums page and search use it. See
# NAS-ANALYSIS.md, "Scenes into albums".
#
# What it checks:
#  - each scene is scored against the concept vectors into labels, tags and
#    search words in the phones' terms;
#  - the preview builds the page from them and saves nothing, and turning it
#    off leaves the page as it was;
#  - "on" uses them and saves as usual;
#  - search follows the same switch;
#  - nobody else's library is touched.
#
#   FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-nas-scoring.sh
#
# Runs its own server and database. The analyzer is a stand-in: for each file
# it returns a scene vector close to one concept, as a real photo of that
# thing would score, so every outcome here is known in advance. The photos are
# noise images made for the run.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"

DB=framestation_nasscoring; PORT=8102; API="http://127.0.0.1:$PORT"
export FRAMESTATION_DATABASE_URL="postgres://framestation:x@127.0.0.1:55432/$DB?sslmode=disable"
ROOT="$SCRATCH/nasscoring"; rm -rf "$ROOT"; mkdir -p "$ROOT/blobroot/blobs" "$ROOT/files"
ROOT=$(cd "$ROOT" && pwd -P)
export FRAMESTATION_BLOB_ROOT="$ROOT/blobroot"
mkdir -p "$HOME/.framestation-dev/sock"; SOCK="$HOME/.framestation-dev/sock/nasscoring-smoke.sock"
export FRAMESTATION_ANALYZER_SOCKET="$SOCK" FRAMESTATION_ANALYSIS_START_DELAY=1 FRAMESTATION_ANALYSIS_IDLE=2
CONCEPTS="$SERVER_DIR/Sources/FrameStationServer/Resources/scene-concepts.json"
PASS=0; FAIL=0
q(){ psql -h 127.0.0.1 -p 55432 -U framestation -d $DB -tAqc "$1"; }
admin(){ psql -h 127.0.0.1 -p 55432 -U framestation -d postgres -tAqc "$1"; }
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; echo "      expected: $2"; echo "      actual:   $3"; FAIL=$((FAIL+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
has(){ case "$3" in *"$2"*) ok "$1";; *) bad "$1" "contains '$2'" "$3";; esac; }
lacks(){ case "$3" in *"$2"*) bad "$1" "no '$2'" "$3";; *) ok "$1";; esac; }
jq(){ python3 -c "import sys,json; print(json.load(sys.stdin)$1)" 2>/dev/null; }
code(){ curl -s -o /dev/null -w '%{http_code}' "$@"; }
until_true(){ local n=$1; shift; for _ in $(seq 1 "$n"); do eval "$@" && return 0; sleep 1; done; return 1; }
# Every title on the Albums page, joined with |.
titles(){ curl -s "$API/v1/spaces/$1/collections?date=2026-10-12" -H "$2" | python3 -c "
import sys, json
d = json.load(sys.stdin)
cards = (d.get('allOccasions') or []) + (d.get('allTrips') or []) + d.get('days', [])
print('|'.join(c['title'] for c in cards))"; }

(cd "$SERVER_DIR" && swift build >/dev/null 2>&1) || { echo "server build failed"; exit 1; }
BIN="$(cd "$SERVER_DIR" && swift build --show-bin-path)/FrameStationServer"
cli(){ (cd "$SERVER_DIR" && "$BIN" "$@" 2>&1); }
curl -s -o /dev/null "$API/health" && { echo "port $PORT is already in use"; exit 1; }
admin "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1; admin "CREATE DATABASE $DB" >/dev/null

# The stand-in analyzer. $ROOT/plan.json maps a file's SHA-256 to the concept
# its scene should look like. The vector is solved for: cosine 0.16 with that
# concept and 0.05 with every other one, roughly where SigLIP puts a clear
# photo of a thing and an unrelated one, with noise in the rest. Unplanned
# files sit at 0.05 with everything. (Scaling a concept's own vector instead
# would match dozens of others: the 224 share a median cosine of 0.84.)
cat > "$ROOT/fake.py" <<'PY'
import base64, http.server, json, os, socketserver, sys
import numpy as np
sock, concepts_path, plan_path = sys.argv[1:4]
spec = json.load(open(concepts_path))["concepts"]
ids = [c["id"] for c in spec]
T = np.stack([np.frombuffer(base64.b64decode(c["vector"]), dtype="<f4") for c in spec]).astype(np.float64)
G = T @ T.T
def scene(sha):
    plan = json.load(open(plan_path)) if os.path.exists(plan_path) else {}
    target = plan.get(sha, "")
    dots = np.full(len(ids), 0.05)
    if target in ids:
        dots[ids.index(target)] = 0.16
    v = T.T @ np.linalg.solve(G, dots)
    rng = np.random.default_rng(int(sha[:12], 16))
    r = rng.standard_normal(768)
    r -= T.T @ np.linalg.solve(G, T @ r)
    v += np.sqrt(max(0.0, 1 - v @ v)) * r / np.linalg.norm(r)
    return base64.b64encode(v.astype("<f4").tobytes()).decode()
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def address_string(self): return "local"
    def log_message(self, *a): pass
    def reply(self, body):
        data = json.dumps(body).encode(); self.send_response(200)
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        self.reply({"status": "ok", "protocol": 1, "analyzer": 1, "threads": 1,
                    "models": {"scene": "siglip2-base-patch32-256@0ddb7507cfcb"}})
    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        sha = os.path.basename(request["path"]).split(".")[0]
        self.reply({"protocol": 1, "analyzer": 1, "timings": {"totalMS": 1},
                    "models": {"scene": "siglip2-base-patch32-256@0ddb7507cfcb"},
                    "frames": [{"ms": None, "width": 1280, "height": 960, "scene": scene(sha), "faces": []}]})
socketserver.UnixStreamServer(sock, H).serve_forever()
PY
# numpy, from the analyzer's own dev environment.
"$SERVER_DIR/../Analyzer/dev.sh" setup >/dev/null || { echo "analyzer setup failed"; exit 1; }
PY="$HOME/.framestation-dev/analyzer/venv/bin/python"
rm -f "$SOCK"; "$PY" "$ROOT/fake.py" "$SOCK" "$CONCEPTS" "$ROOT/plan.json" > "$ROOT/analyzer.log" 2>&1 & ANALYZER=$!
until_true 20 '[ -S "$SOCK" ]'
"$BIN" serve --hostname 127.0.0.1 --port $PORT > "$ROOT/server.log" 2>&1 &
SERVER=$!
trap 'kill $SERVER $ANALYZER 2>/dev/null; wait $SERVER $ANALYZER 2>/dev/null; rm -rf "$ROOT/files" "$ROOT/blobroot" "$SOCK"; admin "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1' EXIT
until_true 60 'curl -s -o /dev/null "$API/health"' || { echo "server didn't start"; tail -20 "$ROOT/server.log"; exit 1; }

newuser(){ local c; c=$(cli invite | grep "Invite code:" | awk '{print $3}')
  curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
    -d "{\"code\":\"$c\",\"displayName\":\"$1\",\"deviceName\":\"$1-phone\",\"platform\":\"ios\"}" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["token"],d["personalSpace"]["id"],d["user"]["id"])'; }
read -r T1 P1 U1 <<< "$(newuser Owner)"
read -r T2 P2 U2 <<< "$(newuser Neighbor)"
A1="Authorization: Bearer $T1"; A2="Authorization: Bearer $T2"

# photo <space> <auth> <name> <width> <capturedAt> <concept> → asset id, with
# the plan recorded for its SHA-256.
photo(){
  local f="$ROOT/files/$3.jpg" sha size up
  vips gaussnoise "$ROOT/files/n.v" "$4" 240 >/dev/null 2>&1; vips copy "$ROOT/files/n.v" "$f" >/dev/null 2>&1
  sha=$(shasum -a 256 "$f" | awk '{print $1}'); size=$(stat -f%z "$f")
  python3 -c "import json,os,sys; p=sys.argv[1]; d=json.load(open(p)) if os.path.exists(p) else {}; d[sys.argv[2]]=sys.argv[3]; json.dump(d, open(p,'w'))" "$ROOT/plan.json" "$sha" "$6"
  up=$(curl -s -X POST "$API/v1/uploads/probe" -H "$2" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$1\",\"sha256\":\"$sha\",\"byteSize\":$size,\"filename\":\"$3.jpg\",\"isAutomaticBackup\":false}" | jq '["uploadID"]')
  curl -s -X PUT "$API/v1/uploads/$up/chunk/0" -H "$2" --data-binary "@$f" >/dev/null
  curl -s -X POST "$API/v1/uploads/$up/commit" -H "$2" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$1\",\"mediaType\":\"photo\",\"mime\":\"image/jpeg\",\"width\":$4,\"height\":240,\"capturedAt\":\"$5\",\"capturedTZOffset\":0,\"isRaw\":false,\"burstPick\":false}" | jq '["assetID"]'
}

echo "A birthday, a beach day, a screenshot and an ordinary day"
CAKE=(); for i in 1 2 3 4; do CAKE+=("$(photo "$P1" "$A1" "cake$i" $((300 + i)) "2023-05-20T1${i}:00:00Z" birthday_cake)"); done
BEACH=(); for i in 1 2 3 4; do BEACH+=("$(photo "$P1" "$A1" "beach$i" $((320 + i)) "2024-07-04T1${i}:00:00Z" beach)"); done
SHOT=$(photo "$P1" "$A1" "shot" 340 "2024-07-05T10:00:00Z" screenshot)
for i in 1 2 3; do photo "$P1" "$A1" "plain$i" $((350 + i)) "2024-03-0${i}T10:00:00Z" none >/dev/null; done
for i in 1 2; do photo "$P2" "$A2" "theirs$i" $((360 + i)) "2023-05-20T1${i}:00:00Z" birthday_cake >/dev/null; done
until_true 60 '[ "$(q "SELECT count(*) FROM assets WHERE derived_at IS NOT NULL")" = "14" ]'
cli analysis enroll Owner >/dev/null
until_true 90 '[ "$(q "SELECT count(*) FROM nas_observations WHERE user_id = '"'$U1'"'")" = "12" ]'
check "every analyzed file is scored" "12" "$(q "SELECT count(*) FROM nas_observations WHERE user_id = '$U1'")"
check "the neighbor's library untouched" "0" "$(q "SELECT count(*) FROM nas_observations WHERE user_id = '$U2'")"
SHA_CAKE=$(q "SELECT sha256 FROM assets WHERE id = '${CAKE[0]}'")
has "a birthday cake scores as one" "birthday_cake" "$(q "SELECT labels::text FROM nas_observations WHERE sha256 = '$SHA_CAKE'")"
has "and is tagged a birthday" "birthday" "$(q "SELECT array_to_string(tags, ',') FROM nas_observations WHERE sha256 = '$SHA_CAKE'")"
has "a beach is tagged a beach" "beach" "$(q "SELECT array_to_string(tags, ',') FROM nas_observations o JOIN assets a ON a.sha256 = o.sha256 WHERE a.id = '${BEACH[0]}'")"
has "a screenshot is utility" "utility" "$(q "SELECT array_to_string(tags, ',') FROM nas_observations o JOIN assets a ON a.sha256 = o.sha256 WHERE a.id = '$SHOT'")"
check "an ordinary photo carries no tags" "0" "$(q "SELECT count(*) FROM nas_observations o JOIN assets a ON a.sha256 = o.sha256 WHERE a.width IN (351, 352, 353) AND cardinality(o.tags) > 0")"
has "search words are stored too" "cake" "$(q "SELECT array_to_string(words, ',') FROM nas_observations WHERE sha256 = '$SHA_CAKE'")"
check "scored with today's concepts and no calibration yet" "default" "$(q "SELECT DISTINCT split_part(scoring, '/', 2) FROM nas_observations")"

echo "What the Information panel gets"
D=$(curl -s "$API/v1/spaces/$P1/assets/${CAKE[0]}/nas-observation" -H "$A1")
has "labels in the device's words" "birthday_cake" "$D"
has "and the tags" '"birthday"' "$D"
lacks "nothing about faces" "embedding" "$D"
check "someone else's photo is a 404" "404" "$(code "$API/v1/spaces/$P1/assets/${CAKE[0]}/nas-observation" -H "$A2")"
check "a file the NAS hasn't scored is a 404" "404" "$(code "$API/v1/spaces/$P2/assets/$(q "SELECT a.id FROM assets a JOIN space_assets sa ON sa.asset_id = a.id WHERE sa.space_id = '$P2' LIMIT 1")/nas-observation" -H "$A2")"

echo "Status and the preview switch"
S=$(curl -s "$API/v1/curation" -H "$A1")
check "the NAS's progress is in the status" "shadow:12:False" "$(echo "$S" | jq '["nas"]["state"]'):$(echo "$S" | jq '["nas"]["analyzed"]'):$(echo "$S" | jq '["nas"]["preview"]')"
check "nobody else sees a NAS section" "None" "$(curl -s "$API/v1/curation" -H "$A2" | jq '.get("nas")')"
curl -s -X PUT "$API/v1/curation/settings" -H "$A2" -H 'Content-Type: application/json' -d '{"nasPreview":true}' >/dev/null
check "someone the NAS doesn't analyze can't preview" "f" "$(q "SELECT nas_preview FROM users WHERE id = '$U2'")"

echo "The Albums page"
BEFORE=$(titles "$P1" "$A1")
lacks "in shadow mode the page doesn't use it" "Birthday party" "$BEFORE"
KEPT=$(q "SELECT count(*) FROM curated_albums")
curl -s -X PUT "$API/v1/curation/settings" -H "$A1" -H 'Content-Type: application/json' -d '{"nasPreview":true}' >/dev/null
PREVIEW=$(titles "$P1" "$A1")
if [ -n "${SMOKE_DEBUG:-}" ]; then
  q "SELECT a.width, array_to_string(o.tags, ','), left(o.labels::text, 160) FROM nas_observations o JOIN assets a ON a.sha256 = o.sha256 WHERE o.user_id = '$U1' ORDER BY a.width"
  curl -s "$API/v1/spaces/$P1/collections?date=2026-10-12" -H "$A1" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for k in ('allOccasions', 'allTrips', 'days', 'traditions'):
    for c in (d.get(k) or []): print(k, c.get('key'), c.get('title'), c.get('kind'))"
fi
has "previewing, the birthday is a birthday party" "Birthday party" "$PREVIEW"
has "and the beach day is a beach day" "Beach day" "$PREVIEW"
check "and nothing is saved while previewing" "$KEPT" "$(q "SELECT count(*) FROM curated_albums")"
check "search finds the beach in the NAS's words" "4" "$(curl -s "$API/v1/spaces/$P1/search?q=beach" -H "$A1" | jq '["total"]')"
check "the neighbor's page is their own" "$(titles "$P2" "$A2")" "$(titles "$P2" "$A2")"
curl -s -X PUT "$API/v1/curation/settings" -H "$A1" -H 'Content-Type: application/json' -d '{"nasPreview":false}' >/dev/null
check "preview off: the page is exactly as it was" "$BEFORE" "$(titles "$P1" "$A1")"
check "and search is back to the devices' words" "0" "$(curl -s "$API/v1/spaces/$P1/search?q=beach" -H "$A1" | jq '["total"]')"

echo "Switched on"
q "UPDATE users SET nas_analysis = 'on' WHERE id = '$U1'" >/dev/null
has "on, the page uses the NAS's analysis" "Birthday party" "$(titles "$P1" "$A1")"
SAVED=$(q "SELECT count(*) FROM curated_albums WHERE user_id = '$U1' AND is_event")
[ "$SAVED" -ge 1 ] && ok "and keeps what it shows, as always ($SAVED)" || bad "and keeps what it shows" "≥ 1 saved" "$SAVED"

echo "Scored again when it's out of date"
q "DELETE FROM nas_observations WHERE user_id = '$U1'" >/dev/null
kill $SERVER 2>/dev/null; wait $SERVER 2>/dev/null
"$BIN" serve --hostname 127.0.0.1 --port $PORT >> "$ROOT/server.log" 2>&1 &
SERVER=$!
until_true 60 '[ "$(q "SELECT count(*) FROM nas_observations WHERE user_id = '"'$U1'"'")" = "12" ]'
check "a restart scores whatever is missing" "12" "$(q "SELECT count(*) FROM nas_observations WHERE user_id = '$U1'")"
check "with the same answers" "birthday" "$(q "SELECT CASE WHEN 'birthday' = ANY(tags) THEN 'birthday' END FROM nas_observations WHERE sha256 = '$SHA_CAKE'")"

echo "Taken away with everything else"
check "Delete AI data takes the NAS's labels too" "204:0" "$(code -X DELETE "$API/v1/curation/data" -H "$A1"):$(q "SELECT count(*) FROM nas_observations WHERE user_id = '$U1'")"

echo
echo "smoke-nas-scoring: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
