-- 0001_init — full schema per ARCHITECTURE.md §5.
--
-- The whole schema lands in one migration because this is a greenfield database
-- and M1+ shouldn't need a migration dance to start writing assets. Everything
-- past M0 is additive.

CREATE TABLE users (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  display_name  text NOT NULL,
  avatar_sha256 text,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE devices (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name         text NOT NULL,
  platform     text NOT NULL CHECK (platform IN ('ios','ipados','macos','tvos')),
  apns_token   text,
  apns_env     text CHECK (apns_env IN ('sandbox','production')),
  token_hash   text NOT NULL UNIQUE,
  created_at   timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz
);

CREATE INDEX ON devices (user_id);

CREATE TABLE spaces (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind       text NOT NULL CHECK (kind IN ('personal','shared')),
  name       text NOT NULL,
  created_by uuid NOT NULL REFERENCES users(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE space_members (
  space_id  uuid NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
  user_id   uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role      text NOT NULL DEFAULT 'contributor'
              CHECK (role IN ('owner','contributor','viewer')),
  joined_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (space_id, user_id)
);

CREATE INDEX ON space_members (user_id);

-- Exactly one personal space per user.
CREATE UNIQUE INDEX one_personal_space_per_user
  ON spaces (created_by) WHERE kind = 'personal';

-- Invites: how a family member joins. Created from the CLI by the NAS owner.
CREATE TABLE invites (
  code        text PRIMARY KEY,
  created_at  timestamptz NOT NULL DEFAULT now(),
  expires_at  timestamptz NOT NULL,
  redeemed_at timestamptz,
  redeemed_by uuid REFERENCES users(id)
);

-- The file. Immutable, deduplicated by content hash, space-agnostic.
CREATE TABLE assets (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sha256          text NOT NULL UNIQUE,
  byte_size       bigint NOT NULL,
  media_type      text NOT NULL CHECK (media_type IN ('photo','video')),
  mime            text NOT NULL,
  width           int,
  height          int,
  duration_ms     int,
  captured_at     timestamptz,
  captured_tz_off int,
  lat             double precision,
  lon             double precision,
  place_name      text,
  camera_make     text,
  camera_model    text,
  lens            text,
  iso             int,
  aperture        real,
  shutter         text,
  focal_len       real,
  exposure_bias   real,
  dynamic_range   text CHECK (dynamic_range IN ('standard','hdr')),
  orientation     int,
  is_raw          boolean NOT NULL DEFAULT false,
  live_group_id   uuid,
  burst_id        text,
  burst_pick      boolean NOT NULL DEFAULT false,
  thumbhash       bytea,
  exif            jsonb,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ON assets (captured_at DESC);
CREATE INDEX ON assets (live_group_id) WHERE live_group_id IS NOT NULL;
CREATE INDEX ON assets (burst_id) WHERE burst_id IS NOT NULL;

-- The placement. Attribution lives here.
CREATE TABLE space_assets (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  space_id            uuid NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
  asset_id            uuid NOT NULL REFERENCES assets(id),
  uploaded_by_user_id uuid NOT NULL REFERENCES users(id),
  uploaded_at         timestamptz NOT NULL DEFAULT now(),
  source_device_id    uuid REFERENCES devices(id) ON DELETE SET NULL,
  source_local_id     text,
  on_device           boolean NOT NULL DEFAULT true,
  description         text,
  rating              smallint CHECK (rating BETWEEN 0 AND 5),
  deleted_at          timestamptz,
  UNIQUE (space_id, asset_id)
);

CREATE INDEX ON space_assets (space_id, uploaded_at DESC);
CREATE INDEX ON space_assets (uploaded_by_user_id);

-- Favorites are per-user: in a shared space "Mom favorited this" and
-- "I favorited this" are different facts.
CREATE TABLE space_asset_favorites (
  space_asset_id uuid NOT NULL REFERENCES space_assets(id) ON DELETE CASCADE,
  user_id        uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  favorited_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (space_asset_id, user_id)
);

CREATE TABLE tags (
  id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  space_id uuid NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
  name     text NOT NULL,
  UNIQUE (space_id, name)
);

CREATE TABLE space_asset_tags (
  space_asset_id uuid NOT NULL REFERENCES space_assets(id) ON DELETE CASCADE,
  tag_id         uuid NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
  PRIMARY KEY (space_asset_id, tag_id)
);

-- Delta sync cursor source. See ARCHITECTURE.md §5 "change_log ordering gotcha":
-- writers MUST hold pg_advisory_xact_lock(hashtext(space_id::text)) so seq
-- assignment and commit are serialized per space.
CREATE TABLE change_log (
  seq       bigserial PRIMARY KEY,
  space_id  uuid NOT NULL,
  entity    text NOT NULL,
  entity_id uuid NOT NULL,
  op        text NOT NULL CHECK (op IN ('insert','update','delete')),
  at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ON change_log (space_id, seq);

-- Batched upload activity, drives the "Morgan added 10 photos" push.
CREATE TABLE activity_sessions (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  space_id    uuid NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
  user_id     uuid NOT NULL REFERENCES users(id),
  photo_count int NOT NULL DEFAULT 0,
  video_count int NOT NULL DEFAULT 0,
  is_bulk     boolean NOT NULL DEFAULT false,
  opened_at   timestamptz NOT NULL DEFAULT now(),
  last_at     timestamptz NOT NULL DEFAULT now(),
  closed_at   timestamptz
);

CREATE UNIQUE INDEX one_open_session_per_space_user
  ON activity_sessions (space_id, user_id) WHERE closed_at IS NULL;
