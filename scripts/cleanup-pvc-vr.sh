#!/bin/bash
# SPDX-FileCopyrightText: The RamenDR authors
# SPDX-License-Identifier: Apache-2.0

# Clean all VolumeReplications, VolumeGroupReplications, VolumeGroupReplicationContents, VolumeGroups, VolumeGroupContents, and PVCs
# from CSI replication clusters for fresh testing.
# Removes finalizers before deletion to avoid resources stuck in Terminating state.

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Centralized cleanup function that can be called by other scripts
# Usage: cleanup_csi_resources <context> [--quiet]
cleanup_csi_resources() {
    local context="$1"
    local quiet="${2:-false}"
    
    if ! kubectl --context="$context" cluster-info &>/dev/null; then
        [[ "$quiet" != "--quiet" ]] && log_warning "Context $context not accessible, skipping"
        return 1
    fi

    [[ "$quiet" != "--quiet" ]] && log_info "=== Cleaning $context ==="

    # 1. Remove finalizers from VolumeReplications first
    local vr_count=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local ns="${line%%/*}"
        local name="${line##*/}"
        kubectl --context="$context" -n "$ns" patch volumereplication "$name" --type=merge -p='{"metadata":{"finalizers":[]}}' 2>/dev/null || true
        vr_count=$((vr_count + 1))
    done < <(kubectl --context="$context" get volumereplication -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

    [[ "$quiet" != "--quiet" ]] && [ "$vr_count" -gt 0 ] && log_info "  Removed finalizers from $vr_count VolumeReplication(s)"

    # 2. Delete all VolumeReplications
    kubectl --context="$context" delete volumereplication -A --all --ignore-not-found --wait=false 2>/dev/null || true
    [[ "$quiet" != "--quiet" ]] && log_info "  Deleted VolumeReplications"

    # 3. Remove finalizers from VolumeGroupReplications first
    local vgr_count=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local ns="${line%%/*}"
        local name="${line##*/}"
        kubectl --context="$context" -n "$ns" patch volumegroupreplication "$name" --type=merge -p='{"metadata":{"finalizers":[]}}' 2>/dev/null || true
        vgr_count=$((vgr_count + 1))
    done < <(kubectl --context="$context" get volumegroupreplication -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

    [[ "$quiet" != "--quiet" ]] && [ "$vgr_count" -gt 0 ] && log_info "  Removed finalizers from $vgr_count VolumeGroupReplication(s)"

    # 4. Delete all VolumeGroupReplications
    kubectl --context="$context" delete volumegroupreplication -A --all --ignore-not-found --wait=false 2>/dev/null || true
    [[ "$quiet" != "--quiet" ]] && log_info "  Deleted VolumeGroupReplications"

    # 5. Remove finalizers from VolumeGroupReplicationContents first
    local vgrc_count=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local ns="${line%%/*}"
        local name="${line##*/}"
        kubectl --context="$context" -n "$ns" patch volumegroupreplicationcontent "$name" --type=merge -p='{"metadata":{"finalizers":[]}}' 2>/dev/null || true
        vgrc_count=$((vgrc_count + 1))
    done < <(kubectl --context="$context" get volumegroupreplicationcontent -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

    [[ "$quiet" != "--quiet" ]] && [ "$vgrc_count" -gt 0 ] && log_info "  Removed finalizers from $vgrc_count VolumeGroupReplicationContent(s)"

    # 6. Delete all VolumeGroupReplicationContents
    kubectl --context="$context" delete volumegroupreplicationcontent -A --all --ignore-not-found --wait=false 2>/dev/null || true
    [[ "$quiet" != "--quiet" ]] && log_info "  Deleted VolumeGroupReplicationContents"

    # 7. Remove finalizers from VolumeGroups first
    local vg_count=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local ns="${line%%/*}"
        local name="${line##*/}"
        kubectl --context="$context" -n "$ns" patch volumegroup "$name" --type=merge -p='{"metadata":{"finalizers":[]}}' 2>/dev/null || true
        vg_count=$((vg_count + 1))
    done < <(kubectl --context="$context" get volumegroup -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

    [[ "$quiet" != "--quiet" ]] && [ "$vg_count" -gt 0 ] && log_info "  Removed finalizers from $vg_count VolumeGroup(s)"

    # 8. Delete all VolumeGroups
    kubectl --context="$context" delete volumegroup -A --all --ignore-not-found --wait=false 2>/dev/null || true
    [[ "$quiet" != "--quiet" ]] && log_info "  Deleted VolumeGroups"

    # 9. Remove finalizers from VolumeGroupContents first (cluster-scoped)
    local vgc_count=0
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        kubectl --context="$context" patch volumegroupcontent "$name" --type=merge -p='{"metadata":{"finalizers":[]}}' 2>/dev/null || true
        vgc_count=$((vgc_count + 1))
    done < <(kubectl --context="$context" get volumegroupcontent -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

    [[ "$quiet" != "--quiet" ]] && [ "$vgc_count" -gt 0 ] && log_info "  Removed finalizers from $vgc_count VolumeGroupContent(s)"

    # 10. Delete all VolumeGroupContents
    kubectl --context="$context" delete volumegroupcontent --all --ignore-not-found --wait=false 2>/dev/null || true
    [[ "$quiet" != "--quiet" ]] && log_info "  Deleted VolumeGroupContents"

    # 11. Remove finalizers from PVCs first
    local pvc_count=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local ns="${line%%/*}"
        local name="${line##*/}"
        kubectl --context="$context" -n "$ns" patch pvc "$name" --type=merge -p='{"metadata":{"finalizers":[]}}' 2>/dev/null || true
        pvc_count=$((pvc_count + 1))
    done < <(kubectl --context="$context" get pvc -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

    [[ "$quiet" != "--quiet" ]] && [ "$pvc_count" -gt 0 ] && log_info "  Removed finalizers from $pvc_count PVC(s)"

    # 12. Delete all PVCs
    kubectl --context="$context" delete pvc -A --all --ignore-not-found --wait=false 2>/dev/null || true
    [[ "$quiet" != "--quiet" ]] && log_info "  Deleted PVCs"

    [[ "$quiet" != "--quiet" ]] && log_success "  $context cleanup complete"
    return 0
}

# If script is being sourced, don't run main logic
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    return 0 2>/dev/null || true
    exit 0
fi

# Main script logic (only runs when script is executed directly)
main() {
    # Parse args: contexts and -y/--force
    local CONTEXTS=""
    local FORCE=false
    for arg in "$@"; do
        case "$arg" in
            -y|--yes|--force) FORCE=true ;;
            *) CONTEXTS="$CONTEXTS $arg" ;;
        esac
    done
    CONTEXTS="${CONTEXTS:-dr1 dr2}"
    CONTEXTS=$(echo "$CONTEXTS" | xargs)

    log_info "Cleaning all VolumeReplications, VolumeGroupReplications, VolumeGroupReplicationContents, VolumeGroups, VolumeGroupContents, and PVCs for fresh testing"
    log_info "Target contexts: $CONTEXTS"
    echo ""

    # Confirmation unless --force (skip prompt when stdin is not a TTY)
    if [ "$FORCE" != "true" ] && [ -t 0 ]; then
        log_warning "This will delete ALL VolumeReplications, VolumeGroupReplications, VolumeGroupReplicationContents, VolumeGroups, VolumeGroupContents, and PVCs in ALL namespaces on: $CONTEXTS"
        read -p "Continue? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Cleanup cancelled."
            exit 0
        fi
    fi

    for context in $CONTEXTS; do
        cleanup_csi_resources "$context"
    done

    echo ""
    log_success "VolumeReplication, VolumeGroupReplication, VolumeGroupReplicationContent, VolumeGroup, VolumeGroupContent, and PVC cleanup complete. Ready for fresh testing."
}

# Run main function with all arguments
main "$@"
