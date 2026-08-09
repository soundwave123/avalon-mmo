-- T-065: class selection at creation — class may be set once (then locked). Reroll
-- (character deletion) is the only way to change it; no respec.
ALTER TABLE chars.characters ADD COLUMN IF NOT EXISTS class_locked BOOLEAN NOT NULL DEFAULT false;
