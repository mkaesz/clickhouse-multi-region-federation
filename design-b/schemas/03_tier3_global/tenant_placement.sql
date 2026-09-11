-- Tier 3 dependency: tenant placement metadata on the GLOBAL router.
--
-- The global cluster's shard names are T-CaaS cluster ids (tcaas-a/tcaas-b),
-- NOT tenants - a federal aggregates many tenants - so tenant -> federal
-- cannot be derived from topology alone. This tiny table is the explicit
-- placement record: which T-CaaS cluster serves which tenant. It is the only
-- "state" the global router carries; treat it as GitOps-managed config
-- (this file IS the source of truth, re-applied on every rollout).
--
-- GeoR hook: for a tenant with active-active copies in TWO T-CaaS clusters,
-- this table pins the PRIMARY copy - queries route only there, so the copy
-- in the other T-CaaS cluster never double-counts. Failover = update the
-- row + SYSTEM RELOAD DICTIONARY default.tenantToFederalShard.
--
-- ReplicatedMergeTree because the operator's `default` database is
-- Replicated; a hand-built production router would use a plain MergeTree
-- (or an executable/file dictionary source with no table at all).

CREATE TABLE IF NOT EXISTS default.tenant_placement
(
    tenant  String,
    federal LowCardinality(String)  -- shard <name> in the `federals` cluster
)
ENGINE = ReplicatedMergeTree()
ORDER BY tenant;

-- Idempotent re-apply: full truncate + insert keeps this file authoritative.
TRUNCATE TABLE default.tenant_placement;

INSERT INTO default.tenant_placement VALUES
    ('tenant1', 'tcaas-a'),
    ('tenant2', 'tcaas-a'),
    ('tenant3', 'tcaas-b');
