-- 0042_ready_copies — copies of a photo that never heard it was ready. See
-- `DerivationWorker.readyCopies`.
--
-- A photo shared into a shared library or an album shared with people is
-- copied, and the copy took the photo's derived_at and ThumbHash as they were
-- then. Shared before the NAS had made its thumbnail — an upload added to an
-- album straight away — the copy was left "not ready" for good, a gray tile
-- everywhere but on the phone that took it, while the photo it copies has
-- long been done. Same file, same content hash, same thumbnails: each such
-- copy is marked as ready as its photo, and every library or album it is in
-- is told, so the devices holding the gray tile fetch the picture.
--
-- Runs before the server takes requests, so writing change_log directly here
-- needs none of ChangeLog.append's locking.
WITH done AS (
    SELECT DISTINCT ON (sha256) sha256, thumbhash, width, height, derived_at, thumb_version
    FROM assets
    WHERE derived_at IS NOT NULL
    ORDER BY sha256, derived_at DESC
),
fixed AS (
    UPDATE assets c
    SET thumbhash     = COALESCE(c.thumbhash, d.thumbhash),
        width         = COALESCE(c.width, d.width),
        height        = COALESCE(c.height, d.height),
        derived_at    = d.derived_at,
        thumb_version = d.thumb_version
    FROM done d
    WHERE c.sha256 = d.sha256 AND c.derived_at IS NULL
    RETURNING c.id
)
INSERT INTO change_log (space_id, entity, entity_id, op)
SELECT sa.space_id, 'space_asset', sa.id, 'update'
FROM space_assets sa
JOIN fixed f ON f.id = sa.asset_id
WHERE sa.deleted_at IS NULL
ORDER BY sa.space_id, sa.id;
