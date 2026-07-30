-- 0006_dsm_users — link FrameStation accounts to DSM accounts.
--
-- DSM becomes the identity provider: family members sign in with the password
-- they already have, and accounts are managed in one place. The credentials
-- themselves are never stored — the server validates them against DSM once and
-- issues its own device token.
--
-- dsm_uid is what lets the server place a user's files in their own DSM home
-- directory with the right ownership, so File Station shows them as theirs.

ALTER TABLE users ADD COLUMN dsm_username text;
ALTER TABLE users ADD COLUMN dsm_uid      int;
ALTER TABLE users ADD COLUMN dsm_home     text;

-- One FrameStation user per DSM account. Partial so invite-created users, which
-- have no DSM account, don't collide on NULL.
CREATE UNIQUE INDEX users_dsm_username ON users (lower(dsm_username))
  WHERE dsm_username IS NOT NULL;
