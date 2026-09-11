#!/usr/bin/env bash
# Generates a shared CA and per-DC server certificates, stores them as
# Kubernetes Secrets, and configures each ClickHouseCluster CR to:
#   - expose tcp_port_secure (9440) with the generated cert
#   - use TLS for all cross-DC global connections
#
# Designed to run after patch-federation.sh and before apply-schemas.sh.
# Run from the repo root: bash scripts/setup-tls.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="/tmp/clickhouse-tls"

FRA_CTX="kind-clickhouse-multi-region-federation-demo-fra"
MUC_CTX="kind-clickhouse-multi-region-federation-demo-muc"
HAM_CTX="kind-clickhouse-multi-region-federation-demo-ham"

# Shared inter-server secret for the `global` cluster (see setup.sh). This
# script writes the AUTHORITATIVE remote_servers.global block (it overwrites
# patch-federation.sh's), so the secret set here is the one that ends up live.
# Inherited from the environment via setup.sh so all 3 DCs match; generated
# here as a fallback for standalone runs. With it set, TLS encrypts the wire
# AND the original user + grants are propagated to remote shards, so per-user
# RBAC is enforced end to end (not silently downgraded to `default`).
CLUSTER_SECRET="${CLICKHOUSE_CLUSTER_SECRET:-$(openssl rand -hex 32)}"

log()  { echo ""; echo "▶  $*"; }
info() { echo "   $*"; }

# ── Step 1: Discover node IPs ─────────────────────────────────────────────────

log "Discovering kind node IPs"
FRA_IP=$(kubectl get nodes --context "$FRA_CTX" \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
MUC_IP=$(kubectl get nodes --context "$MUC_CTX" \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
HAM_IP=$(kubectl get nodes --context "$HAM_CTX" \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
info "FRA: $FRA_IP  MUC: $MUC_IP  HAM: $HAM_IP"

# ── Step 2: Generate CA ───────────────────────────────────────────────────────

log "Generating CA"
mkdir -p "$CERTS_DIR"

if [ ! -f "$CERTS_DIR/ca.key" ]; then
    openssl genrsa -out "$CERTS_DIR/ca.key" 4096 2>/dev/null
    openssl req -new -x509 -days 3650 \
        -key "$CERTS_DIR/ca.key" \
        -out "$CERTS_DIR/ca.crt" \
        -subj "/CN=ClickHouse-demo-CA/O=demo" 2>/dev/null
    info "CA generated: $CERTS_DIR/ca.crt"
else
    info "CA already exists, reusing"
fi

# ── Step 3: Generate per-DC server certificates ───────────────────────────────
# SANs cover all hostnames/IPs a remote CH node may use to connect:
#   - localhost / 127.0.0.1 (intra-pod)
#   - pod FQDN (intra-cluster distributed queries)
#   - headless service FQDN
#   - kind node IP (cross-DC NodePort connections from other clusters)

log "Generating per-DC server certificates"

gen_cert() {
    local dc="$1" node_ip="$2"
    local pod_fqdn="${dc}-clickhouse-0-0-0.${dc}-clickhouse-headless.${dc}.svc.cluster.local"
    local svc_fqdn="${dc}-clickhouse-headless.${dc}.svc.cluster.local"

    info "DC=$dc  pod=$pod_fqdn  nodeIP=$node_ip"

    openssl genrsa -out "$CERTS_DIR/$dc.key" 2048 2>/dev/null

    cat > "$CERTS_DIR/$dc.ext" <<EXT
[req]
req_extensions     = v3_req
distinguished_name = req_distinguished_name
prompt             = no
[req_distinguished_name]
CN = ${dc}-clickhouse
O  = demo
[v3_req]
subjectAltName = @alt_names
[alt_names]
DNS.1 = localhost
DNS.2 = ${pod_fqdn}
DNS.3 = ${svc_fqdn}
IP.1  = 127.0.0.1
IP.2  = ${node_ip}
EXT

    openssl req -new \
        -key "$CERTS_DIR/$dc.key" \
        -out "$CERTS_DIR/$dc.csr" \
        -config "$CERTS_DIR/$dc.ext" 2>/dev/null

    openssl x509 -req -days 3650 \
        -in  "$CERTS_DIR/$dc.csr" \
        -CA  "$CERTS_DIR/ca.crt" \
        -CAkey "$CERTS_DIR/ca.key" \
        -CAcreateserial \
        -out "$CERTS_DIR/$dc.crt" \
        -extfile "$CERTS_DIR/$dc.ext" \
        -extensions v3_req 2>/dev/null

    info "  cert: $CERTS_DIR/$dc.crt"
}

gen_cert fra "$FRA_IP"
gen_cert muc "$MUC_IP"
gen_cert ham "$HAM_IP"

# ── Step 4: Create / update K8s Secrets ──────────────────────────────────────

log "Creating TLS secrets in each DC namespace"

for entry in "fra:$FRA_CTX" "muc:$MUC_CTX" "ham:$HAM_CTX"; do
    dc="${entry%%:*}"; ctx="${entry##*:}"
    info "Secret clickhouse-tls in $dc"
    kubectl create secret generic clickhouse-tls \
        --context "$ctx" -n "$dc" \
        --from-file=ca.crt="$CERTS_DIR/ca.crt" \
        --from-file=server.crt="$CERTS_DIR/$dc.crt" \
        --from-file=server.key="$CERTS_DIR/$dc.key" \
        --dry-run=client -o yaml \
    | kubectl apply --context "$ctx" -n "$dc" -f -
done

# ── Step 5: Patch ClickHouseCluster CRs ──────────────────────────────────────
# One patch per DC covering:
#   - podTemplate.volumes:         mount the TLS secret
#   - containerTemplate.volumeMounts: expose it at /etc/clickhouse-server/certs
#   - extraConfig:                 tcp_port_secure, openSSL, secure global

log "Patching ClickHouseCluster CRs with TLS config"

patch_tls_cr() {
    local dc="$1" ctx="$2"
    local fra_host muc_host ham_host
    local fra_port=30941 muc_port=30942 ham_port=30943

    # Local DC uses loopback (is_local=1), others use NodePort IPs
    case "$dc" in
        fra) fra_host="localhost"; fra_port=9440; muc_host="$MUC_IP"; ham_host="$HAM_IP" ;;
        muc) fra_host="$FRA_IP";  muc_host="localhost"; muc_port=9440; ham_host="$HAM_IP" ;;
        ham) fra_host="$FRA_IP";  muc_host="$MUC_IP";  ham_host="localhost"; ham_port=9440 ;;
    esac

    info "Patching $dc (local shard → localhost:9440, remote shards via NodePort)"

    kubectl patch clickhousecluster "$dc" \
        --context "$ctx" --namespace "$dc" --type merge \
        --patch "$(cat <<JSON
{
  "spec": {
    "podTemplate": {
      "volumes": [
        {"name": "tls-certs", "secret": {"secretName": "clickhouse-tls"}}
      ]
    },
    "containerTemplate": {
      "volumeMounts": [
        {
          "name": "tls-certs",
          "mountPath": "/etc/clickhouse-server/certs",
          "readOnly": true
        }
      ]
    },
    "settings": {
      "extraConfig": {
        "tcp_port_secure": 9440,
        "openSSL": {
          "server": {
            "certificateFile": "/etc/clickhouse-server/certs/server.crt",
            "privateKeyFile":  "/etc/clickhouse-server/certs/server.key",
            "caConfig":        "/etc/clickhouse-server/certs/ca.crt",
            "verificationMode": "relaxed",
            "loadDefaultCAFile": "false",
            "cacheSessions":     "true",
            "disableProtocols":  "sslv2,sslv3",
            "preferServerCiphers": "true"
          },
          "client": {
            "caConfig":        "/etc/clickhouse-server/certs/ca.crt",
            "verificationMode": "relaxed",
            "loadDefaultCAFile": "false",
            "cacheSessions":     "true",
            "disableProtocols":  "sslv2,sslv3",
            "preferServerCiphers": "true"
          }
        },
        "remote_servers": {
          "global": {
            "secret": "${CLUSTER_SECRET}",
            "shard": [
              {"name": "FRA", "replica": {"host": "${fra_host}", "port": ${fra_port}, "secure": 1}},
              {"name": "MUC", "replica": {"host": "${muc_host}", "port": ${muc_port}, "secure": 1}},
              {"name": "HAM", "replica": {"host": "${ham_host}", "port": ${ham_port}, "secure": 1}}
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

patch_tls_cr fra "$FRA_CTX"
patch_tls_cr muc "$MUC_CTX"
patch_tls_cr ham "$HAM_CTX"

# ── Step 6: Wait for CH pods to restart with new config ───────────────────────

log "Waiting for CH pods to restart"
for entry in "fra:$FRA_CTX" "muc:$MUC_CTX" "ham:$HAM_CTX"; do
    dc="${entry%%:*}"; ctx="${entry##*:}"
    kubectl wait pod --context "$ctx" -n "$dc" \
        -l "clickhouse.com/role=clickhouse-server" \
        --for=condition=Ready --timeout=120s 2>&1 | tail -1
done

# ── Step 8: Handle stale Keeper digest (no PVCs — restart dance) ──────────────
# After a CH pod restarts with empty ephemeral storage, the operator's
# DatabaseSync fails because Keeper holds the old replica digest.
# Fix: restart both Keeper and CH so both start fresh.

log "Checking for stale Keeper state"
FRA_POD=$(kubectl get pods --context "$FRA_CTX" -n fra \
    -l "clickhouse.com/role=clickhouse-server" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

DB_OK=$(kubectl exec --context "$FRA_CTX" -n fra "$FRA_POD" -- \
    clickhouse client --port 9001 --query "SHOW DATABASES" 2>/dev/null | grep -c "^default$" || true)

if [ "$DB_OK" -lt 1 ]; then
    info "Default database missing — restarting Keeper + CH to clear stale digest"
    for entry in "fra:$FRA_CTX" "muc:$MUC_CTX" "ham:$HAM_CTX"; do
        dc="${entry%%:*}"; ctx="${entry##*:}"
        kubectl delete pod "${dc}-keeper-0-0" "${dc}-clickhouse-0-0-0" \
            --context "$ctx" -n "$dc" --grace-period=5 2>/dev/null || true
    done
    for entry in "fra:$FRA_CTX" "muc:$MUC_CTX" "ham:$HAM_CTX"; do
        dc="${entry%%:*}"; ctx="${entry##*:}"
        kubectl wait pod --context "$ctx" -n "$dc" \
            -l "clickhouse.com/role=clickhouse-keeper" \
            --for=condition=Ready --timeout=120s 2>&1 | tail -1
        kubectl wait pod --context "$ctx" -n "$dc" \
            -l "clickhouse.com/role=clickhouse-server" \
            --for=condition=Ready --timeout=120s 2>&1 | tail -1
    done
    info "Waiting 25s for operator DatabaseSync..."
    sleep 25
else
    info "Default database present, no restart needed"
fi

# ── Step 9: Reapply schemas (lost after pod restart) ─────────────────────────

log "Reapplying schemas"
bash "$SCRIPT_DIR/apply-schemas.sh"

# ── Step 10: Verify TLS ───────────────────────────────────────────────────────

log "Verifying TLS"

verify_tls() {
    local dc="$1" ctx="$2"
    local pod
    pod=$(kubectl get pods --context "$ctx" -n "$dc" \
        -l "clickhouse.com/role=clickhouse-server" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    # Confirm tcp_port_secure (9440) is accepting TLS connections.
    # clickhouse client inside the pod doesn't know our custom CA, so we use
    # --accept-invalid-certificate (skips cert chain validation for the CLI
    # only — CH server-to-server TLS still validates via openSSL.client.caConfig).
    local tls_ok
    tls_ok=$(kubectl exec --context "$ctx" -n "$dc" "$pod" -- \
        clickhouse client --host 127.0.0.1 --port 9440 --secure \
        --accept-invalid-certificate \
        --query "SELECT 'ok'" 2>/dev/null || echo "fail")

    # Confirm cross-DC federation is using TLS (errors_count=0 means connections succeed)
    local remote_errors=""
    remote_errors=$(kubectl exec --context "$ctx" -n "$dc" "$pod" -- \
        clickhouse client --port 9001 \
        --query "SELECT sum(errors_count) FROM system.clusters WHERE cluster='global' AND is_local=0" 2>/dev/null || echo "?")

    if [ "$dc" = "fra" ]; then
        local remote_shards
        remote_shards=$(kubectl exec --context "$ctx" -n "$dc" "$pod" -- \
            clickhouse client --port 9001 \
            --query "SELECT count() FROM system.clusters WHERE cluster='global' AND is_local=0" 2>/dev/null || echo "?")
        info "$dc: tls=$tls_ok  remote federated shards=$remote_shards (expect 2)  remote_errors=$remote_errors"
    else
        info "$dc: tls=$tls_ok  remote_errors=$remote_errors"
    fi
}

verify_tls fra "$FRA_CTX"
verify_tls muc "$MUC_CTX"
verify_tls ham "$HAM_CTX"

# Quick functional check: cross-DC query from FRA
FRA_POD=$(kubectl get pods --context "$FRA_CTX" -n fra \
    -l "clickhouse.com/role=clickhouse-server" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
bash scripts/verify.sh 2>&1 | grep -E "▶|PASS|FAIL|row_count|count" || true

log "TLS setup complete"
info "Secure TCP port : 9440 (inside pods)"
info "NodePorts (cross-DC) : FRA=30941  MUC=30942  HAM=30943"
info "Host access (TLS):"
info "  FRA: clickhouse client --host localhost --port 9841 --secure"
info "  MUC: clickhouse client --host localhost --port 9842 --secure"
info "  HAM: clickhouse client --host localhost --port 9843 --secure"
info "Certs: $CERTS_DIR/"
