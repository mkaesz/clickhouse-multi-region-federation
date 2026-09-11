#!/usr/bin/env bash
# Deletes all three kind clusters for the multi-region federation demo.
# Run from anywhere: bash demo/teardown.sh

set -euo pipefail

if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    : # docker is default
elif command -v podman &>/dev/null && podman info &>/dev/null 2>&1; then
    export KIND_EXPERIMENTAL_PROVIDER=podman
else
    echo "WARNING: no container runtime detected; attempting kind delete anyway"
fi

for dc in fra muc ham; do
    cluster="clickhouse-multi-region-federation-demo-${dc}"
    echo "Deleting kind cluster '$cluster' ..."
    kind delete cluster --name "$cluster" 2>/dev/null || echo "  (not found, skipping)"
done

echo "Done."
