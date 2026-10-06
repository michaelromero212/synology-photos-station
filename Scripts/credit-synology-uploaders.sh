#!/bin/sh
# Credits each photo imported from Synology Photos' Shared Space to the person
# who shared it there, so its Information panel reads "Added by" them.
#
# Synology files every Shared Space photo under the shared library itself, not
# under whoever added it. But sharing a photo there copies it out of the
# sharer's own library, so whoever's own library holds the same photo, by
# Synology's content fingerprint, is who shared it. When more than one person
# has it (an AirDrop, say), the one whose phone backed it up first. A photo
# nobody else has stays credited as it is. See CreditUploadersCommand and
# MIGRATION.md.
#
# Run on the NAS as root, the dry run first. It only reads Synology's
# database, and the dry run changes nothing anywhere:
#
#   sudo sh credit-synology-uploaders.sh <space-id> --dry-run
#   sudo sh credit-synology-uploaders.sh <space-id>
set -e
SPACE="${1:?usage: credit-synology-uploaders.sh <space-id> [--dry-run]}"
shift
OUT=/volume1/docker/framestation/synology-credits.tsv
TAB=$(printf '\t')

# One line per matched Shared Space photo: the path the import read it from,
# the sharer's Synology uid, and their Synology login.
sudo -u postgres psql -d synofoto -A -t -F "$TAB" -c "
  WITH shared AS (
    SELECT u.id, u.duplicate_hash FROM unit u
    WHERE u.id_user = 0 AND u.duplicate_hash <> ''),
  own AS (
    SELECT u.duplicate_hash, u.id_user, min(u.createtime) AS first_seen,
           bool_or(f.name LIKE '/MobileBackup/%') AS from_phone
    FROM unit u JOIN folder f ON f.id = u.id_folder
    WHERE u.id_user <> 0 AND u.duplicate_hash <> ''
    GROUP BY 1, 2),
  ranked AS (
    SELECT s.id, o.id_user,
           row_number() OVER (PARTITION BY s.id ORDER BY o.from_phone DESC, o.first_seen) AS rank
    FROM shared s JOIN own o ON o.duplicate_hash = s.duplicate_hash)
  SELECT regexp_replace(
           (SELECT name FROM user_info WHERE id = 0) || '/' || f.name || '/' || u.filename,
           '/+', '/', 'g'),
         ui.uid, ui.name
  FROM ranked r
  JOIN unit u ON u.id = r.id
  JOIN folder f ON f.id = u.id_folder
  JOIN user_info ui ON ui.id = r.id_user
  WHERE r.rank = 1 AND ui.uid IS NOT NULL" > "$OUT"

echo "Synology matched $(wc -l < "$OUT" | tr -d ' ') Shared Space photos to the person who shared them."
cd /volume1/docker/framestation
/usr/local/bin/docker compose exec -T server ./FrameStationServer credit-uploaders \
  --from "$OUT" --space "$SPACE" "$@"
