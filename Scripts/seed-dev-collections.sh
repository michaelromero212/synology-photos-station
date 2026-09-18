#!/usr/bin/env bash
#
# Fills the dev library with enough shape to exercise the Albums page.
#
# The page is built on rules that need a library behind them — a trip is two
# consecutive days a long way from home, a busy day is three times the median
# day, a revisit is somewhere unvisited for two years. A dev library of twenty
# photographs across five days correctly produces *nothing*, which is right and
# also impossible to look at. This produces a library with something in it.
#
# The rows carry no blobs, so their tiles render gray. That is fine for what
# this is for — the titles, the grouping, the thresholds and the empty-state
# rules are all exercised, and none of them care what the picture looks like.
# Upload a handful of real photographs through the app if you want covers.
#
#   ./Scripts/seed-dev-collections.sh            # add the fixtures
#   ./Scripts/seed-dev-collections.sh --clean    # take them away again
#
# Every row is tagged `DEVSEED` in its sha256, which is what makes --clean exact.
set -euo pipefail

PGHOST=127.0.0.1
PGPORT=55432
PGUSER=framestation
PGDATABASE=framestation
export PGPASSWORD=x

SPACE=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -tAc \
  "SELECT id FROM spaces WHERE kind = 'personal' ORDER BY created_at LIMIT 1;")
USER_ID=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -tAc \
  "SELECT user_id FROM space_members WHERE space_id = '$SPACE' LIMIT 1;")

if [ -z "$SPACE" ] || [ -z "$USER_ID" ]; then
  echo "No personal space with a member — sign in on the simulator first." >&2
  exit 1
fi

clean() {
  psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" <<'SQL'
DELETE FROM space_assets WHERE asset_id IN (SELECT id FROM assets WHERE sha256 LIKE 'DEVSEED%');
DELETE FROM assets WHERE sha256 LIKE 'DEVSEED%';
SQL
  echo "fixtures removed"
}

if [ "${1:-}" = "--clean" ]; then
  clean
  exit 0
fi

clean >/dev/null

# Dates are relative to today, so the fixtures stay meaningful whenever this is
# run — "on this day" in particular is worthless pinned to a fixed date.
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" <<SQL
-- A quiet baseline. Without it the median day rises until nothing is "busy",
-- which is the single easiest way to seed a library that shows nothing.
INSERT INTO assets (sha256, byte_size, media_type, mime, blob_ext, local_captured_at, place_name, lat, lon)
SELECT 'DEVSEEDQUIET' || lpad(g::text, 52, '0'), 1000, 'photo', 'image/jpeg', 'jpg',
       (CURRENT_DATE - (g / 2 || ' days')::interval + '13:00'::time)::timestamp,
       'Culpeper, Virginia', 38.4716, -77.9967
FROM generate_series(1, 300) g;

-- On this day, one year and six years back.
INSERT INTO assets (sha256, byte_size, media_type, mime, blob_ext, local_captured_at, place_name, lat, lon)
SELECT 'DEVSEEDOTD' || lpad(g::text, 54, '0'), 1000, 'photo', 'image/jpeg', 'jpg',
       ((CURRENT_DATE - CASE WHEN g <= 8 THEN interval '1 year' ELSE interval '6 years' END)
         + ((11 + (g % 7)) || ' hours')::interval)::timestamp,
       'Culpeper, Virginia', 38.4716, -77.9967
FROM generate_series(1, 16) g;

-- A week on the Outer Banks, across three towns: "Seven days in North Carolina".
INSERT INTO assets (sha256, byte_size, media_type, mime, blob_ext, local_captured_at, place_name, lat, lon)
SELECT 'DEVSEEDOBX' || lpad(g::text, 54, '0'), 1000, 'photo', 'image/jpeg', 'jpg',
       ((CURRENT_DATE - interval '7 weeks') + ((g / 9) || ' days')::interval
         + ((10 + (g % 9)) || ' hours')::interval)::timestamp,
       (ARRAY['Nags Head, North Carolina','Kill Devil Hills, North Carolina','Duck, North Carolina'])[(g % 3) + 1],
       35.95 + (g % 5) * 0.01, -75.62 + (g % 4) * 0.01
FROM generate_series(0, 62) g;

-- A trip covering today's date two years ago, so an anniversary exists.
INSERT INTO assets (sha256, byte_size, media_type, mime, blob_ext, local_captured_at, place_name, lat, lon)
SELECT 'DEVSEEDANNIV' || lpad(g::text, 52, '0'), 1000, 'photo', 'image/jpeg', 'jpg',
       ((CURRENT_DATE - interval '2 years' - interval '3 days') + ((g / 10) || ' days')::interval
         + ((10 + (g % 8)) || ' hours')::interval)::timestamp,
       'Bay Lake, Florida', 28.385, -81.563
FROM generate_series(0, 59) g;

-- An evening, and a day of video: two of the derived-title rules.
INSERT INTO assets (sha256, byte_size, media_type, mime, blob_ext, local_captured_at, place_name, lat, lon)
SELECT 'DEVSEEDEVE' || lpad(g::text, 54, '0'), 1000, 'photo', 'image/jpeg', 'jpg',
       ((CURRENT_DATE - interval '25 days') + ((18 + (g % 4)) || ' hours')::interval)::timestamp,
       'Culpeper, Virginia', 38.4716, -77.9967
FROM generate_series(1, 22) g;

INSERT INTO assets (sha256, byte_size, media_type, mime, blob_ext, local_captured_at, place_name, lat, lon, duration_ms)
SELECT 'DEVSEEDVID' || lpad(g::text, 54, '0'), 1000,
       CASE WHEN g <= 16 THEN 'video' ELSE 'photo' END, 'video/mp4', 'mp4',
       ((CURRENT_DATE - interval '40 days') + ((13 + (g % 4)) || ' hours')::interval)::timestamp,
       'Arlington, Virginia', 38.88, -77.10, 5000
FROM generate_series(1, 24) g;

-- Somewhere well known and long unvisited.
INSERT INTO assets (sha256, byte_size, media_type, mime, blob_ext, local_captured_at, place_name, lat, lon)
SELECT 'DEVSEEDOLD' || lpad(g::text, 54, '0'), 1000, 'photo', 'image/jpeg', 'jpg',
       ((CURRENT_DATE - interval '4 years') + ((g % 4) || ' days')::interval + '12:00'::time)::timestamp,
       'Asheville, North Carolina', 35.59, -82.55
FROM generate_series(1, 30) g;

-- Christmas, most recently gone.
INSERT INTO assets (sha256, byte_size, media_type, mime, blob_ext, local_captured_at, place_name, lat, lon)
SELECT 'DEVSEEDXMAS' || lpad(g::text, 53, '0'), 1000, 'photo', 'image/jpeg', 'jpg',
       ((date_trunc('year', CURRENT_DATE) - interval '1 year' + interval '11 months' + interval '24 days')
         + ((10 + (g % 9)) || ' hours')::interval)::timestamp,
       'Culpeper, Virginia', 38.4716, -77.9967
FROM generate_series(1, 34) g;

-- The baseline has to get out of the way of the days it is a baseline *for*.
--
-- It lays two photographs on every day going back, which is what keeps the
-- median honest — and it also lands them on the evening, the day of video and
-- the trip. A 1pm photograph inside an 18:00–21:00 evening widens that day's
-- span from three hours to eight, and "An evening in Culpeper" comes out as "A
-- busy Friday". The rule was right; the fixture was lying to it.
DELETE FROM assets q
WHERE q.sha256 LIKE 'DEVSEEDQUIET%'
  AND to_char(q.local_captured_at, 'YYYY-MM-DD') IN (
      SELECT to_char(s.local_captured_at, 'YYYY-MM-DD')
      FROM assets s
      WHERE s.sha256 LIKE 'DEVSEED%' AND s.sha256 NOT LIKE 'DEVSEEDQUIET%'
  );

INSERT INTO space_assets (space_id, asset_id, uploaded_by_user_id)
SELECT '$SPACE', a.id, '$USER_ID'
FROM assets a WHERE a.sha256 LIKE 'DEVSEED%';
SQL

echo
echo "seeded. Restart the dev server so it re-reads, then open the Albums tab:"
echo "  launchctl kickstart -k gui/\$(id -u)/dev.framestation.server"
