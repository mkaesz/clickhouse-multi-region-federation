#!/usr/bin/env bash
# Injects the two federation levels into the router CRs:
#
#   * FEDERAL routers get remote_servers.customers - one shard per customer
#     ClickHouse of THEIR T-CaaS cluster, addressed via in-cluster
#     headless-service DNS (static, never leaves the cluster). Shard <name> =
#     tenant id (read by the tenantToShard dictionary).
#   * The GLOBAL router gets remote_servers.federals - one shard per T-CaaS
#     cluster, addressed via the federal NodePort on the kind node IP
#     (discovered at runtime, hence this script). Shard <name> = T-CaaS id.
#
# Customer clusters are NEVER patched - they have no federation knowledge.
# This encodes the config-locality property of design-b: adding a customer
# touches only its own T-CaaS federal; adding a T-CaaS cluster touches only
# the global router.
#
# Run from design-b/: bash scripts/patch-federation.sh

set -euo pipefail

TCAAS_A_CTX="kind-clickhouse-hierarchical-federation-demo-tcaas-a"
TCAAS_B_CTX="kind-clickhouse-hierarchical-federation-demo-tcaas-b"
GLOBAL_CTX="kind-clickhouse-hierarchical-federation-demo-global"

# Shared inter-server secret (see setup.sh). Both federation levels carry it,
# so a global read propagates the ORIGINAL user global -> federal -> customer
# and every hop enforces that user's RBAC. The demo reuses one value for both
# levels; production should use a distinct secret per level, each sourced
# from a K8s Secret (<secret from_env=.../>).
CLUSTER_SECRET="${CLICKHOUSE_CLUSTER_SECRET:-$(openssl rand -hex 32)}"

log()  { echo ""; echo "▶  $*"; }
info() { echo "   $*"; }

# ── Get node IPs (global -> federal routing only) ─────────────────────────────

log "Discovering kind node IPs"
TCAAS_A_IP=$(kubectl get nodes --context "$TCAAS_A_CTX" \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
TCAAS_B_IP=$(kubectl get nodes --context "$TCAAS_B_CTX" \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

info "tcaas-a node IP: $TCAAS_A_IP  (federal NodePort 30915)"
info "tcaas-b node IP: $TCAAS_B_IP  (federal NodePort 30925)"

if [ -z "$TCAAS_A_IP" ] || [ -z "$TCAAS_B_IP" ]; then
    echo "ERROR: could not determine one or more node IPs"
    exit 1
fi

# ── Receiver-side secret stanzas ──────────────────────────────────────────────
# The cluster <secret> handshake is validated by the RECEIVER: an incoming
# secure inter-server connection carries the cluster name, and the receiving
# server looks the secret up in ITS OWN remote_servers. So every hop target
# needs the cluster name + secret defined locally:
#   * customer clusters need a minimal `customers` entry,
#   * federal routers need a minimal `federals` entry (they receive from
#     global) in addition to their real `customers` definition.
# The minimal entry contains only the node itself - NO topology. It is static:
# adding a sibling customer never touches it, so config locality is preserved.

patch_customer() {
    local ctx="$1" ns="$2"
    info "Patching ClickHouseCluster/$ns in $ctx (receiver-side secret stanza)"
    kubectl patch clickhousecluster "$ns" \
        --context "$ctx" --namespace "$ns" --type merge --patch "$(cat <<JSON
{
  "spec": {
    "settings": {
      "extraConfig": {
        "remote_servers": {
          "customers": {
            "secret": "${CLUSTER_SECRET}",
            "shard": [
              {"replica": {"host": "localhost", "port": 9001}}
            ]
          }
        }
      }
    }
  }
}
JSON
)"
}

# ── Patch the federal routers (customers cluster, in-cluster DNS) ─────────────
# The operator writes spec.settings.extraConfig verbatim to
# /etc/clickhouse-server/config.d/99-extra-config.yaml (same mechanism as
# design-a). Per-pod FQDN convention of the operator:
#   <cr>-clickhouse-<shard>-<replica>-0.<cr>-clickhouse-headless.<ns>.svc.cluster.local
# The minimal `federals` entry is the receiver-side secret stanza for the
# hop coming in from the global router (see above).

patch_federal_a() {
    info "Patching ClickHouseCluster/federal in $TCAAS_A_CTX (customers: tenant1, tenant2)"
    kubectl patch clickhousecluster federal \
        --context "$TCAAS_A_CTX" --namespace federal --type merge --patch "$(cat <<JSON
{
  "spec": {
    "settings": {
      "extraConfig": {
        "remote_servers": {
          "customers": {
            "secret": "${CLUSTER_SECRET}",
            "shard": [
              {"name": "tenant1", "replica": {"host": "cust1-clickhouse-0-0-0.cust1-clickhouse-headless.cust1.svc.cluster.local", "port": 9001}},
              {"name": "tenant2", "replica": {"host": "cust2-clickhouse-0-0-0.cust2-clickhouse-headless.cust2.svc.cluster.local", "port": 9001}}
            ]
          },
          "federals": {
            "secret": "${CLUSTER_SECRET}",
            "shard": [
              {"replica": {"host": "localhost", "port": 9001}}
            ]
          }
        }
      }
    }
  }
}
JSON
)"
}

patch_federal_b() {
    info "Patching ClickHouseCluster/federal in $TCAAS_B_CTX (customers: tenant3)"
    kubectl patch clickhousecluster federal \
        --context "$TCAAS_B_CTX" --namespace federal --type merge --patch "$(cat <<JSON
{
  "spec": {
    "settings": {
      "extraConfig": {
        "remote_servers": {
          "customers": {
            "secret": "${CLUSTER_SECRET}",
            "shard": [
              {"name": "tenant3", "replica": {"host": "cust3-clickhouse-0-0-0.cust3-clickhouse-headless.cust3.svc.cluster.local", "port": 9001}}
            ]
          },
          "federals": {
            "secret": "${CLUSTER_SECRET}",
            "shard": [
              {"replica": {"host": "localhost", "port": 9001}}
            ]
          }
        }
      }
    }
  }
}
JSON
)"
}

# ── Patch the global router (federals cluster, NodePort across kind network) ──

patch_global() {
    info "Patching ClickHouseCluster/global in $GLOBAL_CTX (federals: tcaas-a, tcaas-b)"
    kubectl patch clickhousecluster global \
        --context "$GLOBAL_CTX" --namespace global --type merge --patch "$(cat <<JSON
{
  "spec": {
    "settings": {
      "extraConfig": {
        "remote_servers": {
          "federals": {
            "secret": "${CLUSTER_SECRET}",
            "shard": [
              {"name": "tcaas-a", "replica": {"host": "${TCAAS_A_IP}", "port": 30915}},
              {"name": "tcaas-b", "replica": {"host": "${TCAAS_B_IP}", "port": 30925}}
            ]
          }
        }
      }
    }
  }
}
JSON
)"
}

log "Patching customer clusters (receiver-side secret stanzas)"
patch_customer "$TCAAS_A_CTX" cust1
patch_customer "$TCAAS_A_CTX" cust2
patch_customer "$TCAAS_B_CTX" cust3

log "Patching federal routers"
patch_federal_a
patch_federal_b

log "Patching global router"
patch_global

# ── Wait for the operator to roll out the updated config ─────────────────────
# The extraConfig change triggers a restart of the router pods (1 replica each).

wait_for_router() {
    local ctx="$1" ns="$2"
    local max=60 i=0
    info "Waiting for $ns router pod in $ctx to be Ready after config patch ..."
    until [ "$(kubectl get pods --context "$ctx" -n "$ns" \
        -l 'clickhouse.com/role=clickhouse-server' \
        -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{.ready}{"\n"}{end}{end}' 2>/dev/null \
        | grep -c '^true$' || true)" -ge 1 ]; do
        i=$((i+1))
        [ "$i" -ge "$max" ] && echo "  ERROR: Timed out" && exit 1
        sleep 5
    done
    info "  Ready"
}

log "Waiting for pods to re-stabilize after config patch"
wait_for_router "$TCAAS_A_CTX" cust1
wait_for_router "$TCAAS_A_CTX" cust2
wait_for_router "$TCAAS_B_CTX" cust3
wait_for_router "$TCAAS_A_CTX" federal
wait_for_router "$TCAAS_B_CTX" federal
wait_for_router "$GLOBAL_CTX" global

# ── Trigger explicit config reload (belt-and-suspenders) ─────────────────────

reload_config() {
    local ctx="$1" ns="$2" pod
    pod=$(kubectl get pods --context "$ctx" -n "$ns" \
        -l 'clickhouse.com/role=clickhouse-server' \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -n "$pod" ]; then
        info "SYSTEM RELOAD CONFIG on $ns/$pod"
        kubectl exec --context "$ctx" -n "$ns" "$pod" -- \
            clickhouse client --query "SYSTEM RELOAD CONFIG" 2>/dev/null || true
    fi
}

log "Reloading ClickHouse config"
reload_config "$TCAAS_A_CTX" cust1
reload_config "$TCAAS_A_CTX" cust2
reload_config "$TCAAS_B_CTX" cust3
reload_config "$TCAAS_A_CTX" federal
reload_config "$TCAAS_B_CTX" federal
reload_config "$GLOBAL_CTX" global

log "Federation patch complete"
info "federal@tcaas-a -> cust1, cust2 (in-cluster DNS)"
info "federal@tcaas-b -> cust3 (in-cluster DNS)"
info "global          -> federal@tcaas-a via $TCAAS_A_IP:30915, federal@tcaas-b via $TCAAS_B_IP:30925"
