#!/bin/bash
# SPDX-FileCopyrightText: The RamenDR authors
# SPDX-License-Identifier: Apache-2.0

# Start existing CSI Replication clusters.
# Run from project root. Requires venv and minikube profiles dr1, dr2.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# Track total execution time
START_TIME=$(date +%s)

echo "Starting CSI replication clusters..."

# Check if clusters exist (running or stopped) by looking for minikube profiles
if ! minikube profile list 2>/dev/null | grep -q "dr1" || \
   ! minikube profile list 2>/dev/null | grep -q "dr2"; then
    echo "⚠️  Clusters not found. Run 'make setup-csi-replication' first."
    exit 1
fi

cd test && source ../venv && drenv start envs/rook.yaml
cd - >/dev/null

echo "Waiting for basic cluster readiness..."
kubectl --context=dr1 wait --for=condition=Ready nodes --all --timeout=300s
kubectl --context=dr2 wait --for=condition=Ready nodes --all --timeout=300s

echo "Waiting for CSI components to be deployed by Rook..."
echo "  Waiting for CSI deployments on dr1..."
kubectl --context=dr1 wait --for=condition=available deployment/csi-rbdplugin-provisioner -n rook-ceph --timeout=300s || true
kubectl --context=dr1 wait --for=condition=available deployment/csi-cephfsplugin-provisioner -n rook-ceph --timeout=300s || true
echo "  Waiting for CSI deployments on dr2..."
kubectl --context=dr2 wait --for=condition=available deployment/csi-rbdplugin-provisioner -n rook-ceph --timeout=300s || true
kubectl --context=dr2 wait --for=condition=available deployment/csi-cephfsplugin-provisioner -n rook-ceph --timeout=300s || true

echo "Applying post-start configuration fixes..."
./scripts/setup-csi-storage-resources.sh

echo "Applying CSI Addons fixes (versions + TLS) for VolumeReplication connectivity..."
./scripts/fix-csi-addons-versions.sh
./scripts/fix-csi-addons-tls.sh

# Calculate total elapsed time
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
MINUTES=$((ELAPSED / 60))
SECONDS=$((ELAPSED % 60))

echo "✅ CSI replication clusters started and configured successfully in ${MINUTES}m ${SECONDS}s"
