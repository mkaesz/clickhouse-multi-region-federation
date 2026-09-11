-- Sanity checks -- run after all Tier 1/2/3 schemas are deployed to all 3 DCs.

-- 1. Confirm each DC's local table only holds rows tagged with its own region.
--    Run this individually against each DC's local endpoint.
SELECT region, count() FROM default.otel_local GROUP BY region;

-- 2. Confirm the shard-pruning profile defaults are active for this session.
--    Both are set on the `default` profile via each CR's
--    spec.settings.extraUsersConfig, so no inline SETTINGS are needed below.
SELECT
    getSetting('optimize_skip_unused_shards')                       AS opt,
    getSetting('allow_nondeterministic_optimize_skip_unused_shards') AS allow_nd;
-- Expect: opt = true, allow_nd = true (these are Bool settings).
-- allow_nd is required because otel_global's sharding key is dictGet(...),
-- which ClickHouse treats as non-deterministic; without it,
-- optimize_skip_unused_shards silently refuses to prune.

-- 3. Confirm shard pruning works on the global table for a single-DC read.
EXPLAIN SELECT * FROM default.otel_global
WHERE region = 'MUC';
-- Expect: only 1 shard referenced in the plan.
-- force_optimize_skip_unused_shards below turns the "silent no-op" failure
-- mode into a hard error, so this doubles as an assertion that pruning ran.
SELECT count() FROM default.otel_global
WHERE region = 'MUC'
SETTINGS force_optimize_skip_unused_shards = 1;

-- 4. Confirm shard pruning works for a multi-region IN(...) read.
EXPLAIN SELECT * FROM default.otel_global
WHERE region IN ('MUC', 'HAM');
-- Expect: only 2 shards referenced in the plan (FRA skipped).

-- 5. Example cross-DC aggregation query (relies on the profile defaults).
SELECT
    region,
    count() AS errors
FROM default.otel_global
WHERE region IN ('MUC', 'HAM')
  AND event_time >= now() - toIntervalHour(1)
GROUP BY ALL
ORDER BY ALL ASC;

-- 6. Confirm app_writer cannot write to the global table (should fail with
--    an access-denied error when run as a user carrying only app_writer).
-- INSERT INTO default.otel_global VALUES (1, now(), 'test', 'FRA');

-- 7. Confirm the regionToShard dictionary loaded and maps every DC to a shard.
--    An empty result means shard <name> is missing from global, or the
--    dictionary source could not read system.clusters.
SYSTEM RELOAD DICTIONARY default.regionToShard;
SELECT region, shardID FROM default.regionToShard ORDER BY shardID;
-- Expect: FRA→0, MUC→1, HAM→2.

-- 8. Confirm the sharding key resolves the same way the dictionary does.
SELECT dc, dictGet('default.regionToShard', 'shardID', tuple(dc)) AS shard
FROM (SELECT arrayJoin(['FRA', 'MUC', 'HAM']) AS dc);
-- Expect: FRA→0, MUC→1, HAM→2.
