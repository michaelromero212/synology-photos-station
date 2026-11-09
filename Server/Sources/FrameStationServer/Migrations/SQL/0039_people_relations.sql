-- 0039_people_relations — who people are to the library's owner, which one
-- is the owner, and the owner's switch for People. See NAS-ANALYSIS.md §6–7.

-- What the owner calls their relationship: "mom", "son", "cousin", "friend".
-- One of `Relationship`'s raw values, checked by the server rather than here,
-- so a word added later needs no migration. NULL until they say.
ALTER TABLE people ADD COLUMN IF NOT EXISTS relation text;

-- "This is me." At most one per owner.
ALTER TABLE people ADD COLUMN IF NOT EXISTS is_me boolean NOT NULL DEFAULT false;
CREATE UNIQUE INDEX IF NOT EXISTS people_one_me ON people (user_id) WHERE is_me;

-- People, on or off. Off, the NAS keeps no face templates for the person and
-- groups no one: their people, names and relationships are deleted, and each
-- face keeps only its box, which is how many people a photo has, not who.
ALTER TABLE users ADD COLUMN IF NOT EXISTS people_enabled boolean NOT NULL DEFAULT true;
ALTER TABLE nas_faces ALTER COLUMN embedding DROP NOT NULL;
