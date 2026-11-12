-- 0041_people_maybe — "Is this Emma?" for a whole unnamed group at once. See
-- NAS-ANALYSIS.md §7 and `PeopleClusterer` (asking).
--
-- The named person an unnamed person may be, and how alike the two are, as
-- the NAS's last grouping pass found it. Only a question: the owner answers
-- yes (the group is merged into them) or no (each of its faces is rejected
-- for them). Set afresh each pass, NULL when there's nothing to ask, and
-- NULL again if the named person goes. Never anyone else's: the server only
-- ever sets it to someone in the same owner's library. Nothing biometric is
-- stored here, only a cosine, as in person_faces.similarity.
ALTER TABLE people ADD COLUMN IF NOT EXISTS maybe_id uuid REFERENCES people(id) ON DELETE SET NULL;
ALTER TABLE people ADD COLUMN IF NOT EXISTS maybe_similarity real;
-- Deleting a person looks here for the questions about them; most rows have
-- none, so only those that do are indexed.
CREATE INDEX IF NOT EXISTS people_maybe ON people (maybe_id) WHERE maybe_id IS NOT NULL;
