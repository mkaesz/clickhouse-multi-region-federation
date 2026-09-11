#!/usr/bin/env bash
# Applies the design-b schemas in dependency order across all six ClickHouse
# clusters (3 customers, 2 federals, 1 global).
# Run from design-b/: bash scripts/apply-schemas.sh
#
# Heal / DDL-readiness machinery is inherited from design-a: the operator's
# Replicated `default` database can wedge after the config-patch restarts
# (stale Keeper registration on emptyDir storage), so every cluster is healed
# and canary-checked before any real DDL runs.
#
# NOTE: plain variables (no bash-4 associative arrays) so the script also
# runs on macOS' stock bash 3.2.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESIGN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCHEMAS="$DESIGN_ROOT/schemas"

TCAAS_A_CTX="kind-clickhouse-hierarchical-federation-demo-tcaas-a"
TCAAS_B_CTX="kind-clickhouse-hierarchical-federation-demo-tcaas-b"
GLOBAL_CTX="kind-clickhouse-hierarchical-federation-demo-global"

log()  { echo ""; echo "▶  $*"; }
info() { echo "   $*"; }

ch_pod() {
    kubectl get pods --context "$1" -n "$2" \
        -l "clickhouse.com/role=clickhouse-server" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

ch_pods() {
    kubectl get pods --context "$1" -n "$2" \
        -l "clickhouse.com/role=clickhouse-server" \
        --field-selector=status.phase=Running \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null
}

has_default_db() {
    local n
    n=$(kubectl exec --context "$1" -n "$2" "$3" -- clickhouse client \
        --query "SELECT count() FROM system.databases WHERE name='default'" 2>/dev/null || echo 0)
    [ -z "$n" ] && n=0
    echo "$n"
}

db_replica_id() { echo "$1" | sed -E 's/.*-clickhouse-([0-9]+)-([0-9]+)-[0-9]+$/\1|\2/'; }

# Heal a wedged Replicated `default` DB (see design-a for the full story).
# With 1 replica per cluster the "no healthy replica" path (restart + retry)
# is the one that matters; the stale-registration drop is kept for safety.
heal_cluster() {
    local ctx="$1" ns="$2" round pod healthy wedged id
    for round in 1 2 3 4; do
        healthy=""; wedged=""
        for pod in $(ch_pods "$ctx" "$ns"); do
            if [ "$(has_default_db "$ctx" "$ns" "$pod")" -ge 1 ]; then
                [ -z "$healthy" ] && healthy="$pod"
            else
                wedged="$wedged $pod"
            fi
        done
        if [ -z "$wedged" ]; then
            info "[$ns] Replicated 'default' DB initialized"
            return 0
        fi
        if [ -z "$healthy" ]; then
            info "[$ns] no healthy replica (round $round) — dropping stale Keeper registration + restarting"
            for pod in $(ch_pods "$ctx" "$ns"); do
                id=$(db_replica_id "$pod")
                # REPLICA_ALREADY_EXISTS wedge on a single-replica cluster:
                # there is no healthy peer to drop the stale registration
                # from, but the wedged server itself is up (it just has no
                # `default` DB) - so drop it via the Keeper path directly.
                # The operator's create-database loop then re-registers the
                # replica cleanly after the restart.
                kubectl exec --context "$ctx" -n "$ns" "$pod" -- clickhouse client \
                    --query "SYSTEM DROP DATABASE REPLICA '$id' FROM ZKPATH '/clickhouse/databases/default'" >/dev/null 2>&1 || true
                kubectl delete pod --context "$ctx" -n "$ns" "$pod" --grace-period=5 >/dev/null 2>&1 || true
            done
        else
            for pod in $wedged; do
                id=$(db_replica_id "$pod")
                info "[$ns] $pod wedged — dropping stale replica '$id' + restarting"
                kubectl exec --context "$ctx" -n "$ns" "$healthy" -- clickhouse client \
                    --query "SYSTEM DROP DATABASE REPLICA '$id' FROM DATABASE default" >/dev/null 2>&1 || true
                kubectl delete pod --context "$ctx" -n "$ns" "$pod" --grace-period=5 >/dev/null 2>&1 || true
            done
        fi
        kubectl wait pod --context "$ctx" -n "$ns" \
            -l "clickhouse.com/role=clickhouse-server" \
            --for=condition=Ready --timeout=180s >/dev/null 2>&1 || true
        sleep 8
    done
    for pod in $(ch_pods "$ctx" "$ns"); do
        [ "$(has_default_db "$ctx" "$ns" "$pod")" -ge 1 ] || {
            echo "ERROR: [$ns] $pod still has no 'default' database after heal"; exit 1; }
    done
}

wait_for_ch() {
    local ctx="$1" ns="$2" pod="$3"
    local max=60 i=0
    info "Waiting for clickhouse client in $ns/$pod ..."
    until kubectl exec --context "$ctx" -n "$ns" "$pod" -- \
            clickhouse client --query "SELECT 1" &>/dev/null; do
        i=$((i + 1))
        [ "$i" -ge "$max" ] && echo "ERROR: CH not responding in $ns/$pod" && exit 1
        sleep 3
    done
    info "OK"
}

TRANSIENT_RE="Macro 'uuid'|QUERY_WAS_CANCELLED|TABLE_IS_READ_ONLY|Coordination|KEEPER_EXCEPTION|ZooKeeper|Not enough|TIMEOUT_EXCEEDED"

run_sql() {
    local ctx="$1" ns="$2" pod="$3" file="$4" attempt out
    info "--> [$ns] $(basename "$file")"
    for attempt in 1 2 3 4 5; do
        # `|| true`: clickhouse client exits non-zero on a CH error, which under
        # `set -e` would abort the script before this retry loop can react.
        out=$(kubectl exec -i --context "$ctx" -n "$ns" "$pod" -- \
            clickhouse client --multiquery < "$file" 2>&1) || true
        if ! echo "$out" | grep -qiE "DB::Exception|Code: [0-9]+"; then
            return 0
        fi
        if echo "$out" | grep -qiE "$TRANSIENT_RE"; then
            info "    transient error (attempt $attempt/5), retrying in 6s: $(echo "$out" | grep -iE 'Code:' | head -1 | cut -c1-90)"
            sleep 6
            continue
        fi
        echo "$out"
        echo "ERROR: applying $(basename "$file") failed on $ns/$pod"
        exit 1
    done
    echo "$out"
    echo "ERROR: $(basename "$file") still failing on $ns/$pod after retries"
    exit 1
}

wait_ddl_ready() {
    local ctx="$1" ns="$2" pod="$3" i out
    for i in $(seq 1 24); do
        out=$(kubectl exec --context "$ctx" -n "$ns" "$pod" -- clickhouse client \
            --query "CREATE TABLE IF NOT EXISTS default.zz_ddl_canary (id UInt64) ENGINE=ReplicatedMergeTree() ORDER BY id" 2>&1) || true
        if ! echo "$out" | grep -qiE "DB::Exception|Code: [0-9]+"; then
            kubectl exec --context "$ctx" -n "$ns" "$pod" -- clickhouse client \
                --query "DROP TABLE IF EXISTS default.zz_ddl_canary SYNC" >/dev/null 2>&1 || true
            info "[$ns] Replicated DB is DDL-ready"
            return 0
        fi
        sleep 5
    done
    # Return (don't exit): prepare_cluster re-heals and retries - the wedge
    # can appear AFTER a heal round when the operator restarts the pod again
    # while reconciling the federation patch.
    info "[$ns] Replicated DB not DDL-ready (last: $(echo "$out" | grep -iE 'Code:' | head -1 | cut -c1-110))"
    return 1
}

# Run a callback over all six clusters: cb <ctx> <ns>
for_each_cluster() {
    "$1" "$TCAAS_A_CTX" cust1
    "$1" "$TCAAS_A_CTX" cust2
    "$1" "$TCAAS_A_CTX" federal
    "$1" "$TCAAS_B_CTX" cust3
    "$1" "$TCAAS_B_CTX" federal
    "$1" "$GLOBAL_CTX" global
}

prepare_cluster() {
    local ctx="$1" ns="$2" pod attempt
    for attempt in 1 2 3; do
        pod=$(ch_pod "$ctx" "$ns")
        info "$ns: $pod (prepare attempt $attempt/3)"
        wait_for_ch "$ctx" "$ns" "$pod"
        heal_cluster "$ctx" "$ns"
        pod=$(ch_pod "$ctx" "$ns")   # pod may have been restarted by the heal
        if wait_ddl_ready "$ctx" "$ns" "$pod"; then
            return 0
        fi
    done
    echo "ERROR: [$ns] could not reach DDL-ready state after 3 heal attempts"
    exit 1
}

log "Preparing all clusters (connect, heal, DDL-readiness)"
for_each_cluster prepare_cluster

# Re-resolve pods after healing; single replica per cluster, so ch_pod is
# deterministic from here on.
POD_CUST1=$(ch_pod "$TCAAS_A_CTX" cust1)
POD_CUST2=$(ch_pod "$TCAAS_A_CTX" cust2)
POD_CUST3=$(ch_pod "$TCAAS_B_CTX" cust3)
POD_FED_A=$(ch_pod "$TCAAS_A_CTX" federal)
POD_FED_B=$(ch_pod "$TCAAS_B_CTX" federal)
POD_GLOBAL=$(ch_pod "$GLOBAL_CTX" global)

log "Step 1: Tier 1 — customer-local tables (ReplicatedMergeTree)"
run_sql "$TCAAS_A_CTX" cust1 "$POD_CUST1" "$SCHEMAS/01_tier1_customer/cust1_otel_local.sql"
run_sql "$TCAAS_A_CTX" cust2 "$POD_CUST2" "$SCHEMAS/01_tier1_customer/cust2_otel_local.sql"
run_sql "$TCAAS_B_CTX" cust3 "$POD_CUST3" "$SCHEMAS/01_tier1_customer/cust3_otel_local.sql"

log "Step 2a: Tier 2 — tenantToShard dictionary (per federal router)"
run_sql "$TCAAS_A_CTX" federal "$POD_FED_A" "$SCHEMAS/02_tier2_federal/dict_tenantToShard.sql"
run_sql "$TCAAS_B_CTX" federal "$POD_FED_B" "$SCHEMAS/02_tier2_federal/dict_tenantToShard.sql"

log "Step 2b: Tier 2 — federal Distributed tables"
run_sql "$TCAAS_A_CTX" federal "$POD_FED_A" "$SCHEMAS/02_tier2_federal/otel_federal.sql"
run_sql "$TCAAS_B_CTX" federal "$POD_FED_B" "$SCHEMAS/02_tier2_federal/otel_federal.sql"

log "Step 3a: Tier 3 — tenant placement metadata (global router)"
run_sql "$GLOBAL_CTX" global "$POD_GLOBAL" "$SCHEMAS/03_tier3_global/tenant_placement.sql"

log "Step 3b: Tier 3 — tenantToFederalShard dictionary (global router)"
run_sql "$GLOBAL_CTX" global "$POD_GLOBAL" "$SCHEMAS/03_tier3_global/dict_tenantToFederalShard.sql"

log "Step 3c: Tier 3 — global Distributed table"
run_sql "$GLOBAL_CTX" global "$POD_GLOBAL" "$SCHEMAS/03_tier3_global/otel_global.sql"

log "Step 4: RBAC — per level (reader must exist BY NAME on every hop)"
run_sql "$TCAAS_A_CTX" cust1 "$POD_CUST1" "$SCHEMAS/04_rbac/customer_rbac.sql"
run_sql "$TCAAS_A_CTX" cust2 "$POD_CUST2" "$SCHEMAS/04_rbac/customer_rbac.sql"
run_sql "$TCAAS_B_CTX" cust3 "$POD_CUST3" "$SCHEMAS/04_rbac/customer_rbac.sql"
run_sql "$TCAAS_A_CTX" federal "$POD_FED_A" "$SCHEMAS/04_rbac/federal_rbac.sql"
run_sql "$TCAAS_B_CTX" federal "$POD_FED_B" "$SCHEMAS/04_rbac/federal_rbac.sql"
run_sql "$GLOBAL_CTX" global "$POD_GLOBAL" "$SCHEMAS/04_rbac/global_rbac.sql"

log "Schemas applied successfully"
