-- RBAC on FEDERAL routers. Run identically on the federal of every T-CaaS
-- cluster.
--
-- The federal is a read-only routing hop: the reader needs SELECT on
-- otel_federal here (the query global forwards targets this table), and the
-- user must exist BY NAME for the cluster-secret propagation to succeed.
-- No writer role: nothing is ever written on a router.

CREATE USER IF NOT EXISTS grafana_reader IDENTIFIED WITH sha256_password BY 'grafana_demo';
GRANT SELECT ON default.otel_federal TO grafana_reader;

-- Safeguard: a Distributed INSERT on a router would fan out to customer
-- clusters - never allowed.
REVOKE INSERT ON default.otel_federal FROM grafana_reader;
