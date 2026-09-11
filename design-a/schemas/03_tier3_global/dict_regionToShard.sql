-- Tier 3 dependency: region -> shard-number dictionary.
-- Drives the sharding key of otel_global so the FRA/MUC/HAM -> shard
-- mapping is derived from the cluster topology instead of being hardcoded.
--
-- Reads shard_name from system.clusters, which is populated from the <name>
-- element on each <shard> in global_remote_servers.xml. shard_num is
-- 1-based, so shardID = shard_num - 1 (0-based) to match the Distributed
-- sharding-key convention (0 = first shard).
--
-- Run once per DC (the 'default' database is Replicated, so the DDL propagates
-- to all replicas inside that DC). Must exist before otel_global is
-- created, since the table's sharding key references it.
--
-- NOTE: the cluster name here is 'global' -- it must match the
-- <remote_servers> entry, otherwise the query returns no rows and the
-- dictionary is empty.

CREATE DICTIONARY IF NOT EXISTS default.regionToShard
(
    `region` String,
    `shardID` Int64
)
PRIMARY KEY region
SOURCE(CLICKHOUSE(
    QUERY 'SELECT shard_name AS region, shard_num - 1 AS shardID
           FROM system.clusters
           WHERE name = ''global'''
))
LIFETIME(MIN 0 MAX 300)
LAYOUT(COMPLEX_KEY_HASHED());
