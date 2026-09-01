-- 0017_occasion_names — what the app cannot work out, and the person can.
--
-- The library can tell that a day was busy, where it happened, how much of it
-- was video and what hours it covered. It cannot tell that it was an engagement
-- party. Nothing in EXIF says so, and no amount of machine learning changes
-- that — a model would guess "Saturday Afternoon" or "Friends" and be
-- confidently beside the point.
--
-- So the app finds the occasion and the person supplies the meaning, once. That
-- is the one thing a self-hosted library can do that a guessing one cannot: be
-- *right*, and stay right every year afterwards.
--
-- Per user by construction. Two people in the same household remember the same
-- afternoon differently, and neither should be able to rename it for the other.
CREATE TABLE IF NOT EXISTS occasion_names (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    space_id    uuid NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
    month       smallint NOT NULL CHECK (month BETWEEN 1 AND 12),
    day         smallint NOT NULL CHECK (day BETWEEN 1 AND 31),
    -- Null means "every year on this date", which is what a birthday is. A row
    -- with a year names one occasion only, which is what an engagement party is.
    -- Storing both shapes in one table is deliberate: the difference between
    -- them is a single answer in the naming sheet, not a different feature.
    year        int,
    name        text NOT NULL CHECK (length(btrim(name)) > 0),
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

-- Two partial indexes rather than one key over a nullable column: Postgres
-- treats NULLs as distinct in a unique constraint, so a single key across
-- (user, space, month, day, year) would happily accept "every year" twice.
CREATE UNIQUE INDEX IF NOT EXISTS occasion_names_annual
  ON occasion_names (user_id, space_id, month, day)
  WHERE year IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS occasion_names_once
  ON occasion_names (user_id, space_id, month, day, year)
  WHERE year IS NOT NULL;

-- The read is "everything this person named in this space", once per Albums
-- page, so it is fetched whole rather than probed per day.
CREATE INDEX IF NOT EXISTS occasion_names_lookup
  ON occasion_names (user_id, space_id);
