-- 0025_placement_lookup — find an asset's placements without reading them all,
-- and retire the motion halves of Live Photos deleted before deletion took them.
--
-- "Where is this asset placed?" is asked on every upload (the thumbnail the
-- phone hands over is announced to each library holding the photo), every time
-- a thumbnail finishes deriving — inside the transaction holding that library's
-- change-log lock — and by retention, the backfills and the browse-tree
-- reconciler. space_assets had no index that starts with asset_id, so each of
-- those read every placement in the house: 4.3 ms against 0.015 ms measured on a
-- 67,000-photo library, several times that on the NAS's disks, and paid once
-- per photo during a backup.
CREATE INDEX IF NOT EXISTS space_assets_asset_id ON space_assets (asset_id);

-- Deleting a Live Photo now deletes its video half with it (see
-- AssetController.remove), but for as long as it didn't, deleting one left the
-- motion clip placed: invisible in every grid, still in each member's File
-- Station folder, and never purged. Those placements take the deletion of their
-- still — its time and who did it — so they go through Recently Deleted and
-- retention exactly as they would have. A video whose still was purged long ago
-- is past the window already and goes on the retention sweeper's next pass.
--
-- Only where no live copy of the same Live Photo remains in that library to
-- need the video. Idempotent: a second run matches nothing.
UPDATE space_assets pv
SET deleted_at = ps.deleted_at,
    deleted_by = ps.deleted_by
FROM space_assets ps
JOIN assets still ON still.id = ps.asset_id
JOIN assets video ON video.live_group_id = still.live_group_id
WHERE still.live_group_id IS NOT NULL
  AND still.media_type = 'photo'
  AND video.media_type = 'video'
  AND video.id <> still.id
  AND ps.deleted_at IS NOT NULL
  AND pv.asset_id = video.id
  AND pv.space_id = ps.space_id
  AND pv.deleted_at IS NULL
  AND NOT EXISTS (
      SELECT 1 FROM space_assets live
      JOIN assets twin ON twin.id = live.asset_id
      WHERE live.space_id = ps.space_id
        AND live.deleted_at IS NULL
        AND twin.live_group_id = still.live_group_id
        AND twin.media_type = 'photo'
  );
