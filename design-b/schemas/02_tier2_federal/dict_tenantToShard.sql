-- Tier 2 dependency: tenant -> shard-number dictionary on the FEDERAL router.
-- Drives the sharding key of otel_federal so tenant-filtered reads prune to
-- exactly one customer cluster.
--
-- Reads shard_name from system.clusters, populated from the <name> element
-- on each <shard> of the `customers` remote_servers definition (injected by
-- scripts/patch-federation.sh). Shard <name> = tenant id by convention, so
-- the mapping is derived from the live topology: adding a customer = append
-- a shard, the dictionary picks it up within LIFETIME (300 s) or immediately
-- via SYSTEM RELOAD DICTIONARY (run as part of the rollout - see the
-- append-only warning in manifests/federal_remote_servers.xml).
--
-- Must exist BEFORE otel_federal (its sharding key references it).

CREATE DICTIONARY IF NOT EXISTS default.tenantToShard
(
    `tenant`  String,
    `shardID` Int64
)
PRIMARY KEY tenant
SOURCE(CLICKHOUSE(
    QUERY 'SELECT shard_name AS tenant, shard_num - 1 AS shardID
           FROM system.clusters
           WHERE name = ''customers'''
))
LIFETIME(MIN 0 MAX 300)
LAYOUT(COMPLEX_KEY_HASHED());
