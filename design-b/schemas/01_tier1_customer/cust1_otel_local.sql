-- Tier 1: Customer-local table (the actual data).
-- Customer: cust1 (tenant1), T-CaaS cluster A.
--
-- ALL writes land here. The customer cluster has zero federation knowledge.
-- The `tenant` column is the federation-wide standard schema requirement:
-- every customer ClickHouse must expose the same table structure
-- (Distributed requires identical structure on all shards), including the
-- tenant column the two pruning levels shard on.
--
-- The operator creates 'default' as a Replicated database, so
-- ReplicatedMergeTree is used without explicit Keeper paths and DDL is
-- issued WITHOUT `ON CLUSTER` (the Replicated database propagates it).

CREATE TABLE IF NOT EXISTS default.otel_local
(
    id         UInt64,
    event_time DateTime,
    payload    String,
    tenant     LowCardinality(String) DEFAULT 'tenant1'
)
ENGINE = ReplicatedMergeTree()
ORDER BY (id, event_time);
