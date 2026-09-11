-- Tier 2: Regional distributed table (read fan-out across shards inside FRA)
-- Currently a no-op since FRA is a single shard today; exists so FRA can grow
-- to multiple shards later without any application-level query changes.
--
-- No sharding key: this table is read-only (all writes go to otel_local), and
-- reads fan out to every shard in the cluster. A sharding key would only be
-- needed to prune shards on read (via optimize_skip_unused_shards), and would
-- then have to be a deterministic column expression -- not rand().

CREATE TABLE IF NOT EXISTS default.otel_regional
AS default.otel_local
ENGINE = Distributed('default', default, otel_local);
