#!/bin/bash
# People, looks and folding: the owner names Emma, merges a small group of her
# other look into her, and keeps finding more such groups to merge. See
# PeopleClusterer ("Looks" and "Folding") and NAS-ANALYSIS.md §6–7.
#
# The bug, with looks off: a big person's average face is almost all her main
# look, so new faces of a small look fall below the join bar and start yet
# another unnamed group, however often the owner merges the last one in. With
# looks on, her other look is kept and used, so those faces join her, and a
# group of that look folds into her on its own.
#
# What it checks:
#  - looks off: the other look's faces join no one and form a group; the
#    owner merges it; the next faces of that look form a new group again;
#  - `analysis people-matches` says a pass with looks would fold that group
#    into Emma, and changes nothing;
#  - looks on (the same database, the server started again): the repeat group
#    folds into Emma and her name and photos are intact; one more photo of the
#    other look joins her on its own; the control, Jack, is untouched; later
#    passes find nothing to do;
#  - a group of that look photographed with Emma is not folded into her.
#
#   FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-people-looks.sh
#
# Runs its own server and database. The analyzer is a stand-in: each photo's
# faces are made-up vectors around known directions. No one's real face is
# involved. The photos are noise images made for the run.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"

DB=framestation_people_looks; PORT=8104; API="http://127.0.0.1:$PORT"
export FRAMESTATION_DATABASE_URL="postgres://framestation:x@127.0.0.1:55432/$DB?sslmode=disable"
ROOT="$SCRATCH/people-looks"; rm -rf "$ROOT"; mkdir -p "$ROOT/blobroot/blobs" "$ROOT/files"
ROOT=$(cd "$ROOT" && pwd -P)
export FRAMESTATION_BLOB_ROOT="$ROOT/blobroot"
mkdir -p "$HOME/.framestation-dev/sock"; SOCK="$HOME/.framestation-dev/sock/people-looks-smoke.sock"
export FRAMESTATION_ANALYZER_SOCKET="$SOCK" FRAMESTATION_ANALYSIS_START_DELAY=1 FRAMESTATION_ANALYSIS_IDLE=2
export FRAMESTATION_PEOPLE_START_DELAY=2 FRAMESTATION_PEOPLE_INTERVAL=3 FRAMESTATION_PEOPLE_SETTLE=0
unset FRAMESTATION_PEOPLE_LOOKS
PASS=0; FAIL=0
q(){ psql -h 127.0.0.1 -p 55432 -U framestation -d $DB -tAqc "$1"; }
admin(){ psql -h 127.0.0.1 -p 55432 -U framestation -d postgres -tAqc "$1"; }
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; echo "      expected: $2"; echo "      actual:   $3"; FAIL=$((FAIL+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
has(){ case "$3" in *"$2"*) ok "$1";; *) bad "$1" "contains '$2'" "$3";; esac; }
jq(){ python3 -c "import sys,json; print(json.load(sys.stdin)$1)" 2>/dev/null; }
until_true(){ local n=$1; shift; for _ in $(seq 1 "$n"); do eval "$@" && return 0; sleep 1; done; return 1; }

"$SERVER_DIR/../Analyzer/dev.sh" setup >/dev/null || { echo "analyzer setup failed"; exit 1; }
PY="$HOME/.framestation-dev/analyzer/venv/bin/python"
(cd "$SERVER_DIR" && swift build >/dev/null 2>&1) || { echo "server build failed"; exit 1; }
BIN="$(cd "$SERVER_DIR" && swift build --show-bin-path)/FrameStationServer"
cli(){ (cd "$SERVER_DIR" && "$BIN" "$@" 2>&1); }
curl -s -o /dev/null "$API/health" && { echo "port $PORT is already in use"; exit 1; }
admin "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1; admin "CREATE DATABASE $DB" >/dev/null

# The stand-in analyzer. $ROOT/plan.json maps a file's SHA-256 to its faces,
# each "emma" (her main look), "emma-b" (her other look) or "jack". A face is
# its direction at cosine 0.95 plus noise of its own, so the faces of one look
# are a tight group (0.92–0.94 to their own average). The other look is
# orthogonal to the main one. Worked out with numpy over 2,000 random runs, at
# 20 main-look faces and 4 faces of the other look:
#  - a first-group face of the other look is at -0.03 to 0.10 from Emma's
#    average: far under the 0.40 that would ask "Is this Emma?";
#  - after the owner merges those 4 in, a new face of the other look is at
#    0.13–0.30 from her average (16–20 of 24 faces are the main look), always
#    under the 0.50 join bar by 0.2 or more: the repeat;
#  - the repeat group, 5 faces, is at 0.97–0.99 from the merged-in look, far
#    over the 0.62 fold bar, and at 0.13–0.30 from her average, so by average
#    alone a report leaves it;
#  - one more face of that look is at 0.94–0.95 from the look (over 0.50),
#    and 0.30–0.47 from her average (under 0.50), so only looks join it.
cat > "$ROOT/fake.py" <<'PY'
import base64, hashlib, http.server, json, os, socketserver, sys
import numpy as np
sock, plan_path = sys.argv[1:3]
def unit(v): return v / np.linalg.norm(v)
emma = unit(np.random.default_rng(1).standard_normal(128))
other = np.random.default_rng(4).standard_normal(128)
people = {"emma": emma, "emma-b": unit(other - (other @ emma) * emma),
          "jack": unit(np.random.default_rng(2).standard_normal(128))}
def face_vector(who, seed):
    rng = np.random.default_rng(seed)
    noise = rng.standard_normal(128)
    target = people[who]
    noise = unit(noise - (noise @ target) * target)
    c = 0.95
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
SERVER=
trap 'kill $SERVER $ANALYZER 2>/dev/null; wait $SERVER $ANALYZER 2>/dev/null; rm -rf "$ROOT/files" "$ROOT/blobroot" "$SOCK"; admin "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1' EXIT
# start_server [FRAMESTATION_PEOPLE_LOOKS value, if any]
start_server(){
  if [ -n "${1:-}" ]; then FRAMESTATION_PEOPLE_LOOKS=$1 "$BIN" serve --hostname 127.0.0.1 --port $PORT >> "$ROOT/server.log" 2>&1 &
  else "$BIN" serve --hostname 127.0.0.1 --port $PORT >> "$ROOT/server.log" 2>&1 &
  fi
  SERVER=$!
  until_true 60 'curl -s -o /dev/null "$API/health"' || { echo "server didn't start"; tail -20 "$ROOT/server.log"; exit 1; }
}
start_server

newuser(){ local c; c=$(cli invite | grep "Invite code:" | awk '{print $3}')
  curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
    -d "{\"code\":\"$c\",\"displayName\":\"$1\",\"deviceName\":\"$1-phone\",\"platform\":\"ios\"}" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["token"],d["personalSpace"]["id"],d["user"]["id"])'; }
read -r T1 P1 U1 <<< "$(newuser Owner)"
A1="Authorization: Bearer $T1"

# photo <name> <width> <day> <faces…> → asset id, with the plan recorded.
photo(){
  local name=$1 width=$2 day=$3; shift 3
  local f="$ROOT/files/$name.jpg" sha size up w="$ROOT/files"
  vips gaussnoise "$w/n.v" "$width" 480 >/dev/null 2>&1; vips copy "$w/n.v" "$f" >/dev/null 2>&1
  sha=$(shasum -a 256 "$f" | awk '{print $1}'); size=$(stat -f%z "$f")
  python3 -c "import json,os,sys; p=sys.argv[1]; d=json.load(open(p)) if os.path.exists(p) else {}; d[sys.argv[2]]=sys.argv[3:]; json.dump(d, open(p,'w'))" "$ROOT/plan.json" "$sha" "$@"
  up=$(curl -s -X POST "$API/v1/uploads/probe" -H "$A1" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$P1\",\"sha256\":\"$sha\",\"byteSize\":$size,\"filename\":\"$name.jpg\",\"isAutomaticBackup\":false}" | jq '["uploadID"]')
  curl -s -X PUT "$API/v1/uploads/$up/chunk/0" -H "$A1" --data-binary "@$f" >/dev/null
  curl -s -X POST "$API/v1/uploads/$up/commit" -H "$A1" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$P1\",\"mediaType\":\"photo\",\"mime\":\"image/jpeg\",\"width\":$width,\"height\":480,\"capturedAt\":\"2025-${day}T12:$(printf %02d $((width % 60))):00Z\",\"capturedTZOffset\":0,\"isRaw\":false,\"burstPick\":false}" | jq '["assetID"]'
}
analyzed(){ [ "$(q "SELECT count(*) FROM nas_analysis WHERE user_id = '$U1' AND status = 'done'")" = "$1" ]; }
# A person's photos, by name, or the one unnamed person's by id.
photos_of(){ curl -s "$API/v1/spaces/$P1/people" -H "$A1" | python3 -c 'import sys,json; print(" ".join(str(p["photoCount"]) for p in json.load(sys.stdin)["people"] if p.get("name") == sys.argv[1] or p["id"].lower() == sys.argv[1].lower()))' "$1"; }
unnamed(){ q "SELECT count(*) FROM people WHERE user_id = '$U1' AND name IS NULL"; }
person_of(){ q "SELECT string_agg(DISTINCT pf.person_id::text, ' ') FROM person_faces pf JOIN assets a ON a.sha256 = pf.sha256 WHERE a.id IN ($1) AND pf.state IN ('auto', 'confirmed')"; }
ids(){ local out=""; for a in "$@"; do out="$out${out:+, }'$a'"; done; echo "$out"; }
grouping_lines(){ grep -c "people: .* faces placed" "$ROOT/server.log"; }
tables(){ q "SELECT md5(coalesce((SELECT string_agg(person_id::text || sha256 || ordinal || state, ',' ORDER BY person_id, sha256, ordinal) FROM person_faces), '')) || '/' || md5(coalesce((SELECT string_agg(id::text || coalesce(name, '-'), ',' ORDER BY id) FROM people), ''))"; }

echo "Emma's main look, and Jack"
EMMA=(); for i in $(seq 1 20); do EMMA+=("$(photo "emma$i" $((600 + i)) "03-$(printf %02d $i)" emma)"); done
JACK=(); for i in 1 2 3 4 5; do JACK+=("$(photo "jack$i" $((630 + i)) "04-0${i}" jack)"); done
until_true 90 '[ "$(q "SELECT count(*) FROM assets WHERE derived_at IS NOT NULL")" = "25" ]'
cli analysis enroll Owner >/dev/null
until_true 120 'analyzed 25'
until_true 60 '[ "$(q "SELECT count(*) FROM people WHERE user_id = '"'$U1'"'")" = "2" ]'
E=$(person_of "$(ids "${EMMA[0]}")"); J=$(person_of "$(ids "${JACK[0]}")")
check "two people found: 20 photos and 5" "2" "$(q "SELECT count(*) FROM people WHERE user_id = '$U1'")"
check "Emma is named" "Emma" "$(curl -s -X PUT "$API/v1/spaces/$P1/people/$E" -H "$A1" -H 'Content-Type: application/json' -d '{"name":"Emma"}' | jq '["name"]')"
check "she's in 20 photos" "20" "$(photos_of Emma)"
check "Jack is a different person, unnamed, in 5" "5" "$(photos_of "$J")"

echo "Looks off: the other look is a group of its own, and the owner merges it"
B1=(); for i in 1 2 3 4; do B1+=("$(photo "bone$i" $((650 + i)) "05-0${i}" emma-b)"); done
until_true 90 'analyzed 29'
until_true 60 '[ "$(unnamed)" = "2" ]'
G1=$(person_of "$(ids "${B1[@]}")")
check "her other look's faces form one new unnamed person" "1" "$(echo "$G1" | wc -w | tr -d ' ')"
check "who isn't Emma or Jack" "yes" "$([ "$G1" != "$E" ] && [ "$G1" != "$J" ] && echo yes || echo no)"
check "and none was even asked about" "0" "$(q "SELECT count(*) FROM person_faces WHERE state = 'suggested'")"
check "the owner says it's Emma: she's in 24 photos" "24" "$(curl -s -X POST "$API/v1/spaces/$P1/people/$E/merge" -H "$A1" -H 'Content-Type: application/json' -d "{\"otherID\":\"$G1\"}" | jq '["photoCount"]')"
check "the group is gone" "0" "$(q "SELECT count(*) FROM people WHERE id = '$G1'")"

echo "Looks off: more of the other look start another group"
B2=(); for i in 1 2 3 4 5; do B2+=("$(photo "btwo$i" $((660 + i)) "06-0${i}" emma-b)"); done
until_true 90 'analyzed 34'
until_true 60 '[ "$(unnamed)" = "2" ]'
sleep 6
G2=$(person_of "$(ids "${B2[@]}")")
check "they form a new unnamed person" "1" "$(echo "$G2" | wc -w | tr -d ' ')"
check "who isn't Emma" "yes" "$([ "$G2" != "$E" ] && [ -n "$G2" ] && echo yes || echo no)"
check "so Emma still has 24 photos" "24" "$(photos_of Emma)"
check "and the new group has its 5" "5" "$(photos_of "$G2")"

echo "The report"
BEFORE=$(tables)
MATCHES=$(cli analysis people-matches Owner 2>&1)
echo "$MATCHES" | sed 's/^/      /'
has "by average, the group is left" "Would fold in 0, ask about 0, leave 2." "$MATCHES"
has "with looks, one group would fold into Emma" "With looks: would fold in 1, ask about 0, leave 1." "$MATCHES"
has "and the real pass says so" "1 folded" "$MATCHES"
has "naming her" "Emma" "$(echo "$MATCHES" | sed -n '/^Folds with looks on/,/^$/p')"
has "and her two looks" "Emma: 2 looks, 0 set aside" "$MATCHES"
check "the report changes nothing" "$BEFORE" "$(tables)"

echo "Looks on: the server starts again with them"
kill $SERVER 2>/dev/null; wait $SERVER 2>/dev/null
start_server 1
until_true 90 '[ "$(unnamed)" = "1" ]'
sleep 4
check "the repeat group folded into Emma" "0" "$(q "SELECT count(*) FROM people WHERE id = '$G2'")"
check "her name is unchanged" "Emma" "$(q "SELECT name FROM people WHERE id = '$E'")"
check "and she's in all 29 photos of both looks" "29" "$(photos_of Emma)"
check "the folded group's faces are hers" "$E" "$(person_of "$(ids "${B2[@]}")")"
check "Jack is untouched: his own, unnamed, in 5" "5 -" "$(photos_of "$J") $(q "SELECT coalesce(name, '-') FROM people WHERE id = '$J'")"

echo "Looks on: one more photo of the other look joins her"
PEOPLE_BEFORE=$(q "SELECT count(*) FROM people WHERE user_id = '$U1'")
B3=$(photo "bthree" 670 "07-01" emma-b)
until_true 90 'analyzed 35'
until_true 60 '[ "$(photos_of Emma)" = "30" ]'
check "she's in 30 photos" "30" "$(photos_of Emma)"
check "by a row of her own, placed by the NAS" "auto" "$(q "SELECT pf.state FROM person_faces pf JOIN assets a ON a.sha256 = pf.sha256 WHERE a.id = '$B3' AND pf.person_id = '$E'")"
check "and no one new was made" "$PEOPLE_BEFORE" "$(q "SELECT count(*) FROM people WHERE user_id = '$U1'")"
check "Jack is still in 5" "5" "$(photos_of "$J")"

echo "Looks on: the passes stop"
sleep 8
LINES1=$(grouping_lines); sleep 9; LINES2=$(grouping_lines)
check "no grouping lines in the log, twice, a few seconds apart" "$LINES1" "$LINES2"
check "the server's log counted the fold" "yes" "$(grep -q "people: .* 1 merged" "$ROOT/server.log" && echo yes || echo no)"

echo "Looks on: the other look in a photo with Emma isn't folded"
# Each photo has Emma's face first, then a face of her other look. The second
# can't join her: it shares a photo frame with a face that already did. The
# four of them form a group, and the fold, which never joins someone to a
# person they were photographed with, leaves it alone.
C=(); for i in 1 2 3 4; do C+=("$(photo "both$i" $((680 + i)) "08-0${i}" emma emma-b)"); done
until_true 90 'analyzed 39'
until_true 60 '[ "$(unnamed)" = "2" ]'
sleep 8
CB=$(q "SELECT string_agg(DISTINCT pf.person_id::text, ' ') FROM person_faces pf JOIN assets a ON a.sha256 = pf.sha256 WHERE a.id IN ($(ids "${C[@]}")) AND pf.ordinal = 1 AND pf.state IN ('auto', 'confirmed')")
check "those four faces are a group of their own" "1" "$(echo "$CB" | wc -w | tr -d ' ')"
check "that isn't Emma" "yes" "$([ -n "$CB" ] && [ "$CB" != "$E" ] && echo yes || echo no)"
check "and is still unnamed, after more passes" "2" "$(unnamed)"
check "Emma's own faces in those photos are hers: she's in 34" "34" "$(photos_of Emma)"

echo
echo "smoke-people-looks: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
