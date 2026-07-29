-- 0002_uploads — resumable chunked upload sessions.
--
-- iOS background URLSession upload tasks cannot resume mid-file: a failed
-- transfer restarts from zero. With ~3,000 videos averaging a few hundred MB,
-- single-shot uploads mean some videos never complete. Large files are split
-- client-side into fixed-size chunks, each its own background task, and
-- reassembled here.

CREATE TABLE upload_sessions (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  space_id      uuid NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
  device_id     uuid REFERENCES devices(id) ON DELETE SET NULL,
  sha256        text NOT NULL,
  byte_size     bigint NOT NULL,
  filename      text NOT NULL,
  chunk_size    int NOT NULL,
  chunk_count   int NOT NULL,
  -- Bitmap of received chunks, one bit per chunk. Updated with Postgres
  -- set_bit() so concurrent chunk PUTs can't lose bits to a read-modify-write
  -- race the way a client-side mask would.
  received_mask bytea NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  committed_at  timestamptz
);

-- One in-flight session per user per file. A retry after a crash resumes the
-- existing session instead of orphaning its staged chunks.
CREATE UNIQUE INDEX one_open_upload_per_user_sha
  ON upload_sessions (user_id, sha256) WHERE committed_at IS NULL;

CREATE INDEX ON upload_sessions (created_at) WHERE committed_at IS NULL;
