-- 0020_media_subtypes — what the device already knew.
--
-- Media Types shipped with two of its six categories decided by guesswork:
--
--   screenshot: camera_make IS NULL AND media_type = 'photo' AND mime = 'image/png'
--   panorama:   width::float / height >= 2
--
-- Both are wrong in both directions. Anything saved rather than photographed is
-- a PNG no camera took — images from Messages, exported graphics, QR codes,
-- scanned documents — and all of it was filed under Screenshots. A screenshot
-- marked up and re-saved as JPEG fell out. A panorama you cropped stopped being
-- a panorama; a wide crop of anything became one. And a screen recording could
-- never appear at all, because the screenshot predicate only looked at photos.
--
-- `PHAsset.mediaSubtypes` has carried the real answer the whole time, set by
-- the device at capture. `PhotoLibraryScanner` was already reading that exact
-- property to find Live Photos.
--
-- A text array rather than Apple's bitmask: the database should not depend on
-- the numeric values of a UIKit enum, and a subtype added later is then a new
-- string rather than another migration.
ALTER TABLE assets
    ADD COLUMN IF NOT EXISTS media_subtypes text[] NOT NULL DEFAULT '{}';

-- Every media-type query is "which assets are this subtype", which is a
-- containment test, which is what GIN is for.
CREATE INDEX IF NOT EXISTS assets_media_subtypes
    ON assets USING GIN (media_subtypes);

-- Nothing is backfilled, deliberately.
--
-- The information does not exist server-side — that is the entire problem this
-- migration solves — so the only backfill available would be to run the old
-- guesses once and freeze their mistakes into a column that reads as
-- authoritative. Existing rows keep an empty array and continue to be matched
-- by the heuristic fallback in `CollectionsController.mediaTypes`, which now
-- applies only to assets that have no subtypes recorded. Anything uploaded from
-- a phone after this ships is exact.
