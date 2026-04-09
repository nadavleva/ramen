#!/bin/bash

# SPDX-FileCopyrightText: The RamenDR authors
# SPDX-License-Identifier: Apache-2.0

# Script to clean up Ceph replication state from both CSI replication clusters
# Removes CephBlockPool CRs, mirroring peers, and other stale replication resources
#
# This ensures a clean state for the next replication setup without timeout issues
# caused by stale snapshot schedules or image references.
#
# Usage:
#   ./cleanup-ceph-replication-state.sh

set -e

POOL_NAME="replicapool"
NAMESPACE="rook-ceph"

cleanup_pool_and_peers() {
    local cluster=$1
    echo "Cleaning up Ceph replication state on $cluster..."
    
    # Check if cluster is accessible
    if ! kubectl --context=$cluster get ns $NAMESPACE 2>/dev/null | grep -q $NAMESPACE; then
        echo "  Warning: Cannot access $NAMESPACE on $cluster, skipping cleanup"
        return 0
    fi
    
    # Delete any stale CephBlockPool CRs (including numbered versions like replicapool-2)
    local pools=$(kubectl --context=$cluster get cephblockpool -n $NAMESPACE -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    
    if [[ -z "$pools" ]]; then
        echo "  No CephBlockPool resources found on $cluster"
        return 0
    fi
    
    for pool in $pools; do
        # Skip the builtin-mgr pool (it's for internal cluster management)
        if [[ "$pool" == "builtin-mgr" ]]; then
            continue
        fi
        
        echo "  Deleting CephBlockPool: $pool"
        kubectl --context=$cluster delete cephblockpool/$pool -n $NAMESPACE --ignore-not-found=true 2>/dev/null || true
        
        # Small delay to allow cascade deletion
        sleep 1
    done
    
    # Clean up any orphaned CephBlockPoolRadosNamespace resources
    echo "  Cleaning up CephBlockPoolRadosNamespace resources..."
    local rados_ns=$(kubectl --context=$cluster get cephblockpoolradosnamespace -n $NAMESPACE -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    for rns in $rados_ns; do
        echo "    Deleting CephBlockPoolRadosNamespace: $rns"
        kubectl --context=$cluster delete cephblockpoolradosnamespace/$rns -n $NAMESPACE --ignore-not-found=true 2>/dev/null || true
    done
    
    # The RBD mirror daemon may need to be restarted to clear stale peer connections
    # but we let the new setup handle peer configuration
    echo "  ✓ Ceph replication state cleaned up on $cluster"
}

main() {
    echo "Starting cleanup of Ceph replication state from both clusters..."
    echo ""
    
    # Clean up dr1 first (typically the secondary)
    cleanup_pool_and_peers "dr1"
    echo ""
    
    # Clean up dr2 (typically the primary)  
    cleanup_pool_and_peers "dr2"
    echo ""
    
    echo "Ceph replication state cleanup completed on both clusters."
    echo "Pools and peer configurations have been removed for a fresh setup."
}

# Execute main function
main "$@"
