#!/bin/bash
# SPDX-FileCopyrightText: The RamenDR authors
# SPDX-License-Identifier: Apache-2.0

# Reset CSI replication state without full setup.
# Use when clusters (dr1, dr2) already exist and are running.
# Fast subset: cleans test resources, re-applies storage + RBD mirroring config.
# ~2-5 min vs 20-30 min for full setup-csi-replication.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# Source the centralized cleanup function
source "$SCRIPT_DIR/cleanup-pvc-vr.sh"

echo "=== Reset CSI Replication State (fast) ==="
echo "Assumes dr1/dr2 clusters are running. Run 'make start-csi-replication' first if stopped."
echo ""

# Check clusters exist and are reachable
if ! kubectl --context=dr1 cluster-info &>/dev/null; then
    echo "❌ dr1 not reachable. Run 'make start-csi-replication' first."
    exit 1
fi
if ! kubectl --context=dr2 cluster-info &>/dev/null; then
    echo "❌ dr2 not reachable. Run 'make start-csi-replication' first."
    exit 1
fi
echo "✓ Clusters reachable"
echo ""

# 1. Clean test resources (VRs, VGRs, PVCs) using centralized cleanup function
echo "1. Cleaning test resources (VRs, VGRs, VGRCs, VGs, VGCs, PVCs)..."
for ctx in dr1 dr2; do
    cleanup_csi_resources "$ctx" --quiet
done
echo "✓ Test resources cleaned"
echo ""

# 1b. Delete all mirrored RBD images from replicapool on both clusters
echo "1b. Cleaning mirrored RBD images..."
./scripts/cleanup-replicated-images.sh || true
echo "✓ Mirrored images cleaned"
echo ""

# 1c. Delete VRCs/VGRClasses BEFORE setup-csi-storage-resources (spec.parameters are immutable)
echo "1c. Removing existing VRCs and VGRClasses (immutable params)..."
for ctx in dr1 dr2; do
    for vrc in vrc-1m vrc-2m vrc-5m rbd-volumereplicationclass rbd-volumereplicationclass-5m; do
        kubectl --context=$ctx delete volumereplicationclass "$vrc" --ignore-not-found=true 2>/dev/null || true
    done
    for vgrclass in vgrc-1m vgrc-2m vgrc-5m; do
        kubectl --context=$ctx delete volumegroupreplicationclass "$vgrclass" --ignore-not-found=true 2>/dev/null || true
    done
done
echo "✓ Cleared"
echo ""

# 2. Re-apply storage resources (VRCs, VGR CRDs, storage classes)
echo "2. Re-applying storage resources..."
./scripts/setup-csi-storage-resources.sh
echo ""

# 3. Re-apply RBD mirroring (vrc-1m, vgrc-1m, peer config)
echo "3. Re-applying RBD mirroring..."
./scripts/setup-rbd-mirroring.sh
echo ""

# 4. Re-apply CSI Addons fixes (ensures VR connectivity after group support changes)
echo "4. Re-applying CSI Addons fixes..."
./scripts/fix-csi-addons-versions.sh
./scripts/fix-csi-addons-tls.sh
echo ""

# 5. Wait for CSI Addons sidecar leader, then restart controller to force reconnection
# fix-csi-addons-tls deletes CSIAddonsNode and restarts pods; controller needs fresh connection to sidecars
echo "5. Waiting for CSI Addons sidecar leader (up to 45s)..."
for ctx in dr1 dr2; do
    for i in $(seq 1 9); do
        rbd_pod=$(kubectl --context=$ctx -n rook-ceph get pods -l app=csi-rbdplugin-provisioner -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        if [[ -n "$rbd_pod" ]] && kubectl --context=$ctx -n rook-ceph logs "$rbd_pod" -c csi-addons 2>/dev/null | grep -q "Obtained leader status"; then
            echo "  ✓ $ctx: leader ready"
            break
        fi
        [[ $i -eq 9 ]] && echo "  ⚠ $ctx: leader not ready (run 'make restart-csi-service' before VGR test)"
        sleep 5
    done
done
echo ""

# 5b. Restart CSI Addons controller to force reconnection to sidecars (avoids "no leader for ControllerService")
echo "5b. Restarting CSI Addons controller to establish connection to sidecars..."
for ctx in dr1 dr2; do
    kubectl --context=$ctx -n csi-addons-system rollout restart deployment/csi-addons-controller-manager 2>/dev/null || true
done
for ctx in dr1 dr2; do
    kubectl --context=$ctx -n csi-addons-system rollout status deployment/csi-addons-controller-manager --timeout=90s 2>/dev/null || echo "  ⚠ Controller rollout wait timed out on $ctx"
done
echo "  ✓ Controller restarted"
echo ""

echo "✅ CSI replication state reset complete (~2-5 min)"
echo ""
echo "Next: make test-csi-replication  # or make test-dr-flow, make test-csi-volumegroupreplication"
echo ""
