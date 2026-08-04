-- Step one of making the file canonical and the database an index.
-- See ARCHITECTURE.md §3a.
--
-- Additive only. storage_path is the absolute path of the canonical file; NULL
-- means the row still points at the content-addressed blob store, which is how
-- every existing row behaves and how rows are still created when the library
-- layout is disabled. Readers prefer storage_path and fall back, so both models
-- coexist while the migration proceeds.
--
-- The unique constraint on sha256 deliberately stays for now. Dropping it is
-- what lets two people hold their own copy of the same photo, but the commit
-- path still relies on ON CONFLICT (sha256) to make re-uploads idempotent, and
-- that only works against a unique index. Both change together in the increment
-- that makes sharing copy files rather than link rows -- removing the
-- constraint before its dependents is how this increment broke every upload the
-- first time.
ALTER TABLE assets ADD COLUMN IF NOT EXISTS storage_path text;

CREATE INDEX IF NOT EXISTS assets_storage_path ON assets (storage_path)
  WHERE storage_path IS NOT NULL;
