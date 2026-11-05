-- 0038_people — the people in a person's own library, as the NAS groups their
-- faces and as they name them. See NAS-ANALYSIS.md §6 and `PeopleClusterer`.
--
-- Per person, by construction: a group is one library owner's, its name is
-- theirs ("Mom" to one person is "Grandma" to another), and faces are only
-- ever compared within one person's library.

CREATE TABLE IF NOT EXISTS people (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    -- What the person called them. NULL until they do.
    name       text,
    named_at   timestamptz,
    -- Taken off the page by the person. Never shown, never suggested.
    hidden     boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS people_user ON people (user_id);

-- Which faces are whose, and how that was decided.
--   auto       grouped by the NAS: close enough that no one needs asking
--   confirmed  the person said yes
--   suggested  close, but not close enough: "Is this Emma?"
--   rejected   the person said no; the NAS never offers it for them again
--
-- Keyed by the face's file and place in it rather than by a face row: a face
-- found again by a newer analyzer is matched back by its box, so a name
-- outlives a model upgrade. Nothing biometric is stored here.
CREATE TABLE IF NOT EXISTS person_faces (
    user_id    uuid NOT NULL,
    sha256     text NOT NULL,
    ordinal    smallint NOT NULL,
    person_id  uuid NOT NULL REFERENCES people(id) ON DELETE CASCADE,
    state      text NOT NULL CHECK (state IN ('auto', 'confirmed', 'suggested', 'rejected')),
    -- Cosine to the person's faces when the NAS placed it; NULL for the
    -- person's own decisions.
    similarity real,
    -- x, y, width, height as fractions of the frame, as in nas_faces.
    box        real[] NOT NULL,
    decided_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, sha256, ordinal, person_id)
);
CREATE INDEX IF NOT EXISTS person_faces_person ON person_faces (person_id, state);
CREATE INDEX IF NOT EXISTS person_faces_file ON person_faces (user_id, sha256);
