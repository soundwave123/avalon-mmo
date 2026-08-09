-- T-412: bank vault capacity TIER — a non-punitive coin SINK (buy more vault storage; zero power).
-- One column on the character row records how many tiers the player has purchased. Tier 0 is the
-- shipped base capacity (VaultLogic.VAULT_SLOTS), so every existing character reads tier 0 and this
-- is a zero-regression add. The ONLY write path is the master vault_op "upgrade" action, which
-- derives the next tier + its cost from ServerConfig.VAULT_TIER_COSTS server-side and debits via
-- ServicesStore.adjust_coins reason "vault_upgrade" (overdraft-guarded; lands in econ.coin_ledger).
-- A client can never name its tier or the price (adversarial-tested in test_adversarial_client.gd).
-- Apply: psql -h 127.0.0.1 -U avalon -d avalon -f infra/postgres/migrations/022_add_vault_tier.sql

ALTER TABLE chars.characters
    ADD COLUMN IF NOT EXISTS vault_tier INT NOT NULL DEFAULT 0 CHECK (vault_tier >= 0);
