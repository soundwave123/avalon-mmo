-- T-414: trainer-taught crafting recipes a character KNOWS. Recipe ids are strings owned by
-- server/world content (data/recipes/recipes.json), so this is a parallel unlock store to
-- chars.character_abilities (whose ids are ints) — same grant-once shape. The ONLY write path is
-- the master recipe_op "learn" action, which debits the coin cost server-side via
-- ServicesStore.adjust_coins reason "recipe" (overdraft-guarded; lands in econ.coin_ledger) before
-- granting. A client can never name a recipe cost or grant itself a recipe (adversarial-tested in
-- test_adversarial_client.gd). Existing characters read an empty known set — zero-regression add.
-- Apply: psql -h 127.0.0.1 -U avalon -d avalon -f infra/postgres/migrations/023_add_known_recipes.sql

CREATE TABLE IF NOT EXISTS chars.character_recipes (
    character_id INT NOT NULL REFERENCES chars.characters(id) ON DELETE CASCADE,
    recipe_id    TEXT NOT NULL,
    learned_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (character_id, recipe_id)
);
