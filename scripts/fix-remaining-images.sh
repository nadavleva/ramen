#!/bin/bash
# SPDX-FileCopyrightText: The RamenDR authors
# SPDX-License-Identifier: Apache-2.0

# Fix remaining image issues after drenv cache loading

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/utils.sh
source "$SCRIPT_DIR/utils.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

detect_container_runtime

echo -e "${GREEN}=== Fixing Remaining Image Issues ===${NC}"
echo -e "${YELLOW}Using $CONTAINER_RUNTIME as container runtime${NC}"

# Get the directory of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Function to read required images from config file
read_required_images() {
    local config_file="$ROOT_DIR/config/required-images.txt"
    
    if [[ ! -f "$config_file" ]]; then
        echo "Error: Required images file not found: $config_file" >&2
        exit 1
    fi
    
    # Read all images (excluding comments and empty lines)
    mapfile -t ALL_REQUIRED_IMAGES < <(grep -v '^[[:space:]]*#' "$config_file" | grep -v '^[[:space:]]*$')
    
    if [[ ${#ALL_REQUIRED_IMAGES[@]} -eq 0 ]]; then
        echo "Error: No images found in $config_file" >&2
        exit 1
    fi
}

# Read the centralized image list
read_required_images

# For remaining image fixes, we focus on CSI-related images
# Filter images that typically need manual loading
MISSING_IMAGES=()
for image in "${ALL_REQUIRED_IMAGES[@]}"; do
    if [[ "$image" == *"csiaddons"* ]] || [[ "$image" == *"csi-"* ]]; then
        MISSING_IMAGES+=("$image")
    fi
done

# Function to load images to both clusters
load_images() {
    local images=("$@")
    echo -e "${YELLOW}Loading ${#images[@]} missing images...${NC}"
    
    # Pull all images in parallel (batches of 3)
    for ((i=0; i<${#images[@]}; i+=3)); do
        batch=("${images[@]:i:3}")
        echo -e "${YELLOW}Pulling batch: ${batch[*]}${NC}"
        
        for image in "${batch[@]}"; do
            $CONTAINER_RUNTIME pull "$image" &
        done
        wait
    done
    
    # Load to both clusters in parallel
    for image in "${images[@]}"; do
        echo -e "${YELLOW}Loading $image to both clusters...${NC}"
        (
            minikube image load "$image" --profile=dr1 && 
            echo -e "${GREEN}✓ Loaded $image to dr1${NC}"
        ) &
        (
            minikube image load "$image" --profile=dr2 && 
            echo -e "${GREEN}✓ Loaded $image to dr2${NC}"
        ) &
    done
    wait
}

# Patch container by name using strategic merge (matches by name, not index)
patch_container() {
    local context=$1
    local resource_type=$2
    local resource_name=$3
    local namespace=$4
    local patch_json=$5
    kubectl --context="$context" patch "$resource_type" "$resource_name" -n "$namespace" \
        --type='strategic' -p="$patch_json" 2>/dev/null || true
}

# Function to patch deployments with custom images to use standard ones
# All patches target containers by NAME (not index) for robustness.
patch_custom_images() {
    echo -e "${YELLOW}Patching deployments with custom nladha images...${NC}"
    
    # Replace custom CSI addons controller image (container name: manager)
    for context in dr1 dr2; do
        patch_container "$context" deployment csi-addons-controller-manager csi-addons-system \
            '{"spec":{"template":{"spec":{"containers":[{"name":"manager","image":"quay.io/csiaddons/k8s-controller:latest"}]}}}}'
    done
    
    # Replace custom CSI addons sidecar images in Rook DaemonSets/Deployments
    for context in dr1 dr2; do
        # csi-rbdplugin-provisioner: log-collector (by name)
        echo -e "${YELLOW}Patching CSI RBD provisioner log-collector in $context...${NC}"
        patch_container "$context" deployment csi-rbdplugin-provisioner rook-ceph \
            '{"spec":{"template":{"spec":{"containers":[{"name":"log-collector","image":"alpine:3.19","command":["sh","-c"],"args":["while true; do sleep 3600; done"]}]}}}}'
        
        # csi-cephfsplugin-provisioner: log-collector (by name)
        echo -e "${YELLOW}Patching CSI CephFS provisioner log-collector in $context...${NC}"
        patch_container "$context" deployment csi-cephfsplugin-provisioner rook-ceph \
            '{"spec":{"template":{"spec":{"containers":[{"name":"log-collector","image":"alpine:3.19","command":["sh","-c"],"args":["while true; do sleep 3600; done"]}]}}}}'
        
        # csi-rbdplugin daemonset: log-collector (by name)
        echo -e "${YELLOW}Patching CSI RBD DaemonSet log-collector in $context...${NC}"
        patch_container "$context" daemonset csi-rbdplugin rook-ceph \
            '{"spec":{"template":{"spec":{"containers":[{"name":"log-collector","image":"alpine:3.19","command":["sh","-c"],"args":["while true; do sleep 3600; done"]}]}}}}'
    done
}

# Function to restart problematic deployments
restart_deployments() {
    echo -e "${YELLOW}Restarting problematic deployments...${NC}"
    
    for context in dr1 dr2; do
        echo -e "${YELLOW}Restarting deployments in $context...${NC}"
        kubectl --context=$context rollout restart deployment -n rook-ceph csi-rbdplugin-provisioner || true
        kubectl --context=$context rollout restart deployment -n rook-ceph csi-cephfsplugin-provisioner || true
        kubectl --context=$context rollout restart daemonset -n rook-ceph csi-rbdplugin || true
        kubectl --context=$context rollout restart deployment -n csi-addons-system csi-addons-controller-manager || true
    done
}

# Function to wait for pods to be ready
wait_for_pods() {
    echo -e "${YELLOW}Waiting for pods to become ready...${NC}"
    
    for context in dr1 dr2; do
        echo -e "${YELLOW}Waiting for pods in $context...${NC}"
        kubectl --context=$context wait --for=condition=ready pod -l app=rook-ceph-operator -n rook-ceph --timeout=300s || true
        kubectl --context=$context wait --for=condition=ready pod -l app=csi-rbdplugin-provisioner -n rook-ceph --timeout=300s || true
        kubectl --context=$context wait --for=condition=ready pod -l app=csi-cephfsplugin-provisioner -n rook-ceph --timeout=300s || true
        kubectl --context=$context wait --for=condition=ready pod -l control-plane=controller-manager -n csi-addons-system --timeout=300s || true
    done
}

# Main execution
main() {
    echo -e "${GREEN}Starting image fix process...${NC}"
    
    # Step 1: Load missing images
    load_images "${MISSING_IMAGES[@]}"
    
    # Step 2: Patch custom images
    patch_custom_images
    
    # Step 3: Restart deployments
    restart_deployments
    
    # Step 4: Wait for everything to be ready
    wait_for_pods
    
    echo -e "${GREEN}=== Checking Final Status ===${NC}"
    for context in dr1 dr2; do
        echo -e "${YELLOW}Failed pods in $context:${NC}"
        kubectl --context=$context get pods -A | grep -E "(ImagePullBackOff|ErrImagePull|Pending)" || echo -e "${GREEN}✓ No failed pods in $context${NC}"
    done
    
    echo -e "${GREEN}Image fix process completed!${NC}"
}

# Run main function
main "$@"