#!/usr/bin/env bash
# Design B: hierarchical federation demo setup.
#
#   3 kind clusters:
#     tcaas-a : customer clusters cust1 (tenant1) + cust2 (tenant2)
#               + stateless federal router
#     tcaas-b : customer cluster cust3 (tenant3)
#               + stateless federal router
#     global  : stateless global router (the Grafana-facing endpoint)
#
#   Query path: otel_global (global router)
#             -> otel_federal (federal router per T-CaaS cluster)
#             -> otel_local  (customer clusters, the actual data)
#
# Run from design-b/:  bash setup.sh
#
# Prerequisites: kind, kubectl, helm, docker OR podman

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS="$SCRIPT_DIR/manifests"

TCAAS_A_CTX="kind-clickhouse-hierarchical-federation-demo-tcaas-a"
TCAAS_B_CTX="kind-clickhouse-hierarchical-federation-demo-tcaas-b"
GLOBAL_CTX="kind-clickhouse-hierarchical-federation-demo-global"

OPERATOR_NS="clickhouse-operator-system"

# Shared inter-server secret used by BOTH federation levels (federals +
# customers). It makes ClickHouse propagate the ORIGINAL querying user across
# every hop (global -> federal -> customer), so each level enforces that
# user's RBAC. Must be identical on all participating nodes; the demo reuses
# one value for both levels, production should use one secret per level,
# sourced from a K8s Secret.
export CLICKHOUSE_CLUSTER_SECRET="${CLICKHOUSE_CLUSTER_SECRET:-$(openssl rand -hex 32)}"

# ── helpers ────────────────────────────────────────────────────────────────────

log()  { echo ""; echo "▶  $*"; }
info() { echo "   $*"; }

detect_runtime() {
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        CONTAINER_RUNTIME=docker
    elif command -v podman &>/dev/null && podman info &>/dev/null 2>&1; then
        CONTAINER_RUNTIME=podman
        export KIND_EXPERIMENTAL_PROVIDER=podman
    else
        echo "ERROR: no container runtime found or running."
        echo "  Start Docker Desktop / podman machine start, then retry."
        exit 1
    fi
    info "Container runtime: $CONTAINER_RUNTIME"
}

check_prereqs() {
    log "Checking prerequisites"
    local missing=()
    for cmd in kind kubectl helm; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        else
            info "$cmd: $(${cmd} version --short 2>/dev/null || ${cmd} version 2>/dev/null | head -1)"
        fi
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "ERROR: missing required tools: ${missing[*]}"
        exit 1
    fi
    detect_runtime
}

wait_for_pods() {
    bash "$SCRIPT_DIR/scripts/wait-for-pods.sh" "$@"
}

# ── Step 1: Create 3 kind clusters ────────────────────────────────────────────

create_clusters() {
    log "Creating kind clusters (2 T-CaaS + 1 global)"
    for c in tcaas-a tcaas-b global; do
        local cluster_name="clickhouse-hierarchical-federation-demo-${c}"
        if kind get clusters 2>/dev/null | grep -q "^${cluster_name}$"; then
            info "Cluster '$cluster_name' already exists, skipping"
        else
            info "Creating cluster '$cluster_name'"
            kind create cluster --config "$MANIFESTS/${c}/kind.yaml"
        fi
    done
}

# ── Step 2: Namespaces ─────────────────────────────────────────────────────────

apply_namespaces() {
    log "Creating namespaces"
    kubectl apply --context "$TCAAS_A_CTX" -f "$MANIFESTS/tcaas-a/00-namespaces.yaml"
    kubectl apply --context "$TCAAS_B_CTX" -f "$MANIFESTS/tcaas-b/00-namespaces.yaml"
    kubectl apply --context "$GLOBAL_CTX" -f "$MANIFESTS/global/00-namespace.yaml"
}

# ── Step 3: Install ClickHouse operator ───────────────────────────────────────

install_operator() {
    log "Installing ClickHouse operator (webhooks disabled)"
    for ctx in "$TCAAS_A_CTX" "$TCAAS_B_CTX" "$GLOBAL_CTX"; do
        info "Installing operator in $ctx"
        helm upgrade --install clickhouse-operator oci://ghcr.io/clickhouse/clickhouse-operator-helm \
            --kube-context "$ctx" \
            --create-namespace \
            --namespace "$OPERATOR_NS" \
            --set webhook.enabled=false \
            --set certManager.enabled=false \
            --wait --timeout 3m
    done
}

# ── Step 4: Deploy KeeperCluster + ClickHouseCluster CRs ──────────────────────

deploy_clickhouse_clusters() {
    log "Deploying KeeperCluster + ClickHouseCluster CRs + NodePort services"
    kubectl apply --context "$TCAAS_A_CTX" -f "$MANIFESTS/tcaas-a/01-cust1.yaml"
    kubectl apply --context "$TCAAS_A_CTX" -f "$MANIFESTS/tcaas-a/02-cust2.yaml"
    kubectl apply --context "$TCAAS_A_CTX" -f "$MANIFESTS/tcaas-a/03-federal.yaml"
    kubectl apply --context "$TCAAS_B_CTX" -f "$MANIFESTS/tcaas-b/01-cust3.yaml"
    kubectl apply --context "$TCAAS_B_CTX" -f "$MANIFESTS/tcaas-b/03-federal.yaml"
    kubectl apply --context "$GLOBAL_CTX" -f "$MANIFESTS/global/01-global.yaml"
}

# ── Step 5: Wait for Keeper + ClickHouse pods (1 replica each) ────────────────

wait_for_keeper() {
    log "Waiting for Keeper pods to be Ready"
    wait_for_pods "$TCAAS_A_CTX" cust1   "clickhouse.com/role=clickhouse-keeper" 1
    wait_for_pods "$TCAAS_A_CTX" cust2   "clickhouse.com/role=clickhouse-keeper" 1
    wait_for_pods "$TCAAS_A_CTX" federal "clickhouse.com/role=clickhouse-keeper" 1
    wait_for_pods "$TCAAS_B_CTX" cust3   "clickhouse.com/role=clickhouse-keeper" 1
    wait_for_pods "$TCAAS_B_CTX" federal "clickhouse.com/role=clickhouse-keeper" 1
    wait_for_pods "$GLOBAL_CTX"  global  "clickhouse.com/role=clickhouse-keeper" 1
}

wait_for_clickhouse() {
    log "Waiting for ClickHouse pods to be Ready"
    wait_for_pods "$TCAAS_A_CTX" cust1   "clickhouse.com/role=clickhouse-server" 1
    wait_for_pods "$TCAAS_A_CTX" cust2   "clickhouse.com/role=clickhouse-server" 1
    wait_for_pods "$TCAAS_A_CTX" federal "clickhouse.com/role=clickhouse-server" 1
    wait_for_pods "$TCAAS_B_CTX" cust3   "clickhouse.com/role=clickhouse-server" 1
    wait_for_pods "$TCAAS_B_CTX" federal "clickhouse.com/role=clickhouse-server" 1
    wait_for_pods "$GLOBAL_CTX"  global  "clickhouse.com/role=clickhouse-server" 1
}

# ── Step 6: Patch federation config (both levels) ─────────────────────────────

patch_federation() {
    log "Patching federation remote_servers (federal + global routers)"
    bash "$SCRIPT_DIR/scripts/patch-federation.sh"
}

# ── Step 7: Apply schemas ─────────────────────────────────────────────────────

apply_schemas() {
    log "Applying ClickHouse schemas (Tier 1 → 2 → 3 → RBAC)"
    bash "$SCRIPT_DIR/scripts/apply-schemas.sh"
}

# ── Step 8: Print access summary ──────────────────────────────────────────────

print_summary() {
    log "design-b demo is ready"
    echo ""
    echo "  Host access (NodePort → kind node → CH pod):"
    echo "    cust1     (tenant1)  HTTP: http://localhost:8811   TCP: clickhouse client --host localhost --port 9811"
    echo "    cust2     (tenant2)  HTTP: http://localhost:8812   TCP: clickhouse client --host localhost --port 9812"
    echo "    federal-a           HTTP: http://localhost:8815   TCP: clickhouse client --host localhost --port 9815"
    echo "    cust3     (tenant3)  HTTP: http://localhost:8821   TCP: clickhouse client --host localhost --port 9821"
    echo "    federal-b           HTTP: http://localhost:8825   TCP: clickhouse client --host localhost --port 9825"
    echo "    global              HTTP: http://localhost:8831   TCP: clickhouse client --host localhost --port 9831"
    echo ""
    echo "  The Grafana datasource would point at the global router only:"
    echo "    clickhouse client --host localhost --port 9831 \\"
    echo "      --query \"SELECT tenant, count() FROM default.otel_global GROUP BY tenant ORDER BY tenant\""
    echo ""
    echo "  HTTP smoke test:"
    echo "    curl 'http://localhost:8831/?query=SELECT+tenant,count()+FROM+default.otel_global+GROUP+BY+tenant'"
    echo ""
    echo "  Full verification suite:"
    echo "    bash scripts/verify.sh"
    echo ""
    echo "  Tear down all 3 clusters:"
    echo "    bash teardown.sh"
}

# ── main ──────────────────────────────────────────────────────────────────────

check_prereqs
create_clusters
apply_namespaces
install_operator
deploy_clickhouse_clusters
wait_for_keeper
wait_for_clickhouse
patch_federation
apply_schemas
print_summary
