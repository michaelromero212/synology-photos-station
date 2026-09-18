-- Hand-picked collections, as opposed to the timeline's automatic grouping.
--
-- An album belongs to a *space*, not to a user. That is what keeps sharing
-- coherent: an album in Family Shared is visible to exactly the people who can
-- already see the space, and one in a personal library is visible to its owner.
-- No separate album-level ACL to drift out of step with space membership.
CREATE TABLE albums (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  space_id      uuid NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
  name          text NOT NULL CHECK (length(trim(name)) > 0),
  -- Denormalized so the album grid doesn't need a per-album query for its
  -- cover. Nullable: an empty album has nothing to show.
  cover_asset_id uuid REFERENCES assets(id) ON DELETE SET NULL,
  created_by    uuid NOT NULL REFERENCES users(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ON albums (space_id, created_at DESC);

-- Which photos are in an album, and in what order.
--
-- References space_assets rather than assets: the placement is what the caller
-- is entitled to see. Pointing at the bare asset would let an album smuggle a
-- photo into a space it was never placed in, which is exactly the class of
-- cross-space leak the upload paths were just hardened against.
CREATE TABLE album_assets (
  album_id       uuid NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
  space_asset_id uuid NOT NULL REFERENCES space_assets(id) ON DELETE CASCADE,
  position       double precision NOT NULL DEFAULT 0,
  added_by       uuid NOT NULL REFERENCES users(id),
  added_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (album_id, space_asset_id)
);

CREATE INDEX ON album_assets (album_id, position, added_at);
CREATE INDEX ON album_assets (space_asset_id);
