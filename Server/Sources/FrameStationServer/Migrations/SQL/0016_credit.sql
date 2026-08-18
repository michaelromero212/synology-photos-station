-- 0016_credit — who a photo is attributed to, when that isn't who sent it.
--
-- `uploaded_by_user_id` is a fact: it records which account's device pushed the
-- bytes, and the upload path depends on it. Overwriting it to fix attribution
-- would destroy that fact to express a different one — and the two genuinely
-- differ. A phone handed round at a birthday uploads under whoever is signed in;
-- a shared iPad backs up everyone's photos under one account. In both cases the
-- upload record is correct and the credit is wrong.
--
-- So the correction is additive. `credited_to_user_id` is null until someone
-- says otherwise, and the displayed "Added by" prefers it when set. Clearing it
-- returns to the truth rather than to another guess.
ALTER TABLE space_assets
  ADD COLUMN IF NOT EXISTS credited_to_user_id uuid REFERENCES users(id),
  ADD COLUMN IF NOT EXISTS credited_by_user_id uuid REFERENCES users(id),
  ADD COLUMN IF NOT EXISTS credited_at timestamptz;

-- Reads go through the join on every bucket page and asset detail, and only a
-- handful of rows are ever corrected, so this stays out of the way until used.
CREATE INDEX IF NOT EXISTS space_assets_credited
  ON space_assets (credited_to_user_id)
  WHERE credited_to_user_id IS NOT NULL;
