-- Albums belong to a person, not to a library.
--
-- The original model hung an album off a space, so an album in Family Shared
-- was visible to everyone in it. Albums are meant to be private: your own way
-- of organising, not a thing you publish. Ownership moves to the user.
--
-- Contents are still `space_assets` placements, so an album can hold anything
-- you can see — including a photo from a shared library — without that album
-- being visible to anyone else. Membership is re-checked when the album is
-- read, so leaving a shared library also removes its photos from your albums
-- rather than leaving you a private window into a space you were removed from.
ALTER TABLE albums ADD COLUMN IF NOT EXISTS owner_user_id uuid REFERENCES users(id) ON DELETE CASCADE;
UPDATE albums SET owner_user_id = created_by WHERE owner_user_id IS NULL;
ALTER TABLE albums ALTER COLUMN owner_user_id SET NOT NULL;

ALTER TABLE albums DROP COLUMN IF EXISTS space_id;

CREATE INDEX IF NOT EXISTS albums_owner ON albums (owner_user_id, updated_at DESC);
