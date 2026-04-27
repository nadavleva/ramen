#!/bin/bash

# SPDX-FileCopyrightText: The RamenDR authors
# SPDX-License-Identifier: Apache-2.0

# Script to clean up old replicated RBD images from both CSI replication clusters
# Removes error-state images (any name) and CSI volumes (csi-vol-*) from replicapool on both dr1 and dr2
#
# Usage:
#   ./cleanup-replicated-images.sh           # Full cleanup: delete all images
#   ./cleanup-replicated-images.sh --error-state-only  # Only fix error/unknown state (keeps in-use images)

set -e

POOL_NAME="replicapool"
ERROR_STATE_ONLY=false
KUBECTL_TIMEOUT=30  # timeout in seconds for kubectl exec commands
[[ "${1:-}" == "--error-state-only" ]] && ERROR_STATE_ONLY=true

# Wrapper for kubectl exec with timeout
kubectl_exec_with_timeout() {
    local cluster=$1
    shift
    local timeout=${KUBECTL_TIMEOUT}s
    
    # Use timeout command to prevent hanging indefinitely
    timeout $timeout kubectl exec -n rook-ceph --context=$cluster "$@" 2>/dev/null || {
        local exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
            echo "    Warning: kubectl exec timed out after ${KUBECTL_TIMEOUT}s on $cluster" >&2
            return 1
        fi
        return 0  # Continue on other errors (e.g., command not found)
    }
}

cleanup_cluster_images() {
    local cluster=$1
    echo "Cleaning replicated images on $cluster..."
    
    # Check if cluster is accessible and rook-ceph-tools pod is running
    if ! kubectl --context=$cluster get pods -n rook-ceph 2>/dev/null | grep -q rook-ceph-tools; then
        echo "  Warning: Cannot access rook-ceph-tools on $cluster, skipping cleanup"
        return 0
    fi
    
    # Check if the pod is actually in Running state
    local pod_status=$(kubectl --context=$cluster get pod -n rook-ceph -l app=rook-ceph-tools \
        -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
    if [[ "$pod_status" != "Running" ]]; then
        echo "  Warning: rook-ceph-tools pod is in $pod_status state on $cluster, skipping cleanup"
        return 0
    fi

    # Get list of all images in pool (replicapool is used for CSI replication - all images are cleanup targets)
    local images=$(kubectl_exec_with_timeout "$cluster" deploy/rook-ceph-tools -- \
        rbd ls $POOL_NAME || true)
    
    if [[ -z "$images" ]]; then
        echo "  No images found on $cluster (pool may be empty)"
    fi

    # Check for images in error or unknown state and handle them first
    # Unknown state blocks mirroring health (image_health: WARNING); error state needs force cleanup
    # Parse rbd mirror pool status --verbose: capture image names before "state:.*error" or "state:.*unknown"
    echo "    Checking for images in error or unknown state..."
    local problematic_images=$(kubectl_exec_with_timeout "$cluster" deploy/rook-ceph-tools -- \
        rbd mirror pool status $POOL_NAME --verbose | \
        awk '/^[^[:space:]]+:$/ {name=$0; gsub(/:$/, "", name); gsub(/^[[:space:]]+/, "", name); next}
             /state:.*(error|unknown)/ {if (name != "") {print name; name=""}}' || true)

    if [[ -n "$problematic_images" ]]; then
        echo "    Found $(echo "$problematic_images" | wc -l) image(s) in error/unknown state, forcing cleanup..."
        for img in $problematic_images; do
            img=$(echo "$img" | tr -d '[:space:]')
            [[ -z "$img" ]] && continue
            echo "      Force disabling mirroring and removing image: $img"
            kubectl_exec_with_timeout "$cluster" deploy/rook-ceph-tools -- \
                rbd mirror image disable --force $POOL_NAME/$img || true
            # Wait a moment for mirroring to fully stop
            sleep 2
            kubectl_exec_with_timeout "$cluster" deploy/rook-ceph-tools -- \
                rbd rm $POOL_NAME/$img || true
        done
    fi

    # Refresh image list after error cleanup - get ALL remaining images
    images=$(kubectl_exec_with_timeout "$cluster" deploy/rook-ceph-tools -- \
        rbd ls $POOL_NAME || true)
    
    if [[ -z "$images" ]]; then
        echo "  All images cleaned up during error state handling"
        return 0
    fi

    if [[ "$ERROR_STATE_ONLY" == "true" ]]; then
        echo "  (--error-state-only: skipping full cleanup, $(echo "$images" | wc -l) image(s) remain)"
        return 0
    fi

    echo "  Found $(echo "$images" | wc -l) remaining image(s) to clean up on $cluster"

    # First disable mirroring for all remaining images
    # Replica/secondary images require --force to disable (error: "mirrored image is not primary, add force option")
    for img in $images; do
        echo "    Disabling mirroring for $img on $cluster"
        kubectl_exec_with_timeout "$cluster" deploy/rook-ceph-tools -- \
            rbd mirror image disable --force $POOL_NAME/$img || true
    done

    # Wait for mirroring to fully stop before deletion
    sleep 3

    # Then delete all remaining images (including snapshots)
    for img in $images; do
        echo "    Cleaning up snapshots for $img on $cluster"
        # Clean up snapshots first
        local snapshots=$(kubectl_exec_with_timeout "$cluster" deploy/rook-ceph-tools -- \
            rbd snap ls $POOL_NAME/$img --format=json | jq -r '.[].name' 2>/dev/null || true)
        for snap in $snapshots; do
            kubectl_exec_with_timeout "$cluster" deploy/rook-ceph-tools -- \
                rbd snap rm $POOL_NAME/$img@$snap || true
        done
        
        echo "    Deleting $img from $cluster"
        kubectl_exec_with_timeout "$cluster" deploy/rook-ceph-tools -- \
            rbd rm $POOL_NAME/$img || true
    done

    echo "  Cleanup completed on $cluster"
    
    # Verify cleanup
    local remaining=$(kubectl_exec_with_timeout "$cluster" deploy/rook-ceph-tools -- \
        rbd ls $POOL_NAME || true)
    if [[ -n "$remaining" ]]; then
        echo "  Warning: Some images may still remain on $cluster:"
        echo "$remaining"
    else
        echo "  ✓ All images successfully removed from $cluster"
    fi
}

main() {
    echo "Starting cleanup of old replicated images from both clusters..."
    
    # Clean up dr1 first (secondary replicas)
    cleanup_cluster_images "dr1"
    
    # Clean up dr2 (primary images)  
    cleanup_cluster_images "dr2"
    
    echo "Image cleanup completed on both clusters."
}

# Execute main function
main "$@"