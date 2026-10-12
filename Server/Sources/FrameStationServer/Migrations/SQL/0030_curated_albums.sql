-- 0030_curated_albums — the trips and occasions a person has been shown, kept.
--
-- The Albums page works its trips and occasions out afresh on every visit, from
-- rules that keep improving. Saved here the first time they're shown, they
-- keep their place as the rules change: a better rule can rename an album or
-- refine its dates, and add new ones, but never make one disappear. Only its
-- photos all being deleted removes one. See `CuratedAlbums`.
--
-- Per person and per library, like the page: what a person's own devices saw,
-- and the names they gave days, make their albums.
CREATE TABLE IF NOT EXISTS curated_albums (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  space_id         uuid NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
  user_id          uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  -- `CollectionKind`: 'trip' or 'day'.
  kind             text NOT NULL,
  -- The days it covers, as the page keys them: "2025-03-10..2025-03-13", or
  -- one day on its own.
  key              text NOT NULL,
  title            text NOT NULL,
  subtitle         text,
  -- What an occasion is, without its year ("Christmas"), when it is anything.
  occasion         text,
  -- Found by what the person's devices saw, which turning curation off hides.
  is_event         boolean NOT NULL DEFAULT false,
  -- Named for a holiday, which turning holidays off hides.
  is_holiday       boolean NOT NULL DEFAULT false,
  -- Named by the person, and kept only while their name stands.
  is_named         boolean NOT NULL DEFAULT false,
  recurs_annually  boolean NOT NULL DEFAULT false,
  -- A holiday shown on its date alone, before the person's devices looked at
  -- the day. Their analysis can still withdraw it; once it has confirmed the
  -- holiday, this is false for good.
  provisional      boolean NOT NULL DEFAULT false,
  -- Removed by the person. Never shown, and never found again.
  hidden           boolean NOT NULL DEFAULT false,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (space_id, user_id, kind, key)
);
