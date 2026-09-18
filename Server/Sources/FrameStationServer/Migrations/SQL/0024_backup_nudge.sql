-- 0024_backup_nudge — what a device has left to back up, so it can be woken to
-- finish it.
--
-- The gap this closes. A phone's backup runs in `BGProcessingTask` windows that
-- iOS hands out when it feels like it — often overnight on charge, sometimes not
-- for most of a day. An initial backup of a few thousand photographs therefore
-- lands in fits and starts over days, and the person watching it concludes the
-- app is broken. Synology solves this with a silent push, and so does this: a
-- `content-available` notification asks iOS for background time directly, and
-- iOS grants it far more readily than it grants a scheduled window.
--
-- Which needs the server to know there is something to wake up *for*, and that
-- is the one fact the server cannot work out. The queue lives on the phone. From
-- here, a phone with four thousand items left and a phone that finished an hour
-- ago are the same silence. So the phone says, and these columns are what it
-- says.
ALTER TABLE devices
    -- What it last told us was outstanding. Zero is the resting state: finished,
    -- or backup turned off, or a Mac that never reports at all.
    ADD COLUMN IF NOT EXISTS backup_pending integer NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS backup_reported_at timestamptz,
    -- When we last spent a silent push on it.
    ADD COLUMN IF NOT EXISTS backup_nudged_at timestamptz,
    -- How many we have spent since it last said anything.
    --
    -- The budget is real: Apple throttles background pushes to a handful an hour
    -- per device and quietly deprioritizes apps that burn them for nothing. A
    -- phone that is switched off, out of the house, or has Background App
    -- Refresh disabled would otherwise be nudged every half hour for ever. So
    -- this counts up, the nudger stops at a small number, and *any* report from
    -- the device resets it to zero — which means progress earns more attempts
    -- and silence does not.
    ADD COLUMN IF NOT EXISTS backup_nudges integer NOT NULL DEFAULT 0;

-- The nudger's whole query, which runs every minute or so against a table that
-- is mostly devices with nothing outstanding.
CREATE INDEX IF NOT EXISTS devices_backup_pending
    ON devices (backup_reported_at)
    WHERE backup_pending > 0 AND apns_token IS NOT NULL;
