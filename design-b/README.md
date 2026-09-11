# Design B: Hierarchical ClickHouse Federation

Customer ClickHouse clusters are spread over many T-CaaS (Kubernetes)
clusters. A central Grafana must query all of them through **one** endpoint,
and adding a customer must never require touching anything outside its own
T-CaaS cluster. Design B solves this with a two-level hierarchy of
**stateless query routers**:

```
                        Grafana (one datasource URL)
                                   │
                        ┌──────────▼──────────┐
                        │   global router     │   otel_global
                        │   (stateless)       │   Distributed('federals', …)
                        └─────┬───────────┬───┘
              knows ONE endpoint per T-CaaS cluster
                              │           │
              ┌───────────────▼──┐     ┌──▼───────────────┐
              │ federal router   │     │ federal router   │   otel_federal
              │ T-CaaS cluster A │     │ T-CaaS cluster B │   Distributed('customers', …)
              └───┬─────────┬────┘     └────────┬─────────┘
        knows only ITS customers                │
                  │         │                   │
             ┌────▼───┐ ┌───▼────┐         ┌────▼───┐
             │ cust1  │ │ cust2  │         │ cust3  │          otel_local
             │tenant1 │ │tenant2 │         │tenant3 │          ReplicatedMergeTree
             └────────┘ └────────┘         └────────┘          (the actual data)
```

Key properties:

- **Config locality.** Adding a customer = appending one shard to the
  `customers` cluster of *its* federal router (hot-reloaded ConfigMap in
  production). The global router and every other T-CaaS cluster are
  untouched. Adding a whole T-CaaS cluster = appending one shard on the
  global router.
- **Star topology, not mesh.** Customer clusters know **no topology** — they
  only accept incoming connections, in-cluster, and carry a single static
  receiver-side secret stanza (see design note below) that never changes
  when siblings are added. Per T-CaaS cluster exactly one endpoint (the
  federal router) is exposed; the global router is the only thing that
  needs to reach it.
- **Routers are stateless.** Federal and global routers hold no MergeTree
  event data — only remote_servers config, Distributed tables and (globally)
  a tiny placement-metadata table. In production you run ≥ 2 identical
  replicas per router and, for the global pair, deploy it in two DCs behind
  one DNS name / GSLB: that name is the Grafana datasource URL.
- **No replication or Raft ever crosses a boundary.** The hierarchy exists
  only in the routers' `remote_servers` configs; it is pure query-level
  federation (same principle as design-a).

---

## Schema tiers

| Tier | Table | Where | Engine |
|------|-------|-------|--------|
| 1 | `otel_local` | every customer cluster | `ReplicatedMergeTree` — **all writes land here** |
| 2 | `otel_federal` | federal router (per T-CaaS cluster) | `Distributed('customers', …, otel_local, dictGet(tenantToShard, …))` |
| 3 | `otel_global` | global router | `Distributed('federals', …, otel_federal, dictGet(tenantToFederalShard, …))` |

A read of `otel_global` is **Distributed over Distributed**: it expands
`otel_global → otel_federal → otel_local` across two fan-out levels;
aggregation states merge correctly level by level.

**Standard schema requirement:** `Distributed` demands the identical table
structure on every shard. All customer clusters must therefore expose the
same `otel_local` structure, including the `tenant` column both pruning
levels shard on. This is the hardest *organisational* requirement of the
model.

**Tenant pruning at both levels** (mandatory — without it every Grafana
panel fans out to every customer cluster everywhere):

- Federal: sharding key `dictGet(tenantToShard, …)`; the dictionary derives
  tenant → shard from `system.clusters` (shard `<name>` = tenant id).
- Global: sharding key `dictGet(tenantToFederalShard, …)`; the dictionary
  joins the explicit `tenant_placement` metadata table (tenant → T-CaaS
  cluster *name*) against `system.clusters` (name → shard number).
- `dictGet` is non-deterministic, so both routers set
  `optimize_skip_unused_shards` **and**
  `allow_nondeterministic_optimize_skip_unused_shards` as profile defaults
  (via `extraUsersConfig` in the CRs, same as design-a).

**RBAC across two hops:** both cluster definitions carry a shared
`<secret>`, so a global read propagates the *original* user
global → federal → customer and every hop enforces that user's grants.
Because the user propagates *by name* and roles do **not** propagate, the
reader (`grafana_reader`) is created identically on **every** cluster with
**direct** grants: `otel_global` (global), `otel_federal` (federals),
`otel_local` (customers). Writers stay role-based (`app_writer`) — they
never cross a hop.

---

## Repository layout

```
design-b/
├── setup.sh / teardown.sh
├── manifests/
│   ├── tcaas-a/        # kind cluster A: cust1, cust2, federal router
│   ├── tcaas-b/        # kind cluster B: cust3, federal router
│   ├── global/         # kind cluster: global router
│   ├── federal_remote_servers.xml   # production-shaped reference (per T-CaaS)
│   └── global_remote_servers.xml    # production-shaped reference (global)
├── schemas/
│   ├── 01_tier1_customer/   # otel_local per customer
│   ├── 02_tier2_federal/    # tenantToShard dict + otel_federal
│   ├── 03_tier3_global/     # tenant_placement + dict + otel_global
│   ├── 04_rbac/             # per-level roles/grants
│   └── 05_verification/     # interactive sanity checks
└── scripts/
    ├── wait-for-pods.sh
    ├── patch-federation.sh  # injects both federation levels + secret
    ├── apply-schemas.sh     # SQL in dependency order across all 6 clusters
    └── verify.sh            # end-to-end: counts, pruning, 2-hop RBAC
```

---

## Quick start

```bash
cd design-b
bash setup.sh          # ~10 min: 3 kind clusters, operator, 6 CH clusters
bash scripts/verify.sh # end-to-end verification suite
```

Host access after setup:

| Endpoint | HTTP | Native TCP |
|----------|------|------------|
| cust1 (tenant1) | localhost:8811 | localhost:9811 |
| cust2 (tenant2) | localhost:8812 | localhost:9812 |
| federal-a | localhost:8815 | localhost:9815 |
| cust3 (tenant3) | localhost:8821 | localhost:9821 |
| federal-b | localhost:8825 | localhost:9825 |
| **global (Grafana)** | **localhost:8831** | **localhost:9831** |

The query Grafana would run:

```sql
-- against localhost:9831 (global router) only
SELECT tenant, count() FROM default.otel_global GROUP BY tenant ORDER BY tenant;

-- tenant-filtered: prunes to ONE T-CaaS cluster and behind it ONE customer
SELECT count() FROM default.otel_global WHERE tenant = 'tenant3'
SETTINGS force_optimize_skip_unused_shards = 1;   -- errors if pruning is off
```

"Add a customer" walkthrough (the property this design exists for): deploy
a new customer ClickHouse in T-CaaS cluster A (its standard deploy template
includes the static receiver-side secret stanza), then append one shard to
the federal-a `customers` definition (in the demo: extend `patch_federal_a`
in `scripts/patch-federation.sh`; in production: one ConfigMap owned by the
T-CaaS-A team), create `otel_local` there, run the customer RBAC file, and
add one row to `tenant_placement` on the global router. Nothing else in the
world changes.

---

## Design notes

### Receiver-side secret validation (found the hard way)
The cluster `<secret>` handshake is validated by the **receiving** server:
an incoming secure inter-server connection carries the cluster name, and
the receiver looks the secret up in its **own** `remote_servers`. A leaf
with no federation config at all therefore *resets the connection*
(`NETWORK_ERROR: Connection reset by peer`) — which is exactly what the
first run of this demo produced. The fix keeps the config-locality story
intact: every customer cluster carries one minimal, static `customers`
stanza (same cluster name + secret, only itself as shard, no topology), and
every federal router carries an equivalent minimal `federals` stanza for
the hop coming in from the global router. These stanzas are part of the
standard deploy template and never change when the topology grows. See
`manifests/federal_remote_servers.xml` for the production shape.

### Routers are stateless — the demo Keeper is an operator artifact
The official operator always creates `default` as a Replicated database,
which needs a Keeper — hence each demo router carries a 1-node
KeeperCluster. A production router built from plain ClickHouse config
(Atomic database, schema rolled out via GitOps) needs **no Keeper at all**:
there is nothing to coordinate. That also means no `ON CLUSTER` DDL on
routers — schema is just config, shipped by the same pipeline as
remote_servers.

### Two Distributed levels, not three
Customer clusters here are single-shard, so `otel_federal` targets
`otel_local` directly. If a customer cluster is itself sharded, either list
its shards in the federal `customers` definition (config churn on customer
resharding) or point the federal at the customer's own regional Distributed
table — a third fan-out level. That works, but every level adds a hop and a
merge stage; treat three levels as the ceiling.

### GeoR / active-active — decide it WITH the hierarchy, not after
Identical copies of one tenant's data must appear in the federation as
**replicas of one shard** (one is picked per query), never as two shards
(rows count twice). That works only while both copies live under the *same*
federal. GeoR copies in *different* T-CaaS clusters surface at the global
level as two shards — duplicates return, and the global level cannot
dedupe per tenant because its shards are whole federals. This design
handles it via `tenant_placement`: the table pins the tenant's **primary**
T-CaaS cluster, tenant-filtered queries route only there, and failover is a
metadata update + `SYSTEM RELOAD DICTIONARY`. The cost: unfiltered
cross-tenant queries still hit both copies' federals — those queries must
tolerate (or dedupe) the GeoR tenants, or GeoR pairs get modeled directly
at the global level as one shard with two replicas, bypassing the clean
hierarchy. There is no free option; pick consciously.

### Append-only topology changes
Both sharding dictionaries refresh within `LIFETIME (MAX 300)` seconds.
Inserting a shard in the middle of a cluster definition shifts
`shard_num`, and until the dictionary refreshes, pruning silently
mis-routes. Rules: append shards, never insert; run
`SYSTEM RELOAD DICTIONARY` as part of every topology rollout; keep
`force_optimize_skip_unused_shards = 1` available per query as an assertion
(this is how `verify.sh` proves pruning is live).

### RBAC alternative: service credentials per hop
Propagating the end user by name (this demo) gives per-user enforcement and
auditing on every leaf — at the price of provisioning the reader on every
customer cluster. The pragmatic alternative for an internal-only Grafana:
fixed `<user>/<password>` interserver credentials per shard entry, with the
RBAC boundary (and row policies for tenant isolation) at the router. Leaves
then no longer see the end user. Pick per security requirement.

### Fleet version policy
Distributed-over-Distributed merges **serialized aggregate-function
states** between servers on both levels. State formats are not guaranteed
compatible across arbitrary version gaps, and dozens of independently
operated customer clusters *will* skew. A fleet-wide rule (e.g. max N minor
versions apart) is a prerequisite of this architecture, not an
optimization.

### Failure and load behavior
`skip_unavailable_shards = 1` keeps global dashboards alive when a customer
cluster is down — at the price of silent data gaps, and it only covers
connect-time failures (a hanging leaf still holds the query until timeout).
For a central Grafana also plan: query cache on the routers
(`use_query_cache`) against refresh storms, and for fleet-wide overview
panels consider pushing small pre-aggregated rollups to a central store
instead of fanning out to the world on every refresh — federation is
strongest for per-tenant drill-down.

### TLS
Omitted here to keep the demo focused on topology. Production runs both
levels over `<secure>1</secure>` + mutual TLS exactly as demonstrated in
design-a (`design-a/scripts/setup-tls.sh`); the mechanics are identical,
just applied per level.
