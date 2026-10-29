-- 0035_ladder_kind — the stream ladder replaces the single cellular rendition.
--
-- The queue's kinds are a CHECK constraint, and a kind it doesn't list is
-- refused on insert: that is how the rendition itself once went unbuilt for a
-- whole library (0023). Dropped by name and re-added, as there.
ALTER TABLE derivation_jobs DROP CONSTRAINT IF EXISTS derivation_jobs_kind_check;
ALTER TABLE derivation_jobs ADD CONSTRAINT derivation_jobs_kind_check
  CHECK (kind IN ('metadata', 'thumbnails', 'poster', 'playback', 'ladder'));

-- Renditions still waiting would each hold the one transcode slot for minutes
-- to build a file only an app from before ladders asks for. Those that exist
-- stay on disk and are still served to such an app; the rest are let go.
UPDATE derivation_jobs
SET state = 'done', last_error = 'superseded by the stream ladder', finished_at = now()
WHERE kind = 'playback' AND state <> 'done';
