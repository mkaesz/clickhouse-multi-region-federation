-- RBAC on CUSTOMER clusters (leaves). Run identically on cust1, cust2, cust3.
--
-- Two-hop RBAC model (see design-b README):
--   * Both federation levels carry a cluster <secret>, so a read of
--     otel_global propagates the ORIGINAL user global -> federal -> customer,
--     and every hop enforces that user's privileges.
--   * The user is propagated BY NAME and its ROLES are NOT enabled remotely,
--     so the reader must EXIST on every hop and carry DIRECT grants
--     (design-a lesson, doubly relevant with two hops).
--
-- Writers stay role-based: they only ever touch the local otel_local and
-- never traverse a federation hop.

-- ── Writers: role-based, this customer cluster only ──────────────────────────
CREATE ROLE IF NOT EXISTS app_writer;
GRANT INSERT, SELECT ON default.otel_local TO app_writer;
-- Assign to the customer's ingest users as needed:
-- GRANT app_writer TO ingest_user;

-- ── Reader: DIRECT grants on the USER, identical on every cluster ─────────────
-- Demo credentials - replace with real secrets management in production.
CREATE USER IF NOT EXISTS grafana_reader IDENTIFIED WITH sha256_password BY 'grafana_demo';
GRANT SELECT ON default.otel_local TO grafana_reader;
