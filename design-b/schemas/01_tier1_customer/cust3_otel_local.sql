-- Tier 1: Customer-local table (the actual data).
-- Customer: cust3 (tenant3), T-CaaS cluster B.
-- See cust1_otel_local.sql for the full commentary.

CREATE TABLE IF NOT EXISTS default.otel_local
(
    id         UInt64,
    event_time DateTime,
    payload    String,
    tenant     LowCardinality(String) DEFAULT 'tenant3'
)
ENGINE = ReplicatedMergeTree()
ORDER BY (id, event_time);
