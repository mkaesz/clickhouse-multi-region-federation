#!/usr/bin/env bash
# Applies ClickHouse schemas in the correct deployment order across all 3 DCs.
# Run from the repo root: bash scripts/apply-schemas.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCHEMAS="$REPO_ROOT/schemas"

FRA_CTX="kind-clickhouse-multi-region-federation-demo-fra"
MUC_CTX="kind-clickhouse-multi-region-federation-demo-muc"
HAM_CTX="kind-clickhouse-multi-region-federation-demo-ham"

log()  { echo ""; echo "▶  $*"; }
info() { echo "   $*"; }

ch_pod() {
    kubectl get pods --context "$1" -n "$2" \
        -l "clickhouse.com/role=clickhouse-server" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# All Running clickhouse-server pods in a DC, one per line.
ch_pods() {
    kubectl get pods --context "$1" -n "$2" \
        -l "clickhouse.com/role=clickhouse-server" \
        --field-selector=status.phase=Running \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null
}

# 1 if the pod's Replicated `default` database is initialized, else 0.
has_default_db() {
    local n
    n=$(kubectl exec --context "$1" -n "$2" "$3" -- clickhouse client \
        --query "SELECT count() FROM system.databases WHERE name='default'" 2>/dev/null || echo 0)
    [ -z "$n" ] && n=0
    echo "$n"
}

# DatabaseReplicated identity of a pod: <dc>-clickhouse-<shard>-<replica>-0 -> "<shard>|<replica>".
db_replica_id() { echo "$1" | sed -E 's/.*-clickhouse-([0-9]+)-([0-9]+)-[0-9]+$/\1|\2/'; }

# Heal wedged replicas so the Replicated `default` DB is initialized on EVERY
# pod BEFORE any DDL runs. Storage is emptyDir, so a restarted CH pod comes up
# with fresh local state but a leftover Keeper registration from its previous
# incarnation; the digests disagree and it aborts init with REPLICA_ALREADY_EXISTS
# ("/replicas/<id>/digest ... already exists"), leaving it with NO `default` DB
# forever. A plain restart can't fix it -- the stale Keeper node must be dropped
# first. Per wedged replica: drop its registration from a healthy peer, then
# restart it so it re-registers cleanly and replays the DDL log. The
# config-patch restarts (patch-federation, TLS) are what trigger the wedge, so
# this must run here, after those restarts, before we CREATE anything.
heal_dc() {
    local ctx="$1" ns="$2" round pod healthy wedged id n
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
            info "[$ns] Replicated 'default' DB initialized on all replicas"
            return 0
        fi
        if [ -z "$healthy" ]; then
            info "[$ns] no healthy replica yet (round $round) — restarting all, retrying"
            for pod in $(ch_pods "$ctx" "$ns"); do
                kubectl delete pod --context "$ctx" -n "$ns" "$pod" --grace-period=5 >/dev/null 2>&1 || true
            done
        else
            for pod in $wedged; do
                id=$(db_replica_id "$pod")
                info "[$ns] $pod wedged (no 'default' DB) — dropping stale replica '$id' + restarting"
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

# A pod in the DC whose Replicated `default` DB is initialized (schema target).
healthy_pod() {
    local pod
    for pod in $(ch_pods "$1" "$2"); do
        [ "$(has_default_db "$1" "$2" "$pod")" -ge 1 ] && { echo "$pod"; return 0; }
    done
    ch_pod "$1" "$2"  # fallback
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

# Transient errors that appear briefly after a replica restart, while the
# Replicated database is still stabilizing (e.g. the {uuid} macro can't resolve
# until the DB re-registers, or a coordination call is retried). Safe to retry:
# the schema DDL is all IF NOT EXISTS.
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

# Confirm the Replicated `default` DB can actually run {uuid}-based DDL before we
# apply the real schemas. Right after heal_dc restarts a replica, a CREATE can
# briefly fail with "Macro 'uuid' ... only supported ..." until the DB
# re-stabilizes. Loop a throwaway ReplicatedMergeTree create/drop until it
# succeeds, so schema application never races that window.
wait_ddl_ready() {
    local ctx="$1" ns="$2" pod="$3" i out
    for i in $(seq 1 24); do
        # `|| true`: don't let `set -e` abort on the canary's own CH error --
        # that transient failure is exactly what we're looping to ride out.
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
    echo "ERROR: [$ns] Replicated DB never became DDL-ready (last: $(echo "$out" | grep -iE 'Code:' | head -1))"
    exit 1
}

log "Discovering CH pods"
POD_FRA=$(ch_pod "$FRA_CTX" fra)
POD_MUC=$(ch_pod "$MUC_CTX" muc)
POD_HAM=$(ch_pod "$HAM_CTX" ham)
info "FRA: $POD_FRA  MUC: $POD_MUC  HAM: $POD_HAM"

log "Waiting for CH to accept connections"
wait_for_ch "$FRA_CTX" fra "$POD_FRA"
wait_for_ch "$MUC_CTX" muc "$POD_MUC"
wait_for_ch "$HAM_CTX" ham "$POD_HAM"

log "Healing wedged replicas (Replicated 'default' DB must be up on every pod)"
heal_dc "$FRA_CTX" fra
heal_dc "$MUC_CTX" muc
heal_dc "$HAM_CTX" ham

# Re-select the schema target as a HEALTHY replica per DC. heal_dc may have
# restarted the pod ch_pod picked, and DDL must run against an initialized
# Replicated DB (from there it auto-propagates to the other replica).
POD_FRA=$(healthy_pod "$FRA_CTX" fra)
POD_MUC=$(healthy_pod "$MUC_CTX" muc)
POD_HAM=$(healthy_pod "$HAM_CTX" ham)
info "Schema targets — FRA: $POD_FRA  MUC: $POD_MUC  HAM: $POD_HAM"

log "Waiting for Replicated DB to be DDL-ready (post-heal stabilization)"
wait_ddl_ready "$FRA_CTX" fra "$POD_FRA"
wait_ddl_ready "$MUC_CTX" muc "$POD_MUC"
wait_ddl_ready "$HAM_CTX" ham "$POD_HAM"

log "Step 1: Tier 1 — local tables (ReplicatedMergeTree)"
run_sql "$FRA_CTX" fra "$POD_FRA" "$SCHEMAS/01_tier1_local/fra_otel_local.sql"
run_sql "$MUC_CTX" muc "$POD_MUC" "$SCHEMAS/01_tier1_local/muc_otel_local.sql"
run_sql "$HAM_CTX" ham "$POD_HAM" "$SCHEMAS/01_tier1_local/ham_otel_local.sql"

log "Step 2: Tier 2 — regional Distributed tables"
run_sql "$FRA_CTX" fra "$POD_FRA" "$SCHEMAS/02_tier2_regional/fra_otel_regional.sql"
run_sql "$MUC_CTX" muc "$POD_MUC" "$SCHEMAS/02_tier2_regional/muc_otel_regional.sql"
run_sql "$HAM_CTX" ham "$POD_HAM" "$SCHEMAS/02_tier2_regional/ham_otel_regional.sql"

log "Step 3a: Tier 3 — regionToShard dictionary (sharding-key source, per DC)"
run_sql "$FRA_CTX" fra "$POD_FRA" "$SCHEMAS/03_tier3_global/dict_regionToShard.sql"
run_sql "$MUC_CTX" muc "$POD_MUC" "$SCHEMAS/03_tier3_global/dict_regionToShard.sql"
run_sql "$HAM_CTX" ham "$POD_HAM" "$SCHEMAS/03_tier3_global/dict_regionToShard.sql"

log "Step 3b: Tier 3 — global Distributed tables (cross-DC)"
run_sql "$FRA_CTX" fra "$POD_FRA" "$SCHEMAS/03_tier3_global/fra_otel_global.sql"
run_sql "$MUC_CTX" muc "$POD_MUC" "$SCHEMAS/03_tier3_global/muc_otel_global.sql"
run_sql "$HAM_CTX" ham "$POD_HAM" "$SCHEMAS/03_tier3_global/ham_otel_global.sql"

log "Step 4: RBAC — roles and grants (per-DC)"
run_sql "$FRA_CTX" fra "$POD_FRA" "$SCHEMAS/04_rbac/roles_and_grants.sql"
run_sql "$MUC_CTX" muc "$POD_MUC" "$SCHEMAS/04_rbac/roles_and_grants.sql"
run_sql "$HAM_CTX" ham "$POD_HAM" "$SCHEMAS/04_rbac/roles_and_grants.sql"

log "Schemas applied successfully"
