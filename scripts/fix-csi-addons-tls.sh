#!/bin/bash
# SPDX-FileCopyrightText: The RamenDR authors
# SPDX-License-Identifier: Apache-2.0

# Script to apply TLS configuration fix to CSI Addons controllers and sidecars.
# Required for Ceph CSI sidecar compatibility (controller uses TLS by default,
# sidecars use plain gRPC - this mismatch causes handshake failures).
#
# All container patches use strategic merge and target by container NAME (not index)
# for robustness against ordering changes.

set -e

echo "Disabling TLS authentication in CSI Addons controllers and sidecars (required for Ceph CSI sidecar compatibility)..."
echo ""

# Helper: patch container by name using strategic merge (matches by name)
patch_container_by_name() {
    local context=$1
    local resource_type=$2
    local resource_name=$3
    local namespace=$4
    local container_name=$5
    local patch_json=$6
    kubectl --context="$context" patch "$resource_type" "$resource_name" -n "$namespace" \
        --type='strategic' -p="$patch_json" 2>/dev/null || true
}

for context in dr1 dr2; do
    echo "=== Fixing $context cluster ==="

    # --- CSI Addons Controller ---
    if kubectl --context=$context get deployment -n csi-addons-system csi-addons-controller-manager >/dev/null 2>&1; then
        kubectl --context=$context patch deployment -n csi-addons-system csi-addons-controller-manager \
            --type='strategic' \
            -p='{"spec":{"template":{"spec":{"containers":[{"name":"manager","args":["--enable-auth=false"]}]}}}}' 2>/dev/null || true
        kubectl --context=$context set env deployment/csi-addons-controller-manager -n csi-addons-system NODE_ID=$context --containers=manager 2>/dev/null || true
        echo "  ✓ TLS fix and NODE_ID applied to CSI Addons controller"
    else
        echo "  ⚠ CSI Addons controller not found"
    fi

    # --- CSI Sidecar TLS (csi-addons containers only) ---
    # Include leader-election args so we don't overwrite/strip them (required for VGR "no leader" fix)
    # Staging path matches Rook default; leader-election uses shorter durations for faster recovery
    # IMPORTANT: csi-addons (kubernetes-csi-addons sidecar) auto-detects controller capability from driver
    # Do NOT include -controllerserver flag here - that flag doesn't exist for csi-addons-sidecar
    CSI_ADDONS_PATCH='{"spec":{"template":{"spec":{"containers":[{"name":"csi-addons","args":["--node-id=$(NODE_ID)","--csi-addons-address=$(CSIADDONS_ENDPOINT)","--controller-port=9070","--pod=$(POD_NAME)","--namespace=$(POD_NAMESPACE)","--pod-uid=$(POD_UID)","--stagingpath=/var/lib/kubelet/plugins/kubernetes.io/csi/","--leader-election-namespace=$(POD_NAMESPACE)","--leader-election-lease-duration=15s","--leader-election-renew-deadline=10s","--leader-election-retry-period=2s"]}]}}}}'
    echo "  Fixing CSI sidecar TLS (preserving leader-election args)..."

    # csi-rbdplugin-provisioner: csi-addons, csi-rbdplugin, log-collector (by name)
    if kubectl --context=$context get deployment csi-rbdplugin-provisioner -n rook-ceph &>/dev/null; then
        # CRITICAL: Ensure csi-rbdplugin runs with -controllerserver=true for NetworkFence capability
        # This is required for the sidecar to advertise CONTROLLER_SERVICE and NetworkFence capabilities
        patch_container_by_name "$context" deployment csi-rbdplugin-provisioner rook-ceph csi-rbdplugin \
            '{"spec":{"template":{"spec":{"containers":[{"name":"csi-rbdplugin","args":["--nodeid=$(NODE_ID)","--type=rbd","--controllerserver=true","--endpoint=unix:///csi/csi-provisioner.sock","--csi-addons-endpoint=$(CSIADDONS_ENDPOINT)","--v=0","--drivername=rook-ceph.rbd.csi.ceph.com","--pidlimit=-1"]}]}}}}'
        
        # Also restore if it was wrongly patched (alpine image or sleep args)
        rbdplugin_img=$(kubectl --context=$context get deployment csi-rbdplugin-provisioner -n rook-ceph -o json 2>/dev/null | \
            jq -r '.spec.template.spec.containers[] | select(.name=="csi-rbdplugin") | .image' 2>/dev/null || true)
        rbdplugin_args=$(kubectl --context=$context get deployment csi-rbdplugin-provisioner -n rook-ceph -o json 2>/dev/null | \
            jq -r '.spec.template.spec.containers[] | select(.name=="csi-rbdplugin") | .args | join(" ")' 2>/dev/null || true)
        if echo "$rbdplugin_img" | grep -q "alpine" || echo "$rbdplugin_args" | grep -q "while true"; then
            patch_container_by_name "$context" deployment csi-rbdplugin-provisioner rook-ceph csi-rbdplugin \
                '{"spec":{"template":{"spec":{"containers":[{"name":"csi-rbdplugin","image":"quay.io/cephcsi/cephcsi:v3.15.0","args":["--nodeid=$(NODE_ID)","--type=rbd","--controllerserver=true","--endpoint=unix:///csi/csi-provisioner.sock","--csi-addons-endpoint=$(CSIADDONS_ENDPOINT)","--v=0","--drivername=rook-ceph.rbd.csi.ceph.com","--pidlimit=-1"]}]}}}}'
            echo "  ✓ Restored csi-rbdplugin-provisioner csi-rbdplugin (was wrongly patched)"
        fi
        patch_container_by_name "$context" deployment csi-rbdplugin-provisioner rook-ceph csi-addons "$CSI_ADDONS_PATCH"
    fi

    # csi-cephfsplugin-provisioner: csi-addons, csi-cephfsplugin, csi-provisioner (by name)
    if kubectl --context=$context get deployment csi-cephfsplugin-provisioner -n rook-ceph &>/dev/null; then
        # CRITICAL: Ensure csi-cephfsplugin runs with -controllerserver=true for NetworkFence capability
        patch_container_by_name "$context" deployment csi-cephfsplugin-provisioner rook-ceph csi-cephfsplugin \
            '{"spec":{"template":{"spec":{"containers":[{"name":"csi-cephfsplugin","args":["--nodeid=$(NODE_ID)","--type=cephfs","--controllerserver=true","--endpoint=unix:///csi/csi-provisioner.sock","--v=0","--drivername=rook-ceph.cephfs.csi.ceph.com","--pidlimit=-1","--csi-addons-endpoint=$(CSIADDONS_ENDPOINT)"]}]}}}}'
        
        prov_args=$(kubectl --context=$context get deployment csi-cephfsplugin-provisioner -n rook-ceph -o json 2>/dev/null | \
            jq -r '.spec.template.spec.containers[] | select(.name=="csi-provisioner") | .args | join(" ")' 2>/dev/null || true)
        if echo "$prov_args" | grep -q "listen-port"; then
            patch_container_by_name "$context" deployment csi-cephfsplugin-provisioner rook-ceph csi-provisioner \
                '{"spec":{"template":{"spec":{"containers":[{"name":"csi-provisioner","args":["--csi-address=$(ADDRESS)","--v=0","--timeout=2m30s","--retry-interval-start=500ms","--leader-election=true","--leader-election-namespace=rook-ceph","--leader-election-lease-duration=2m17s","--leader-election-renew-deadline=1m47s","--leader-election-retry-period=26s","--default-fstype=ext4","--extra-create-metadata=true","--prevent-volume-mode-conversion=true","--feature-gates=HonorPVReclaimPolicy=true","--feature-gates=CrossNamespaceVolumeDataSource=false","--feature-gates=Topology=false"]}]}}}}'
            echo "  ✓ Restored csi-cephfsplugin-provisioner csi-provisioner args (was wrongly patched)"
        fi
        patch_container_by_name "$context" deployment csi-cephfsplugin-provisioner rook-ceph csi-addons "$CSI_ADDONS_PATCH"
    fi

    # csi-rbdplugin daemonset: log-collector (by name)
    if kubectl --context=$context get daemonset csi-rbdplugin -n rook-ceph &>/dev/null; then
        if kubectl --context=$context get daemonset csi-rbdplugin -n rook-ceph -o json 2>/dev/null | jq -e '.spec.template.spec.containers[] | select(.name=="log-collector")' &>/dev/null; then
            patch_container_by_name "$context" daemonset csi-rbdplugin rook-ceph log-collector \
                '{"spec":{"template":{"spec":{"containers":[{"name":"log-collector","command":["sh","-c"],"args":["while true; do sleep 3600; done"]}]}}}}'
            echo "  ✓ Fixed csi-rbdplugin daemonset log-collector"
        fi
    fi

    # csi-cephfsplugin daemonset: log-collector (by name)
    if kubectl --context=$context get daemonset csi-cephfsplugin -n rook-ceph &>/dev/null; then
        if kubectl --context=$context get daemonset csi-cephfsplugin -n rook-ceph -o json 2>/dev/null | jq -e '.spec.template.spec.containers[] | select(.name=="log-collector")' &>/dev/null; then
            patch_container_by_name "$context" daemonset csi-cephfsplugin rook-ceph log-collector \
                '{"spec":{"template":{"spec":{"containers":[{"name":"log-collector","command":["sh","-c"],"args":["while true; do sleep 3600; done"]}]}}}}'
            echo "  ✓ Fixed csi-cephfsplugin daemonset log-collector"
        fi
    fi

    echo ""
done

# --- Clean up old CSIAddonsNode resources to force fresh capability probe ---
echo "Cleaning up old CSIAddonsNode resources to force fresh capability detection..."
for context in dr1 dr2; do
    if kubectl --context=$context get csiaddonsnode -A >/dev/null 2>&1; then
        kubectl --context=$context delete csiaddonsnode --all -A --ignore-not-found=true 2>/dev/null || true
    fi
done
sleep 5

# --- Wait for controller rollouts ---
echo "Waiting for CSI Addons controllers to restart..."
kubectl --context=dr1 rollout status deployment/csi-addons-controller-manager -n csi-addons-system --timeout=60s 2>/dev/null || true
kubectl --context=dr2 rollout status deployment/csi-addons-controller-manager -n csi-addons-system --timeout=60s 2>/dev/null || true

# --- Clean up CSIAddonsNode resources to force reconnection ---
echo "Cleaning up problematic CSIAddonsNode resources to force reconnection..."
for context in dr1 dr2; do
    if kubectl --context=$context get csiaddonsnode -n rook-ceph >/dev/null 2>&1; then
        kubectl --context=$context delete csiaddonsnode -n rook-ceph --all --ignore-not-found=true 2>/dev/null || true
    fi
done

# --- Restart CSI plugin pods ---
echo "Restarting CSI plugin pods to establish fresh connections..."
for context in dr1 dr2; do
    kubectl --context=$context delete pods -n rook-ceph -l app=csi-rbdplugin-provisioner --ignore-not-found=true 2>/dev/null || true
    kubectl --context=$context delete pods -n rook-ceph -l app=csi-cephfsplugin-provisioner --ignore-not-found=true 2>/dev/null || true
    kubectl --context=$context delete pods -n rook-ceph -l app=csi-cephfsplugin --ignore-not-found=true 2>/dev/null || true
    kubectl --context=$context delete pods -n rook-ceph -l app=csi-rbdplugin --ignore-not-found=true 2>/dev/null || true
done

# Wait for CSI provisioner pods to be ready (avoids FailedScheduling on single-node due to anti-affinity)
echo "Waiting for CSI plugin pods to be ready..."
for context in dr1 dr2; do
    kubectl --context=$context rollout status deployment/csi-rbdplugin-provisioner -n rook-ceph --timeout=180s 2>/dev/null || echo "  ⚠ csi-rbdplugin-provisioner rollout wait timed out on $context"
    kubectl --context=$context rollout status deployment/csi-cephfsplugin-provisioner -n rook-ceph --timeout=180s 2>/dev/null || echo "  ⚠ csi-cephfsplugin-provisioner rollout wait timed out on $context"
done

# --- Recreate CSIAddonsNode for provisioner pods to enable capability re-probe ---
echo "Creating CSIAddonsNode for provisioner pods to enable capability re-detection..."
for context in dr1 dr2; do
    # Get RBD provisioner pod name for CSIAddonsNode endpoint
    local prov_pod
    prov_pod=$(kubectl --context=$context -n rook-ceph get pods -l app=csi-rbdplugin-provisioner \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$prov_pod" ]; then
        # Use template file from test/yaml/objects for consistency across scripts
        CONTEXT=$context PROVISIONER_POD=$prov_pod envsubst < "$(dirname "$0")/../test/yaml/objects/csiaddonsnode-provisioner-rbd.yaml" | \
            kubectl --context=$context apply -f -
        echo "  ✓ CSIAddonsNode created for RBD provisioner pod ${prov_pod}"
    else
        echo "  ⚠ No RBD provisioner pod found — skipping CSIAddonsNode creation for $context"
    fi
done

echo ""
echo "✓ CSI Addons TLS configuration and NODE_ID fixes completed."
