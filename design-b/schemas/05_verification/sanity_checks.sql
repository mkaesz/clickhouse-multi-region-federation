-- Sanity checks - run manually on the relevant node. scripts/verify.sh runs
-- the full end-to-end suite; these are for interactive poking.

-- On a FEDERAL router: the customers of this T-CaaS cluster.
-- shard_name = tenant id; errors_count > 0 means the leaf is unreachable.
SELECT shard_num, shard_name, host_name, port, is_local, errors_count
FROM system.clusters
WHERE cluster = 'customers'
ORDER BY shard_num;

-- On a FEDERAL router: the tenant -> shard map driving otel_federal pruning.
SELECT tenant, dictGet('default.tenantToShard', 'shardID', tuple(tenant)) AS shardID
FROM (SELECT DISTINCT shard_name AS tenant FROM system.clusters WHERE cluster = 'customers');

-- On the GLOBAL router: one shard per T-CaaS cluster.
SELECT shard_num, shard_name, host_name, port, errors_count
FROM system.clusters
WHERE cluster = 'federals'
ORDER BY shard_num;

-- On the GLOBAL router: placement metadata vs. resolved shard numbers.
SELECT p.tenant,
       p.federal,
       dictGet('default.tenantToFederalShard', 'shardID', tuple(p.tenant)) AS shardID
FROM default.tenant_placement AS p
ORDER BY p.tenant;

-- On the GLOBAL router: end-to-end read across both federation levels.
SELECT tenant, count() AS rows
FROM default.otel_global
GROUP BY tenant
ORDER BY tenant;

-- On the GLOBAL router: prove tenant pruning is live (errors if it is not).
SELECT count()
FROM default.otel_global
WHERE tenant = 'tenant1'
SETTINGS force_optimize_skip_unused_shards = 1;
