-- 0040_written_numbers — the age written in a birthday photo.
--
-- For a birthday album named for whose it was, how old they turned, from what
-- the family wrote: a "2" candle, "Happy 2nd Birthday" on the cake, a "TWO"
-- banner. The person's own phone reads the writing in the photos the NAS calls
-- a birthday, only for someone with People on, and sends whole numbers from 1
-- to 18. The writing itself never leaves the phone. See
-- `PhotoAnalyzer.readNumbers` and `CollectionsController.writtenAge`.
--
-- On the person's own observation row, so Delete AI data and account
-- deletion, which remove those rows, remove these with them.

-- NULL until read; empty when the photo said none.
ALTER TABLE media_observations ADD COLUMN IF NOT EXISTS written smallint[];
-- Which version of the reading wrote it. NULL until read. A newer version
-- replaces an older one, and only the birthday photos are read again.
ALTER TABLE media_observations ADD COLUMN IF NOT EXISTS written_version smallint;
