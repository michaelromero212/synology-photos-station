#!/bin/bash
# A read-only look at one person's Synology Photos library before it's
# imported: what's there, which dates each file carries inside it, and what
# Synology Photos records that the files don't. The grid orders by local
# capture time, so a file whose date or time zone the import can't read is one
# that can land out of order. See MIGRATION.md.
#
# Prints counts and a few sample dates, never file names or pictures. Writes
# nothing. Run as root on the NAS, with the person's DSM username:
#
#   sudo bash /tmp/audit-synology-library.sh "<user>"
set -uo pipefail
# DSM's sudo leaves /usr/local/bin off the PATH, and that's where docker is.
export PATH="/usr/local/bin:$PATH"

# No apostrophe in this message: bash 4.4, the NAS's, reads one inside a
# double-quoted ${...} as the start of a quote and runs on for 13 lines.
NAME="${1:?Give the DSM username, in quotes if it has a space.}"
PHOTOS="/volume1/homes/$NAME/Photos"
APP=/volume1/docker/framestation
[ "$(id -u)" = 0 ] || { echo "Run with sudo." >&2; exit 2; }
[ -d "$PHOTOS" ] || { echo "No $PHOTOS." >&2; exit 2; }

say(){ printf '\n== %s\n' "$*"; }
synofoto(){ sudo -u postgres psql -d synofoto -X -q -A -t -F ' | ' -v name="$NAME" "$@"; }
library(){ (cd "$APP" && docker compose exec -T db psql -U framestation -d framestation -X -q -A -t -F ' | ' -v name="$NAME" "$@"); }
# exiftool from the server's own image, which mounts /volume1 the way an
# import does. Its own container, so the running server is untouched.
exiftool_(){ (cd "$APP" && docker compose run --rm --no-deps -T --entrypoint exiftool server "$@"); }

say "Folders in $NAME's Photos"
ls -1 "$PHOTOS" | sed 's/^/  /'

# The two that are Synology Photos' own; Personal/ and Shared/ are the app's.
SOURCES=()
for top in MobileBackup PhotoLibrary; do [ -d "$PHOTOS/$top" ] && SOURCES+=("$PHOTOS/$top"); done
[ "${#SOURCES[@]}" -gt 0 ] || { echo "Neither MobileBackup nor PhotoLibrary is here." >&2; exit 1; }

# Every file under the given folders, as "size name", leaving out Synology's
# thumbnails (@eaDir) and recycle bin.
media(){ find "$@" -path '*/@eaDir' -prune -o -path '*/#recycle' -prune -o -type f -printf '%s %f\n' 2>/dev/null; }

say "Files on disk, by folder (thumbnails in @eaDir left out)"
for source in "${SOURCES[@]}"; do
  for folder in "$source"/*/; do
    [ -d "$folder" ] || continue
    case "$(basename "$folder")" in @eaDir|'#recycle') continue;; esac
    years=$(find "$folder" -mindepth 1 -maxdepth 2 -type d -regex '.*/[12][0-9][0-9][0-9]$' -printf '%f\n' 2>/dev/null | sort -u | sed -n '1p;$p' | paste -sd- -)
    media "$folder" | awk -v name="${folder#"$PHOTOS"/}" -v years="${years:--}" \
      '{ n++; b += $1 } END { printf "  %-40s %7d files  %6.1f GB  years %s\n", name, n, b/1e9, years }'
  done
done

say "Files on disk, by type"
media "${SOURCES[@]}" | awk '{ sub(/^[0-9]+ /, ""); n = split($0, p, "."); print (n > 1 ? toupper(p[n]) : "(none)") }' \
  | sort | uniq -c | sort -rn | sed 's/^/  /'

say "Synology Photos' database"
USER_ID=$(synofoto -c "SELECT id FROM user_info WHERE name = '$(printf %s "$NAME" | sed "s/'/''/g")'")
if [ -z "$USER_ID" ]; then
  echo "  No user_info row named $NAME."
else
  echo "  user_info id $USER_ID"
  synofoto <<'SQL' | sed 's/^/  /'
\echo items by type (0 photo, 1 video) | count | without a taken time
SELECT u.type, count(*), count(*) FILTER (WHERE u.takentime IS NULL OR u.takentime = 0)
FROM unit u JOIN user_info i ON i.id = u.id_user
WHERE i.name = :'name' GROUP BY u.type ORDER BY u.type;
SQL
  echo "  unit's columns:"
  synofoto -c "SELECT string_agg(column_name || ' ' || data_type, ', ' ORDER BY ordinal_position) FROM information_schema.columns WHERE table_name = 'unit'" | fold -s -w 100 | sed 's/^/    /'
  echo "  other tables with a row of theirs (albums, tags, people and the like):"
  for table in $(synofoto -c "SELECT table_name FROM information_schema.columns WHERE column_name = 'id_user' AND table_schema = 'public' AND table_name NOT IN ('unit', 'folder') ORDER BY 1"); do
    rows=$(synofoto -c "SELECT count(*) FROM \"$table\" WHERE id_user = $USER_ID")
    [ "${rows:-0}" -gt 0 ] && printf '    %-36s %s\n' "$table" "$rows"
  done
fi

say "Dates inside the files (this reads every file's metadata; a few minutes)"
# -f prints "-" for a tag the file doesn't have. Keys:CreationDate is the
# local time and zone an iPhone writes into a video; QuickTime:CreateDate is
# the same moment in UTC, with no zone.
exiftool_ -r -f -q -q -i @eaDir -i '#recycle' \
  -p '$FileType|$EXIF:DateTimeOriginal|$EXIF:OffsetTimeOriginal|$EXIF:CreateDate|$Keys:CreationDate|$QuickTime:CreateDate|$XMP:DateCreated|$GPSLatitude' \
  "${SOURCES[@]}" 2>/dev/null \
| awk -F'|' '
  function kind(t) {
    if (t ~ /^(MOV|MP4|M4V|3GP|AVI|MKV|MTS|M2TS|WEBM)$/) return "video"
    if (t ~ /^(HEIC|HEIF|JPEG|JPG|PNG|GIF|TIFF|DNG|CR2|CR3|NEF|ARW|RAF|ORF|RW2|WEBP|BMP|AVIF)$/) return "photo"
    return "other"
  }
  {
    k = kind($1); gps = ($8 != "-") ? "has GPS" : "no GPS"
    if (k == "photo") {
      if ($2 != "-" && $3 != "-") c = "photo: date and zone"
      else if ($2 != "-")         c = "photo: date, no zone (" gps ")"
      else if ($4 != "-")         c = "photo: EXIF CreateDate only (" gps ")"
      else if ($7 != "-")         c = "photo: XMP DateCreated only (" gps ")"
      else                        c = "photo: no date inside (" gps ")"
    } else if (k == "video") {
      if ($5 != "-")      c = "video: local date and zone"
      else if ($6 != "-" && $6 !~ /^0000/) c = "video: UTC date only (" gps ")"
      else                c = "video: no date inside (" gps ")"
    } else c = "other: " $1
    n[c]++
  }
  END { for (c in n) printf "  %7d  %s\n", n[c], c }' | sort -k2

say "How Synology Photos' taken time compares, for a few recent items"
# Whether Synology keeps the moment or the local clock decides how its dates
# can be used. Dates only: no names.
if [ -n "${USER_ID:-}" ]; then
  PHOTOS_SQL=$(printf %s "$PHOTOS" | sed "s/'/''/g")
  for type in 0 1; do
    mapfile -t rows < <(synofoto <<SQL
SELECT regexp_replace('$PHOTOS_SQL/' || f.name || '/' || u.filename, '/+', '/', 'g')
       || '|' || to_char(to_timestamp(u.takentime) AT TIME ZONE 'UTC', 'YYYY:MM:DD HH24:MI:SS')
FROM unit u JOIN folder f ON f.id = u.id_folder
WHERE u.id_user = $USER_ID AND u.type = $type AND u.takentime > 0
ORDER BY u.takentime DESC LIMIT 5;
SQL
)
    [ "${#rows[@]}" -gt 0 ] || continue
    paths=(); taken=()
    for row in "${rows[@]}"; do paths+=("${row%|*}"); taken+=("${row##*|}"); done
    [ "$type" = 0 ] && echo "  photos — Synology (as UTC) | DateTimeOriginal | OffsetTimeOriginal" \
                    || echo "  videos — Synology (as UTC) | Keys:CreationDate | QuickTime:CreateDate (UTC)"
    # Matched by path here, so a file exiftool can't read shows as "?" rather
    # than shifting every line after it. The paths stay in the script.
    declare -A inside=()
    while IFS='|' read -r path dto off created utc; do
      inside["$path"]="$dto|$off|$created|$utc"
    done < <(exiftool_ -f -q -q \
      -p '$Directory/$FileName|$EXIF:DateTimeOriginal|$EXIF:OffsetTimeOriginal|$Keys:CreationDate|$QuickTime:CreateDate' \
      "${paths[@]}" 2>/dev/null)
    for i in "${!paths[@]}"; do
      IFS='|' read -r dto off created utc <<< "${inside[${paths[$i]}]:-?|?|?|?}"
      if [ "$type" = 0 ]; then echo "    ${taken[$i]} | $dto | $off"
      else echo "    ${taken[$i]} | $created | $utc"; fi
    done
    unset inside
  done
fi

say "Their FrameStation library"
library <<'SQL' | sed 's/^/  /'
\echo personal library id | items in it
SELECT s.id, (SELECT count(*) FROM space_assets sa WHERE sa.space_id = s.id AND sa.deleted_at IS NULL)
FROM spaces s
JOIN space_members m ON m.space_id = s.id AND m.role = 'owner'
JOIN users u ON u.id = m.user_id
WHERE s.kind = 'personal' AND u.dsm_username = :'name' AND u.deleted_at IS NULL;
SQL

say "The Shared Space import, for comparison: imported rows without a time zone"
library <<'SQL' | sed 's/^/  /'
\echo type | imported | without a time zone
SELECT a.media_type, count(*), count(*) FILTER (WHERE a.captured_tz_off IS NULL)
FROM import_records r JOIN assets a ON a.id = r.asset_id
WHERE r.source_path LIKE '/volume1/photo/%' AND r.outcome = 'imported'
GROUP BY a.media_type ORDER BY 1;
SQL

say "Time zone the server runs in"
(cd "$APP" && docker compose exec -T server sh -c 'echo "  TZ=${TZ:-unset}  now: $(date)"')

echo
echo "Done. Nothing was changed."
