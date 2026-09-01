-- 0018_browse_entries — one tree entry per person who may see the photo.
--
-- `space_assets.browse_path` held a single path, which was right while every
-- photo appeared in exactly one place: a personal photo in its owner's home, a
-- shared photo in one folder everybody could read. That second half is the
-- problem. One folder everybody can read means everybody can read it — File
-- Station has no idea which app-level space somebody belongs to, so a shared
-- library was visible to the whole household regardless of membership.
--
-- So a shared photo now appears in *each member's* home instead, and the
-- enforcement becomes DSM's own home permissions, which already work and which
-- nobody has to remember to configure. That needs one path per member, which is
-- a row rather than a column.
--
-- Reflink makes this nearly free: the bytes are shared with the blob store and
-- with each other, so five members cost one copy on disk. Measured on this NAS
-- rather than assumed — see DEPLOY.md, and note that a fall back to a real copy
-- would silently change that arithmetic.
CREATE TABLE IF NOT EXISTS browse_entries (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    space_asset_id  uuid NOT NULL REFERENCES space_assets(id) ON DELETE CASCADE,
    -- Whose home this copy lives in. For a personal space that is the owner;
    -- for a shared space, one row per member.
    user_id         uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    path            text NOT NULL,
    -- reflink | hardlink | copy. Recorded because a silent fall back to `copy`
    -- is the difference between five members costing one copy and five.
    link_kind       text NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (space_asset_id, user_id)
);

-- The reconciler asks "which placements are missing an entry for somebody who
-- should have one", and the remover asks "what did this person have".
CREATE INDEX IF NOT EXISTS browse_entries_placement ON browse_entries (space_asset_id);
CREATE INDEX IF NOT EXISTS browse_entries_user ON browse_entries (user_id);

-- Existing single-path entries carry over, so a library that has already been
-- placed is not re-linked from scratch. `uploaded_by_user_id` is the right
-- owner for the personal case, which is the only case that has ever run.
INSERT INTO browse_entries (space_asset_id, user_id, path, link_kind)
SELECT sa.id, sa.uploaded_by_user_id, sa.browse_path, 'reflink'
FROM space_assets sa
WHERE sa.browse_path IS NOT NULL
ON CONFLICT (space_asset_id, user_id) DO NOTHING;
