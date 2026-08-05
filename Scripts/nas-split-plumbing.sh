#!/bin/bash
# One-off: split FrameStation's plumbing out of its media share.
#
# The share was laid out before ARCHITECTURE.md §3a, when the content-addressed
# store *was* the library and app data and media were genuinely the same thing.
# They aren't any more, and one folder forces one snapshot policy onto four
# things that need three: a live Postgres must never be filesystem-snapshotted
# as if it were a photo, chunk staging is pure churn, and derivatives rebuild
# themselves.
#
#   /volume1/docker/framestation/   .env, compose, pgdata, blobs, derivatives, incoming
#   /volume1/FrameStation/          shared-space media, and nothing else
#
# Run ON THE NAS, as root:
#     sudo bash /volume1/FrameStation/nas-split-plumbing.sh
#
# Safe to re-run: it stops at the first step that has already been done.
set -euo pipefail

MEDIA="${FRAMESTATION_MEDIA:-/volume1/FrameStation}"
DATA="${FRAMESTATION_DATA:-/volume1/docker/framestation}"
DOCKER="${DOCKER_BIN:-/usr/local/bin/docker}"
MOVE="pgdata blobs derivatives incoming"

say() { echo "  $*"; }
die() { echo "FAILED: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run me with sudo — pgdata is owned by the postgres uid"
[ -d "$MEDIA" ]      || die "no media share at $MEDIA"
[ -x "$DOCKER" ]     || die "no docker at $DOCKER"

echo "==> 1. stopping the stack"
if [ -f "$MEDIA/docker-compose.yml" ]; then
  (cd "$MEDIA" && "$DOCKER" compose down) || die "could not stop the stack"
  say "stopped"
else
  say "no compose file in $MEDIA — assuming already moved"
fi

echo "==> 2. preparing $DATA"
mkdir -p "$DATA"
say "ready"

echo "==> 3. copying plumbing across (verified before anything is removed)"
# cp -a, not mv: these are separate Btrfs subvolumes, so a move is a copy and a
# delete anyway — doing it in two explicit steps means a failure leaves the
# original untouched rather than half-moved.
for dir in $MOVE; do
  if [ ! -e "$MEDIA/$dir" ]; then say "$dir — not present, skipping"; continue; fi
  if [ -e "$DATA/$dir" ];   then say "$dir — already at destination, skipping"; continue; fi

  cp -a "$MEDIA/$dir" "$DATA/$dir" || die "copying $dir"

  before=$(find "$MEDIA/$dir" | wc -l)
  after=$(find "$DATA/$dir"  | wc -l)
  [ "$before" -eq "$after" ] || die "$dir: $before entries in, $after out — leaving the original alone"
  say "$dir — $after entries, verified"
done

for file in .env docker-compose.yml; do
  [ -f "$MEDIA/$file" ] && [ ! -f "$DATA/$file" ] && cp -a "$MEDIA/$file" "$DATA/$file" && say "$file — copied"
done
true

echo "==> 4. rewriting .env for the split layout"
# The password is rewritten without ever being printed.
if [ -f "$DATA/.env" ]; then
  password=$(grep '^POSTGRES_PASSWORD=' "$DATA/.env" | head -1 | cut -d= -f2-)
  [ -n "$password" ] || die "no POSTGRES_PASSWORD found in $DATA/.env"
  log=$(grep '^LOG_LEVEL=' "$DATA/.env" | head -1 | cut -d= -f2- || true)
  cp -a "$DATA/.env" "$DATA/.env.bak-$(date +%Y%m%d)"
  cat > "$DATA/.env" <<EOF
POSTGRES_PASSWORD=$password
FRAMESTATION_DATA=$DATA
FRAMESTATION_MEDIA=$MEDIA
FRAMESTATION_HOMES=/volume1/homes
LOG_LEVEL=${log:-info}
EOF
  chmod 600 "$DATA/.env"
  say "written (password preserved, never displayed)"
fi

echo "==> 5. starting from the new location"
[ -f "$DATA/docker-compose.yml" ] || die "no docker-compose.yml at $DATA — copy the new one up first"
(cd "$DATA" && "$DOCKER" compose up -d) || die "could not start the stack"

echo "==> 6. waiting for health"
ok=""
for _ in $(seq 1 30); do
  sleep 2
  if curl -sf --max-time 3 http://127.0.0.1:8080/health >/dev/null 2>&1; then ok=1; break; fi
done
[ -n "$ok" ] || die "server did not come back — check: $DOCKER compose -f $DATA/docker-compose.yml logs server"
echo
curl -s http://127.0.0.1:8080/health; echo
echo

# Deliberately not automatic. The old copies are the only rollback there is,
# and a script that deletes a database it has just moved is a script that
# deletes a database.
echo "==> done. The originals are still in place:"
for dir in $MOVE; do [ -e "$MEDIA/$dir" ] && echo "     $MEDIA/$dir"; done
echo
echo "    Once the app has been exercised against the new layout, remove them:"
echo "      sudo rm -rf $MEDIA/{pgdata,blobs,derivatives,incoming,browse,Shared}"
echo "      sudo rm -f  $MEDIA/docker-compose.yml* $MEDIA/.env $MEDIA/nas-split-plumbing.sh"
echo
echo "    $MEDIA then holds shared media only, and the stack lives at $DATA."
