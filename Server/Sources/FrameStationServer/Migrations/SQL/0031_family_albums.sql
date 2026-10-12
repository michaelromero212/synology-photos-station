-- 0031_family_albums — albums that belong to a shared library.
--
-- Albums became private in 0011: your own way of organizing, owned by you.
-- They still are, by default. A family album is the other kind, chosen when
-- it's made: it belongs to a shared library, every member sees it, and it
-- holds only that library's photos. `space_id` is null for an album that's
-- yours alone. Deleting the library deletes its albums, never its photos'
-- other copies. See `AlbumController`.
ALTER TABLE albums ADD COLUMN IF NOT EXISTS space_id uuid REFERENCES spaces(id) ON DELETE CASCADE;

CREATE INDEX IF NOT EXISTS albums_space ON albums (space_id, updated_at DESC)
  WHERE space_id IS NOT NULL;
