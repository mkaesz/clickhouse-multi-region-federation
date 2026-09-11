-- RBAC on the GLOBAL router - the user Grafana connects as.
--
-- grafana_reader authenticates HERE (password checked on this hop only);
-- both cluster secrets then propagate the identity by name down the chain,
-- where the federal checks SELECT on otel_federal and each customer cluster
-- checks SELECT on otel_local. Direct grants everywhere - roles would not
-- propagate across the secure inter-server protocol.

CREATE USER IF NOT EXISTS grafana_reader IDENTIFIED WITH sha256_password BY 'grafana_demo';
GRANT SELECT ON default.otel_global TO grafana_reader;

-- Safeguards: the Grafana user is strictly read-only.
REVOKE INSERT ON default.otel_global FROM grafana_reader;
