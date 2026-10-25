-- 0034_stacked — a file shown through another, as Synology Photos shows it.
--
-- Synology Photos makes one grid item of every file in a folder that carries
-- the same Apple Live Photo identifier: a Live Photo's photo and video, and a
-- JPEG exported or an Instagram copy saved from it. It shows one and keeps the
-- rest with it. An imported library is grouped the same way (`ImportGrouping`),
-- so its grid has the items Synology's has. A Live Photo's own video keeps its
-- `live_group_id`, as an upload's does; anything else in the item points at the
-- file it's shown through, stays off the grid (`TimelineController.visible`),
-- and is removed, restored and purged with it.
ALTER TABLE assets
  ADD COLUMN IF NOT EXISTS stacked_under uuid REFERENCES assets(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS assets_stacked_under
  ON assets (stacked_under) WHERE stacked_under IS NOT NULL;

-- The identifier the import read from each file, so a library imported over
-- several runs is grouped as a whole: NULL until read, '' when it has none.
ALTER TABLE import_records ADD COLUMN IF NOT EXISTS live_identifier text;
