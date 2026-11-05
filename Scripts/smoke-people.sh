#!/bin/bash
# People: the NAS groups the faces in an owner's library into the people in
# it, the owner names them, and their word is final. See NAS-ANALYSIS.md §6
# and PeopleClusterer.
#
# What it checks:
#  - two people are found, and strangers in one photo each aren't anyone;
#  - two faces in one photo stay two people;
#  - a name sticks;
#  - a borderline face becomes "Is this …?", and yes and no both stick;
#  - "Not this person" sticks, and merging joins two people;
#  - someone's photos come newest first, a page at a time;
#  - face pictures are served, only to the owner;
#  - Delete AI data takes it all.
#
#   FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-people.sh
#
# Runs its own server and database. The analyzer is a stand-in: each photo's
# faces are made-up vectors around one of two people, or a stranger, so who
# is who is known in advance. No one's real face is involved. The photos are
# noise images made for the run.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"

DB=framestation_people; PORT=8103; API="http://127.0.0.1:$PORT"
export FRAMESTATION_DATABASE_URL="postgres://framestation:x@127.0.0.1:55432/$DB?sslmode=disable"
ROOT="$SCRATCH/people"; rm -rf "$ROOT"; mkdir -p "$ROOT/blobroot/blobs" "$ROOT/files"
ROOT=$(cd "$ROOT" && pwd -P)
export FRAMESTATION_BLOB_ROOT="$ROOT/blobroot"
mkdir -p "$HOME/.framestation-dev/sock"; SOCK="$HOME/.framestation-dev/sock/people-smoke.sock"
export FRAMESTATION_ANALYZER_SOCKET="$SOCK" FRAMESTATION_ANALYSIS_START_DELAY=1 FRAMESTATION_ANALYSIS_IDLE=2
export FRAMESTATION_PEOPLE_START_DELAY=2 FRAMESTATION_PEOPLE_INTERVAL=3 FRAMESTATION_PEOPLE_SETTLE=0
# Five to a page, so Emma's eight photos are two pages.
export FRAMESTATION_PERSON_PAGE=5
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

"$SERVER_DIR/../Analyzer/dev.sh" setup >/dev/null || { echo "analyzer setup failed"; exit 1; }
PY="$HOME/.framestation-dev/analyzer/venv/bin/python"
(cd "$SERVER_DIR" && swift build >/dev/null 2>&1) || { echo "server build failed"; exit 1; }
BIN="$(cd "$SERVER_DIR" && swift build --show-bin-path)/FrameStationServer"
cli(){ (cd "$SERVER_DIR" && "$BIN" "$@" 2>&1); }
curl -s -o /dev/null "$API/health" && { echo "port $PORT is already in use"; exit 1; }
admin "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1; admin "CREATE DATABASE $DB" >/dev/null

# The stand-in analyzer. $ROOT/plan.json maps a file's SHA-256 to its faces,
# each "emma", "jack", "near-emma" (about as like Emma as a sibling) or
# "stranger". A face is its person's direction at cosine 0.95 plus noise of
# its own, so each person's faces are a tight group. A sibling-close face is
# at 0.46, which lands 0.457 ± 0.009 from Emma's faces: always inside the
# 0.40–0.50 band where the NAS asks rather than decides. At 0.8 the group's
# own noise moved that by ± 0.02, and one run in a few put a face outside.
cat > "$ROOT/fake.py" <<'PY'
import base64, hashlib, http.server, json, os, socketserver, sys
import numpy as np
sock, plan_path = sys.argv[1:3]
def unit(v): return v / np.linalg.norm(v)
people = {name: unit(np.random.default_rng(seed).standard_normal(128)) for name, seed in (("emma", 1), ("jack", 2))}
def face_vector(who, seed):
    rng = np.random.default_rng(seed)
    noise = rng.standard_normal(128)
    if who == "stranger":
        return unit(noise)
    target = people["emma" if who == "near-emma" else who]
    noise = unit(noise - (noise @ target) * target)
    c = 0.46 if who == "near-emma" else 0.95
    return unit(c * target + np.sqrt(1 - c * c) * noise)
def b64(v): return base64.b64encode(np.asarray(v, dtype="<f4").tobytes()).decode()
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
        plan = json.load(open(plan_path)) if os.path.exists(plan_path) else {}
        faces = []
        for i, who in enumerate(plan.get(sha, [])):
            x = 0.1 + 0.45 * i
            faces.append({"box": [x, 0.2, 0.3, 0.4],
                          "landmarks": [x + .08, .3, x + .2, .3, x + .14, .38, x + .1, .46, x + .2, .46],
                          "score": 0.95, "size": 120, "sharpness": 50.0,
                          "embedding": b64(face_vector(who, int(hashlib.sha256((sha + str(i)).encode()).hexdigest()[:8], 16)))})
        scene = b64(unit(np.random.default_rng(int(sha[:8], 16)).standard_normal(768)))
        self.reply({"protocol": 1, "analyzer": 1, "timings": {"totalMS": 1},
                    "models": {"scene": "siglip2-base-patch32-256@0ddb7507cfcb"},
                    "frames": [{"ms": None, "width": 640, "height": 480, "scene": scene, "faces": faces}]})
socketserver.UnixStreamServer(sock, H).serve_forever()
PY
rm -f "$SOCK"; "$PY" "$ROOT/fake.py" "$SOCK" "$ROOT/plan.json" > "$ROOT/analyzer.log" 2>&1 & ANALYZER=$!
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

# photo <name> <width> <day> <faces…> → asset id, with the plan recorded.
photo(){
  local name=$1 width=$2 day=$3; shift 3
  local f="$ROOT/files/$name.jpg" sha size up
  vips gaussnoise "$ROOT/files/n.v" "$width" 480 >/dev/null 2>&1; vips copy "$ROOT/files/n.v" "$f" >/dev/null 2>&1
  sha=$(shasum -a 256 "$f" | awk '{print $1}'); size=$(stat -f%z "$f")
  python3 -c "import json,os,sys; p=sys.argv[1]; d=json.load(open(p)) if os.path.exists(p) else {}; d[sys.argv[2]]=sys.argv[3:]; json.dump(d, open(p,'w'))" "$ROOT/plan.json" "$sha" "$@"
  up=$(curl -s -X POST "$API/v1/uploads/probe" -H "$A1" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$P1\",\"sha256\":\"$sha\",\"byteSize\":$size,\"filename\":\"$name.jpg\",\"isAutomaticBackup\":false}" | jq '["uploadID"]')
  curl -s -X PUT "$API/v1/uploads/$up/chunk/0" -H "$A1" --data-binary "@$f" >/dev/null
  curl -s -X POST "$API/v1/uploads/$up/commit" -H "$A1" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$P1\",\"mediaType\":\"photo\",\"mime\":\"image/jpeg\",\"width\":$width,\"height\":480,\"capturedAt\":\"2025-${day}T12:00:00Z\",\"capturedTZOffset\":0,\"isRaw\":false,\"burstPick\":false}" | jq '["assetID"]'
}

echo "A library: Emma, Jack, both together, and strangers"
EMMA=(); for i in 1 2 3 4 5 6; do EMMA+=("$(photo "emma$i" $((600 + i)) "03-0${i}" emma)"); done
JACK=(); for i in 1 2 3 4 5; do JACK+=("$(photo "jack$i" $((620 + i)) "04-0${i}" jack)"); done
BOTH=(); for i in 1 2; do BOTH+=("$(photo "both$i" $((640 + i)) "05-0${i}" emma jack)"); done
for i in 1 2 3; do photo "stranger$i" $((660 + i)) "06-0${i}" stranger >/dev/null; done
until_true 60 '[ "$(q "SELECT count(*) FROM assets WHERE derived_at IS NOT NULL")" = "16" ]'
cli analysis enroll Owner >/dev/null
until_true 90 '[ "$(q "SELECT count(*) FROM nas_analysis WHERE user_id = '"'$U1'"'")" = "16" ]'
until_true 60 '[ "$(curl -s "$API/v1/spaces/$P1/people" -H "$A1" | jq '"'"'["people"].__len__()'"'"')" = "2" ]'
PEOPLE=$(curl -s "$API/v1/spaces/$P1/people" -H "$A1")
check "two people found" "2" "$(echo "$PEOPLE" | jq '["people"].__len__()')"
check "in 8 and 7 photos" "8,7" "$(echo "$PEOPLE" | python3 -c 'import sys,json; print(",".join(str(p["photoCount"]) for p in json.load(sys.stdin)["people"]))')"
check "a stranger in one photo isn't anyone" "0" "$(q "SELECT count(*) FROM person_faces pf JOIN assets a ON a.sha256 = pf.sha256 WHERE a.width IN (661, 662, 663)")"
check "two faces in one photo are two people" "2" "$(q "SELECT count(DISTINCT person_id) FROM person_faces pf JOIN assets a ON a.sha256 = pf.sha256 WHERE a.id = '${BOTH[0]}' AND pf.state = 'auto'")"
E=$(q "SELECT pf.person_id FROM person_faces pf JOIN assets a ON a.sha256 = pf.sha256 WHERE a.id = '${EMMA[0]}' LIMIT 1")
J=$(q "SELECT pf.person_id FROM person_faces pf JOIN assets a ON a.sha256 = pf.sha256 WHERE a.id = '${JACK[0]}' LIMIT 1")

echo "Naming"
check "naming answers with the person" "Emma" "$(curl -s -X PUT "$API/v1/spaces/$P1/people/$E" -H "$A1" -H 'Content-Type: application/json' -d '{"name":"  Emma "}' | jq '["name"]')"
has "the page's People row starts with her" "Emma" "$(curl -s "$API/v1/spaces/$P1/collections?date=2026-10-12" -H "$A1" | python3 -c 'import sys,json; print([p.get("name") for p in json.load(sys.stdin)["people"]][0])')"
check "her photos are a collection" "8" "$(curl -s "$API/v1/spaces/$P1/collections/items?kind=person&key=$E" -H "$A1" | jq '["total"]')"
ITEMS=$(curl -s "$API/v1/spaces/$P1/collections/items?kind=person&key=$E" -H "$A1")
check "newest first" "${BOTH[1]}" "$(echo "$ITEMS" | jq '["items"][0]["assetID"]')"
check "a page at a time" "5 5" "$(echo "$ITEMS" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(len(d["items"]), d.get("nextOffset"))')"
check "and the next page is the rest" "3 None ${EMMA[0]}" "$(curl -s "$API/v1/spaces/$P1/collections/items?kind=person&key=$E&offset=5" -H "$A1" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(len(d["items"]), d.get("nextOffset"), d["items"][-1]["assetID"])')"
check "other collections still come whole, oldest first" "None" "$(curl -s "$API/v1/spaces/$P1/collections/items?kind=recentlyAdded&key=30" -H "$A1" | jq '.get("nextOffset")')"
check "her face is a picture" "200 image/jpeg" "$(curl -s -o /dev/null -w '%{http_code} %{content_type}' "$API/v1/spaces/$P1/people/$E/face" -H "$A1")"
check "so is one face in a photo" "200" "$(code "$API/v1/spaces/$P1/assets/${BOTH[0]}/faces/0" -H "$A1")"
check "an unnamed person can't be asked about" "0" "$(curl -s "$API/v1/spaces/$P1/people" -H "$A1" | python3 -c 'import sys,json; print([p["questions"] for p in json.load(sys.stdin)["people"] if p.get("name") is None][0])')"

echo "Is this Emma?"
NEAR1=$(photo "near1" 680 "07-01" near-emma); NEAR2=$(photo "near2" 681 "07-02" near-emma)
until_true 60 '[ "$(curl -s "$API/v1/spaces/$P1/people/$E/suggestions" -H "$A1" | jq '"'"'["suggestions"].__len__()'"'"')" = "2" ]'
S=$(curl -s "$API/v1/spaces/$P1/people/$E/suggestions" -H "$A1")
check "a sibling-close face is a question, not a member" "2" "$(echo "$S" | jq '["suggestions"].__len__()')"
check "the question count is on her card" "2" "$(curl -s "$API/v1/spaces/$P1/people" -H "$A1" | python3 -c 'import sys,json; print([p["questions"] for p in json.load(sys.stdin)["people"] if p.get("name") == "Emma"][0])')"
# Bodies made first: inside "$( … )", bash brace-expands a JSON object's
# commas and sends three words instead of one body.
YES=$(printf '{"assetID":"%s","ordinal":0,"isPerson":true}' "$NEAR1")
NO=$(printf '{"assetID":"%s","ordinal":0,"isPerson":false}' "$NEAR2")
check "yes makes it hers" "9" "$(curl -s -X POST "$API/v1/spaces/$P1/people/$E/suggestions" -H "$A1" -H 'Content-Type: application/json' -d "$YES" | jq '["photoCount"]')"
curl -s -X POST "$API/v1/spaces/$P1/people/$E/suggestions" -H "$A1" -H 'Content-Type: application/json' -d "$NO" >/dev/null
sleep 8
check "no stays no, and yes stays yes" "rejected confirmed" "$(q "SELECT string_agg(state, ' ' ORDER BY a.width DESC) FROM person_faces pf JOIN assets a ON a.sha256 = pf.sha256 WHERE a.id IN ('$NEAR1', '$NEAR2') AND pf.person_id = '$E'")"
check "nothing left to ask" "0" "$(curl -s "$API/v1/spaces/$P1/people/$E/suggestions" -H "$A1" | jq '["suggestions"].__len__()')"

echo "Not this person, and the same person"
check "not Emma takes the photo out" "8" "$(curl -s -X POST "$API/v1/spaces/$P1/people/$E/remove" -H "$A1" -H 'Content-Type: application/json' -d "{\"assetIDs\":[\"${EMMA[5]}\"]}" | jq '["photoCount"]')"
sleep 8
check "and it doesn't come back" "8" "$(curl -s "$API/v1/spaces/$P1/collections/items?kind=person&key=$E" -H "$A1" | jq '["total"]')"
check "the same person: merging joins them (the two together count once)" "Emma:13" "$(curl -s -X POST "$API/v1/spaces/$P1/people/$E/merge" -H "$A1" -H 'Content-Type: application/json' -d "{\"otherID\":\"$J\"}" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("%s:%d" % (d["name"], d["photoCount"]))')"
check "and the other is gone" "0" "$(q "SELECT count(*) FROM people WHERE id = '$J'")"

echo "Only the owner"
check "someone else's library is a 404" "404" "$(code "$API/v1/spaces/$P1/people" -H "$A2")"
check "their own isn't analyzed: 404" "404" "$(code "$API/v1/spaces/$P2/people" -H "$A2")"
check "nor can they name someone" "404" "$(code -X PUT "$API/v1/spaces/$P2/people/$E" -H "$A2" -H 'Content-Type: application/json' -d '{"name":"x"}')"
check "nor see a face" "404" "$(code "$API/v1/spaces/$P1/people/$E/face" -H "$A2")"
check "nor find her photos" "0" "$(curl -s "$API/v1/spaces/$P2/collections/items?kind=person&key=$E" -H "$A2" | jq '["total"]')"
check "their page has no People row" "None" "$(curl -s "$API/v1/spaces/$P2/collections?date=2026-10-12" -H "$A2" | jq '.get("people")')"
lacks "no face numbers in any answer" "embedding" "$(curl -s "$API/v1/spaces/$P1/people" -H "$A1")$(curl -s "$API/v1/spaces/$P1/people/$E/suggestions" -H "$A1")"

echo "Taken away with the AI data"
check "Delete AI data answers" "204" "$(code -X DELETE "$API/v1/curation/data" -H "$A1")"
check "and the people go too" "0:0" "$(q "SELECT (SELECT count(*) FROM people WHERE user_id = '$U1') || ':' || (SELECT count(*) FROM person_faces WHERE user_id = '$U1')")"

echo
echo "smoke-people: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
