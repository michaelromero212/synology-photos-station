#!/bin/bash
# Synology Photos' own taken time for every file in one person's library, or
# in the Shared Space, for `FrameStationServer compare-dates`, `import` and
# `redate`: one line per file of its path as the
# import walks it, the local time Synology Photos shows it at and orders it
# by, and its item (a Live Photo is two files and one item). See MIGRATION.md.
#
# Reads Synology's database and changes nothing there. Run as root on the NAS
# with the person's DSM username, or --shared-space for the Shared Space, and
# a file to write, somewhere the server's container can read:
#
#   sudo bash /tmp/export-synology-dates.sh "<user>" /volume1/docker/framestation/synology-dates.tsv
#   sudo bash /tmp/export-synology-dates.sh --shared-space /volume1/docker/framestation/shared-space-dates.tsv
set -uo pipefail

# No apostrophe in these messages: bash 4.4, the NAS's, reads one inside a
# double-quoted ${...} as the start of a quote.
NAME="${1:?Give the DSM username, in quotes if it has a space, or --shared-space.}"
OUT="${2:?Give a file to write, such as /volume1/docker/framestation/synology-dates.tsv}"
[ "$(id -u)" = 0 ] || { echo "Run with sudo." >&2; exit 2; }
if [ "$NAME" = "--shared-space" ]; then
  # Synology files the Shared Space under user 0, named for its folder.
  ROOT=$(echo "SELECT name FROM user_info WHERE id = 0;" | sudo -u postgres psql -d synofoto -X -q -A -t)
else
  ROOT="/volume1/homes/$NAME/Photos"
fi
[ -d "$ROOT" ] || { echo "No $ROOT." >&2; exit 2; }

# It names every file in the library, so it's root's alone. The chmod as well
# as the umask, because a new file otherwise takes the shared folder's access
# list, which lets everyone read.
umask 077
: > "$OUT" && chmod 600 "$OUT" || exit 1

sudo -u postgres psql -d synofoto -X -q -A -t -F $'\t' -v name="$NAME" -v root="$ROOT" > "$OUT" <<'SQL'
SELECT regexp_replace(:'root' || '/' || f.name || '/' || u.filename, '/+', '/', 'g'),
       to_char(to_timestamp(u.takentime) AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS'),
       u.id_item
FROM unit u
JOIN folder f ON f.id = u.id_folder
JOIN user_info i ON i.id = u.id_user
WHERE CASE WHEN :'name' = '--shared-space' THEN u.id_user = 0 ELSE i.name = :'name' END
  AND u.takentime > 0;
SQL

echo "$(wc -l < "$OUT") files' dates written to $OUT"
