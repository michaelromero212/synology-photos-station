-- 0003_derivations — the media pipeline's work queue.
--
-- Metadata extraction is fast (~50 ms) and the timeline needs captured_at and
-- dimensions immediately, so commit does that inline. Thumbnails are the slow
-- part and get queued: at 100k assets an import must be able to run for hours,
-- survive restarts, and resume where it stopped.

ALTER TABLE assets ADD COLUMN derived_at timestamptz;

-- The blob filename is <sha256>.<ext>, where ext comes from the *upload
-- filename*, not the MIME type. Deriving it from MIME later would guess wrong
-- (IMG.JPEG vs image/jpeg) and the worker would look for a file that isn't
-- there, so it is recorded at commit instead.
ALTER TABLE assets ADD COLUMN blob_ext text NOT NULL DEFAULT '';

CREATE TABLE derivation_jobs (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  asset_id    uuid NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
  kind        text NOT NULL CHECK (kind IN ('metadata','thumbnails','poster')),
  state       text NOT NULL DEFAULT 'pending'
                CHECK (state IN ('pending','running','done','failed')),
  attempts    int NOT NULL DEFAULT 0,
  last_error  text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  started_at  timestamptz,
  finished_at timestamptz,
  UNIQUE (asset_id, kind)
);

-- Claim index. Workers pull with FOR UPDATE SKIP LOCKED so several can drain
-- the queue in parallel without fighting over the same row.
CREATE INDEX derivation_jobs_claimable
  ON derivation_jobs (created_at)
  WHERE state IN ('pending', 'failed');
