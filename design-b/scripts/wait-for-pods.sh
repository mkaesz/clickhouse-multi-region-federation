#!/usr/bin/env bash
# Usage: wait-for-pods.sh <kube-context> <namespace> <label-selector> <expected-count>
# Waits until expected-count pods matching the selector are Running and Ready.

set -euo pipefail

info() { echo "   $*"; }

CTX="$1"
NS="$2"
SELECTOR="$3"
EXPECTED="${4:-1}"
TIMEOUT=300
INTERVAL=5
ELAPSED=0

info "Waiting for $EXPECTED pod(s) [ctx=$CTX ns=$NS selector=$SELECTOR] ..."

while true; do
    READY=$(kubectl get pods --context "$CTX" -n "$NS" -l "$SELECTOR" \
        --field-selector=status.phase=Running \
        -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{.ready}{"\n"}{end}{end}' 2>/dev/null \
        | grep -c "^true$" || true)

    if [ "$READY" -ge "$EXPECTED" ]; then
        info "Ready ($READY/$EXPECTED)"
        exit 0
    fi

    if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
        echo "ERROR: Timed out after ${TIMEOUT}s waiting for [$SELECTOR] in $NS"
        kubectl get pods --context "$CTX" -n "$NS" -l "$SELECTOR" 2>/dev/null || true
        local_pod=$(kubectl get pods --context "$CTX" -n "$NS" -l "$SELECTOR" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        if [ -n "$local_pod" ]; then
            kubectl logs --context "$CTX" -n "$NS" "$local_pod" --tail=20 2>/dev/null || true
        fi
        exit 1
    fi

    info "... $READY/$EXPECTED ready (${ELAPSED}s elapsed)"
    sleep "$INTERVAL"
    ELAPSED=$((ELAPSED + INTERVAL))
done
