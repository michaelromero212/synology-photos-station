-- Step three of ARCHITECTURE.md §3a: removing a photo is remembered.
--
-- "Not on the server" and "never backed up" are different facts, and treating
-- them the same makes deleted photos resurrect on the next backup run. The
-- soft-deleted placement is the record that the user removed something
-- deliberately, and it has to outlive an app reinstall — the phone's local
-- queue does not.
--
-- deleted_at already existed and was only ever cleared. This indexes it for the
-- lookup probe now performs, and records who removed it and when the file was
-- moved aside.
ALTER TABLE space_assets ADD COLUMN IF NOT EXISTS deleted_by uuid REFERENCES users(id);
ALTER TABLE space_assets ADD COLUMN IF NOT EXISTS recycled_path text;

CREATE INDEX IF NOT EXISTS space_assets_removed
  ON space_assets (space_id, uploaded_by_user_id)
  WHERE deleted_at IS NOT NULL;
