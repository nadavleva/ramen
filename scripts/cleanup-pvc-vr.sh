#!/bin/bash
# SPDX-FileCopyrightText: The RamenDR authors
# SPDX-License-Identifier: Apache-2.0

# Clean all VolumeReplications, VolumeGroupReplications, VolumeGroupReplicationContents, and PVCs
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

# Parse args: contexts and -y/--force
CONTEXTS=""
FORCE=false
for arg in "$@"; do
    case "$arg" in
        -y|--yes|--force) FORCE=true ;;
        *) CONTEXTS="$CONTEXTS $arg" ;;
    esac
done
CONTEXTS="${CONTEXTS:-dr1 dr2}"
CONTEXTS=$(echo "$CONTEXTS" | xargs)

log_info "Cleaning all VolumeReplications, VolumeGroupReplications, VolumeGroupReplicationContents, and PVCs for fresh testing"
log_info "Target contexts: $CONTEXTS"
echo ""

# Confirmation unless --force (skip prompt when stdin is not a TTY)
if [ "$FORCE" != "true" ] && [ -t 0 ]; then
    log_warning "This will delete ALL VolumeReplications, VolumeGroupReplications, VolumeGroupReplicationContents, and PVCs in ALL namespaces on: $CONTEXTS"
    read -p "Continue? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Cleanup cancelled."
        exit 0
    fi
fi

for context in $CONTEXTS; do
    if ! kubectl --context="$context" cluster-info &>/dev/null; then
        log_warning "Context $context not accessible, skipping"
        continue
    fi

    echo ""
    log_info "=== Cleaning $context ==="

    # 1. Remove finalizers from VolumeReplications first
    vr_count=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        ns="${line%%/*}"
        name="${line##*/}"
        kubectl --context="$context" -n "$ns" patch volumereplication "$name" --type=merge -p='{"metadata":{"finalizers":[]}}' 2>/dev/null || true
        vr_count=$((vr_count + 1))
    done < <(kubectl --context="$context" get volumereplication -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

    if [ "$vr_count" -gt 0 ]; then
        log_info "  Removed finalizers from $vr_count VolumeReplication(s)"
    fi

    # 2. Delete all VolumeReplications
    kubectl --context="$context" delete volumereplication -A --all --ignore-not-found --wait=false 2>/dev/null || true
    log_info "  Deleted VolumeReplications"

    # 3. Remove finalizers from VolumeGroupReplications first
    vgr_count=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        ns="${line%%/*}"
        name="${line##*/}"
        kubectl --context="$context" -n "$ns" patch volumegroupreplication "$name" --type=merge -p='{"metadata":{"finalizers":[]}}' 2>/dev/null || true
        vgr_count=$((vgr_count + 1))
    done < <(kubectl --context="$context" get volumegroupreplication -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

    if [ "$vgr_count" -gt 0 ]; then
        log_info "  Removed finalizers from $vgr_count VolumeGroupReplication(s)"
    fi

    # 4. Delete all VolumeGroupReplications
    kubectl --context="$context" delete volumegroupreplication -A --all --ignore-not-found --wait=false 2>/dev/null || true
    log_info "  Deleted VolumeGroupReplications"

    # 5. Remove finalizers from VolumeGroupReplicationContents first
    vgrc_count=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        ns="${line%%/*}"
        name="${line##*/}"
        kubectl --context="$context" -n "$ns" patch volumegroupreplicationcontent "$name" --type=merge -p='{"metadata":{"finalizers":[]}}' 2>/dev/null || true
        vgrc_count=$((vgrc_count + 1))
    done < <(kubectl --context="$context" get volumegroupreplicationcontent -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

    if [ "$vgrc_count" -gt 0 ]; then
        log_info "  Removed finalizers from $vgrc_count VolumeGroupReplicationContent(s)"
    fi

    # 6. Delete all VolumeGroupReplicationContents
    kubectl --context="$context" delete volumegroupreplicationcontent -A --all --ignore-not-found --wait=false 2>/dev/null || true
    log_info "  Deleted VolumeGroupReplicationContents"

    # 7. Remove finalizers from PVCs first
    pvc_count=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        ns="${line%%/*}"
        name="${line##*/}"
        kubectl --context="$context" -n "$ns" patch pvc "$name" --type=merge -p='{"metadata":{"finalizers":[]}}' 2>/dev/null || true
        pvc_count=$((pvc_count + 1))
    done < <(kubectl --context="$context" get pvc -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

    if [ "$pvc_count" -gt 0 ]; then
        log_info "  Removed finalizers from $pvc_count PVC(s)"
    fi

    # 8. Delete all PVCs
    kubectl --context="$context" delete pvc -A --all --ignore-not-found --wait=false 2>/dev/null || true
    log_info "  Deleted PVCs"

    log_success "  $context cleanup complete"
done

echo ""
log_success "VolumeReplication, VolumeGroupReplication, VolumeGroupReplicationContent, and PVC cleanup complete. Ready for fresh testing."
