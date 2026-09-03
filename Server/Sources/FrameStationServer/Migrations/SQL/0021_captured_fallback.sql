-- 0021_captured_fallback — a last-resort capture date for files that carry none.
--
-- A photograph's date comes from one of three places, in order of trust:
--
--   1. What the client states outright — a phone's `PHAsset.creationDate`,
--      which is authoritative and set at commit.
--   2. EXIF `DateTimeOriginal`, read by the derivation pass.
--   3. This: the file's own creation date, sent by a client that has nothing
--      better. A screenshot has no EXIF date at all, but the file was created
--      the moment it was taken, so its creation date *is* the capture time —
--      which is why the Mac shows one in Get Info while the app said "Date
--      unknown".
--
-- It is a separate column rather than written straight into `captured_at` so
-- that it stays the lowest priority: the derivation fills `captured_at` from
-- EXIF first and only falls back to this when EXIF is silent. Writing it into
-- `captured_at` at upload would let a dragged photo's copy date win over its
-- real EXIF capture date.
ALTER TABLE assets
    ADD COLUMN IF NOT EXISTS captured_at_fallback timestamptz;
