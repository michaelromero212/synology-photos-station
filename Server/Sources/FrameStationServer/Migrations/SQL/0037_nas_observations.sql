-- 0037_nas_observations — what the NAS's analysis means, in the phones' words.
--
-- The analyzer stores a scene embedding per photo and per sampled video frame
-- (nas_analysis). The server scores those against concept vectors made once
-- from SigLIP 2's text side (Resources/scene-concepts.json): one confidence
-- per Vision label the vocabulary uses, so the same `CurationVocabulary`
-- rules turn them into the same kinds of tags. The Albums page and search can
-- then read either source unchanged: a person's devices (media_observations)
-- or the NAS (this table), with the same columns.
--
-- Derived data, made again from nas_analysis whenever the concepts, the
-- calibration or the vocabulary change; no file is analyzed twice for it. It
-- goes with its nas_analysis row.
CREATE TABLE IF NOT EXISTS nas_observations (
    user_id            uuid NOT NULL,
    sha256             text NOT NULL,
    -- [{"id": "beach", "confidence": 0.62}, …], strongest first, calibrated to
    -- the scale the vocabulary's thresholds were written for.
    labels             jsonb NOT NULL,
    -- The NAS has no aesthetic model; covers and highlights keep the phones'.
    aesthetic          real,
    -- Vision's own screenshot flag has no NAS counterpart; the `utility` tag
    -- carries it here.
    is_utility         boolean NOT NULL DEFAULT false,
    -- Faces the analyzer found, in the frame with the most. A count only.
    people_count       smallint NOT NULL DEFAULT 0,
    animal_count       smallint NOT NULL DEFAULT 0,
    tags               text[] NOT NULL DEFAULT '{}',
    terms              text[] NOT NULL DEFAULT '{}',
    words              text[] NOT NULL DEFAULT '{}',
    vocabulary_version smallint NOT NULL DEFAULT 0,
    -- Which concept vectors and which calibration scored it, so a change to
    -- either is found without a scan.
    scoring            text NOT NULL,
    scored_at          timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, sha256),
    FOREIGN KEY (user_id, sha256) REFERENCES nas_analysis (user_id, sha256) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS nas_observations_scoring ON nas_observations (scoring, vocabulary_version);
CREATE INDEX IF NOT EXISTS nas_observations_terms ON nas_observations USING gin (terms);
CREATE INDEX IF NOT EXISTS nas_observations_words ON nas_observations USING gin (words);

-- Where SigLIP's score for each label is as sure as Vision's 0.3, worked out
-- on this NAS from photos both a phone and the NAS analyzed: the same share of
-- photos clears it as Vision found, between SigLIP probabilities of 0.0005
-- and 0.02. See `NASScoring`.
CREATE TABLE IF NOT EXISTS nas_calibration (
    label       text PRIMARY KEY,
    -- The SigLIP logit that reads as 0.3.
    threshold   real NOT NULL,
    -- Photos Vision put at 0.3 or more, of `overlap` photos both analyzed.
    positives   integer NOT NULL,
    overlap     integer NOT NULL,
    computed_at timestamptz NOT NULL DEFAULT now()
);

-- A person's look at the Albums page built from the NAS's analysis instead of
-- their devices'. Nothing is saved while it's on, so turning it off leaves the
-- page exactly as it was. Only for someone the NAS analyzes.
ALTER TABLE users ADD COLUMN IF NOT EXISTS nas_preview boolean NOT NULL DEFAULT false;
