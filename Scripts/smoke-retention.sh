#!/bin/bash
# Recently Deleted: a 29-day window the app owns, end to end.
#
# The unit tests cover the day arithmetic and a transaction covered the holder
# check. This covers the part neither can: that deleting through the real
# endpoint puts a photograph in Recently Deleted with a purge date on it, that
# it can still be looked at there (and a video played) but not downloaded,
# that restoring takes it back out, and that the sweeper's own query picks it
# up once it is old enough — against the real schema rather than a
# hand-written one. And that what a person's phone saw in a photo goes once
# no library they're in holds it, and what the NAS's analyzer saw, faces and
# the names given them included, once their own library doesn't: by the pass
# the server makes as it starts and hourly after, with no analyzer set up.
#
#   FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-retention.sh
#
# Runs its own server against its own database and blob store.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"

DB=framestation_retention; PORT=8083; API="http://127.0.0.1:$PORT"
export FRAMESTATION_DATABASE_URL="postgres://framestation:x@127.0.0.1:55432/$DB?sslmode=disable"
ROOT="$SCRATCH/retention"; rm -rf "$ROOT"; mkdir -p "$ROOT/blobroot" "$ROOT/files"
ROOT=$(cd "$ROOT" && pwd -P)
export FRAMESTATION_BLOB_ROOT="$ROOT/blobroot"
PASS=0; FAIL=0
q(){ psql -h 127.0.0.1 -p 55432 -U framestation -d $DB -tAqc "$1"; }
admin(){ psql -h 127.0.0.1 -p 55432 -U framestation -d postgres -tAqc "$1"; }
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; echo "      expected: $2"; echo "      actual:   $3"; FAIL=$((FAIL+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
has(){ case "$3" in *"$2"*) ok "$1";; *) bad "$1" "contains '$2'" "$3";; esac; }
lacks(){ case "$3" in *"$2"*) bad "$1" "no '$2'" "$3";; *) ok "$1";; esac; }
jq(){ python3 -c "import sys,json; print(json.load(sys.stdin)$1)" 2>/dev/null; }

(cd "$SERVER_DIR" && swift build >/dev/null 2>&1) || { echo "server build failed"; exit 1; }
BIN="$(cd "$SERVER_DIR" && swift build --show-bin-path)/FrameStationServer"
# Whatever already answers on this port would be tested in this server's place.
curl -s -o /dev/null "$API/health" && { echo "port $PORT is already in use"; exit 1; }
admin "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1; admin "CREATE DATABASE $DB" >/dev/null
# Started again near the end, for the pass the server makes as it starts.
start_server(){
  "$BIN" serve --hostname 127.0.0.1 --port $PORT >> "$ROOT/server.log" 2>&1 &
  SERVER=$!
  for _ in $(seq 1 120); do curl -s -o /dev/null "$API/health" && break; sleep 0.5; done
  curl -s -o /dev/null "$API/health" || { echo "server didn't start:"; tail -20 "$ROOT/server.log"; exit 1; }
}
stop_server(){ kill $SERVER 2>/dev/null; wait $SERVER 2>/dev/null; }
# The log stays for a look after a failure; the files made for the run go.
trap 'stop_server; rm -rf "$ROOT/files" "$ROOT/blobroot"' EXIT
start_server

c=$(cd "$SERVER_DIR" && "$BIN" invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
R=$(curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$c\",\"displayName\":\"Michael\",\"deviceName\":\"iPhone\",\"platform\":\"ios\"}")
T=$(echo "$R" | jq '["token"]'); SP=$(echo "$R" | jq '["personalSpace"]["id"]')
UM=$(echo "$R" | jq '["user"]["id"]')
A="Authorization: Bearer $T"
[ -n "$T" ] || { echo "could not authenticate"; tail -20 "$ROOT/server.log"; exit 1; }
# Someone else on the same NAS, who shares nothing with Michael.
c=$(cd "$SERVER_DIR" && "$BIN" invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
R2=$(curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$c\",\"displayName\":\"Neighbor\",\"deviceName\":\"iPhone\",\"platform\":\"ios\"}")
OTHER="Authorization: Bearer $(echo "$R2" | jq '["token"]')"
SPN=$(echo "$R2" | jq '["personalSpace"]["id"]'); UN=$(echo "$R2" | jq '["user"]["id"]')
# status <auth header> <path> → the HTTP status of a GET
status(){ curl -s -o /dev/null -w '%{http_code}' -H "$1" "$API$2"; }
# binned <asset id> → whether Recently Deleted lists it, as a count
binned(){ curl -s "$API/v1/spaces/$SP/collections/deleted" -H "$A" | python3 -c "import sys,json
print(sum(1 for i in json.load(sys.stdin)['items'] if i['assetID'].lower() == '$1'.lower()))"; }

f="$ROOT/files/IMG_9100.jpg"
vips gaussnoise "$ROOT/files/n.v" 400 300 >/dev/null 2>&1
vips copy "$ROOT/files/n.v" "$f" >/dev/null 2>&1
SHA=$(shasum -a 256 "$f" | awk '{print $1}'); SZ=$(stat -f%z "$f")

UP=$(curl -s -X POST "$API/v1/uploads/probe" -H "$A" -H 'Content-Type: application/json' \
  -d "{\"spaceID\":\"$SP\",\"sha256\":\"$SHA\",\"byteSize\":$SZ,\"filename\":\"IMG_9100.jpg\",\"isAutomaticBackup\":false}" | jq '["uploadID"]')
curl -s -X PUT "$API/v1/uploads/$UP/chunk/0" -H "$A" --data-binary "@$f" >/dev/null
AID=$(curl -s -X POST "$API/v1/uploads/$UP/commit" -H "$A" -H 'Content-Type: application/json' \
  -d "{\"spaceID\":\"$SP\",\"mediaType\":\"photo\",\"mime\":\"image/jpeg\",\"width\":400,\"height\":300,\"isRaw\":false,\"burstPick\":false}" | jq '["assetID"]')
[ -n "$AID" ] || { echo "upload failed"; exit 1; }
echo "asset $AID"

# A second of video, to play from Recently Deleted.
v="$ROOT/files/IMG_9101.mp4"
ffmpeg -v error -y -f lavfi -i "testsrc2=size=320x240:rate=30:duration=1" \
  -c:v libx264 -pix_fmt yuv420p "$v"
VSHA=$(shasum -a 256 "$v" | awk '{print $1}'); VSZ=$(stat -f%z "$v")
UP=$(curl -s -X POST "$API/v1/uploads/probe" -H "$A" -H 'Content-Type: application/json' \
  -d "{\"spaceID\":\"$SP\",\"sha256\":\"$VSHA\",\"byteSize\":$VSZ,\"filename\":\"IMG_9101.mp4\",\"isAutomaticBackup\":false}" | jq '["uploadID"]')
curl -s -X PUT "$API/v1/uploads/$UP/chunk/0" -H "$A" --data-binary "@$v" >/dev/null
VID=$(curl -s -X POST "$API/v1/uploads/$UP/commit" -H "$A" -H 'Content-Type: application/json' \
  -d "{\"spaceID\":\"$SP\",\"mediaType\":\"video\",\"mime\":\"video/mp4\",\"width\":320,\"height\":240,\"durationMs\":1000,\"isRaw\":false,\"burstPick\":false}" | jq '["assetID"]')
[ -n "$VID" ] || { echo "video upload failed"; exit 1; }
# Thumbnails made, so a missing one below means refused rather than not yet.
for _ in $(seq 1 120); do [ "$(q "select count(*) from assets where derived_at is null")" = "0" ] && break; sleep 0.5; done

echo "== before deletion =="
check "not in Recently Deleted" "0" \
  "$(curl -s "$API/v1/spaces/$SP/collections/deleted" -H "$A" | jq '["total"]')"

echo "== deleting =="
curl -s -X DELETE "$API/v1/spaces/$SP/assets/$AID" -H "$A" >/dev/null

check "soft-deleted, not purged" "true|false" \
  "$(q "select (deleted_at is not null)||'|'||(purged_at is not null)
       from space_assets where asset_id='$AID';")"

# The old path moved the blob out from under every other copy of it. It must
# still be exactly where it was.
check "blob untouched by the delete" "1" \
  "$(q "select count(*) from assets where id='$AID' and sha256='$SHA';")"

D=$(curl -s "$API/v1/spaces/$SP/collections/deleted" -H "$A")
check "appears in Recently Deleted" "1" "$(echo "$D" | jq '["total"]')"

# The whole point of the redesign: a date the client can count down to.
P=$(echo "$D" | jq '["items"][0]["purgeAt"]')
[ -n "$P" ] && [ "$P" != "None" ] && ok "carries a purge date ($P)" \
  || bad "carries a purge date" "an ISO date" "$P"

# Rounded, not rounded up: 29 days that span a change of the clocks are an hour
# more or less than 29 times 24 hours, and in October rounding up read 30.
check "29 days out, to the day" "29" \
  "$(q "select round(extract(epoch from (deleted_at + interval '29 days') - now())/86400.0)::int
       from space_assets where asset_id='$AID';")"

echo "== looking before deciding =="
check "its thumbnail still loads" "200" "$(status "$A" "/v1/assets/$AID/thumb?size=256")"
check "and so does its full-size preview" "200" "$(status "$A" "/v1/assets/$AID/preview")"
check "but not its original, until it's put back" "404" "$(status "$A" "/v1/assets/$AID/original")"
check "and someone it was never shared with sees nothing" "404" \
  "$(status "$OTHER" "/v1/assets/$AID/preview")"
curl -s -X DELETE "$API/v1/spaces/$SP/assets/$VID" -H "$A" >/dev/null
LINK=$(curl -s "$API/v1/assets/$VID/playback" -H "$A" | jq '["url"]')
check "a deleted video still gets a link to play" "yes" "$([ -n "$LINK" ] && echo yes || echo no)"
check "and the link plays" "200" "$(curl -s -o /dev/null -w '%{http_code}' "$LINK")"
check "but not for anyone else" "404" "$(status "$OTHER" "/v1/assets/$VID/playback")"

echo "== restoring =="
curl -s -X POST "$API/v1/spaces/$SP/collections/deleted/restore" -H "$A" -H 'Content-Type: application/json' \
  -d "{\"assetIDs\":[\"$AID\"]}" >/dev/null
check "back in the library" "f" \
  "$(q "select (deleted_at is not null) from space_assets where asset_id='$AID';")"
check "gone from Recently Deleted" "0" "$(binned "$AID")"

echo "== past the window =="
curl -s -X DELETE "$API/v1/spaces/$SP/assets/$AID" -H "$A" >/dev/null
q "update space_assets set deleted_at = now() - interval '30 days' where asset_id='$AID';" >/dev/null

check "the sweeper's own query finds it" "1" \
  "$(q "select count(*) from space_assets
        where asset_id='$AID' and deleted_at is not null and purged_at is null
          and deleted_at < now() - interval '29 days';")"

# Restoring something past its window would hand back a photo whose bytes the
# sweeper is about to remove.
q "update space_assets set purged_at = now() where asset_id='$AID';" >/dev/null
curl -s -X POST "$API/v1/spaces/$SP/collections/deleted/restore" -H "$A" -H 'Content-Type: application/json' \
  -d "{\"assetIDs\":[\"$AID\"]}" >/dev/null
check "a purged row cannot be restored" "t" \
  "$(q "select (deleted_at is not null) from space_assets where asset_id='$AID';")"
check "and is hidden from Recently Deleted" "0" "$(binned "$AID")"
check "its preview is gone with it" "404" "$(status "$A" "/v1/assets/$AID/preview")"
q "update space_assets set purged_at = now() where asset_id='$VID';" >/dev/null
check "and a purged video's link plays nothing" "404" "$(curl -s -o /dev/null -w '%{http_code}' "$LINK")"

echo "== what was seen in a photo goes with it =="
# photo <name> → a new JPEG, with bytes unlike any other's
photo(){ local f="$ROOT/files/$1.jpg"
  vips gaussnoise "$ROOT/files/n.v" 400 300 >/dev/null 2>&1; vips copy "$ROOT/files/n.v" "$f" >/dev/null 2>&1
  echo "$f"; }
sha(){ shasum -a 256 "$1" | awk '{print $1}'; }
# send <space> <auth> <file> → the id it has there once uploaded
send(){ local up
  up=$(curl -s -X POST "$API/v1/uploads/probe" -H "$2" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$1\",\"sha256\":\"$(sha "$3")\",\"byteSize\":$(stat -f%z "$3"),\"filename\":\"$(basename "$3")\",\"isAutomaticBackup\":false}" | jq '["uploadID"]')
  curl -s -X PUT "$API/v1/uploads/$up/chunk/0" -H "$2" --data-binary "@$3" >/dev/null
  curl -s -X POST "$API/v1/uploads/$up/commit" -H "$2" -H 'Content-Type: application/json' \
    -d "{\"spaceID\":\"$1\",\"mediaType\":\"photo\",\"mime\":\"image/jpeg\",\"width\":400,\"height\":300,\"isRaw\":false,\"burstPick\":false}" | jq '["assetID"]'; }
# observe <space> <auth> <asset> → how many the server kept, as the phone reports it
observe(){ curl -s -X POST "$API/v1/spaces/$1/curation/observations" -H "$2" -H 'Content-Type: application/json' \
  -d "{\"analysisVersion\":1,\"modelVersion\":\"smoke\",\"observations\":[{\"assetID\":\"$3\",\"labels\":[{\"id\":\"beach\",\"confidence\":0.9}],\"aesthetic\":0.4,\"isUtility\":false,\"peopleCount\":1,\"animalCount\":0}]}" | jq '["accepted"]'; }
# seen <user> <file> → 1 while that person's row for the file is kept
seen(){ q "select count(*) from media_observations where user_id = '$1' and sha256 = '$(sha "$2")';"; }
# nas <user> <file>: what the NAS's analyzer stores for a file, written as it
# would: the analysis, one face, the name given to it, and the scene's labels.
nas(){ local s; s=$(sha "$2")
  q "insert into nas_analysis (user_id, sha256, analyzer_version, models, status, frames, face_count)
       values ('$1', '$s', 1, 'smoke', 'done', 1, 1);
     insert into nas_faces (user_id, sha256, ordinal, box, landmarks, score, size_px, sharpness, embedding)
       values ('$1', '$s', 0, '{0.1,0.1,0.2,0.2}', '{0,0,0,0,0,0,0,0,0,0}', 0.9, 100, 0.5, '\x00');
     insert into person_faces (user_id, sha256, ordinal, person_id, state, box)
       values ('$1', '$s', 0, (select id from people where user_id = '$1'), 'confirmed', '{0.1,0.1,0.2,0.2}');
     insert into nas_observations (user_id, sha256, labels, scoring) values ('$1', '$s', '[]', 'smoke');" >/dev/null; }
# nasleft <user> <file> → analyses|faces|names|scene rows still kept for it
nasleft(){ local s; s=$(sha "$2")
  q "select (select count(*) from nas_analysis where user_id = '$1' and sha256 = '$s') || '|' ||
            (select count(*) from nas_faces where user_id = '$1' and sha256 = '$s') || '|' ||
            (select count(*) from person_faces where user_id = '$1' and sha256 = '$s') || '|' ||
            (select count(*) from nas_observations where user_id = '$1' and sha256 = '$s');"; }
# remove <space> <auth> <asset>: into Recently Deleted. purge: Delete Permanently.
remove(){ curl -s -o /dev/null -X DELETE "$API/v1/spaces/$1/assets/$3" -H "$2"; }
purge(){ curl -s -o /dev/null -X POST "$API/v1/spaces/$1/collections/deleted/purge" -H "$2" \
  -H 'Content-Type: application/json' -d "{\"assetIDs\":[\"$3\"]}"; }
# pass <n>: restarts the server and waits for the nth pass to remove something.
pass(){ stop_server; start_server
  for _ in $(seq 1 60); do [ "$(grep -c 'retention: removed' "$ROOT/server.log")" -ge "$1" ] && break; sleep 0.5; done; }

# The neighbor's library, which Michael is in, and one of Michael's own.
NS=$(curl -s -X POST "$API/v1/spaces" -H "$OTHER" -H 'Content-Type: application/json' \
  -d "{\"name\":\"Next door\",\"memberIDs\":[\"$UM\"]}" | jq '["id"]')
FAM=$(curl -s -X POST "$API/v1/spaces" -H "$A" -H 'Content-Type: application/json' \
  -d '{"name":"Family","memberIDs":[]}' | jq '["id"]')
[ -n "$NS" ] && [ -n "$FAM" ] || { echo "setup failed: no shared library"; tail -20 "$ROOT/server.log"; exit 1; }

F_KEEP=$(photo IMG_9200); KEEP=$(send "$SP" "$A" "$F_KEEP")
F_HELD=$(photo IMG_9201); HELD=$(send "$SP" "$A" "$F_HELD")
F_GONE=$(photo IMG_9202); GONE=$(send "$SP" "$A" "$F_GONE")
F_SHARED=$(photo IMG_9203); SHARED=$(send "$SP" "$A" "$F_SHARED")
F_THEIRS=$(photo IMG_9204); THEIRS=$(send "$SP" "$A" "$F_THEIRS")
F_OLD=$(photo IMG_9205); OLD=$(send "$SP" "$A" "$F_OLD")
# The same bytes as one of his in the neighbor's own library, and as another
# in the library they share with him: second asset rows over the same file.
NGONE=$(send "$SPN" "$OTHER" "$F_GONE")
NTHEIRS=$(send "$NS" "$OTHER" "$F_THEIRS")
[ -n "$OLD" ] && [ -n "$NGONE" ] && [ -n "$NTHEIRS" ] || { echo "setup failed: an upload"; exit 1; }
curl -s -o /dev/null -X POST "$API/v1/spaces/$SP/assets/share" -H "$A" -H 'Content-Type: application/json' \
  -d "{\"assetIDs\":[\"$SHARED\"],\"destinationSpaceID\":\"$FAM\"}"
FAMID=$(q "select sa.asset_id from space_assets sa join assets a on a.id = sa.asset_id
           where sa.space_id = '$FAM' and a.sha256 = '$(sha "$F_SHARED")' and sa.deleted_at is null;")
check "one of his is shared into his family library" "yes" "$([ -n "$FAMID" ] && echo yes || echo no)"

n=0; for x in "$KEEP" "$HELD" "$GONE" "$SHARED" "$THEIRS" "$OLD"; do n=$((n + $(observe "$SP" "$A" "$x"))); done
check "his phone's observations are stored" "6" "$n"
check "and the neighbor's phone's, of their copy" "1" "$(observe "$SPN" "$OTHER" "$NGONE")"
# And what the NAS saw, as if it had analyzed them. This server has no
# analyzer, so the pass below has to forget it without one.
q "insert into people (user_id, name) values ('$UM', 'Mom'), ('$UN', 'Grandpa');" >/dev/null
for x in "$F_KEEP" "$F_HELD" "$F_GONE" "$F_SHARED"; do nas "$UM" "$x"; done
nas "$UN" "$F_GONE"
check "the NAS's analyses are stored, with faces and names" "1|1|1|1" "$(nasleft "$UM" "$F_GONE")"
lacks "and no analyzer is set up" "expecting the analyzer" "$(cat "$ROOT/server.log")"

remove "$SP" "$A" "$HELD"
for x in "$GONE" "$SHARED" "$THEIRS"; do remove "$SP" "$A" "$x"; purge "$SP" "$A" "$x"; done
check "three deleted for good" "3" "$(q "select count(*) from space_assets
  where space_id = '$SP' and asset_id in ('$GONE', '$SHARED', '$THEIRS') and purged_at is not null;")"
remove "$SP" "$A" "$OLD"
q "update space_assets set deleted_at = now() - interval '30 days'
   where space_id = '$SP' and asset_id = '$OLD';" >/dev/null

pass 1
check "deleted for good, what his phone saw goes" "0" "$(seen "$UM" "$F_GONE")"
check "the pass purged what ran out its 29 days" "t" \
  "$(q "select purged_at is not null from space_assets where space_id = '$SP' and asset_id = '$OLD';")"
check "and forgot it in the same pass" "0" "$(seen "$UM" "$F_OLD")"
check "the neighbor's copy keeps what their phone saw" "1" "$(seen "$UN" "$F_GONE")"
check "in Recently Deleted, it's kept for a restore" "1" "$(seen "$UM" "$F_HELD")"
check "kept while his family library holds the photo" "1" "$(seen "$UM" "$F_SHARED")"
check "and while a library he's in holds the same bytes" "1" "$(seen "$UM" "$F_THEIRS")"
check "a photo nobody deleted keeps it" "1" "$(seen "$UM" "$F_KEEP")"
check "the NAS's analysis goes too, faces, names and all" "0|0|0|0" "$(nasleft "$UM" "$F_GONE")"
check "out of his own library, it goes, the family library notwithstanding" "0|0|0|0" \
  "$(nasleft "$UM" "$F_SHARED")"
check "in Recently Deleted, the NAS's is kept too" "1|1|1|1" "$(nasleft "$UM" "$F_HELD")"
check "and for the photo nobody deleted" "1|1|1|1" "$(nasleft "$UM" "$F_KEEP")"
check "the neighbor's copy keeps the NAS's analysis of it" "1|1|1|1" "$(nasleft "$UN" "$F_GONE")"
check "the names given stay with their person" "2" "$(q "select count(*) from people where name is not null;")"
has "the log says how many went" "retention: removed 2 device observations and 2 NAS analyses" \
  "$(grep 'retention:' "$ROOT/server.log")"

remove "$FAM" "$A" "$FAMID"; purge "$FAM" "$A" "$FAMID"
check "he leaves the neighbor's library" "204" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "$API/v1/spaces/$NS/members/$UM" -H "$A")"

pass 2
check "deleted for good from his last library, it goes" "0" "$(seen "$UM" "$F_SHARED")"
check "once he's left the library that held it, it goes" "0" "$(seen "$UM" "$F_THEIRS")"
check "Recently Deleted still keeps it" "1" "$(seen "$UM" "$F_HELD")"
check "and the photo nobody deleted" "1" "$(seen "$UM" "$F_KEEP")"
curl -s -o /dev/null -X POST "$API/v1/spaces/$SP/collections/deleted/restore" -H "$A" \
  -H 'Content-Type: application/json' -d "{\"assetIDs\":[\"$HELD\"]}"
check "restored, it shows what was seen without a new analysis" "200" \
  "$(status "$A" "/v1/spaces/$SP/assets/$HELD/observation")"
check "and what the NAS saw" "200" "$(status "$A" "/v1/spaces/$SP/assets/$HELD/nas-observation")"
lacks "and the pass's log names no file" "$(sha "$F_GONE" | cut -c1-8)" "$(grep 'retention' "$ROOT/server.log")"

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
