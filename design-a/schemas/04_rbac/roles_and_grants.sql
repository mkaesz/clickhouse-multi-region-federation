-- RBAC: run identically in FRA, MUC, and HAM.
-- Users/roles are NOT shared across DCs (no cross-DC Keeper/RBAC storage),
-- so this file must be executed once per DC against that DC's own cluster.
--
-- ── Cross-DC caveat: the `global` cluster <secret> ───────────────────────────
-- The `global` cluster carries a shared inter-server secret, so a cross-DC read
-- propagates the ORIGINAL querying user to remote shards and each shard enforces
-- that user's privileges (instead of silently running as `default`). BUT
-- ClickHouse propagates the user IDENTITY only -- it does NOT enable that user's
-- ROLES on the remote shard. Only privileges granted DIRECTLY to the user are
-- enforced remotely; role-granted privileges apply on the INITIATING node only.
-- Consequences baked into the split below:
--   * Writers never read cross-DC (all writes land on the local otel_local),
--     so they stay role-based (app_writer).
--   * Readers DO fan out across DCs (otel_global), so reader USERS must receive
--     their SELECT grants DIRECTLY, on every DC -- a role would not propagate.

-- ── Writers: role-based, local DC only ───────────────────────────────────────
CREATE ROLE IF NOT EXISTS app_writer;

-- All writes go directly to the local MergeTree (otel_local). Writers never
-- INSERT through a Distributed table and never touch otel_global.
GRANT INSERT, SELECT ON default.otel_local TO app_writer;
GRANT SELECT ON default.otel_regional TO app_writer;

-- Safeguard: never allow INSERT into a Distributed table. All writes must
-- target the local MergeTree (otel_local) only.
REVOKE INSERT ON default.otel_regional FROM app_writer;
REVOKE INSERT ON default.otel_global  FROM app_writer;

-- Shard pruning: set on the role so writer sessions get it without an inline
-- SETTINGS clause. BOTH settings are required -- otel_global's sharding key is
-- dictGet(...), which ClickHouse treats as non-deterministic, so
-- optimize_skip_unused_shards alone silently refuses to prune;
-- allow_nondeterministic_optimize_skip_unused_shards unlocks it. (These are also
-- profile defaults via each CR's extraUsersConfig, so ALL sessions -- readers
-- included -- get them regardless; see the note at the bottom of this file.)
ALTER ROLE app_writer SETTINGS
    optimize_skip_unused_shards = 1,
    allow_nondeterministic_optimize_skip_unused_shards = 1;

-- ── Readers: DIRECT grants on the USER (see cross-DC caveat above) ────────────
-- Reading otel_global fans out otel_global -> otel_regional -> otel_local and
-- ClickHouse checks SELECT on EACH table on EVERY shard the query touches.
-- Because roles are not propagated over the secure inter-server protocol, a
-- reader defined via a role would fail on remote shards with ACCESS_DENIED.
-- Grant the three SELECTs DIRECTLY to each reader user, and CREATE that user
-- identically on FRA, MUC, and HAM (the secret propagates the user by name; the
-- user must exist on every DC or the remote drops the connection). Example:
--
--   CREATE USER bi_user IDENTIFIED WITH sha256_password BY '...';   -- same on all 3 DCs
--   GRANT SELECT ON default.otel_global   TO bi_user;
--   GRANT SELECT ON default.otel_regional TO bi_user;
--   GRANT SELECT ON default.otel_local    TO bi_user;
--   -- Never grant INSERT on a Distributed table to a reader.
--
-- (There is intentionally no app_reader role: a role could not carry these
-- privileges across DCs under the cluster secret.)

-- Assign the writer role to actual users (adjust usernames as needed):
-- GRANT app_writer TO ingest_user;

-- NOTE: the built-in 'default' user is defined in the read-only users_xml
-- config and cannot be altered via SQL (returns ACCESS_STORAGE_READONLY).
-- The two pruning settings are therefore applied to the `default` profile via
-- each ClickHouseCluster CR's extraUsersConfig (NOT extraConfig -- that writes
-- to config.d/ which is ignored for profile settings; extraUsersConfig writes
-- to the users realm):
--   spec.settings.extraUsersConfig.profiles.default:
--     optimize_skip_unused_shards: 1
--     allow_nondeterministic_optimize_skip_unused_shards: 1
-- This is encoded in manifests/{fra,muc,ham}/01-clickhouse-crs.yaml, so a
-- fresh `bash setup.sh` brings all 3 DCs up with pruning already on for every
-- user, readers (direct-grant, no role) included.
