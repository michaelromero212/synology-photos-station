-- 0032_account_and_safety — deleting your account, reporting a photo,
-- blocking a member, and inviting someone straight into a shared library.
--
-- The first three are what the App Store asks of an app where people make
-- accounts and share with each other. Each is also something a family library
-- should have had anyway. See `AccountController` and `SafetyController`.

-- A deleted account keeps its row, with nothing personal left in it. Photos
-- the person added to a shared library stay there for the family, and those
-- rows name who added them — a row that vanished would take them with it. The
-- row is what "Added by a former member" points at, and no one can sign in
-- to it again: its devices are gone and its DSM link is cleared.
ALTER TABLE users ADD COLUMN IF NOT EXISTS deleted_at timestamptz;

-- A photo someone in a shared library would rather not see. Hidden from them
-- at once; the library's owner decides whether it stays for everyone else.
-- One report per person per photo.
CREATE TABLE IF NOT EXISTS content_reports (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  space_asset_id uuid NOT NULL REFERENCES space_assets(id) ON DELETE CASCADE,
  reporter_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  reason         text NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  resolved_at    timestamptz,
  resolved_by    uuid REFERENCES users(id) ON DELETE SET NULL,
  outcome        text CHECK (outcome IN ('removed', 'kept')),
  UNIQUE (space_asset_id, reporter_id)
);

CREATE INDEX IF NOT EXISTS content_reports_open
  ON content_reports (space_asset_id) WHERE resolved_at IS NULL;

-- Someone whose photos a member would rather not see in shared libraries. Only
-- ever the blocker's own view: nothing changes for anyone else.
CREATE TABLE IF NOT EXISTS user_blocks (
  blocker_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  blocked_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (blocker_id, blocked_id),
  CHECK (blocker_id <> blocked_id)
);

-- An invite that brings its person into a shared library as they join, so
-- they open the app onto the family's photos rather than an empty library.
ALTER TABLE invites ADD COLUMN IF NOT EXISTS space_id uuid REFERENCES spaces(id) ON DELETE SET NULL;

-- How many more people a code can let in. One, as every code always was,
-- unless whoever made it said otherwise: a server set up for App Review, say,
-- where more than one reviewer signs in with the code they were given. A code
-- is used up when this reaches zero, and only then is `redeemed_at` set.
ALTER TABLE invites ADD COLUMN IF NOT EXISTS uses_left integer NOT NULL DEFAULT 1
  CHECK (uses_left >= 0);
