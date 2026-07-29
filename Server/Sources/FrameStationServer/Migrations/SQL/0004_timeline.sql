-- 0004_timeline — a stored local capture time so bucket queries are indexable.
--
-- Photos must group by the *local wall clock* of the place they were taken: a
-- shot at 11pm in Virginia belongs to that day, not the next one in UTC. That
-- means captured_at shifted by captured_tz_off.
--
-- Computing it inline would be correct but unindexable, so every bucket fetch
-- while scrolling would sequentially scan space_assets. A generated column is
-- not an option either — `timestamptz AT TIME ZONE text` is STABLE, not
-- IMMUTABLE, so Postgres rejects it. Hence a plain column, written wherever
-- captured_at is written.

ALTER TABLE assets ADD COLUMN local_captured_at timestamp;

UPDATE assets
SET local_captured_at =
    (captured_at + COALESCE(captured_tz_off, 0) * interval '1 second') AT TIME ZONE 'UTC'
WHERE captured_at IS NOT NULL;

CREATE INDEX assets_local_captured_at ON assets (local_captured_at DESC NULLS LAST);
