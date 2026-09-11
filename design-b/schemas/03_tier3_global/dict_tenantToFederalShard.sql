-- Tier 3 dependency: tenant -> federal-shard-number dictionary on the GLOBAL
-- router. Drives the sharding key of otel_global so tenant-filtered reads
-- prune to exactly one T-CaaS cluster (and behind it, via the federal's own
-- pruning, to exactly one customer cluster).
--
-- Combines the explicit placement record (tenant_placement: tenant ->
-- federal NAME) with the live topology (system.clusters: federal name ->
-- shard_num). Placement never hardcodes shard numbers, so re-ordering risk
-- is confined to the `federals` cluster definition (append-only rule, see
-- manifests/global_remote_servers.xml).
--
-- Must exist BEFORE otel_global (its sharding key references it).

CREATE DICTIONARY IF NOT EXISTS default.tenantToFederalShard
(
    `tenant`  String,
    `shardID` Int64
)
PRIMARY KEY tenant
SOURCE(CLICKHOUSE(
    QUERY 'SELECT p.tenant AS tenant, c.shard_num - 1 AS shardID
           FROM default.tenant_placement AS p
           INNER JOIN system.clusters AS c ON c.shard_name = p.federal
           WHERE c.name = ''federals'''
))
LIFETIME(MIN 0 MAX 300)
LAYOUT(COMPLEX_KEY_HASHED());
