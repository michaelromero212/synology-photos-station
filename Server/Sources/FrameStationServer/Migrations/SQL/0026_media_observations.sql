-- 0026_media_observations — what a person's own devices saw in their photos.
--
-- Curated albums (ARCHITECTURE.md, "Curated albums") are worked out here, from
-- dates and places as before, now with what Vision recognized on the phone. The
-- phone sends labels, scores and counts, never pixels. The NAS decides what
-- they mean (CurationVocabulary.swift), so the rules can change without anyone
-- re-analyzing a photograph.
--
-- Per person, by construction. Two people holding the same bytes each have
-- their own row, so deleting "my AI data" deletes exactly mine.
--
-- Keyed by the file's SHA-256 rather than an asset id. `rebuild` gives every
-- asset a new id and would orphan rows keyed by the old one; the hash survives
-- it, and identical bytes in two of a person's libraries are analyzed once. The
-- server reads the hash from the asset row and never accepts one from a client,
-- so a hash is never a way to ask whether a photo exists.
CREATE TABLE IF NOT EXISTS media_observations (
    user_id            uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    sha256             text NOT NULL,
    analysis_version   smallint NOT NULL,
    model_version      text NOT NULL,
    -- [{"id": "beach", "confidence": 0.83}, …], strongest first.
    labels             jsonb NOT NULL,
    -- Vision's overall aesthetic score, -1 to 1.
    aesthetic          real,
    -- Vision's own call, from its aesthetics request, that this is a
    -- screenshot, receipt or document. Label-based catches are the `utility`
    -- tag instead. Either way, never evidence of an occasion.
    is_utility         boolean NOT NULL DEFAULT false,
    people_count       smallint NOT NULL DEFAULT 0,
    animal_count       smallint NOT NULL DEFAULT 0,
    -- What the server made of the labels, and under which rules.
    tags               text[] NOT NULL DEFAULT '{}',
    vocabulary_version smallint NOT NULL DEFAULT 0,
    device_id          uuid REFERENCES devices(id) ON DELETE SET NULL,
    observed_at        timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, sha256)
);

-- Re-deriving tags after a rules change finds the stale rows without a scan.
CREATE INDEX IF NOT EXISTS media_observations_vocabulary
  ON media_observations (vocabulary_version);

-- On unless the person turns it off. Held here rather than on a device so that
-- turning it off on the phone turns it off on the iPad too.
ALTER TABLE users ADD COLUMN IF NOT EXISTS curation_enabled boolean NOT NULL DEFAULT true;
ALTER TABLE users ADD COLUMN IF NOT EXISTS curation_holidays boolean NOT NULL DEFAULT true;
