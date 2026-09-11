#!/usr/bin/env bash
# End-to-end verification of the hierarchical federation:
#   1. Writes land on customer clusters only (otel_local).
#   2. Each federal aggregates exactly its own customers (otel_federal).
#   3. The global router sees every tenant across both T-CaaS clusters
#      (otel_global = Distributed over Distributed, counts must match leaves).
#   4. Tenant pruning is live on the global level (force_... succeeds with a
#      tenant filter, fails without one).
#   5. Two-hop RBAC: grafana_reader (propagated by name via the cluster
#      secrets) can read otel_global end to end but cannot INSERT anywhere.
#
# Run from design-b/: bash scripts/verify.sh

set -euo pipefail

TCAAS_A_CTX="kind-clickhouse-hierarchical-federation-demo-tcaas-a"
TCAAS_B_CTX="kind-clickhouse-hierarchical-federation-demo-tcaas-b"
GLOBAL_CTX="kind-clickhouse-hierarchical-federation-demo-global"

PASS=0
FAIL=0

log()  { echo ""; echo "▶  $*"; }
ok()   { echo "   ✓ $*"; PASS=$((PASS+1)); }
bad()  { echo "   ✗ $*"; FAIL=$((FAIL+1)); }

ch_pod() {
    kubectl get pods --context "$1" -n "$2" \
        -l "clickhouse.com/role=clickhouse-server" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# q <ctx> <ns> <pod> <query> [extra clickhouse client args...]
# Retries transient failures (remote hop still settling after restarts).
q() {
    local ctx="$1" ns="$2" pod="$3" query="$4"; shift 4
    local attempt out
    for attempt in 1 2 3 4 5; do
        out=$(kubectl exec --context "$ctx" -n "$ns" "$pod" -- \
            clickhouse client --query "$query" "$@" 2>&1) && { echo "$out"; return 0; }
        if echo "$out" | grep -qiE "NETWORK_ERROR|ALL_CONNECTION_TRIES_FAILED|Timeout|Broken pipe|SOCKET_TIMEOUT"; then
            sleep 5; continue
        fi
        echo "$out"; return 1
    done
    echo "$out"; return 1
}

log "Discovering pods"
POD_CUST1=$(ch_pod "$TCAAS_A_CTX" cust1)
POD_CUST2=$(ch_pod "$TCAAS_A_CTX" cust2)
POD_CUST3=$(ch_pod "$TCAAS_B_CTX" cust3)
POD_FED_A=$(ch_pod "$TCAAS_A_CTX" federal)
POD_FED_B=$(ch_pod "$TCAAS_B_CTX" federal)
POD_GLOBAL=$(ch_pod "$GLOBAL_CTX" global)
echo "   cust1=$POD_CUST1 cust2=$POD_CUST2 cust3=$POD_CUST3"
echo "   federal-a=$POD_FED_A federal-b=$POD_FED_B global=$POD_GLOBAL"

# ── 1. Writes: local otel_local only ──────────────────────────────────────────

log "1. Inserting demo rows on each customer cluster (otel_local)"
q "$TCAAS_A_CTX" cust1 "$POD_CUST1" \
    "INSERT INTO default.otel_local (id, event_time, payload) VALUES (1, now(), 'cust1 row'), (2, now(), 'cust1 row'), (3, now(), 'cust1 row')" >/dev/null \
    && ok "insert into cust1 otel_local" || bad "insert into cust1 otel_local"
q "$TCAAS_A_CTX" cust2 "$POD_CUST2" \
    "INSERT INTO default.otel_local (id, event_time, payload) VALUES (11, now(), 'cust2 row'), (12, now(), 'cust2 row')" >/dev/null \
    && ok "insert into cust2 otel_local" || bad "insert into cust2 otel_local"
q "$TCAAS_B_CTX" cust3 "$POD_CUST3" \
    "INSERT INTO default.otel_local (id, event_time, payload) VALUES (21, now(), 'cust3 row')" >/dev/null \
    && ok "insert into cust3 otel_local" || bad "insert into cust3 otel_local"

# `|| VAR=ERR`: a failed capture must not abort the suite under set -e -
# the mismatch check below reports it as a failure instead.
C1=$(q "$TCAAS_A_CTX" cust1 "$POD_CUST1" "SELECT count() FROM default.otel_local") || C1=ERR
C2=$(q "$TCAAS_A_CTX" cust2 "$POD_CUST2" "SELECT count() FROM default.otel_local") || C2=ERR
C3=$(q "$TCAAS_B_CTX" cust3 "$POD_CUST3" "SELECT count() FROM default.otel_local") || C3=ERR
echo "   leaf counts: cust1=$C1 cust2=$C2 cust3=$C3"

# ── 2. Federal level: each federal sees exactly its own customers ─────────────

log "2. Federal fan-out (otel_federal)"
FA=$(q "$TCAAS_A_CTX" federal "$POD_FED_A" "SELECT count() FROM default.otel_federal") || FA="ERR: $FA"
[ "$FA" = "$((C1 + C2))" ] \
    && ok "federal-a count $FA == cust1+cust2 ($((C1 + C2)))" \
    || bad "federal-a count $FA != cust1+cust2 ($((C1 + C2)))"

FB=$(q "$TCAAS_B_CTX" federal "$POD_FED_B" "SELECT count() FROM default.otel_federal") || FB="ERR: $FB"
[ "$FB" = "$C3" ] \
    && ok "federal-b count $FB == cust3 ($C3)" \
    || bad "federal-b count $FB != cust3 ($C3)"

TEN_A=$(q "$TCAAS_A_CTX" federal "$POD_FED_A" \
    "SELECT arraySort(groupArray(tenant)) FROM (SELECT DISTINCT tenant FROM default.otel_federal)") || TEN_A=ERR
[ "$TEN_A" = "['tenant1','tenant2']" ] \
    && ok "federal-a sees only its own tenants: $TEN_A" \
    || bad "federal-a tenants unexpected: $TEN_A"

# ── 3. Global level: Distributed over Distributed ─────────────────────────────

log "3. Global fan-out across both T-CaaS clusters (otel_global)"
G=$(q "$GLOBAL_CTX" global "$POD_GLOBAL" "SELECT count() FROM default.otel_global") || G="ERR: $G"
[ "$G" = "$((C1 + C2 + C3))" ] \
    && ok "global count $G == sum of all leaves ($((C1 + C2 + C3)))" \
    || bad "global count $G != sum of all leaves ($((C1 + C2 + C3)))"

G1=$(q "$GLOBAL_CTX" global "$POD_GLOBAL" \
    "SELECT count() FROM default.otel_global WHERE tenant = 'tenant1'") || G1=ERR
[ "$G1" = "$C1" ] \
    && ok "global tenant1 count $G1 == cust1 ($C1)" \
    || bad "global tenant1 count $G1 != cust1 ($C1)"

G3=$(q "$GLOBAL_CTX" global "$POD_GLOBAL" \
    "SELECT count() FROM default.otel_global WHERE tenant = 'tenant3'") || G3=ERR
[ "$G3" = "$C3" ] \
    && ok "global tenant3 count $G3 == cust3 ($C3)" \
    || bad "global tenant3 count $G3 != cust3 ($C3)"

# ── 4. Tenant pruning on the global router ────────────────────────────────────

log "4. Tenant pruning (force_optimize_skip_unused_shards)"
if q "$GLOBAL_CTX" global "$POD_GLOBAL" \
    "SELECT count() FROM default.otel_global WHERE tenant = 'tenant3' SETTINGS force_optimize_skip_unused_shards = 1" >/dev/null; then
    ok "tenant-filtered query prunes (force setting accepted)"
else
    bad "tenant-filtered query did NOT prune"
fi

# An unfiltered read cannot prune - force=1 must turn that into an error;
# if it doesn't, pruning was never in play at all.
if q "$GLOBAL_CTX" global "$POD_GLOBAL" \
    "SELECT count() FROM default.otel_global SETTINGS force_optimize_skip_unused_shards = 1" >/dev/null 2>&1; then
    bad "unfiltered query unexpectedly passed force_optimize_skip_unused_shards"
else
    ok "unfiltered query correctly rejected under force_optimize_skip_unused_shards"
fi

# ── 5. Two-hop RBAC (grafana_reader propagated by name via cluster secrets) ───

log "5. RBAC: grafana_reader end to end"
R=$(q "$GLOBAL_CTX" global "$POD_GLOBAL" \
    "SELECT count() FROM default.otel_global" \
    --user grafana_reader --password grafana_demo) \
    && ok "grafana_reader reads otel_global across both hops (count=$R)" \
    || bad "grafana_reader failed to read otel_global: $R"

if q "$GLOBAL_CTX" global "$POD_GLOBAL" \
    "INSERT INTO default.otel_global (id, event_time, payload, tenant) VALUES (999, now(), 'nope', 'tenant1')" \
    --user grafana_reader --password grafana_demo >/dev/null 2>&1; then
    bad "grafana_reader could INSERT into otel_global (must be read-only)"
else
    ok "grafana_reader INSERT into otel_global rejected"
fi

if q "$TCAAS_A_CTX" federal "$POD_FED_A" \
    "INSERT INTO default.otel_federal (id, event_time, payload, tenant) VALUES (999, now(), 'nope', 'tenant1')" \
    --user grafana_reader --password grafana_demo >/dev/null 2>&1; then
    bad "grafana_reader could INSERT into otel_federal (must be read-only)"
else
    ok "grafana_reader INSERT into otel_federal rejected"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

log "Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
