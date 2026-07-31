-- The File Station tree: a browsable copy of each photo alongside the
-- content-addressed store.
--
-- Blobs are named by hash, which is right for storage and useless to a person
-- opening File Station. These columns track the human-readable counterpart so
-- it can be built once, skipped when already present, and repaired if the tree
-- is deleted from under us.
ALTER TABLE space_assets ADD COLUMN IF NOT EXISTS filename text;
-- Absolute path of the reflink, NULL until it has been placed.
ALTER TABLE space_assets ADD COLUMN IF NOT EXISTS browse_path text;
ALTER TABLE space_assets ADD COLUMN IF NOT EXISTS browse_error text;

-- The claim query: placements still waiting for a tree entry.
CREATE INDEX IF NOT EXISTS space_assets_unplaced
  ON space_assets (id) WHERE browse_path IS NULL AND deleted_at IS NULL;
