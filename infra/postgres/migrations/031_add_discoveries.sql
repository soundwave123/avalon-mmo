-- T-427: once-per-character exploration/discovery reward gate.
-- The row is inserted in the same master SQL statement as XP/rested/coin rewards, so ON CONFLICT
-- makes re-entry an atomic no-op. Reward snapshots preserve an auditable record of what paid.
CREATE TABLE IF NOT EXISTS chars.character_discovery (
    character_id INT  NOT NULL REFERENCES chars.characters(id) ON DELETE CASCADE,
    node_id       TEXT NOT NULL,
    discovered_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    xp_granted    INT  NOT NULL DEFAULT 0 CHECK (xp_granted >= 0),
    rested_bonus  INT  NOT NULL DEFAULT 0 CHECK (rested_bonus >= 0),
    coins_granted INT  NOT NULL DEFAULT 0 CHECK (coins_granted >= 0),
    PRIMARY KEY (character_id, node_id)
);

CREATE INDEX IF NOT EXISTS character_discovery_node_idx
    ON chars.character_discovery (node_id, discovered_at);

-- Discovery coin is a faucet, not a player transfer. Keep the T-366 inflation rollup honest.
CREATE OR REPLACE VIEW econ.coin_flow AS
SELECT
    l.id, l.ts, l.character_id, l.delta, l.reason, c.level,
    CASE
        WHEN l.reason IN (
            'quest_reward', 'achievement_reward', 'discovery_reward',
            'vendor_sell', 'kill_loot'
        ) THEN 'faucet'
        WHEN l.reason IN ('trainer', 'guild_create', 'vendor_buy', 'service') THEN 'sink'
        ELSE 'transfer'
    END AS flow
FROM econ.coin_ledger l
JOIN chars.characters c ON c.id = l.character_id;
