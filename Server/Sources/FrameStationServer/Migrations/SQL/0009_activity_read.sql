-- Per-user read watermark for the in-app activity feed.
--
-- A single timestamp rather than per-row read state: "clear all" is the only
-- gesture the UI offers, so anything finer would be state nobody can change.
-- Unread is simply "closed after this instant".
--
-- NULL means never cleared, which correctly reads as "everything is unread"
-- rather than "nothing is".
ALTER TABLE users ADD COLUMN IF NOT EXISTS activity_read_at timestamptz;

-- The feed orders by closed_at across a member's spaces.
CREATE INDEX IF NOT EXISTS activity_sessions_closed
  ON activity_sessions (closed_at DESC) WHERE closed_at IS NOT NULL;
