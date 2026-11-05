-- 0036_nas_analysis — what the NAS itself saw in each photo and video.
--
-- The analyzer container (Analyzer/, NAS-ANALYSIS.md) reads originals with
-- pinned open models and no network. The server stores what it answers and
-- is the only writer. Shadow mode first: nothing here reaches any endpoint.
--
-- Per person and file, like media_observations: two people holding the same
-- bytes each have their own row, so deleting "my AI data" deletes exactly mine.
-- Keyed by SHA-256, which survives `rebuild`, read from the asset row and
-- never accepted from a client.
CREATE TABLE IF NOT EXISTS nas_analysis (
    user_id          uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    sha256           text NOT NULL,
    -- The analyzer's own version. A newer analyzer analyzes again whatever an
    -- older one produced.
    analyzer_version smallint NOT NULL,
    -- Which model files, by name and hash prefix, for the record.
    models           text NOT NULL,
    status           text NOT NULL CHECK (status IN ('done', 'failed', 'skipped')),
    -- A short code from the analyzer or the server ('unsupported',
    -- 'not-found', …). Never a path, never anything from inside the file.
    error            text,
    attempts         smallint NOT NULL DEFAULT 1,
    -- 1 for a photo; the sampled keyframes for a video.
    frames           smallint NOT NULL DEFAULT 0,
    -- frames × 768 little-endian float32: SigLIP 2's view of each frame.
    scene            bytea,
    face_count       smallint NOT NULL DEFAULT 0,
    duration_ms      integer,
    analyzed_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, sha256)
);

-- Finding what an analyzer upgrade or a retry still owes, without a scan.
CREATE INDEX IF NOT EXISTS nas_analysis_version ON nas_analysis (analyzer_version, status);

-- One row per face. The embedding is biometric data: sealed with AES-GCM under
-- a key in secrets/ and bound to its own row, never logged, never returned by
-- any endpoint. See NAS-ANALYSIS.md §6.
CREATE TABLE IF NOT EXISTS nas_faces (
    user_id    uuid NOT NULL,
    sha256     text NOT NULL,
    -- Order within the file: frame first, then the analyzer's own order.
    ordinal    smallint NOT NULL,
    frame      smallint NOT NULL DEFAULT 0,
    -- Where in a video, in milliseconds. NULL for a photo.
    frame_ms   integer,
    -- x, y, width, height as fractions of the frame.
    box        real[] NOT NULL,
    -- Five points (eyes, nose, mouth corners) as x, y fractions.
    landmarks  real[] NOT NULL,
    score      real NOT NULL,
    -- Shorter side of the face in pixels, in the 1,280-pixel render.
    size_px    smallint NOT NULL,
    sharpness  real NOT NULL,
    -- AES-GCM: 12-byte nonce, ciphertext of 128 float32, 16-byte tag.
    embedding  bytea NOT NULL,
    PRIMARY KEY (user_id, sha256, ordinal),
    FOREIGN KEY (user_id, sha256) REFERENCES nas_analysis (user_id, sha256) ON DELETE CASCADE
);

-- Whose library the NAS analyzes. Off until enrolled: shadow mode starts with
-- one library, switched on from the command line, and nobody else's is read
-- until the People switch is in the apps. 'on' is for when results feed the
-- Albums page.
ALTER TABLE users ADD COLUMN IF NOT EXISTS nas_analysis text NOT NULL DEFAULT 'off';
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_nas_analysis_check;
ALTER TABLE users ADD CONSTRAINT users_nas_analysis_check
  CHECK (nas_analysis IN ('off', 'shadow', 'on'));
