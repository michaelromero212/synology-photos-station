#!/bin/bash
# NAS analysis in shadow mode: the analyzer's view of photos and videos,
# stored by the server and shown to no one. See NAS-ANALYSIS.md.
#
# What it checks:
#  - only an enrolled person's library is read;
#  - faces are sealed, and nothing reaches any endpoint;
#  - the same file gives the same answer twice;
#  - turning curation off, deleting AI data, removing a person, deleting a
#    photo for good and deleting an account all take it away;
#  - an analyzer that's gone, or one that lies, never breaks the server.
#
#   FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-analysis.sh
#
# Runs its own server, database and analyzer (Analyzer/dev.sh).
# - Photos are copied read-only from the dev library, so there are real faces
#   to find. Only pass/fail lines and counts are printed, never what any photo
#   shows.
# - The video is a test pattern made for the run.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/bin:$PATH"

DB=framestation_analysis; PORT=8101; API="http://127.0.0.1:$PORT"
export FRAMESTATION_DATABASE_URL="postgres://framestation:x@127.0.0.1:55432/$DB?sslmode=disable"
ROOT="$SCRATCH/analysis"; rm -rf "$ROOT"; mkdir -p "$ROOT/blobroot/blobs" "$ROOT/files"
ROOT=$(cd "$ROOT" && pwd -P)
export FRAMESTATION_BLOB_ROOT="$ROOT/blobroot"
# A Unix socket's path is capped at 104 bytes on macOS, which a scratch
# directory can exceed, so it lives with the dev stack's other sockets.
mkdir -p "$HOME/.framestation-dev/sock"; SOCK="$HOME/.framestation-dev/sock/analysis-smoke.sock"
export FRAMESTATION_ANALYZER_SOCKET="$SOCK" FRAMESTATION_ANALYSIS_START_DELAY=1 FRAMESTATION_ANALYSIS_IDLE=2
PASS=0; FAIL=0
q(){ psql -h 127.0.0.1 -p 55432 -U framestation -d $DB -tAqc "$1"; }
admin(){ psql -h 127.0.0.1 -p 55432 -U framestation -d postgres -tAqc "$1"; }
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; echo "      expected: $2"; echo "      actual:   $3"; FAIL=$((FAIL+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
has(){ case "$3" in *"$2"*) ok "$1";; *) bad "$1" "contains '$2'" "$3";; esac; }
lacks(){ case "$3" in *"$2"*) bad "$1" "no '$2'" "(found)";; *) ok "$1";; esac; }
jq(){ python3 -c "import sys,json; print(json.load(sys.stdin)$1)" 2>/dev/null; }
code(){ curl -s -o /dev/null -w '%{http_code}' "$@"; }
# until <seconds> <command…>: retries a check once a second.
until_true(){ local n=$1; shift; for _ in $(seq 1 "$n"); do eval "$@" && return 0; sleep 1; done; return 1; }

"$REPO/Analyzer/dev.sh" setup >/dev/null || { echo "analyzer setup failed"; exit 1; }
(cd "$SERVER_DIR" && swift build >/dev/null 2>&1) || { echo "server build failed"; exit 1; }
BIN="$(cd "$SERVER_DIR" && swift build --show-bin-path)/FrameStationServer"
cli(){ (cd "$SERVER_DIR" && "$BIN" "$@" 2>&1); }
curl -s -o /dev/null "$API/health" && { echo "port $PORT is already in use"; exit 1; }
admin "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1; admin "CREATE DATABASE $DB" >/dev/null

ANALYZER=""; SERVER=""
start_analyzer(){
  rm -f "$SOCK"
  "$REPO/Analyzer/dev.sh" run "$SOCK" "$ROOT/blobroot/blobs" >> "$ROOT/analyzer.log" 2>&1 &
  ANALYZER=$!
  until_true 60 '[ -S "$SOCK" ]' || { echo "analyzer didn't start:"; tail -20 "$ROOT/analyzer.log"; exit 1; }
}
stop_analyzer(){ [ -n "$ANALYZER" ] && kill "$ANALYZER" 2>/dev/null; wait "$ANALYZER" 2>/dev/null; ANALYZER=""; }
start_server(){
  "$BIN" serve --hostname 127.0.0.1 --port $PORT >> "$ROOT/server.log" 2>&1 &
  SERVER=$!
  until_true 60 'curl -s -o /dev/null "$API/health"' || { echo "server didn't start:"; tail -20 "$ROOT/server.log"; exit 1; }
}
stop_server(){ [ -n "$SERVER" ] && kill "$SERVER" 2>/dev/null; wait "$SERVER" 2>/dev/null; SERVER=""; }
# The logs stay for a look after a failure; the files made for the run go,
# and so does the database.
trap 'stop_server; stop_analyzer; rm -rf "$ROOT/files" "$ROOT/blobroot" "$ROOT/fake.py" "$SOCK"; admin "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1' EXIT
start_analyzer
start_server

newuser(){ local c; c=$(cli invite | grep "Invite code:" | awk '{print $3}')
  curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
    -d "{\"code\":\"$c\",\"displayName\":\"$1\",\"deviceName\":\"$1-phone\",\"platform\":\"ios\"}" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["token"],d["personalSpace"]["id"],d["user"]["id"])'; }
read -r T1 P1 U1 <<< "$(newuser Owner)"
read -r T2 P2 U2 <<< "$(newuser Neighbor)"
A1="Authorization: Bearer $T1"; A2="Authorization: Bearer $T2"
[ -n "$P1" ] && [ -n "$P2" ] || { echo "setup failed: no space"; tail -20 "$ROOT/server.log"; exit 1; }

# upload <file> <space> <auth> <photo|video> <mime> <capturedAt> → asset id
upload(){
  local f="$1" sha size probe up chunk n
  sha=$(shasum -a 256 "$f" | awk '{print $1}'); size=$(stat -f%z "$f")
  probe=$(curl -s -X POST "$API/v1/uploads/probe" -H "$3" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$2\",\"sha256\":\"$sha\",\"byteSize\":$size,\"filename\":\"$(basename "$f")\",\"isAutomaticBackup\":false}")
  up=$(echo "$probe" | jq '["uploadID"]'); chunk=$(echo "$probe" | jq '["chunkSize"]')
  for n in $(seq 0 $(( (size - 1) / chunk ))); do
    dd if="$f" bs="$chunk" skip="$n" count=1 2>/dev/null \
      | curl -s -X PUT "$API/v1/uploads/$up/chunk/$n" -H "$3" --data-binary @- >/dev/null
  done
  curl -s -X POST "$API/v1/uploads/$up/commit" -H "$3" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$2\",\"mediaType\":\"$4\",\"mime\":\"$5\",\"width\":640,\"height\":480,\"capturedAt\":\"$6\",\"capturedTZOffset\":0,\"isRaw\":false,\"burstPick\":false}" | jq '["assetID"]'
}
mime_of(){ case "$(echo "${1##*.}" | tr 'A-Z' 'a-z')" in heic|heif) echo image/heic;; *) echo image/jpeg;; esac; }

# Photos from the dev library, read-only, in a fixed order.
DEV_ROOT=$(sed -n 's/^export //; s/^FRAMESTATION_BLOB_ROOT=//p' "$HOME/.framestation-dev/env" 2>/dev/null | tr -d '"' | head -1)
DEV_ROOT="${DEV_ROOT:-$HOME/.framestation-dev}"
PHOTOS=()
while IFS= read -r f; do PHOTOS+=("$f"); done < <(find "$DEV_ROOT/blobs" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.heic' \) -size -15M 2>/dev/null | sort | head -28)
[ "${#PHOTOS[@]}" -ge 28 ] || { echo "the dev library has too few photos (${#PHOTOS[@]})"; exit 1; }

echo "Uploads"
OWNER_IDS=(); i=0
for f in "${PHOTOS[@]:0:24}"; do
  i=$((i+1)); cp "$f" "$ROOT/files/p$i.${f##*.}"
  OWNER_IDS+=("$(upload "$ROOT/files/p$i.${f##*.}" "$P1" "$A1" photo "$(mime_of "$f")" "2025-0$(( i % 9 + 1 ))-1${i: -1}T12:00:00Z")")
done
for f in "${PHOTOS[@]:24:2}"; do
  i=$((i+1)); cp "$f" "$ROOT/files/p$i.${f##*.}"
  upload "$ROOT/files/p$i.${f##*.}" "$P2" "$A2" photo "$(mime_of "$f")" "2025-03-0${i: -1}T12:00:00Z" >/dev/null
done
ffmpeg -loglevel error -f lavfi -i testsrc2=size=640x360:rate=30 -t 12 -c:v libx264 -g 30 -pix_fmt yuv420p "$ROOT/files/clip.mp4" -y
VIDEO=$(upload "$ROOT/files/clip.mp4" "$P1" "$A1" video video/mp4 "2025-10-01T12:00:00Z")
until_true 120 '[ "$(q "SELECT count(*) FROM assets WHERE derived_at IS NOT NULL")" = "27" ]'
check "27 files uploaded and thumbnailed" "27" "$(q "SELECT count(*) FROM assets WHERE derived_at IS NOT NULL")"

echo "Nothing is read until someone is enrolled"
sleep 5
check "no analysis without enrollment" "0" "$(q "SELECT count(*) FROM nas_analysis")"
has "status says nobody is analyzed" "Nobody's library" "$(cli analysis status)"
has "status sees the analyzer" "Analyzer: ready, version 1" "$(cli analysis status)"

echo "Shadow mode for one library"
has "enrolling names the person" "Owner: analyzed by the NAS in shadow mode" "$(cli analysis enroll Owner)"
until_true 180 '[ "$(q "SELECT count(*) FROM nas_analysis WHERE user_id = '"'$U1'"'")" = "25" ]'
check "every photo and the video analyzed" "25" "$(q "SELECT count(*) FROM nas_analysis WHERE user_id = '$U1' AND status = 'done'")"
check "the neighbor's library untouched" "0" "$(q "SELECT count(*) FROM nas_analysis WHERE user_id = '$U2'")"
check "a photo is one frame of 768 numbers" "24" \
  "$(q "SELECT count(*) FROM nas_analysis n JOIN assets a ON a.sha256 = n.sha256 WHERE a.media_type = 'photo' AND n.user_id = '$U1' AND n.frames = 1 AND octet_length(n.scene) = 3072")"
check "a 12-second clip is three keyframes" "3:9216" \
  "$(q "SELECT n.frames || ':' || octet_length(n.scene) FROM nas_analysis n JOIN assets a ON a.sha256 = n.sha256 WHERE a.id = '$VIDEO'")"
has "the models are on record" "face-detector=yunet-2023mar@8f2383e4dd3c" "$(q "SELECT models FROM nas_analysis LIMIT 1")"
has "status shows the progress" "Owner (shadow): 25 of 25 files (100%)" "$(cli analysis status)"

FACES=$(q "SELECT count(*) FROM nas_faces WHERE user_id = '$U1'")
if [ "$FACES" -gt 0 ]; then
  check "faces counted on their rows" "$FACES" "$(q "SELECT sum(face_count) FROM nas_analysis WHERE user_id = '$U1'")"
  check "every embedding is sealed (nonce, 512 bytes, tag)" "$FACES" "$(q "SELECT count(*) FROM nas_faces WHERE octet_length(embedding) = 540")"
  check "boxes and landmarks are fractions of the frame" "$FACES" \
    "$(q "SELECT count(*) FROM nas_faces WHERE array_length(box, 1) = 4 AND array_length(landmarks, 1) = 10 AND 0 <= ALL(box || landmarks) AND 1 >= ALL(box || landmarks)")"
  check "nothing too small to recognize is kept" "0" "$(q "SELECT count(*) FROM nas_faces WHERE size_px < 16")"
  WITH_FACE=$(q "SELECT a.id FROM nas_analysis n JOIN assets a ON a.sha256 = n.sha256 WHERE n.face_count > 0 AND a.media_type = 'photo' ORDER BY a.sha256 LIMIT 1")
else
  echo "  · no faces in this sample of the dev library; the face checks are skipped"
  WITH_FACE="${OWNER_IDS[0]}"
fi
check "the face key is the server's alone" "600" "$(stat -f '%Lp' "$ROOT/blobroot/secrets/face-embeddings.key")"

echo "Same file, same answer"
SHA=$(q "SELECT sha256 FROM assets WHERE id = '$WITH_FACE'")
BEFORE=$(q "SELECT md5(scene) || ':' || face_count FROM nas_analysis WHERE sha256 = '$SHA'")
BOXES=$(q "SELECT string_agg(box::text || landmarks::text, ';' ORDER BY ordinal) FROM nas_faces WHERE sha256 = '$SHA'")
SEALED=$(q "SELECT string_agg(md5(embedding), ';' ORDER BY ordinal) FROM nas_faces WHERE sha256 = '$SHA'")
q "DELETE FROM nas_analysis WHERE sha256 = '$SHA'" >/dev/null
until_true 60 '[ -n "$(q "SELECT 1 FROM nas_analysis WHERE sha256 = '"'$SHA'"'")" ]'
check "the scene vector and face count are identical" "$BEFORE" "$(q "SELECT md5(scene) || ':' || face_count FROM nas_analysis WHERE sha256 = '$SHA'")"
check "and so are the boxes and landmarks" "$BOXES" "$(q "SELECT string_agg(box::text || landmarks::text, ';' ORDER BY ordinal) FROM nas_faces WHERE sha256 = '$SHA'")"
if [ "$FACES" -gt 0 ]; then
  NOW=$(q "SELECT string_agg(md5(embedding), ';' ORDER BY ordinal) FROM nas_faces WHERE sha256 = '$SHA'")
  [ "$NOW" != "$SEALED" ] && ok "sealed afresh each time (a new nonce)" || bad "sealed afresh each time" "different ciphertext" "identical"
fi

echo "Nothing reaches an endpoint"
BUCKET=$(curl -s "$API/v1/spaces/$P1/timeline" -H "$A1" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["buckets"][0]["key"] if d.get("buckets") else "")' 2>/dev/null)
OUT="$(curl -s "$API/v1/spaces/$P1/assets/$WITH_FACE/detail" -H "$A1")$(curl -s "$API/v1/spaces/$P1/timeline/$BUCKET" -H "$A1")$(curl -s "$API/v1/spaces/$P1/collections" -H "$A1")$(curl -s "$API/v1/curation" -H "$A1")$(curl -s "$API/v1/spaces/$P1/assets/$WITH_FACE/observation" -H "$A1")"
for word in embedding landmark sharpness nas_ face_count; do lacks "no '$word' in any answer" "$word" "$OUT"; done
lacks "the server log never names a file's path" "$ROOT/blobroot/blobs" "$(cat "$ROOT/server.log")"

echo "When the analyzer goes away"
stop_analyzer
cp "${PHOTOS[26]}" "$ROOT/files/late.${PHOTOS[26]##*.}"
LATE=$(upload "$ROOT/files/late.${PHOTOS[26]##*.}" "$P1" "$A1" photo "$(mime_of "${PHOTOS[26]}")" "2025-11-01T12:00:00Z")
check "the server still answers" "200" "$(code "$API/health")"
check "uploads still work" "200" "$(code "$API/v1/spaces/$P1/assets/$LATE/detail" -H "$A1")"
until_true 30 'grep -q "isn.t answering" "$ROOT/server.log"'
sleep 12
check "it says so once, not on every retry" "1" "$(grep -c "isn't answering" "$ROOT/server.log")"
start_analyzer
LATE_SHA=$(q "SELECT sha256 FROM assets WHERE id = '$LATE'")
until_true 90 '[ "$(q "SELECT status FROM nas_analysis WHERE sha256 = '"'$LATE_SHA'"'")" = "done" ]'
check "and picks up where it left off when it's back" "done" "$(q "SELECT status FROM nas_analysis WHERE sha256 = '$LATE_SHA'")"

echo "An analyzer that lies is not believed"
stop_analyzer
cat > "$ROOT/fake.py" <<'PY'
# A stand-in analyzer. "lie": a scene vector of NaNs. "faces": a valid answer
# with two made-up faces, so storing and sealing is tested without anyone's.
import http.server, json, socketserver, sys, base64, struct, random
mode = sys.argv[2]
def vec(n, value=None):
    rng = random.Random(n)
    return base64.b64encode(struct.pack("<%df" % n, *([value] * n if value is not None else [rng.uniform(-1, 1) for _ in range(n)]))).decode()
face = lambda x: {"box": [x, 0.2, 0.1, 0.15], "landmarks": [x + 0.02, 0.25, x + 0.07, 0.25, x + 0.05, 0.28, x + 0.03, 0.31, x + 0.07, 0.31],
                  "score": 0.93, "size": 120, "sharpness": 42.5, "embedding": vec(128)}
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def address_string(self): return "local"
    def log_message(self, *a): pass
    def reply(self, body):
        data = json.dumps(body).encode(); self.send_response(200)
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        self.reply({"status": "ok", "protocol": 1, "analyzer": 1, "models": {"scene": "fake@0"}, "threads": 1})
    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        frame = {"ms": None, "width": 1280, "height": 960, "faces": []}
        if mode == "lie":
            frame["scene"] = vec(768, float("nan"))
        else:
            frame["scene"] = vec(768); frame["faces"] = [face(0.1), face(0.6)]
        self.reply({"protocol": 1, "analyzer": 1, "models": {"scene": "fake@0"}, "timings": {"totalMS": 1}, "frames": [frame]})
socketserver.UnixStreamServer(sys.argv[1], H).serve_forever()
PY
fake(){ stop_analyzer; rm -f "$SOCK"; python3 "$ROOT/fake.py" "$SOCK" "$1" >> "$ROOT/analyzer.log" 2>&1 & ANALYZER=$!; until_true 20 '[ -S "$SOCK" ]'; }
fake lie
cp "${PHOTOS[25]}" "$ROOT/files/lie.${PHOTOS[25]##*.}"
LIE=$(upload "$ROOT/files/lie.${PHOTOS[25]##*.}" "$P1" "$A1" photo "$(mime_of "${PHOTOS[25]}")" "2025-11-02T12:00:00Z")
LIE_SHA=$(q "SELECT sha256 FROM assets WHERE id = '$LIE'")
until_true 90 '[ -n "$(q "SELECT 1 FROM nas_analysis WHERE sha256 = '"'$LIE_SHA'"' AND user_id = '"'$U1'"'")" ]'
check "a vector that isn't numbers is refused" "failed:malformed:" \
  "$(q "SELECT status || ':' || error || ':' || coalesce(octet_length(scene)::text, '') FROM nas_analysis WHERE sha256 = '$LIE_SHA' AND user_id = '$U1'")"

echo "Faces are sealed before they're stored"
fake faces
cp "${PHOTOS[27]}" "$ROOT/files/faces.${PHOTOS[27]##*.}"
FACED=$(upload "$ROOT/files/faces.${PHOTOS[27]##*.}" "$P1" "$A1" photo "$(mime_of "${PHOTOS[27]}")" "2025-11-03T12:00:00Z")
FACED_SHA=$(q "SELECT sha256 FROM assets WHERE id = '$FACED'")
until_true 90 '[ -n "$(q "SELECT 1 FROM nas_analysis WHERE sha256 = '"'$FACED_SHA'"' AND user_id = '"'$U1'"'")" ]'
check "two faces on the row and two rows" "2:2" \
  "$(q "SELECT face_count || ':' || (SELECT count(*) FROM nas_faces WHERE sha256 = '$FACED_SHA') FROM nas_analysis WHERE sha256 = '$FACED_SHA'")"
check "each sealed: nonce, 512 bytes, tag" "2" "$(q "SELECT count(*) FROM nas_faces WHERE sha256 = '$FACED_SHA' AND octet_length(embedding) = 540")"
check "box, landmarks, score and size kept" "{0.1,0.2,0.1,0.15}:10:0.93:120:" \
  "$(q "SELECT box::text || ':' || array_length(landmarks, 1) || ':' || score || ':' || size_px || ':' || coalesce(frame_ms::text, '') FROM nas_faces WHERE sha256 = '$FACED_SHA' AND ordinal = 0")"
has "the stored faces open with the server's key" "Owner: 2 of 2 faces open" "$(cli analysis verify Owner)"
q "UPDATE nas_faces SET embedding = (SELECT embedding FROM nas_faces WHERE sha256 = '$FACED_SHA' AND ordinal = 0) WHERE sha256 = '$FACED_SHA' AND ordinal = 1" >/dev/null
has "a sealed face moved to another row won't open" "Owner: 1 of 2 faces open" "$(cli analysis verify Owner)"
stop_analyzer; start_analyzer

echo "Switches and deletion"
curl -s -X PUT "$API/v1/curation/settings" -H "$A1" -H 'Content-Type: application/json' -d '{"enabled":false}' >/dev/null
q "DELETE FROM nas_analysis WHERE sha256 = '$LATE_SHA'" >/dev/null
sleep 6
check "curation off: nothing new is analyzed" "0" "$(q "SELECT count(*) FROM nas_analysis WHERE sha256 = '$LATE_SHA'")"
curl -s -X PUT "$API/v1/curation/settings" -H "$A1" -H 'Content-Type: application/json' -d '{"enabled":true}' >/dev/null
until_true 60 '[ -n "$(q "SELECT 1 FROM nas_analysis WHERE sha256 = '"'$LATE_SHA'"'")" ]'
check "curation back on: it carries on" "done" "$(q "SELECT status FROM nas_analysis WHERE sha256 = '$LATE_SHA'")"

# Off first, as a person would, so nothing is analyzed again in between.
curl -s -X PUT "$API/v1/curation/settings" -H "$A1" -H 'Content-Type: application/json' -d '{"enabled":false}' >/dev/null
sleep 3
check "Delete AI data answers" "204" "$(code -X DELETE "$API/v1/curation/data" -H "$A1")"
check "and takes every analysis with it" "0:0" \
  "$(q "SELECT (SELECT count(*) FROM nas_analysis WHERE user_id = '$U1') || ':' || (SELECT count(*) FROM nas_faces WHERE user_id = '$U1')")"
curl -s -X PUT "$API/v1/curation/settings" -H "$A1" -H 'Content-Type: application/json' -d '{"enabled":true}' >/dev/null

# Deleted for good: removed, purged, and then the next sweep (one runs as
# the server starts) takes its analysis.
until_true 120 '[ "$(q "SELECT count(*) FROM nas_analysis WHERE user_id = '"'$U1'"' AND status = '"'done'"'")" -ge 27 ]'
GONE_SHA=$(q "SELECT sha256 FROM assets WHERE id = '${OWNER_IDS[1]}'")
check "a photo can be removed" "204" "$(code -X DELETE "$API/v1/spaces/$P1/assets/${OWNER_IDS[1]}" -H "$A1")"
curl -s -X POST "$API/v1/spaces/$P1/collections/deleted/purge" -H "$A1" -H 'Content-Type: application/json' \
  -d "{\"assetIDs\":[\"${OWNER_IDS[1]}\"]}" >/dev/null
stop_server; start_server
until_true 30 '[ "$(q "SELECT count(*) FROM nas_analysis WHERE sha256 = '"'$GONE_SHA'"'")" = "0" ]'
check "deleted for good, its analysis goes too" "0" "$(q "SELECT count(*) FROM nas_analysis WHERE sha256 = '$GONE_SHA'")"

has "removing a person says how much went" "Owner: no longer analyzed by the NAS" "$(cli analysis remove Owner)"
check "and leaves nothing behind" "off:0:0" \
  "$(q "SELECT nas_analysis || ':' || (SELECT count(*) FROM nas_analysis WHERE user_id = '$U1') || ':' || (SELECT count(*) FROM nas_faces WHERE user_id = '$U1') FROM users WHERE id = '$U1'")"

cli analysis enroll Neighbor >/dev/null
until_true 90 '[ "$(q "SELECT count(*) FROM nas_analysis WHERE user_id = '"'$U2'"'")" = "2" ]'
check "the neighbor, once enrolled, is analyzed" "2" "$(q "SELECT count(*) FROM nas_analysis WHERE user_id = '$U2'")"
check "deleting an account answers" "204" "$(code -X DELETE "$API/v1/me" -H "$A2")"
check "and takes their analysis with it" "0:off" \
  "$(q "SELECT (SELECT count(*) FROM nas_analysis WHERE user_id = '$U2') || ':' || nas_analysis FROM users WHERE id = '$U2'")"

echo
echo "smoke-analysis: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
