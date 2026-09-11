-- Tier 1: Local table (the actual data)
-- DC: MUC
-- The operator creates 'default' as a Replicated database, so ReplicatedMergeTree
-- must be used without explicit Keeper paths (the database handles them).
-- DDL is issued WITHOUT `ON CLUSTER`: the Replicated database propagates each
-- statement to every replica by itself. Layering `ON CLUSTER 'default'` on top
-- races that mechanism and, at >1 replica, gets cancelled mid-flight.

CREATE TABLE IF NOT EXISTS default.otel_local
(
    id         UInt64,
    event_time DateTime,
    payload    String,
    region     LowCardinality(String) DEFAULT 'MUC'
)
ENGINE = ReplicatedMergeTree()
ORDER BY (id, event_time);
