-- Tier 3: Global distributed table (fan-out across all 3 DCs)
-- Requires otel_regional to already exist in FRA, MUC, and HAM, requires the
-- global remote_servers definition (3 shards: FRA/MUC/HAM) to be present,
-- and requires the default.regionToShard dictionary (see dict_regionToShard.sql).

CREATE TABLE IF NOT EXISTS default.otel_global
AS default.otel_local
ENGINE = Distributed(
    'global',
    default,
    otel_regional,
    -- Sharding key derived from cluster topology via the regionToShard
    -- dictionary (region -> 0-based shard number), replacing the hardcoded
    -- transform() map. COMPLEX_KEY_HASHED layout requires a tuple key.
    --
    -- NOTE: dictGet is non-deterministic (dictionaries can reload), so
    -- optimize_skip_unused_shards will NOT prune with this key unless
    -- allow_nondeterministic_optimize_skip_unused_shards is also enabled.
    -- Both are set as `default` profile defaults via each CR's
    -- spec.settings.extraUsersConfig, so region-filtered reads prune the
    -- non-matching shards out of the box.
    dictGet('default.regionToShard', 'shardID', tuple(region))
);
