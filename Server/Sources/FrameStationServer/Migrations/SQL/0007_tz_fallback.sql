-- The uploading device's UTC offset, kept separate from captured_tz_off.
--
-- PHAsset.creationDate is an absolute instant that Photos built by reading the
-- file's EXIF. When EXIF carries OffsetTimeOriginal, that offset is authoritative
-- and recovers the photographer's wall clock exactly. When it does not — old
-- scans, cameras that never wrote the tag — Photos falls back to interpreting the
-- naive timestamp in the *device's* timezone, so the device offset is what undoes
-- it. Storing the two apart lets derivation prefer EXIF and use this only when
-- EXIF is silent, instead of the client's guess overwriting real metadata.
ALTER TABLE assets ADD COLUMN IF NOT EXISTS tz_off_fallback integer;
