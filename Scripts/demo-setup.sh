#!/bin/bash
# Sets up the App Review server on the NAS: a library owner, a shared library
# of sample photos they added, and a code reviewers sign in with. See
# APP-REVIEW.md, which also covers the reverse proxy this needs afterward.
#
# Run as root from the demo's own folder, once it holds this script, the
# demo's docker-compose.yml, a .env with a new POSTGRES_PASSWORD, and the
# sample photos in seed/:
#
#   cd /volume1/docker/framestation-demo && sudo bash demo-setup.sh
#
# Safe to run again. It keeps the owner and library it already made, imports
# only photos it hasn't, and prints a fresh reviewer code each time.
#
# Locations are stripped from the sample photos before they're imported, so
# nobody can read where they were taken from the copies on this server. Set
# KEEP_LOCATIONS=1 to keep them, for photos of public places you're happy to
# have on a map.
set -euo pipefail
# DSM's sudo leaves /usr/local/bin off the PATH, and that's where docker is.
export PATH="/usr/local/bin:$PATH"
cd "$(dirname "$0")"
DIR=$(pwd)
API=http://127.0.0.1:8081
OWNER_NAME="Sam (Demo)"
LIBRARY_NAME="Demo Family"
# Who the setup made, so a second run finds them. Root's alone: the token in
# it signs in as the owner.
STATE="$DIR/.demo-state"

say(){ printf '\n%s\n' "$*"; }
die(){ printf '\n✗ %s\n' "$*" >&2; exit 1; }
compose(){ docker compose --project-directory "$DIR" "$@"; }
server(){ compose exec -T server ./FrameStationServer "$@"; }
# One string field from a JSON object with no objects inside it.
field(){ sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"; }

[ "$(id -u)" = 0 ] || die "Run with sudo: Docker on DSM needs root."
[ -f docker-compose.yml ] || die "No docker-compose.yml here. Copy Demo/docker-compose.yml in first."
grep -q '^POSTGRES_PASSWORD=..*' .env 2>/dev/null \
  || die "No POSTGRES_PASSWORD in .env. Make a new one; never the family server's."
ls seed/* >/dev/null 2>&1 || die "No sample photos in seed/."

say "Folders"
mkdir -p data pgdata
# The server runs as the image's own user, which has to be able to write here.
compose pull -q server db
OWNER_IDS=$(compose run --rm --no-deps -T --entrypoint sh server -c 'echo "$(id -u):$(id -g)"' | tr -d '\r')
chown -R "$OWNER_IDS" data
# The chmod is what makes the chown count. A folder made inside a shared
# folder inherits DSM's access list, which lets "everyone" read and nothing
# more, whoever owns it; a chmod switches it to plain Linux permissions. Owned
# and not chmodded, every import failed with "Permission denied" (10/14).
# Postgres does the same to its own folder at startup, which is why pgdata
# never had the problem.
chmod -R u+rwX,go+rX data
chmod -R a+rX seed
echo "  data/ belongs to $OWNER_IDS; seed/ is readable"

if [ "${KEEP_LOCATIONS:-0}" != 1 ]; then
  say "Stripping locations from the sample photos"
  compose run --rm --no-deps -T --user 0:0 -v "$DIR/seed:/strip" --entrypoint exiftool server \
    -r -q -q -overwrite_original -gps:all= -xmp:all= \
    -Keys:GPSCoordinates= -UserData:GPSCoordinates= -ItemList:GPSCoordinates= /strip || true
  LEFT=$(compose run --rm --no-deps -T --user 0:0 -v "$DIR/seed:/strip" --entrypoint exiftool server \
    -r -q -q -if '$gpslatitude or $gpscoordinates' -p '$directory/$filename' /strip | tr -d '\r' || true)
  [ -z "$LEFT" ] || die "These still say where they were taken, so nothing was imported: $LEFT"
  echo "  none of them say where they were taken"
fi

say "Starting the server"
compose up -d
for _ in $(seq 1 120); do curl -sf "$API/health" >/dev/null && break; sleep 1; done
curl -sf "$API/health" >/dev/null || die "The server didn't answer on $API. See: sudo docker compose logs server"
echo "  $(curl -s "$API/health")"

OWNER_ID=""; OWNER_TOKEN=""; LIBRARY_ID=""
# shellcheck disable=SC1090
[ -f "$STATE" ] && . "$STATE"
if [ -n "$OWNER_TOKEN" ] && curl -sf "$API/v1/me" -H "Authorization: Bearer $OWNER_TOKEN" >/dev/null; then
  say "The owner and library from last time are still here"
else
  say "Making $OWNER_NAME, who owns the library and added its photos"
  CODE=$(server invite --expires-hours 1 | sed -n 's/.*Invite code: *\([A-Z0-9-]*\).*/\1/p')
  [ -n "$CODE" ] || die "Couldn't make an invite code."
  REPLY=$(curl -s -X POST "$API/v1/auth/redeem" -H 'Content-Type: application/json' \
    -d "{\"code\":\"$CODE\",\"displayName\":\"$OWNER_NAME\",\"deviceName\":\"Setup\",\"platform\":\"ios\"}")
  OWNER_TOKEN=$(echo "$REPLY" | field token)
  OWNER_ID=$(echo "$REPLY" | grep -o '"user":{[^}]*}' | field id)
  [ -n "$OWNER_TOKEN" ] && [ -n "$OWNER_ID" ] || die "Couldn't sign in the owner: $REPLY"

  REPLY=$(curl -s -X POST "$API/v1/spaces" -H "Authorization: Bearer $OWNER_TOKEN" \
    -H 'Content-Type: application/json' -d "{\"name\":\"$LIBRARY_NAME\",\"memberIDs\":[]}")
  LIBRARY_ID=$(echo "$REPLY" | field id)
  [ -n "$LIBRARY_ID" ] || die "Couldn't make the library: $REPLY"

  umask 077
  printf 'OWNER_ID=%s\nOWNER_TOKEN=%s\nLIBRARY_ID=%s\n' "$OWNER_ID" "$OWNER_TOKEN" "$LIBRARY_ID" > "$STATE"
fi
# The umask isn't enough on DSM: the new file took the docker share's access
# list, which lets everyone read, and any NAS account could read the owner's
# token (10/23). As with data/ above, a chmod switches it to plain permissions.
chmod 600 "$STATE"

say "Importing the sample photos into $LIBRARY_NAME"
server import --path /seed --space "$LIBRARY_ID" --user "$OWNER_ID" --mode copy

say "A code for App Review"
# Joins whoever redeems it to the library as a contributor. Good for twenty
# sign-ins over ninety days: reviewers sign in on more than one device, and
# again after testing Delete Account.
server invite --space "$LIBRARY_ID" --uses 20 --expires-hours 2160

say "Done. Next: the reverse proxy rule in APP-REVIEW.md, then check the address from outside."
