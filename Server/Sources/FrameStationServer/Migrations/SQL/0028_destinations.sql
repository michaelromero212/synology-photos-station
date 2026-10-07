-- 0028_destinations — the name a place goes by when it isn't its town's.
--
-- The town dataset files a photo at Epcot under Celebration and one at Old
-- Faithful under West Yellowstone, Montana. `destination` holds the name the
-- place is actually known by, "Walt Disney World, Florida", for photos taken
-- inside one of the places `Destinations` draws. Everything that shows a
-- place reads it ahead of `place_name`, which stays as it was, so the town
-- can still be searched for.
--
-- `destination_version` is the version of the list a row was filed under.
-- Every row starts at 0, so the server's boot-time pass files the whole
-- library once, and again whenever the list changes. See
-- `Destinations.backfill`.
ALTER TABLE assets ADD COLUMN IF NOT EXISTS destination text;
ALTER TABLE assets ADD COLUMN IF NOT EXISTS destination_version int NOT NULL DEFAULT 0;
