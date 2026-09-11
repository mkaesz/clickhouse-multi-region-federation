-- Tier 3: Global Distributed table on the STATELESS global router - the
-- single table Grafana queries.
--
-- Distributed over Distributed: each shard of the `federals` cluster is a
-- federal router whose default.otel_federal is itself a Distributed table.
-- A read expands otel_global -> otel_federal -> otel_local; aggregation
-- states merge correctly across both fan-out levels.
--
-- Requires: the `federals` remote_servers definition (patch-federation.sh),
-- otel_federal on every federal router, tenant_placement and
-- default.tenantToFederalShard on this router.

CREATE TABLE IF NOT EXISTS default.otel_global
(
    id         UInt64,
    event_time DateTime,
    payload    String,
    tenant     LowCardinality(String)
)
ENGINE = Distributed(
    'federals',
    default,
    otel_federal,
    dictGet('default.tenantToFederalShard', 'shardID', tuple(tenant))
);
