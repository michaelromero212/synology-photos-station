-- 0027_observation_terms — what a photo can be searched for.
--
-- Searching by what's in a photo ("beach", "dog", "birthday") reads one array
-- per photo: the server's tags, plus the Vision labels the device was fairly
-- sure of. See CurationVocabulary.terms.
--
-- Its own column, with a GIN index, so "every photo with a dog" is an index
-- lookup rather than a walk through every label of every photo. The J4125
-- would feel the difference at 100,000 photos.
--
-- Rows stored before this read as empty until the server's boot-time retag
-- fills them in, which the vocabulary version bump that ships with this
-- triggers. Nothing has to be analyzed again.
ALTER TABLE media_observations ADD COLUMN IF NOT EXISTS terms text[] NOT NULL DEFAULT '{}';

CREATE INDEX IF NOT EXISTS media_observations_terms
  ON media_observations USING gin (terms);

-- The single words inside those terms, for typed searches. Vision says
-- "birthday_cake", and somebody types "cake"; this is what lets the one find
-- the other through an index. See CurationVocabulary.words.
ALTER TABLE media_observations ADD COLUMN IF NOT EXISTS words text[] NOT NULL DEFAULT '{}';

CREATE INDEX IF NOT EXISTS media_observations_words
  ON media_observations USING gin (words);
