-- 0019_retention — Recently Deleted becomes a fixed window rather than a place
-- things go to and stay.
--
-- Deletion used to move the file into a `#recycle` folder beside itself at the
-- moment you pressed delete, and record where it went in `recycled_path`. Two
-- things were wrong with that. Nothing ever aged anything out, so Recently
-- Deleted was a one-way door — items landed there and stayed for good. And the
-- bin carried DSM's own name, so DSM's scheduled emptying could reclaim the
-- bytes at any point, which is why the list had to check the file still existed
-- before offering a restore that might fail.
--
-- Now FrameStation owns the clock. Deleting sets `deleted_at` and nothing else;
-- the browse-tree reconciler already withdraws the copies from every member's
-- home on its next sweep, which is what makes it *deleted* as far as File
-- Station is concerned. The bytes stay in the blob store, untouched, until the
-- retention sweeper purges them.
--
-- Because the app owns the window, the countdown it shows is one it can keep.
ALTER TABLE space_assets
    ADD COLUMN IF NOT EXISTS purged_at timestamptz;

-- The sweeper asks "what is past the window and not yet purged", which is a
-- small slice of a column that is NULL for almost every row in the table.
CREATE INDEX IF NOT EXISTS space_assets_pending_purge
    ON space_assets (deleted_at)
    WHERE deleted_at IS NOT NULL AND purged_at IS NULL;

-- Anything already deleted under the old scheme starts its 29 days now rather
-- than from whenever it was deleted. These rows were never going to expire at
-- all, so dating the window from the original deletion would purge them the
-- instant this ships — including things deleted minutes earlier. Restarting the
-- clock is the conservative reading of a window that did not previously exist.
UPDATE space_assets
SET deleted_at = now()
WHERE deleted_at IS NOT NULL AND purged_at IS NULL;

-- `recycled_path` is left in place rather than dropped. Files moved into
-- `#recycle` by the old delete path are still sitting there, and the column is
-- the only record of where they went; a later migration can drain them once
-- there is nothing left to drain. Nothing reads it any more.
COMMENT ON COLUMN space_assets.recycled_path IS
    'Legacy: where the old delete path moved the file. Unused since 0019.';
