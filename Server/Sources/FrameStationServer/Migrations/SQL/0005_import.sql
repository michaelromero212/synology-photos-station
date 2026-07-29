-- 0005_import — resumability for the one-time library import.
--
-- The import walks 800 GB. The hashing pass alone is ~75 minutes disk-bound,
-- so a run interrupted at hour three must not start over. Recording each source
-- path with its size and mtime lets a resumed run skip untouched files without
-- re-reading a byte.
--
-- Keyed on source_path rather than sha256 because the question being asked is
-- "have I already dealt with this file on disk", which is distinct from "do I
-- already have these bytes" — two copies of the same photo in different folders
-- are one asset but two import records.

CREATE TABLE import_records (
  source_path text PRIMARY KEY,
  sha256      text,
  asset_id    uuid REFERENCES assets(id) ON DELETE SET NULL,
  byte_size   bigint NOT NULL,
  modified_at timestamptz NOT NULL,
  imported_at timestamptz NOT NULL DEFAULT now(),
  -- 'imported' | 'deduplicated' | 'skipped' | 'failed'
  outcome     text NOT NULL,
  error       text
);

CREATE INDEX import_records_outcome ON import_records (outcome);
CREATE INDEX import_records_asset ON import_records (asset_id);
