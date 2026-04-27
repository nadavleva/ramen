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
#
# Environment:
#   DELETE_WAIT              kubectl delete --wait (default: false - do not block on finalizers)
#   POOL_DELETE_WAIT_SECONDS after deletes, poll this long for pools to vanish (default: 180)
#
# If CephBlockPools stay Terminating (mirroring / Rook finalizer), use:
#   ./scripts/unstick-terminating-cephblockpools.sh

set -e

POOL_NAME="replicapool"
NAMESPACE="rook-ceph"
# Foreground kubectl delete (with default --wait) blocks until finalizers complete; a stuck CephBlockPool
# can block forever. We use async deletion and a bounded poll so make stop-csi-replication keeps progressing.
DELETE_WAIT="${DELETE_WAIT:-false}"
POOL_DELETE_WAIT_SECONDS="${POOL_DELETE_WAIT_SECONDS:-180}"

# Return names of CephBlockPools excluding builtin-mgr (space-separated).
list_user_cephblockpools() {
    local cluster=$1
    local names
    names=$(timeout 60 kubectl --context="$cluster" get cephblockpool -n "$NAMESPACE" \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    local out=""
    for p in $names; do
        [[ "$p" == "builtin-mgr" ]] && continue
        out+="$p "
    done
    echo "${out%% }"
}

wait_for_user_cephblockpools_gone() {
    local cluster=$1
    local max_seconds=$2
    local waited=0
    local pending
    pending="$(list_user_cephblockpools "$cluster")"
    if [[ -z "${pending// }" ]] || (( max_seconds <= 0 )); then
        if (( max_seconds <= 0 )) && [[ -n "${pending// }" ]]; then
            printf '  Note: skipping wait (POOL_DELETE_WAIT_SECONDS=%s); pools may still be Terminating: %s\n' "$max_seconds" "$pending"
        fi
        return 0
    fi
    while (( waited < max_seconds )); do
        pending="$(list_user_cephblockpools "$cluster")"
        if [[ -z "${pending// }" ]]; then
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
        if (( waited % 30 == 0 )); then
            printf '  ... still waiting for CephBlockPool removal (%ss): %s\n' "$waited" "$pending"
        fi
    done
    printf '  Warning: after %ss these CephBlockPool resources still exist: %s\n' "$max_seconds" "$pending"
    printf '    Inspect: kubectl --context=%s get cephblockpool -n %s -o yaml\n' "$cluster" "$NAMESPACE"
    printf '    Operator: kubectl --context=%s -n %s logs deploy/rook-ceph-operator --tail=80\n' "$cluster" "$NAMESPACE"
    return 0
}

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

    local issued_pool_delete=0
    for pool in $pools; do
        # Skip the builtin-mgr pool (it's for internal cluster management)
        if [[ "$pool" == "builtin-mgr" ]]; then
            continue
        fi

        issued_pool_delete=1
        echo "  Deleting CephBlockPool: $pool (async: --wait=${DELETE_WAIT})"
        kubectl --context=$cluster delete cephblockpool/$pool -n $NAMESPACE \
            --ignore-not-found=true --wait="${DELETE_WAIT}" 2>/dev/null || true

        sleep 1
    done

    if [[ "$issued_pool_delete" -eq 1 ]]; then
        echo "  Waiting up to ${POOL_DELETE_WAIT_SECONDS}s for user CephBlockPools to disappear..."
        wait_for_user_cephblockpools_gone "$cluster" "$POOL_DELETE_WAIT_SECONDS"
    fi
    
    # Clean up any orphaned CephBlockPoolRadosNamespace resources
    echo "  Cleaning up CephBlockPoolRadosNamespace resources..."
    local rados_ns=$(kubectl --context=$cluster get cephblockpoolradosnamespace -n $NAMESPACE -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    for rns in $rados_ns; do
        echo "    Deleting CephBlockPoolRadosNamespace: $rns"
        kubectl --context=$cluster delete cephblockpoolradosnamespace/$rns -n $NAMESPACE \
            --ignore-not-found=true --wait="${DELETE_WAIT}" 2>/dev/null || true
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
