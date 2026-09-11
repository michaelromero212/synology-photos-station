-- 0023_playback_kind — let the derivation queue accept the cellular rendition.
--
-- `derivation_jobs.kind` has carried a CHECK constraint listing every allowed
-- job since 0003, and the 1080p playback rendition added a fourth kind without
-- widening it. Postgres rejected every insert: the upload-time enqueue and the
-- startup heal both failed, so no job was ever created, no ffmpeg ever ran, and
-- cellular playback quietly went on serving the 51 Mbps original. The upload
-- path swallowed its error (`try?`, so one video's rendition can't fail an
-- upload), which is why nothing surfaced until the queue was read directly.
--
-- Dropped by name and re-added rather than edited: a CHECK constraint cannot be
-- altered in place, and `IF EXISTS` keeps this replayable on a database where an
-- earlier attempt got part-way.
ALTER TABLE derivation_jobs DROP CONSTRAINT IF EXISTS derivation_jobs_kind_check;
ALTER TABLE derivation_jobs ADD CONSTRAINT derivation_jobs_kind_check
  CHECK (kind IN ('metadata', 'thumbnails', 'poster', 'playback'));
