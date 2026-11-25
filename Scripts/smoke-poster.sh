#!/bin/bash
# Video posters. A video's thumbnail comes from the sharpest of a few early
# frames that isn't black, blown out or blank, rather than whatever was on
# screen one second in. One second in stays the choice while it's about as
# sharp as the best. Videos have their own thumbnail version, so a change to
# posters rebuilds only videos, and a photo with no thumbnail yet is made
# before any rebuild, so new uploads never wait behind one.
#
# An HDR clip's poster is tone-mapped to SDR where ffmpeg can, and written the
# plain way where it can't, never left without one but not counted as
# converted either. Every poster made measures its clip's range. A boot makes
# again only what v5 changed: HDR clips not yet tone-mapped, where they can
# be, and clips never measured. An SDR clip keeps version 4 and its bytes, and
# nothing is made again on the boot after. Homebrew's ffmpeg has no zscale, so
# a stand-in ffmpeg plays the one that can tone-map: that checks what the
# server does when it works, and which filters it asks for, but not how the
# picture looks. Server/Dockerfile measures that, on the image's own ffmpeg.
#
#   FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-poster.sh
#
# Runs its own server against its own database and blob store.
set -uo pipefail
SCRATCH="${FRAMESTATION_TEST_DIR:-/tmp/framestation-test}"
SERVER_DIR="${FRAMESTATION_SERVER_DIR:-$(cd "$(dirname "$0")/../Server" && pwd)}"
export PATH="/opt/homebrew/bin:$PATH"

DB=framestation_poster; PORT=8095; API="http://127.0.0.1:$PORT"
export FRAMESTATION_DATABASE_URL="postgres://framestation:x@127.0.0.1:55432/$DB?sslmode=disable"
ROOT="$SCRATCH/poster"; rm -rf "$ROOT"; mkdir -p "$ROOT/blobroot" "$ROOT/lib"
ROOT=$(cd "$ROOT" && pwd -P)
export FRAMESTATION_BLOB_ROOT="$ROOT/blobroot"
LIB="$ROOT/lib"

PASS=0; FAIL=0
q(){ psql -h 127.0.0.1 -p 55432 -U framestation -d $DB -tAqc "$1"; }
admin(){ psql -h 127.0.0.1 -p 55432 -U framestation -d postgres -tAqc "$1"; }
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; echo "      expected: $2"; echo "      actual:   $3"; FAIL=$((FAIL+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
jq(){ python3 -c "import sys,json; print(json.load(sys.stdin)$1)" 2>/dev/null; }
above(){ python3 -c "print('yes' if float('$1') > float('$2') else 'no')"; }
truthy(){ [ "$2" = "yes" ] && ok "$1" || bad "$1" "yes" "no — $3"; }
has(){ case "$3" in *"$2"*) ok "$1";; *) bad "$1" "contains '$2'" "$3";; esac }

(cd "$SERVER_DIR" && swift build >/dev/null 2>&1) || { echo "server build failed"; exit 1; }
BIN="$(cd "$SERVER_DIR" && swift build --show-bin-path)/FrameStationServer"
admin "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1; admin "CREATE DATABASE $DB" >/dev/null

SERVER=""
serve(){
  "$BIN" serve --hostname 127.0.0.1 --port $PORT >> "$ROOT/server.log" 2>&1 &
  SERVER=$!
  for _ in $(seq 1 120); do curl -s -o /dev/null "$API/health" && return; sleep 0.5; done
  echo "server didn't start:"; tail -20 "$ROOT/server.log"; exit 1
}
stop(){ kill "$SERVER" 2>/dev/null; wait "$SERVER" 2>/dev/null; }
trap stop EXIT

# A frame measured the way the server measures candidates: squeezed to a
# 384 px gray square. Prints "brightness sharpness".
measure(){ # file [seconds into a video]
  # Positional rather than an array: macOS's bash 3.2 calls an empty array
  # unbound under `set -u`.
  if [ -n "${2:-}" ]; then set -- -ss "$2" -i "$1"; else set -- -i "$1"; fi
  ffmpeg -v error "$@" -frames:v 1 -vf "scale=384:384:flags=area,format=gray" \
    -f rawvideo - 2>/dev/null | python3 -c '
import sys
d = sys.stdin.buffer.read(); s = 384
if len(d) != s * s: print("0 0"); sys.exit()
mean = sum(d) / len(d)
lap = [4*d[i] - d[i-1] - d[i+1] - d[i-s] - d[i+s]
       for y in range(1, s-1) for i in range(y*s+1, y*s+s-1)]
m = sum(lap) / len(lap)
print(f"{mean:.1f} {sum(v*v for v in lap)/len(lap) - m*m:.1f}")'
}
asset(){ q "SELECT a.$2 FROM assets a JOIN space_assets sa ON sa.asset_id = a.id WHERE sa.filename = '$1'"; }
poster(){ local sha; sha=$(asset "$1" sha256)
  echo "$FRAMESTATION_BLOB_ROOT/derivatives/${sha:0:2}/${sha:2:2}/$sha/poster.jpg"; }
said(){ grep -c "derive $(asset "$1" sha256 | cut -c1-8): poster from $2" "$ROOT/server.log"; }

echo "Videos that start badly, and some that don't"
mk(){ ffmpeg -v error -y -f lavfi -i "$2" ${3:+-vf "$3"} -c:v libx264 -g 30 -pix_fmt yuv420p "$LIB/$1"; }
mk blurry-start.mp4 "testsrc2=size=1280x720:rate=30:duration=5" \
  "boxblur=luma_radius=24:luma_power=3:chroma_radius=12:enable='lt(t,1.8)'"
mk black-start.mp4 "testsrc2=size=1280x720:rate=30:duration=5" \
  "drawbox=color=black:t=fill:enable='lt(t,1.2)'"
mk steady.mp4 "smptehdbars=size=1280x720:rate=30:duration=5"
mk short.mp4 "testsrc2=size=1280x720:rate=30:duration=0.4"
mk dark.mp4 "testsrc2=size=1280x720:rate=30:duration=5" "lutyuv=y=val*0.07"
for p in photo photo2; do
  vips gaussnoise "$ROOT/n.v" 900 600 >/dev/null 2>&1 && vips copy "$ROOT/n.v" "$LIB/$p.jpg" >/dev/null 2>&1
done

serve
CODE=$(cd "$SERVER_DIR" && "$BIN" invite 2>/dev/null | grep "Invite code:" | awk '{print $3}')
R=$(curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$CODE\",\"displayName\":\"Tester\",\"deviceName\":\"iPhone\",\"platform\":\"ios\"}")
SPACE=$(echo "$R" | jq '["personalSpace"]["id"]')
(cd "$SERVER_DIR" && "$BIN" import --path "$LIB" --space "$SPACE" >/dev/null 2>&1)
for _ in $(seq 1 120); do [ "$(q "SELECT count(*) FROM assets WHERE derived_at IS NULL")" = "0" ] && break; sleep 1; done

BLURRED=$(measure "$LIB/blurry-start.mp4" 1.0 | awk '{print $2}')
SHARP=$(measure "$LIB/blurry-start.mp4" 3.0 | awk '{print $2}')
GOT=$(measure "$(poster blurry-start.mp4)" | awk '{print $2}')
truthy "a blurry start gives way to a sharp frame" "$(above "$GOT" "$(python3 -c "print($SHARP * 0.6)")")" \
  "poster sharpness $GOT, sharp frame $SHARP, blurred frame $BLURRED"
check "and the log says which" "1" "$(said blurry-start.mp4 '[234]\.0s')"
BRIGHT=$(measure "$(poster black-start.mp4)" | awk '{print $1}')
truthy "a black start is skipped" "$(above "$BRIGHT" 40)" "poster brightness $BRIGHT"
check "a steady video keeps the frame at one second" "0" "$(said steady.mp4 '')"
[ -s "$(poster steady.mp4)" ] && ok "and has its poster" || bad "and has its poster" "a poster" "none"
check "a clip shorter than any candidate uses its first frame" "1" "$(said short.mp4 '0\.0s')"
[ -s "$(poster dark.mp4)" ] && ok "a video dark all the way through still gets a poster" \
  || bad "a video dark all the way through still gets a poster" "a poster" "none"
check "videos carry the video thumbnail version" "4 4 4 4 4" \
  "$(for f in blurry-start black-start steady short dark; do asset "$f.mp4" thumb_version; done | tr '\n' ' ' | sed 's/ $//')"
check "photos keep the photo version" "3 3" "$(asset photo.jpg thumb_version) $(asset photo2.jpg thumb_version)"
stop

echo "Rebuilding: only videos, and never ahead of a new photo"
BLURRY=$(asset blurry-start.mp4 id); PHOTO=$(asset photo.jpg id)
# One video built before this version, with a full-screen preview made from
# its old poster.
q "UPDATE assets SET thumb_version = 3 WHERE id = '$BLURRY'" >/dev/null
PREVIEW="$(dirname "$(poster blurry-start.mp4)")/preview-2048.jpg"
cp "$(poster blurry-start.mp4)" "$PREVIEW"
# A photo that has no thumbnail yet, queued an hour after the rebuild job, so
# oldest-first alone would make it wait.
q "UPDATE assets SET derived_at = NULL WHERE id = '$PHOTO'" >/dev/null
q "UPDATE derivation_jobs SET state = 'pending', started_at = NULL, created_at = now() - interval '2 hours'
   WHERE asset_id = '$BLURRY' AND kind = 'thumbnails'" >/dev/null
q "UPDATE derivation_jobs SET state = 'pending', started_at = NULL, created_at = now() - interval '1 hour'
   WHERE asset_id = '$PHOTO' AND kind = 'thumbnails'" >/dev/null
OTHERS="SELECT string_agg(j.started_at::text, ',' ORDER BY j.id) FROM derivation_jobs j
        WHERE j.kind = 'thumbnails' AND j.asset_id NOT IN ('$BLURRY', '$PHOTO')"
BEFORE=$(q "$OTHERS")
FRAMESTATION_DERIVATION_LANES=1 serve
for _ in $(seq 1 120); do
  [ "$(asset blurry-start.mp4 thumb_version)" = "4" ] \
    && [ "$(q "SELECT derived_at IS NOT NULL FROM assets WHERE id = '$PHOTO'")" = "t" ] && break
  sleep 1
done
sleep 2
check "the old video is rebuilt to the new version" "4" "$(asset blurry-start.mp4 thumb_version)"
[ -e "$PREVIEW" ] && bad "its stale full-screen preview is dropped" "gone" "still there" \
  || ok "its stale full-screen preview is dropped"
check "the photo with no thumbnail went first" "t" \
  "$(q "SELECT p.started_at < v.started_at FROM derivation_jobs p, derivation_jobs v
        WHERE p.asset_id = '$PHOTO' AND p.kind = 'thumbnails'
          AND v.asset_id = '$BLURRY' AND v.kind = 'thumbnails'")"
check "nothing else was rebuilt, photo or video" "$BEFORE" "$(q "$OTHERS")"
stop

# Each boot's own lines of the log, from the mark set before it.
MARK=0
since(){ tail -n +"$((MARK + 1))" "$ROOT/server.log"; }
boot(){ MARK=$(wc -l < "$ROOT/server.log"); serve
  for _ in $(seq 1 120); do since | grep -q "derivation worker starting" && break; sleep 0.5; done
  drained; }
# Every thumbnail job the boot's pass queued has finished.
drained(){ for _ in $(seq 1 180); do
    [ "$(q "SELECT count(*) FROM derivation_jobs WHERE kind = 'thumbnails'
            AND state IN ('pending', 'running')")" = "0" ] && return
    sleep 1; done; }
job(){ q "SELECT j.$2 FROM derivation_jobs j JOIN space_assets sa ON sa.asset_id = j.asset_id
          WHERE sa.filename = '$1' AND j.kind = 'thumbnails'"; }
# When each thumbnail job last started, but for the files named.
started(){ q "SELECT string_agg(sa.filename || '=' || j.started_at::text, ',' ORDER BY sa.filename)
              FROM derivation_jobs j JOIN space_assets sa ON sa.asset_id = j.asset_id
              WHERE j.kind = 'thumbnails' AND sa.filename NOT IN ($1)"; }
changed(){ [ "$1" != "$2" ] && echo yes || echo no; }
told(){ q "SELECT count(*) FROM change_log c JOIN space_assets sa ON sa.id = c.entity_id
           WHERE c.entity = 'space_asset' AND sa.filename = '$1'"; }

echo "HDR clips, where this ffmpeg can't tone-map"
HDRLIB="$ROOT/hdrlib"; mkdir -p "$HDRLIB"
# 10-bit and tagged as an iPhone tags its video: HLG, and PQ as HDR10 has it.
# HEVC, as a phone records, where there's an encoder for it. Tagged on the
# frames as well as the output: ffmpeg 8 takes the transfer and the colors
# from the frames, and the test pattern's have none.
ENCODERS=$(ffmpeg -hide_banner -encoders 2>/dev/null)
case "$ENCODERS" in
  *libx265*) HEVC="-c:v libx265 -preset ultrafast -x265-params log-level=error -tag:v hvc1" ;;
  *) HEVC="-c:v libx264 -profile:v high10" ;;
esac
hdr(){ # file transfer seconds
  ffmpeg -v error -y -f lavfi -i "testsrc2=size=1280x720:rate=30:duration=$3" \
    -vf "format=yuv420p10le,setparams=color_primaries=bt2020:color_trc=$2:colorspace=bt2020nc:range=tv" \
    $HEVC -color_primaries bt2020 -color_trc "$2" -colorspace bt2020nc -color_range tv "$HDRLIB/$1"; }
hdr concert.mov arib-std-b67 5
hdr hdr10.mp4 smpte2084 3
boot
has "the boot says HDR posters can't be tone-mapped here, and why" \
  "HDR posters: this ffmpeg can't tone-map (No such filter: 'zscale')" "$(since | grep 'HDR posters:')"
(cd "$SERVER_DIR" && "$BIN" import --path "$HDRLIB" --space "$SPACE" >/dev/null 2>&1)
drained
CSHA=$(asset concert.mov sha256 | cut -c1-8); PSHA=$(asset hdr10.mp4 sha256 | cut -c1-8)
[ -s "$(poster concert.mov)" ] && [ -s "$(poster hdr10.mp4)" ] && ok "HLG and PQ clips still get their posters" \
  || bad "HLG and PQ clips still get their posters" "two posters" "$(ls "$(dirname "$(poster concert.mov)")" 2>&1)"
check "and their range is recorded" "hdr hdr" "$(asset concert.mov dynamic_range) $(asset hdr10.mp4 dynamic_range)"
check "but they aren't counted as converted" "4 4" \
  "$(asset concert.mov thumb_version) $(asset hdr10.mp4 thumb_version)"
check "the log says so, and why" "1 1" \
  "$(since | grep -c "derive $CSHA: HLG poster not tone-mapped, written as before: this ffmpeg can't tone-map (No such filter: 'zscale')") $(since | grep -c "derive $PSHA: PQ poster not tone-mapped")"
check "and so does its job" "done HDR poster not tone-mapped: this ffmpeg can't tone-map (No such filter: 'zscale')" \
  "$(job concert.mov state) $(job concert.mov last_error)"
stop

echo "Booting again: only what v5 changed is made again"
# As the NAS has them: an HDR clip and an SDR one that no ladder ever
# measured, and an HDR clip that one did.
q "UPDATE assets SET dynamic_range = NULL WHERE id IN ('$(asset concert.mov id)', '$(asset steady.mp4 id)')" >/dev/null
CPREVIEW="$(dirname "$(poster concert.mov)")/preview-2048.jpg"; cp "$(poster concert.mov)" "$CPREVIEW"
SDIR=$(dirname "$(poster steady.mp4)")
sums(){ (cd "$SDIR" && shasum -a 256 poster.jpg thumb-256.jpg thumb-512.jpg | awk '{print $1}' | tr '\n' ' '); }
STEADY_SUMS=$(sums)
CONCERT_RUN=$(job concert.mov started_at); STEADY_RUN=$(job steady.mp4 started_at)
REST=$(started "'concert.mov', 'steady.mp4'")
boot
truthy "an HDR clip never measured is made again" "$(changed "$(job concert.mov started_at)" "$CONCERT_RUN")" \
  "its job last started $CONCERT_RUN"
check "and measured, as its poster is made" "hdr" "$(asset concert.mov dynamic_range)"
check "still at the plain version: nothing here can tone-map it" "4" "$(asset concert.mov thumb_version)"
[ -e "$CPREVIEW" ] && bad "its full-screen preview is dropped, to be made again" "gone" "still there" \
  || ok "its full-screen preview is dropped, to be made again"
truthy "an SDR clip never measured is made again" "$(changed "$(job steady.mp4 started_at)" "$STEADY_RUN")" \
  "its job last started $STEADY_RUN"
check "and measured" "standard" "$(asset steady.mp4 dynamic_range)"
check "it keeps version 4, so no device fetches it again" "4" "$(asset steady.mp4 thumb_version)"
check "and is the same picture, byte for byte" "$STEADY_SUMS" "$(sums)"
check "nothing else is made again: measured SDR clips, the measured HDR one, photos" \
  "$REST" "$(started "'concert.mov', 'steady.mp4'")"
stop
ALL=$(started "''")
boot; sleep 2
check "the boot after makes nothing again" "$ALL" "$(started "''")"
stop

echo "Where ffmpeg fails to tone-map, the poster is still made"
REST=$(started "'concert.mov', 'hdr10.mp4'")
CONCERT_RUN=$(job concert.mov started_at); HDR10_RUN=$(job hdr10.mp4 started_at)
# Says tone mapping works, so the HDR clips go back in line and the ffmpeg
# that hasn't zscale is asked to all the same.
FRAMESTATION_HDR_POSTERS=on boot
has "the boot takes it that HDR posters can be tone-mapped" "HDR posters: tone-mapped to SDR" \
  "$(since | grep 'HDR posters:')"
check "so the HDR clips are made again" "yes yes" \
  "$(changed "$(job concert.mov started_at)" "$CONCERT_RUN") $(changed "$(job hdr10.mp4 started_at)" "$HDR10_RUN")"
[ -s "$(poster concert.mov)" ] && [ -s "$(poster hdr10.mp4)" ] && ok "they still have posters" \
  || bad "they still have posters" "two posters" "missing"
check "written the plain way and not counted as converted" "4 4" \
  "$(asset concert.mov thumb_version) $(asset hdr10.mp4 thumb_version)"
check "the log says why" "1" \
  "$(since | grep -c "derive $CSHA: HLG poster not tone-mapped, written as before: ffmpeg failed to tone-map it: No such filter: 'zscale'")"
has "and so does the job" "HDR poster not tone-mapped: ffmpeg failed to tone-map it: No such filter" \
  "$(job concert.mov last_error)"
check "SDR clips and photos are left alone" "$REST" "$(started "'concert.mov', 'hdr10.mp4'")"
stop

echo "Where ffmpeg can tone-map, an HDR clip is converted, once"
# Stands in for an ffmpeg with zscale: the filters that make an HDR frame SDR
# are noted and swapped for a plain RGB frame, so the server takes the path
# it takes when tone mapping works. How the picture looks isn't checked here.
SHIM="$ROOT/shim"; mkdir -p "$SHIM"; : > "$SHIM/chains.log"
cat > "$SHIM/ffmpeg" <<EOF
#!/bin/bash
args=()
for a in "\$@"; do
  case "\$a" in *zscale=*) printf '%s\n' "\$a" >> "$SHIM/chains.log"; a="format=gbrp" ;; esac
  args+=("\$a")
done
exec "$(command -v ffmpeg)" "\${args[@]}"
EOF
chmod +x "$SHIM/ffmpeg"
REST=$(started "'concert.mov', 'hdr10.mp4'")
CONCERT_TOLD=$(told concert.mov)
PATH="$SHIM:$PATH" boot
has "the boot checks it can tone-map, and can" "HDR posters: tone-mapped to SDR" "$(since | grep 'HDR posters:')"
check "the HDR clips are tone-mapped, and move to version 5" "5 5" \
  "$(asset concert.mov thumb_version) $(asset hdr10.mp4 thumb_version)"
check "the log says so" "1 1" \
  "$(since | grep -c "derive $CSHA: HLG poster tone-mapped") $(since | grep -c "derive $PSHA: PQ poster tone-mapped")"
check "with nothing kept beside the job" "" "$(job concert.mov last_error)"
truthy "and devices are told, so they fetch the new thumbnail" \
  "$(above "$(told concert.mov)" "$CONCERT_TOLD")" "$(told concert.mov) announcements, $CONCERT_TOLD before"
check "SDR clips and photos are left alone" "$REST" "$(started "'concert.mov', 'hdr10.mp4'")"
HLG_CHAIN=$(grep -m1 '^scale=.*tin=arib-std-b67' "$SHIM/chains.log")
has "the filters say the clip's transfer, colors, matrix and range outright" \
  "tin=arib-std-b67:pin=bt2020:min=bt2020nc:rin=limited:" "$HLG_CHAIN"
has "and a PQ clip's say its own transfer" "tin=smpte2084:" "$(grep -m1 '^scale=.*tin=smpte2084' "$SHIM/chains.log")"
check "they're the filters the image checks" \
  "$(sed -n 's/^RUN chain="\([^"]*\)".*/\1/p' "$SERVER_DIR/Dockerfile")" "$HLG_CHAIN"
stop
ALL=$(started "''")
PATH="$SHIM:$PATH" boot; sleep 2
check "once converted, it isn't made again" "$ALL" "$(started "''")"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
