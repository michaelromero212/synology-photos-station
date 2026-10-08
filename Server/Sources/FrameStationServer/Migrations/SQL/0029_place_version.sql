-- 0029_place_version — which rules a photo's town was named under.
--
-- Towns are named from the coordinates by the town dataset (`Geocoder`), and
-- the rules for doing it can change: a city's neighborhoods now take the
-- city's name, so Times Square is New York City and the 16th arrondissement
-- is Paris. Every row starts at 0, and the server's boot-time pass names the
-- stored library again under the current rules, and again whenever they
-- change. See `PlaceFiling`.
ALTER TABLE assets ADD COLUMN IF NOT EXISTS place_version int NOT NULL DEFAULT 0;
