#!/usr/bin/env bash
# Deletes all three kind clusters of the design-b hierarchical federation demo.

set -euo pipefail

if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    : # docker is default
elif command -v podman &>/dev/null && podman info &>/dev/null 2>&1; then
    export KIND_EXPERIMENTAL_PROVIDER=podman
else
    echo "WARNING: no container runtime detected; attempting kind delete anyway"
fi

for c in tcaas-a tcaas-b global; do
    cluster="clickhouse-hierarchical-federation-demo-${c}"
    echo "Deleting kind cluster '$cluster' ..."
    kind delete cluster --name "$cluster" 2>/dev/null || echo "  (not found, skipping)"
done

echo "Done."
