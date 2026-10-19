-- 0033_people_albums — a shared album shared with the people you pick.
--
-- A shared album used to live inside a shared library and inherit everyone in
-- it. Now you choose who: the whole family for one album, two cousins for
-- another, your partner for a third. Each such album gets a space of its own,
-- kind 'album', holding exactly its people and its photos. Never shown as a
-- library: no switcher entry, no backup destination, no File Station folder.
-- Reusing a space is what lets every existing check — who may see a photo,
-- who may add, who hears about it — apply to an album unchanged.
--
-- An album with nobody else in it is yours alone again, as any album was.
-- See `AlbumController`.
ALTER TABLE spaces DROP CONSTRAINT IF EXISTS spaces_kind_check;
ALTER TABLE spaces ADD CONSTRAINT spaces_kind_check
  CHECK (kind IN ('personal', 'shared', 'album'));
