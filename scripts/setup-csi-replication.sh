#!/bin/bash
# SPDX-FileCopyrightText: The RamenDR authors
# SPDX-License-Identifier: Apache-2.0

# Script to setup DR clusters with Ceph SDS Storage for CSI Replication testing using rook environment
#
# OPTIMIZATION: This script uses a local registry mirror to avoid slow image loading.
# Instead of loading all images directly to minikube clusters via `minikube image load` 
# (which is very slow), we:
# 1. Set up a local registry on port 5000
# 2. Push all required images to this registry
# 3. Configure minikube with MINIKUBE_REGISTRY_MIRROR to use our local registry
# 4. Only load critical startup images directly (2-3 images vs 25+ images)
# 5. Let minikube pull other images from the fast local registry automatically
#
# This reduces setup time from ~10-15 minutes to ~3-5 minutes.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/utils.sh
source "$SCRIPT_DIR/utils.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Create logs directory and setup logging
mkdir -p Logs
LOG_FILE="Logs/setup-csi-replication-$(date +%Y%m%d-%H%M%S).log"

# Function to log both to console and file
log_both() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

# Override log functions to write to both console and file
log_info() { log_both "${BLUE}[INFO]${NC} $1"; }
log_success() { log_both "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { log_both "${YELLOW}[WARNING]${NC} $1"; }
log_error() { log_both "${RED}[ERROR]${NC} $1"; }

detect_container_runtime
export CONTAINER_RUNTIME

log_info "🚀 Setting up CSI Replication environment using Rook/Ceph-focused setup..."
log_info "This creates dr1 + dr2 clusters with Ceph, CSI addons, and RBD mirroring."
log_info "Logging to: $LOG_FILE"
log_info ""

log_info "Step 1: Setting up local registry to avoid network pull issues..."
log_info "Using $CONTAINER_RUNTIME as container runtime"

# Check if local registry is running
REGISTRY_RUNNING=false
if $CONTAINER_RUNTIME ps | grep -q "local-registry"; then
    REGISTRY_RUNNING=true
    log_info "Local registry already running on port 5000"
else
    log_info "Starting local registry on port 5000..."
    $CONTAINER_RUNTIME run -d --restart=always -p 5000:5000 --name local-registry registry:2
    REGISTRY_RUNNING=true
fi

# Define required images from central config file
IMAGES=()
while IFS= read -r line; do
    # Skip comments and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue
    IMAGES+=("$line")
done < "config/required-images.txt"

# Check which images need to be loaded to registry
log_info "Checking which images need to be loaded to local registry..."
IMAGES_TO_LOAD=()

# First verify registry is accessible
if ! curl -sf "http://localhost:5000/v2/_catalog" >/dev/null 2>&1; then
    log_warning "Local registry not accessible, will load all images"
    IMAGES_TO_LOAD=("${IMAGES[@]}")
else
    # Registry is accessible, check individual images
    for image in "${IMAGES[@]}"; do
        local_tag="localhost:5000/${image#*/}"  # Remove registry prefix, add localhost:5000
        repo_name="${image#*/}"  # Remove registry prefix (quay.io/, registry.k8s.io/, etc)
        tag_name="${image##*:}"  # Extract tag name
        
        # Check if image exists in local registry (with timeout and error handling)
        if curl -sf --max-time 5 "http://localhost:5000/v2/${repo_name}/tags/list" 2>/dev/null | grep -q "\"${tag_name}\""; then
            log_info "Already in registry: $image"
        else
            IMAGES_TO_LOAD+=("$image")
            log_info "Need to load: $image"
        fi
    done
fi

# Load only missing images
# Podman requires --tls-verify=false for HTTP registries (localhost:5000)
PUSH_OPTS=()
[[ "$CONTAINER_RUNTIME" == "podman" ]] && PUSH_OPTS=(--tls-verify=false)

if [ ${#IMAGES_TO_LOAD[@]} -gt 0 ]; then
    log_info "Loading ${#IMAGES_TO_LOAD[@]} missing images to local registry..."
    for image in "${IMAGES_TO_LOAD[@]}"; do
        local_tag="localhost:5000/${image#*/}"
        log_info "Processing: $image -> $local_tag"
        $CONTAINER_RUNTIME pull "$image" || log_warning "Failed to pull $image, will try to continue"
        $CONTAINER_RUNTIME tag "$image" "$local_tag" || true
        $CONTAINER_RUNTIME push "${PUSH_OPTS[@]}" "$local_tag" || log_warning "Failed to push $local_tag"
    done
else
    log_info "All required images already present in local registry"
fi

# Validate registry is accessible and contains images
log_info "Validating local registry setup..."
if curl -sf "http://localhost:5000/v2/_catalog" >/dev/null 2>&1; then
    CATALOG=$(curl -s "http://localhost:5000/v2/_catalog" 2>/dev/null || echo '{"repositories":[]}')
    REPO_COUNT=$(echo "$CATALOG" | grep -o '"repositories":\[' | wc -l)
    if [ "$REPO_COUNT" -gt 0 ]; then
        log_success "Local registry is accessible and contains repositories"
        log_info "Registry URL: http://localhost:5000/v2/_catalog"
    else
        log_warning "Local registry is accessible but may be empty"
    fi
else
    log_error "Local registry is not accessible at http://localhost:5000"
    log_error "This may cause image pull failures during deployment"
fi

log_info ""
log_info "Step 2: Preparing environment configuration..."
cd test && source ../venv && drenv setup envs/rook.yaml
cd - >/dev/null

log_info ""
log_info "Step 3: Creating empty minikube clusters with local registry mirror..."
# Get host IP that minikube can access
HOST_IP=$(ip route get 1.1.1.1 | awk '{print $7}' | head -1)
REGISTRY_URL="http://${HOST_IP}:5000"

# Configure minikube to use local registry mirror
export MINIKUBE_REGISTRY_MIRROR="$REGISTRY_URL"
log_info "Registry mirror configured: $MINIKUBE_REGISTRY_MIRROR"

# Create clusters first without deploying Rook/addons so critical images can be loaded
cd test && source ../venv && drenv start envs/rook.yaml --skip-addons --skip-tests
cd - >/dev/null

# Wait for clusters to be ready before configuring registry access
log_info "Waiting for clusters to stabilize before image preloading..."
kubectl --context=dr1 wait --for=condition=Ready nodes --all --timeout=180s 2>/dev/null || log_warning "dr1 nodes not ready yet"
kubectl --context=dr2 wait --for=condition=Ready nodes --all --timeout=180s 2>/dev/null || log_warning "dr2 nodes not ready yet"
sleep 10

log_info ""
log_info "Step 5: Loading critical startup images into clusters..."
log_info "Using preload-images.sh to load images from registry into minikube clusters"

# Run preload-images script to load images into clusters
# This ensures critical images are available before deployments try to use them
./scripts/preload-images.sh dr1 dr2 2>&1 | tee -a "$LOG_FILE" || log_warning "Image preloading had some issues, continuing..."

log_info ""
log_info "Step 6: Deploying Rook/Ceph addons (using registry mirror for fast image pulls)..."
cd test && source ../venv && drenv start envs/rook.yaml
cd - >/dev/null

log_info ""
log_info "Step 7: Waiting for cluster components to be ready..."
log_info "  Waiting for basic cluster readiness..."
kubectl --context=dr1 wait --for=condition=Ready nodes --all --timeout=300s
kubectl --context=dr2 wait --for=condition=Ready nodes --all --timeout=300s
log_info "  Waiting for Rook operator deployment..."
kubectl --context=dr1 -n rook-ceph wait --for=condition=available deployment/rook-ceph-operator --timeout=300s || true
kubectl --context=dr2 -n rook-ceph wait --for=condition=available deployment/rook-ceph-operator --timeout=300s || true

log_info ""
log_info "Step 8: Applying CSI provisioner fixes for Ceph CSI compatibility..."
./scripts/fix-csi-provisioners.sh

log_info ""
log_info "Step 9: Updating CSI Addons to compatible versions..."
./scripts/fix-csi-addons-versions.sh

log_info ""
log_info "Step 10: Applying CSI Addons TLS fix (controller/sidecar compatibility)..."
make fix-csi-addons-tls || log_warning "TLS fix had issues - run 'make fix-csi-addons-tls' manually if VolumeReplication stays Unknown"

log_info ""
log_info "Step 11: Setting up storage classes and replication classes..."
./scripts/setup-csi-storage-resources.sh

log_info ""
log_info "Step 12: Setting up RBD mirroring between clusters..."
./scripts/setup-rbd-mirroring.sh

log_info ""
log_success "🎉 Setup complete! Your clusters are ready for CSI replication testing."
log_info "Available resources:"
log_info "  - Storage Classes: rook-ceph-block, rook-ceph-block-2"
log_info "  - Volume Replication Classes: rbd-volumereplicationclass, rbd-volumereplicationclass-5m"
log_info "  - RBD Pools: replicapool, replicapool-2"
log_info ""
log_info "Next steps:"
log_info "Access clusters with: kubectl --context=dr1|dr2 get nodes"
log_info "Test replication with: bash test/test-csi-replication.sh"
log_info "Test registry mirror: make test-registry-mirror"
log_info ""

# Quick validation that clusters are responsive
log_info "Final validation - checking cluster accessibility..."
if kubectl --context=dr1 get nodes >/dev/null 2>&1 && kubectl --context=dr2 get nodes >/dev/null 2>&1; then
    log_success "✅ Both dr1 and dr2 clusters are accessible and ready"
else
    log_warning "⚠ One or both clusters may have issues - check with 'kubectl --context=dr1|dr2 get nodes'"
fi