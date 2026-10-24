#!/bin/bash
# Synology Photos' own taken time for every file in one person's library, for
# `FrameStationServer compare-dates`: one line per file of its path as the
# import walks it, the local time Synology Photos shows it at and orders it
# by, and its item (a Live Photo is two files and one item). See MIGRATION.md.
#
# Reads Synology's database and changes nothing there. Run as root on the NAS
# with the person's DSM username and a file to write, somewhere the server's
# container can read:
#
#   sudo bash /tmp/export-synology-dates.sh "<user>" /volume1/docker/framestation/synology-dates.tsv
set -uo pipefail

# No apostrophe in these messages: bash 4.4, the NAS's, reads one inside a
# double-quoted ${...} as the start of a quote.
NAME="${1:?Give the DSM username, in quotes if it has a space.}"
OUT="${2:?Give a file to write, such as /volume1/docker/framestation/synology-dates.tsv}"
ROOT="/volume1/homes/$NAME/Photos"
[ "$(id -u)" = 0 ] || { echo "Run with sudo." >&2; exit 2; }
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
WHERE i.name = :'name' AND u.takentime > 0;
SQL

echo "$(wc -l < "$OUT") files' dates written to $OUT"
