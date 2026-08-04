-- Step two of ARCHITECTURE.md §3a: adding a photo to a shared library copies
-- the file, the way Synology Photos copies into its Shared Space.
--
-- Two placements now mean two files, so they need two rows: one asset row per
-- file, each with its own storage_path. A unique constraint on the content hash
-- would force them back into one.
--
-- Safe to drop only now. The commit path used ON CONFLICT (sha256) to make a
-- repeated commit idempotent, and that needs a unique index -- removing the
-- constraint while commit still depended on it broke every upload. Commit
-- guards on upload_sessions.committed_at instead, which is the more direct
-- statement of what it actually wants: this upload has already been committed.
ALTER TABLE assets DROP CONSTRAINT IF EXISTS assets_sha256_key;

-- Still indexed, just no longer unique. The hash is how a re-upload is
-- recognised and how a file can be checked against what we believe it to be;
-- it simply no longer decides identity.
CREATE INDEX IF NOT EXISTS assets_sha256 ON assets (sha256);
