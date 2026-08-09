-- T-366: coin sink/faucet ledger — inflation guard for a sink-light economy.
-- An append-only record of every coin movement the master (the single coin authority) applies.
-- SERVER-OBSERVED ONLY: rows are written from ServicesStore.adjust_coins / trade_ops persistence,
-- never from a client verb (no @rpc / dispatch surface touches this table). tools/coin_ledger.py
-- aggregates it into net-creation-per-day/band so a faucet-heavy economy shows up before it inflates.
-- Apply: podman exec -i avalon-postgres psql -U avalon -d avalon < infra/postgres/migrations/016_add_coin_ledger.sql
CREATE SCHEMA IF NOT EXISTS econ;

CREATE TABLE IF NOT EXISTS econ.coin_ledger (
    id           BIGSERIAL   PRIMARY KEY,
    ts           TIMESTAMPTZ NOT NULL DEFAULT now(),
    character_id BIGINT      NOT NULL REFERENCES chars.characters(id) ON DELETE CASCADE,
    delta        BIGINT      NOT NULL,   -- signed copper: + credit/faucet, - debit/sink
    reason       TEXT        NOT NULL    -- quest_reward | achievement_reward | trainer | guild_create
                                         -- | trade | auction_sale | auction_escrow | auction_refund
);
-- Rollup access paths: over time (net creation per day) and by reason (faucet vs sink breakdown).
CREATE INDEX IF NOT EXISTS coin_ledger_ts_idx     ON econ.coin_ledger (ts);
CREATE INDEX IF NOT EXISTS coin_ledger_reason_idx ON econ.coin_ledger (reason, ts);

-- Classify each movement into faucet (mints new coin) / sink (burns coin) / transfer
-- (player<->player, zero-sum). Net coin creation = faucet + sink, because transfers cancel across
-- the two parties. Joins current character level so the report can bucket income per level band.
CREATE OR REPLACE VIEW econ.coin_flow AS
SELECT
    l.id, l.ts, l.character_id, l.delta, l.reason, c.level,
    CASE
        WHEN l.reason IN ('quest_reward', 'achievement_reward', 'vendor_sell', 'kill_loot') THEN 'faucet'
        WHEN l.reason IN ('trainer', 'guild_create', 'vendor_buy', 'service') THEN 'sink'
        ELSE 'transfer'
    END AS flow
FROM econ.coin_ledger l
JOIN chars.characters c ON c.id = l.character_id;

-- Net coin creation per day (transfers excluded — they net to zero across the two parties).
-- A persistently positive net_created is the inflation signal the ticket guards against.
CREATE OR REPLACE VIEW econ.coin_flow_daily AS
SELECT date_trunc('day', ts) AS day,
       COALESCE(SUM(delta) FILTER (WHERE flow = 'faucet'), 0)               AS faucet,
       COALESCE(SUM(delta) FILTER (WHERE flow = 'sink'), 0)                 AS sink,
       COALESCE(SUM(delta) FILTER (WHERE flow IN ('faucet', 'sink')), 0)    AS net_created
FROM econ.coin_flow
GROUP BY 1 ORDER BY 1;
