#!/bin/bash
# One person's Synology Photos albums, for `FrameStationServer import-albums`:
# a line per file of each album's items, in the album's order: the album's id
# there, its name, when it was made (UTC), the item's place in it, the item's
# id, the file's path as the import walks it, and "cover" on the cover's file.
# See MIGRATION.md.
#
# Reads Synology's database and changes nothing there. Run as root on the NAS
# with the person's DSM username and a file to write, somewhere the server's
# container can read:
#
#   sudo bash /tmp/export-synology-albums.sh "<user>" /volume1/docker/framestation/synology-albums.tsv
set -uo pipefail

# No apostrophe in these messages: bash 4.4, the NAS's, reads one inside a
# double-quoted ${...} as the start of a quote.
NAME="${1:?Give the DSM username, in quotes if it has a space.}"
OUT="${2:?Give a file to write, such as /volume1/docker/framestation/synology-albums.tsv}"
ROOT="/volume1/homes/$NAME/Photos"
[ "$(id -u)" = 0 ] || { echo "Run with sudo." >&2; exit 2; }
[ -d "$ROOT" ] || { echo "No $ROOT." >&2; exit 2; }

# It names photos, so it's root's alone; the chmod as well as the umask,
# because a new file otherwise takes the shared folder's access list.
umask 077
: > "$OUT" && chmod 600 "$OUT" || exit 1

# In the order the album shows them: by time taken, newest first where it's
# set to (sort_direction 2), oldest first otherwise, then by Synology's own
# sequence. An item is one or more files (a Live Photo is two).
sudo -u postgres psql -d synofoto -X -q -A -t -F $'\t' -v name="$NAME" -v root="$ROOT" > "$OUT" <<'SQL'
WITH items AS (
  SELECT na.id AS album, na.name, na.create_time, na.cover, na.sort_direction,
         m.id_item, m.sequence, min(u.takentime) AS taken
  FROM normal_album na
  JOIN user_info i ON i.id = na.id_user
  JOIN many_item_has_many_normal_album m ON m.id_normal_album = na.id
  JOIN unit u ON u.id_item = m.id_item
  WHERE i.name = :'name'
  GROUP BY na.id, na.name, na.create_time, na.cover, na.sort_direction, m.id_item, m.sequence
), placed AS (
  SELECT *, row_number() OVER (
           PARTITION BY album
           ORDER BY CASE WHEN sort_direction = 2 THEN -taken ELSE taken END, sequence, id_item) - 1 AS position
  FROM items
)
SELECT p.album, p.name, to_char(to_timestamp(p.create_time) AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS'),
       p.position, p.id_item,
       regexp_replace(:'root' || '/' || f.name || '/' || u.filename, '/+', '/', 'g'),
       CASE WHEN u.id = p.cover THEN 'cover' ELSE '' END
FROM placed p
JOIN unit u ON u.id_item = p.id_item
JOIN folder f ON f.id = u.id_folder
ORDER BY p.album, p.position, u.id;
SQL

echo "$(cut -f1 "$OUT" | sort -u | wc -l) albums, $(wc -l < "$OUT") files written to $OUT"
