-- Push delivery state for the batching sweeper.
--
-- `devices` already carries apns_token/apns_env from 0001, so registration only
-- fills those in. What was missing is a record of what has been *sent*: a
-- session is closed and notified in two steps, and without notified_at a
-- restart between them would either re-notify the family or drop the message.
ALTER TABLE activity_sessions ADD COLUMN IF NOT EXISTS notified_at timestamptz;
ALTER TABLE activity_sessions ADD COLUMN IF NOT EXISTS notify_error text;

-- The sweeper's claim query: open sessions, oldest activity first.
CREATE INDEX IF NOT EXISTS activity_sessions_open
  ON activity_sessions (last_at) WHERE closed_at IS NULL;

-- Fan-out looks up every member of a space that has a token registered.
CREATE INDEX IF NOT EXISTS devices_with_push
  ON devices (user_id) WHERE apns_token IS NOT NULL;
