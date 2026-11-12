#!/bin/bash
# People, asking: with looks on, an unnamed group that is like a named person
# but not enough to fold ("Is this Emma?") carries that question as `maybe`,
# and the owner answers once for the whole group. See PeopleClusterer
# ("Asking", `writeAsks`), PeopleController (`summaries`, `answerMaybe`,
# `merge`) and migration 0041.
#
# What it checks:
#  - looks off (the groups are made this way): no one has a question;
#  - looks on (the server started again): a group in the ask band has `maybe`
#    naming the right person, on the list and on its own summary; Jack, like
#    no one, has no `maybe` key; a group over the fold bar is folded, not
#    asked about; the groups with a question are `suggested` and listed ahead
#    of Jack, who has more days, closest likeness first;
#  - errors: same id 400, an unnamed or unknown named person 404, a path
#    person with a name or "me" 409, another user 404; nothing changes;
#  - no: one rejected row per face of the group for that person, the question
#    gone at once and after later passes, the group neither folded nor asked
#    about them again;
#  - two candidates: asked about the closer, and after a no, the other;
#  - yes: the group is merged into the named person, whose summary comes back
#    with the name unchanged and the group's photos added;
#  - latest word wins: a no, then the owner's merge: the faces are the
#    person's and no rejected row is left for them;
#  - naming a group clears its question;
#  - nothing biometric or numeric in `maybe` (id, name, face only);
#  - more than 18 groups with a question: 18 are suggested, the rest are
#    `more` and keep their `maybe`;
#  - looks off again: a pass clears every question.
#
#   FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-people-asks.sh
#
# Runs its own server and database. The analyzer is a stand-in: each photo's
# faces are made-up vectors around known directions, the same ones every run
# (a face's noise is seeded by its own name, not by the file). No one's real
# face is involved. The photos are noise images made for the run.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"

DB=framestation_people_asks; PORT=8105; API="http://127.0.0.1:$PORT"
export FRAMESTATION_DATABASE_URL="postgres://framestation:x@127.0.0.1:55432/$DB?sslmode=disable"
ROOT="$SCRATCH/people-asks"; rm -rf "$ROOT"; mkdir -p "$ROOT/blobroot/blobs" "$ROOT/files"
ROOT=$(cd "$ROOT" && pwd -P)
export FRAMESTATION_BLOB_ROOT="$ROOT/blobroot"
mkdir -p "$HOME/.framestation-dev/sock"; SOCK="$HOME/.framestation-dev/sock/people-asks-smoke.sock"
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
# (Another SwiftPM instance may be building in Server/; wait for it.)
BUILT=
for _ in $(seq 1 30); do
  if (cd "$SERVER_DIR" && swift build >"$ROOT/build.log" 2>&1); then BUILT=1; break; fi
  grep -q "another instance of SwiftPM" "$ROOT/build.log" || break
  sleep 10
done
[ -n "$BUILT" ] || { echo "server build failed"; tail -20 "$ROOT/build.log"; exit 1; }
BIN="$(cd "$SERVER_DIR" && swift build --show-bin-path)/FrameStationServer"
cli(){ (cd "$SERVER_DIR" && "$BIN" "$@" 2>&1); }
curl -s -o /dev/null "$API/health" && { echo "port $PORT is already in use"; exit 1; }
admin "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1; admin "CREATE DATABASE $DB" >/dev/null

# The stand-in analyzer. $ROOT/plan.json maps a file's SHA-256 to its faces,
# each a token "<who>~<name>": who is a direction, name makes the face's noise
# its own and the same every run. A face is its direction at cosine 0.9995
# plus that noise, so the faces of one group are very tight and a group's
# average is its direction. Directions are columns of one orthonormal basis:
#  emma, frank, jack   three of them, orthogonal;
#  emma-b              Emma's other look, 0.15 from her main one (the look
#                      suite's, but not orthogonal, so it is never "as like
#                      someone else as its own main look" and stays usable);
#  u<k>                0.475 from emma, orthogonal to everything else: the
#                      groups in the ask band;
#  two                 0.482 from emma and 0.462 from frank: in the band for
#                      both, the closer one Emma.
# Worked out with numpy for the exact faces used (20 Emma, 5 Frank, 4 + 5 of
# her other look, 5 per ask group), against the rules (join 0.50, suggest
# 0.40, ask 0.45, fold 0.62, new person 4 faces in 3 files, merge 0.62):
#  - every face of an ask group is at most 0.484 from Emma's main look, 0.45
#    from her average once the other look is in her: under the 0.50 that
#    would join it to her, so the groups form (a face at 0.40–0.50 that
#    didn't would be a question of its own);
#  - an ask group is at 0.472–0.482 from that look (the group's likeness, the
#    largest of average and looks): over the 0.45 that asks by 0.022 or more,
#    far under the 0.62 that folds; at 0.00–0.01 from Frank; "two" is at 0.482
#    from Emma and 0.463 from Frank, over 0.45 for both by 0.013 or more, and
#    0.019 apart;
#  - the groups are 0.23 from one another (under 0.50 and 0.62): none joins or
#    merges with another;
#  - Emma's other look: the 4 faces owner-merged in are 0.15 from her average
#    (under 0.40), the 5 that follow are 0.33 from it (under 0.40, under
#    0.50) so they form a group with looks off, and 0.9998 from the look: a
#    fold with looks on, by far over 0.62, with Frank at 0.00 (margin) and her
#    average the closer one too;
#  - Jack is 0.00 from everyone: no question.
# Photos with many faces (the last test) put each face in its own spot, all
# inside the frame.
cat > "$ROOT/fake.py" <<'PY'
import base64, hashlib, http.server, json, os, socketserver, sys
import numpy as np
sock, plan_path = sys.argv[1:3]
def unit(v): return v / np.linalg.norm(v)
Q, _ = np.linalg.qr(np.random.default_rng(11).standard_normal((128, 40)))
Q = Q.T
AE, TWO_E, TWO_F, C = 0.475, 0.482, 0.462, 0.9995
def direction(who):
    if who == "emma": return Q[0]
    if who == "emma-b": return unit(0.15 * Q[0] + np.sqrt(1 - 0.0225) * Q[1])
    if who == "frank": return Q[2]
    if who == "jack": return Q[3]
    if who == "two":
        return TWO_E * Q[0] + TWO_F * Q[2] + np.sqrt(1 - TWO_E ** 2 - TWO_F ** 2) * Q[34]
    return AE * Q[0] + np.sqrt(1 - AE ** 2) * Q[4 + int(who[1:])]
def face_vector(token):
    rng = np.random.default_rng(int(hashlib.sha256(token.encode()).hexdigest()[:8], 16))
    noise = rng.standard_normal(128)
    target = direction(token.split("~")[0])
    noise = unit(noise - (noise @ target) * target)
    return unit(C * target + np.sqrt(1 - C * C) * noise)
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
        for i, token in enumerate(plan.get(sha, [])):
            x, y = 0.05 + 0.22 * (i % 4), 0.05 + 0.17 * (i // 4)
            faces.append({"box": [x, y, 0.1, 0.1],
                          "landmarks": [x + .02, y + .03, x + .06, y + .03, x + .04, y + .05, x + .03, y + .07, x + .06, y + .07],
                          "score": 0.95, "size": 120, "sharpness": 50.0,
                          "embedding": b64(face_vector(token))})
        scene = b64(unit(np.random.default_rng(int(sha[:8], 16)).standard_normal(768)))
        self.reply({"protocol": 1, "analyzer": 1, "timings": {"totalMS": 1},
                    "models": {"scene": "siglip2-base-patch32-256@0ddb7507cfcb"},
                    "frames": [{"ms": None, "width": 640, "height": 480, "scene": scene, "faces": faces}]})
socketserver.UnixStreamServer(sock, H).serve_forever()
PY
# Reads the people list (or one summary) on stdin.
#   get <id> <expr>      expr on p, the person; ABSENT if not listed
#   before <a> <b>       yes if a is listed ahead of b
#   count <expr>         how many people the expr holds for
#   ids <expr>           their ids, lowercase, in list order
cat > "$ROOT/pl.py" <<'PY'
import sys, json
d = json.load(sys.stdin)["people"]
mode = sys.argv[1]
def find(i): return next((p for p in d if p["id"].lower() == i.lower() or p.get("name") == i), None)
if mode == "get":
    p = find(sys.argv[2])
    print("ABSENT" if p is None else eval(sys.argv[3]))
elif mode == "before":
    ids = [p["id"].lower() for p in d]
    a, b = sys.argv[2].lower(), sys.argv[3].lower()
    print("yes" if a in ids and b in ids and ids.index(a) < ids.index(b) else "no")
elif mode == "count":
    print(sum(1 for p in d if eval(sys.argv[2])))
elif mode == "ids":
    print(" ".join(p["id"].lower() for p in d if eval(sys.argv[2])))
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
stop_server(){ kill $SERVER 2>/dev/null; wait $SERVER 2>/dev/null; }
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
# placed <n>: n faces belong to someone (a pass can run before the last photo's
# faces are in, and then people exist while some faces are still waiting)
placed(){ [ "$(q "SELECT count(*) FROM person_faces WHERE user_id = '$U1' AND state IN ('auto', 'confirmed')")" = "$1" ]; }
analyzed(){ [ "$(q "SELECT count(*) FROM nas_analysis WHERE user_id = '$U1' AND status = 'done'")" = "$1" ]; }
unnamed(){ q "SELECT count(*) FROM people WHERE user_id = '$U1' AND name IS NULL"; }
person_of(){ q "SELECT string_agg(DISTINCT pf.person_id::text, ' ') FROM person_faces pf JOIN assets a ON a.sha256 = pf.sha256 WHERE a.id IN ($1) AND pf.state IN ('auto', 'confirmed')"; }
ids(){ local out=""; for a in "$@"; do out="$out${out:+, }'$a'"; done; echo "$out"; }
PL(){ curl -s "$API/v1/spaces/$P1/people" -H "$A1"; }
pq(){ PL | python3 "$ROOT/pl.py" "$@"; }
photos_of(){ pq get "$1" 'p["photoCount"]'; }
# api <METHOD> <path> <token> [body] → CODE and BODY
api(){
  local out
  if [ -n "${4:-}" ]; then out=$(curl -s -w '\n%{http_code}' -X "$1" "$API$2" -H "Authorization: Bearer $3" -H 'Content-Type: application/json' -d "$4")
  else out=$(curl -s -w '\n%{http_code}' -X "$1" "$API$2" -H "Authorization: Bearer $3"); fi
  CODE=${out##*$'\n'}; BODY=${out%$'\n'*}
}
# answer <group> <named person> true|false [token] [space]
answer(){ api POST "/v1/spaces/${5:-$P1}/people/$1/maybe" "${4:-$T1}" "{\"personID\":\"$2\",\"isPerson\":$3}"; }
haskey(){ python3 -c 'import sys,json; print("yes" if sys.argv[1] in json.loads(sys.stdin.read()) else "no")' "$1"; }
askn(){ q "SELECT count(*) FROM people WHERE user_id = '$U1' AND maybe_id IS NOT NULL"; }
maybe_of(){ q "SELECT coalesce(maybe_id::text, '-') FROM people WHERE id = '$1'"; }
# rejected <person> <assets…>: faces of those photos said not to be the person
rejected(){ local p=$1; shift; q "SELECT count(*) FROM person_faces pf JOIN assets a ON a.sha256 = pf.sha256 WHERE a.id IN ($(ids "$@")) AND pf.person_id = '$p' AND pf.state = 'rejected'"; }
# held <person> <assets…>: faces of those photos that are the person's
held(){ local p=$1; shift; q "SELECT count(*) FROM person_faces pf JOIN assets a ON a.sha256 = pf.sha256 WHERE a.id IN ($(ids "$@")) AND pf.person_id = '$p' AND pf.state IN ('auto', 'confirmed')"; }
# force_pass <canary>: a group's question is wiped by hand, and the owner's
# word that touches the grouping is sent; the question being back means a
# pass has run since.
force_pass(){
  CANARY=$1
  q "UPDATE people SET maybe_id = NULL, maybe_similarity = NULL WHERE id = '$CANARY'" >/dev/null
  api PUT "/v1/spaces/$P1/people/$E" "$T1" '{"name":"Emma"}'
  until_true 40 '[ "$(maybe_of "$CANARY")" != "-" ]'
}

echo "Looks off: Emma, Frank and Jack"
EMMA=(); for i in $(seq 1 20); do EMMA+=("$(photo "emma$i" $((600 + i)) "03-$(printf %02d $i)" "emma~emma$i")"); done
JACK=(); for i in $(seq 1 20); do JACK+=("$(photo "jack$i" $((640 + i)) "04-$(printf %02d $i)" "jack~jack$i")"); done
FRANK=(); for i in 1 2 3 4 5; do FRANK+=("$(photo "frank$i" $((670 + i)) "05-0$i" "frank~frank$i")"); done
until_true 120 '[ "$(q "SELECT count(*) FROM assets WHERE derived_at IS NOT NULL")" = "45" ]'
cli analysis enroll Owner >/dev/null
until_true 150 'analyzed 45'
until_true 60 '[ "$(q "SELECT count(*) FROM people WHERE user_id = '"'$U1'"'")" = "3" ]'
until_true 60 'placed 45'
E=$(person_of "$(ids "${EMMA[0]}")"); F=$(person_of "$(ids "${FRANK[0]}")"); J=$(person_of "$(ids "${JACK[0]}")")
check "three people found" "3" "$(q "SELECT count(*) FROM people WHERE user_id = '$U1'")"
api PUT "/v1/spaces/$P1/people/$E" "$T1" '{"name":"Emma"}'; check "Emma is named" "Emma" "$(echo "$BODY" | jq '["name"]')"
api PUT "/v1/spaces/$P1/people/$F" "$T1" '{"name":"Frank"}'; check "Frank is named" "Frank" "$(echo "$BODY" | jq '["name"]')"
check "Emma is in 20 photos" "20" "$(photos_of Emma)"
check "Frank in 5" "5" "$(photos_of Frank)"
check "Jack is unnamed, in 20 photos" "20 -" "$(photos_of "$J") $(q "SELECT coalesce(name, '-') FROM people WHERE id = '$J'")"

echo "Looks off: Emma's other look is merged in, and more of it form a group"
B1=(); for i in 1 2 3 4; do B1+=("$(photo "bone$i" $((700 + i)) "06-0$i" "emma-b~bone$i")"); done
until_true 90 'analyzed 49'
until_true 60 '[ "$(unnamed)" = "2" ]'
until_true 60 'placed 49'
G1=$(person_of "$(ids "${B1[@]}")")
check "the other look's 4 faces form one new person" "1" "$(echo "$G1" | wc -w | tr -d ' ')"
api POST "/v1/spaces/$P1/people/$E/merge" "$T1" "{\"otherID\":\"$G1\"}"
check "the owner merges them into Emma: 24 photos" "24" "$(echo "$BODY" | jq '["photoCount"]')"
B2=(); for i in 1 2 3 4 5; do B2+=("$(photo "btwo$i" $((710 + i)) "06-1$i" "emma-b~btwo$i")"); done
until_true 90 'analyzed 54'
until_true 60 '[ "$(unnamed)" = "2" ]'
until_true 60 'placed 54'
G2=$(person_of "$(ids "${B2[@]}")")
check "the next 5 form a group of their own" "1" "$(echo "$G2" | wc -w | tr -d ' ')"
check "who isn't Emma" "yes" "$([ -n "$G2" ] && [ "$G2" != "$E" ] && echo yes || echo no)"

echo "Looks off: groups of faces like Emma, but only half-way"
# Four groups with Emma as their one candidate, and one with two.
mkgroup(){ local k=$1 days=$2 var=$3 i; local -a got=()
  for i in 1 2 3 4 5; do got+=("$(photo "g${k}p$i" $((720 + 10 * k + i)) "$days$i" "u$k~g${k}p$i")"); done
  eval "$var=(\"\${got[@]}\")"; }
mkgroup 0 07-0 GYES; mkgroup 1 07-1 GNO; mkgroup 2 08-0 GLATEST; mkgroup 3 08-1 GNAME
GTWO=(); for i in 1 2 3 4 5; do GTWO+=("$(photo "two$i" $((780 + i)) "09-0$i" "two~two$i")"); done
until_true 150 'analyzed 79'
until_true 60 '[ "$(unnamed)" = "7" ]'
until_true 60 'placed 79'
sleep 4
YES=$(person_of "$(ids "${GYES[@]}")"); NO=$(person_of "$(ids "${GNO[@]}")")
LATEST=$(person_of "$(ids "${GLATEST[@]}")"); NAME=$(person_of "$(ids "${GNAME[@]}")"); TWO=$(person_of "$(ids "${GTWO[@]}")")
check "each is one new person (and they are five different ones)" "1 1 1 1 1 5" "$(for g in $YES $NO $LATEST $NAME $TWO; do echo "$g" | wc -w | tr -d ' '; done | tr '\n' ' ')$(printf '%s\n' $YES $NO $LATEST $NAME $TWO | sort -u | wc -l | tr -d ' ')"
check "each in 5 photos" "5 5 5 5 5" "$(for g in $YES $NO $LATEST $NAME $TWO; do photos_of "$g"; done | tr '\n' ' ' | sed 's/ $//')"
check "none is anyone's question yet" "0" "$(askn)"
check "no person has a maybe in the list" "0" "$(pq count '"maybe" in p')"
check "Emma is still in 24 photos, none of those 25 joined her" "24" "$(photos_of Emma)"

echo "Looks on: the server starts again with them"
stop_server; start_server 1
until_true 90 '[ "$(askn)" = "5" ] && [ "$(unnamed)" = "6" ]'
sleep 8
check "five groups are asked about" "5" "$(askn)"
check "the group that folds is gone, into Emma" "0" "$(q "SELECT count(*) FROM people WHERE id = '$G2'")"
check "Emma has her name and all 29 photos" "Emma 29" "$(q "SELECT name FROM people WHERE id = '$E'") $(photos_of Emma)"
check "the folded group's faces are hers" "$E" "$(person_of "$(ids "${B2[@]}")")"
check "the folded group was not asked about anyone" "0" "$(q "SELECT count(*) FROM people WHERE id = '$G2' AND maybe_id IS NOT NULL")"
check "a group in the band: its question names Emma" "$E" "$(maybe_of "$YES")"
check "the group in the band for two: the closer, Emma" "$E" "$(maybe_of "$TWO")"
check "Jack: no question" "-" "$(maybe_of "$J")"
check "Emma and Frank: none" "- -" "$(maybe_of "$E") $(maybe_of "$F")"

echo "The question on the list and on a summary"
for g in $YES $NO $LATEST $NAME $TWO; do
  check "list: ${g:0:8} has maybe → Emma, by name" "Emma $E" "$(pq get "$g" 'p["maybe"]["name"]') $(pq get "$g" 'p["maybe"]["id"].lower()')"
done
check "list: the face key is Emma's own" "$(pq get "$E" 'p["face"]')" "$(pq get "$YES" 'p["maybe"]["face"]')"
check "list: the face isn't none" "yes" "$([ "$(pq get "$YES" 'p["maybe"]["face"]')" != "none" ] && echo yes || echo no)"
api PUT "/v1/spaces/$P1/people/$YES/relation" "$T1" '{"relation":null}'
check "its own summary has maybe → Emma" "Emma $E" "$(echo "$BODY" | jq '["maybe"]["name"]') $(echo "$BODY" | jq '["maybe"]["id"].lower()')"
api PUT "/v1/spaces/$P1/people/$TWO/relation" "$T1" '{"relation":null}'
check "so does the one for two, still Emma" "Emma" "$(echo "$BODY" | jq '["maybe"]["name"]')"
check "list: Jack has no maybe key at all" "False" "$(pq get "$J" '"maybe" in p')"
api PUT "/v1/spaces/$P1/people/$J/relation" "$T1" '{"relation":null}'
check "Jack's summary has no maybe key either" "no" "$(echo "$BODY" | haskey maybe)"
check "Emma's has none" "False" "$(pq get "$E" '"maybe" in p')"
check "only the five unnamed people with a question carry one" "5" "$(pq count '"maybe" in p')"

echo "Tier and order"
for g in $YES $NO $LATEST $NAME $TWO; do
  check "${g:0:8} is suggested" "suggested" "$(pq get "$g" 'p["tier"]')"
done
check "Jack, 20 photos on 20 days with no question, is suggested too" "suggested" "$(pq get "$J" 'p["tier"]')"
check "so he has more days than any of them: 20 against 5" "20 5" "$(q "SELECT count(DISTINCT a.local_captured_at::date) FROM person_faces pf JOIN assets a ON a.sha256 = pf.sha256 WHERE pf.person_id = '$J'") $(q "SELECT count(DISTINCT a.local_captured_at::date) FROM person_faces pf JOIN assets a ON a.sha256 = pf.sha256 WHERE pf.person_id = '$YES'")"
for g in $YES $NO $LATEST $NAME $TWO; do
  check "${g:0:8} is listed ahead of Jack" "yes" "$(PL | python3 "$ROOT/pl.py" before "$g" "$J")"
done
check "they follow the named people" "yes" "$(PL | python3 "$ROOT/pl.py" before "$F" "$YES")"
check "and run closest likeness first" "$(q "SELECT string_agg(id::text, ' ' ORDER BY maybe_similarity DESC) FROM people WHERE user_id = '$U1' AND maybe_id IS NOT NULL")" "$(pq ids '"maybe" in p')"
check "the likeness is over the ask bar and under the fold" "5" "$(q "SELECT count(*) FROM people WHERE user_id = '$U1' AND maybe_similarity >= 0.45 AND maybe_similarity < 0.62")"

echo "Nothing biometric, no likeness"
LIST=$(PL)
check "maybe holds only id, name and face" "['face', 'id', 'name']" "$(echo "$LIST" | python3 -c 'import sys,json; print(sorted(set(k for p in json.load(sys.stdin)["people"] if "maybe" in p for k in p["maybe"])))')"
check "no likeness, embedding or vector in the list" "0" "$(echo "$LIST" | grep -ciE 'similarity|embedding|vector|cosine|maybe_')"
check "nor in a summary" "0" "$(echo "$BODY" | grep -ciE 'similarity|embedding|vector|cosine|maybe_')"
api PUT "/v1/spaces/$P1/people/$YES/relation" "$T1" '{"relation":null}'
check "nor in a summary with a question" "0" "$(echo "$BODY" | grep -ciE 'similarity|embedding|vector|cosine|maybe_')"

echo "Errors"
read -r T2 P2 U2 <<< "$(newuser Other)"
answer "$NAME" "$NAME" false; check "the same id: 400" "400" "$CODE"
answer "$NAME" "$NAME" true; check "the same id, yes: 400" "400" "$CODE"
answer "$NAME" "$J" false; check "an unnamed person to ask about: 404" "404" "$CODE"
answer "$NAME" "$(uuidgen)" false; check "a person who isn't anyone's: 404" "404" "$CODE"
answer "$(uuidgen)" "$E" false; check "a path person who isn't anyone's: 404" "404" "$CODE"
answer "$E" "$F" false; check "a path person with a name: 409" "409" "$CODE"
api PUT "/v1/spaces/$P1/people/$J/me" "$T1" '{"isMe":true}'
answer "$J" "$E" false; check "a path person who is me: 409" "409" "$CODE"
api PUT "/v1/spaces/$P1/people/$J/me" "$T1" '{"isMe":false}'
check "(and Jack is put back: unnamed, not me)" "f -" "$(q "SELECT is_me FROM people WHERE id = '$J'") $(q "SELECT coalesce(name, '-') FROM people WHERE id = '$J'")"
api GET "/v1/spaces/$P1/people" "$T2"; check "another user: the list is 404" "404" "$CODE"
answer "$NAME" "$E" false "$T2"; check "another user: the answer is 404" "404" "$CODE"
answer "$NAME" "$E" true "$T2"; check "another user: a yes is 404" "404" "$CODE"
answer "$NAME" "$E" false "$T2" "$P2"; check "another user in their own space: 404" "404" "$CODE"
check "no error changed anything: five questions, nothing rejected" "5 0" "$(askn) $(q "SELECT count(*) FROM person_faces WHERE state = 'rejected'")"
check "and the group is as it was" "$E" "$(maybe_of "$NAME")"

echo "No"
answer "$NO" "$E" false
check "the answer is a 200" "200" "$CODE"
check "it's the group's summary" "$NO" "$(echo "$BODY" | jq '["id"].lower()')"
check "without maybe" "no" "$(echo "$BODY" | haskey maybe)"
check "still unnamed" "None" "$(echo "$BODY" | jq '.get("name")')"
check "Emma has a rejected row for each of its 5 faces" "5" "$(rejected "$E" "${GNO[@]}")"
check "and only those" "5" "$(q "SELECT count(*) FROM person_faces WHERE person_id = '$E' AND state = 'rejected'")"
check "the group's faces are still its own" "$NO" "$(person_of "$(ids "${GNO[@]}")")"
check "the question is gone at once" "-" "$(maybe_of "$NO")"
check "from the list too" "False" "$(pq get "$NO" '"maybe" in p')"
check "and the others' questions stand" "4" "$(askn)"
force_pass "$NAME"
force_pass "$NAME"
check "after two more passes the question is still gone" "-" "$(maybe_of "$NO")"
check "from the list" "False" "$(pq get "$NO" '"maybe" in p')"
check "the group is not Emma's: still its own, still unnamed" "$NO -" "$(person_of "$(ids "${GNO[@]}")") $(q "SELECT coalesce(name, '-') FROM people WHERE id = '$NO'")"
check "and she holds none of its faces" "0" "$(held "$E" "${GNO[@]}")"
check "the rejected rows are all still there" "5" "$(rejected "$E" "${GNO[@]}")"
check "the others' questions were set again by those passes" "4" "$(askn)"

echo "Two candidates"
answer "$TWO" "$E" false
check "no to the closer, Emma: 200 and no maybe" "200 no" "$CODE $(echo "$BODY" | haskey maybe)"
check "5 more rejected rows for Emma" "5" "$(rejected "$E" "${GTWO[@]}")"
until_true 40 '[ "$(maybe_of "$TWO")" = "$F" ]'
check "a later pass asks about the other, Frank" "$F" "$(maybe_of "$TWO")"
check "the list says so" "Frank" "$(pq get "$TWO" 'p["maybe"]["name"]')"
force_pass "$NAME"
check "and it stays Frank, not Emma again" "$F" "$(maybe_of "$TWO")"
check "Frank holds none of its faces" "0" "$(held "$F" "${GTWO[@]}")"

echo "Yes"
BEFORE=$(photos_of Emma)
answer "$YES" "$E" true
check "the answer is a 200" "200" "$CODE"
check "it's Emma's summary" "$E" "$(echo "$BODY" | jq '["id"].lower()')"
check "with her name unchanged" "Emma" "$(echo "$BODY" | jq '["name"]')"
check "and the group's 5 photos added" "$((BEFORE + 5))" "$(echo "$BODY" | jq '["photoCount"]')"
check "the same on the list" "$((BEFORE + 5))" "$(photos_of Emma)"
check "no maybe on Emma" "no" "$(echo "$BODY" | haskey maybe)"
check "the group is gone" "0" "$(q "SELECT count(*) FROM people WHERE id = '$YES'")"
check "gone from the list" "ABSENT" "$(pq get "$YES" 'p["id"]')"
check "its 5 faces are Emma's" "5" "$(held "$E" "${GYES[@]}")"
check "her name in the database is unchanged" "Emma" "$(q "SELECT name FROM people WHERE id = '$E'")"
force_pass "$NAME"
check "after a pass: still Emma's, still gone" "5 0" "$(held "$E" "${GYES[@]}") $(q "SELECT count(*) FROM people WHERE id = '$YES'")"

echo "The latest word wins"
BEFORE=$(photos_of Emma)
answer "$LATEST" "$E" false
check "a no: 5 rejected rows for Emma" "5" "$(rejected "$E" "${GLATEST[@]}")"
check "and she holds none" "0" "$(held "$E" "${GLATEST[@]}")"
api POST "/v1/spaces/$P1/people/$E/merge" "$T1" "{\"otherID\":\"$LATEST\"}"
check "then the owner merges the group into Emma: 200" "200" "$CODE"
check "her photos show it" "$((BEFORE + 5))" "$(echo "$BODY" | jq '["photoCount"]')"
check "the group is gone" "0" "$(q "SELECT count(*) FROM people WHERE id = '$LATEST'")"
check "its faces are hers" "5" "$(held "$E" "${GLATEST[@]}")"
check "no rejected row is left for them" "0" "$(rejected "$E" "${GLATEST[@]}")"
force_pass "$NAME"
check "after a pass: still hers, none rejected" "5 0" "$(held "$E" "${GLATEST[@]}") $(rejected "$E" "${GLATEST[@]}")"
check "the others' no's stand: 10 rejected rows" "10" "$(q "SELECT count(*) FROM person_faces WHERE person_id = '$E' AND state = 'rejected'")"
check "and her photos on the list" "$((BEFORE + 5))" "$(photos_of Emma)"

echo "Naming a group clears its question"
check "the group has one" "$E" "$(maybe_of "$NAME")"
api PUT "/v1/spaces/$P1/people/$NAME" "$T1" '{"name":"Gina"}'
check "named Gina" "Gina" "$(echo "$BODY" | jq '["name"]')"
check "the summary has no maybe" "no" "$(echo "$BODY" | haskey maybe)"
check "the question is gone at once" "-" "$(maybe_of "$NAME")"
force_pass "$TWO"
check "and after a pass" "-" "$(maybe_of "$NAME")"
check "she's listed with no maybe" "Gina False" "$(pq get "$NAME" 'p["name"]') $(pq get "$NAME" '"maybe" in p')"
check "and she's named, not asked about" "named" "$(pq get "$NAME" 'p["tier"]')"
check "Frank's question about the other group stands" "$F" "$(maybe_of "$TWO")"

echo "More questions than room"
# 19 more groups in the ask band, from 5 photos with 19 faces each: with the
# one about Frank, 20 questions for 18 places.
BULK=(); for i in 1 2 3 4 5; do
  faces=(); for k in $(seq 5 23); do faces+=("u$k~g${k}p$i"); done
  BULK+=("$(photo "bulk$i" $((800 + i)) "10-0$i" "${faces[@]}")")
done
until_true 150 'analyzed 84'
until_true 90 '[ "$(askn)" = "20" ]'
until_true 60 'placed 174'
sleep 6
check "19 new groups, 20 questions in all" "20 22" "$(askn) $(unnamed)"
check "18 with a question are suggested" "18" "$(pq count 'p.get("tier") == "suggested" and "maybe" in p')"
check "18 suggested in all: no unnamed person past the limit" "18" "$(pq count 'p.get("tier") == "suggested"')"
check "the 2 left over are 'more', and keep their maybe" "2" "$(pq count 'p.get("tier") == "more" and "maybe" in p')"
check "the 18 are the 18 closest" "$(q "SELECT string_agg(id::text, ' ' ORDER BY maybe_similarity DESC) FROM (SELECT id, maybe_similarity FROM people WHERE user_id = '$U1' AND maybe_id IS NOT NULL ORDER BY maybe_similarity DESC LIMIT 18) s")" "$(pq ids 'p.get("tier") == "suggested" and "maybe" in p')"
check "Jack, with no question, was pushed to 'more'" "more" "$(pq get "$J" 'p["tier"]')"
check "every unnamed person with a question in the list has one" "20" "$(pq count '"maybe" in p')"
check "none of the 18 is the one about Frank (the least like)" "more" "$(pq get "$TWO" 'p["tier"]')"

echo "Looks off: a pass clears every question"
stop_server; start_server
until_true 60 '[ "$(askn)" = "0" ]'
sleep 8
check "no person has a suggestion" "0" "$(q "SELECT count(*) FROM people WHERE maybe_id IS NOT NULL OR maybe_similarity IS NOT NULL")"
check "the list has no maybe" "0" "$(pq count '"maybe" in p')"
check "still none after more passes" "0" "$(askn)"
check "answers still work with looks off: a no is 200" "200" "$(answer "$NO" "$E" false; echo "$CODE")"

echo
echo "smoke-people-asks: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
