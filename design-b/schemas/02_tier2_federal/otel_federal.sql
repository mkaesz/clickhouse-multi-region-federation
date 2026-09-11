-- Tier 2: Federal Distributed table on the STATELESS federal router
-- (one per T-CaaS cluster; this same file is applied on every federal).
--
-- Fans a read out to the customer clusters of THIS T-CaaS cluster only.
-- Columns are declared explicitly (not `AS otel_local`) because the router
-- holds no local copy of the table - only this Distributed handle.
-- Structure MUST match the customer-side otel_local exactly.
--
-- Requires: the `customers` remote_servers definition (patch-federation.sh),
-- otel_local on every customer cluster, and default.tenantToShard.
--
-- dictGet is non-deterministic, so pruning additionally needs
-- allow_nondeterministic_optimize_skip_unused_shards - both settings are
-- profile defaults via the federal CR's extraUsersConfig.

CREATE TABLE IF NOT EXISTS default.otel_federal
(
    id         UInt64,
    event_time DateTime,
    payload    String,
    tenant     LowCardinality(String)
)
ENGINE = Distributed(
    'customers',
    default,
    otel_local,
    dictGet('default.tenantToShard', 'shardID', tuple(tenant))
);
