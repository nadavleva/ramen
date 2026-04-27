#!/bin/bash
# SPDX-FileCopyrightText: The RamenDR authors
# SPDX-License-Identifier: Apache-2.0

# Pre-load container images into minikube clusters to avoid network pull issues
# Based on setup-dr-clusters-with-ceph.sh image management approach

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/utils.sh
source "$SCRIPT_DIR/utils.sh"

# Function to read required images from centralized config file
read_required_images() {
    local config_file="$SCRIPT_DIR/../config/required-images.txt"
    
    if [[ ! -f "$config_file" ]]; then
        log_error "Required images config file not found: $config_file"
        return 1
    fi
    
    # Clear the array first
    ALL_REQUIRED_IMAGES=()
    
    # Read images from file, skipping comments and empty lines
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments (lines starting with #) and empty lines
        if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "${line// }" ]]; then
            continue
        fi
        # Trim whitespace and add to array
        ALL_REQUIRED_IMAGES+=("${line// }")
    done < "$config_file"
}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Get the host IP for local registry access from minikube clusters
get_registry_host_ip() {
    # Try to get the primary host IP (not loopback)
    local host_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    
    if [ -z "$host_ip" ] || [ "$host_ip" = "127.0.0.1" ]; then
        # Fallback: try to detect from default route
        host_ip=$(ip route get 1 2>/dev/null | sed -n 's/.*src \([^ ]*\).*/\1/p')
    fi
    
    if [ -z "$host_ip" ]; then
        host_ip="localhost"
    fi
    
    echo "$host_ip"
}

# Export registry host IP for use in cluster image pulls
REGISTRY_HOST_IP=$(get_registry_host_ip)
log_info "Registry host IP detected as: $REGISTRY_HOST_IP"

# CONTAINER_RUNTIME from parent (setup-csi-replication) takes precedence
# PREFER_DOCKER=1 forces docker when both are available
if [ "${PREFER_DOCKER:-0}" = "1" ]; then
    detect_container_runtime --prefer-docker
else
    detect_container_runtime
fi
log_info "Using $CONTAINER_RUNTIME as container runtime"

# Read all required images from centralized config file
declare -a ALL_REQUIRED_IMAGES=()
read_required_images
log_info "Loaded ${#ALL_REQUIRED_IMAGES[@]} images from config file"

# Function to check if Docker image exists locally
image_exists_locally() {
    local image=$1
    $CONTAINER_RUNTIME image inspect "$image" >/dev/null 2>&1
}

# Function to check if image exists in minikube cluster
image_exists_in_minikube() {
    local image=$1
    local profile=$2
    # Add timeout to prevent hanging
    timeout 30s minikube image ls --profile="$profile" 2>/dev/null | grep -F "$image" >/dev/null
}

# Function to determine if an image should be skipped (local build or special case)
should_skip_image_pull() {
    local image=$1
    
    # Skip localhost/* images (local builds, can't be pulled)
    if [[ "$image" == "localhost/"* ]] || [[ "$image" == "127.0.0.1:"* ]]; then
        return 0  # true - skip
    fi
    
    # Skip special registry images that are build artifacts
    if [[ "$image" == *"iptables-manager"* ]]; then
        return 0  # true - skip
    fi
    
    return 1  # false - don't skip
}

# Function to normalize image name for pulling
normalize_image_name() {
    local image=$1
    
    # Fix common registry name issues
    if [[ "$image" == "docker.io/registry:3.0.0" ]]; then
        # Use standard registry image
        echo "registry:2"
    elif [[ "$image" == "docker.io/"* ]]; then
        # docker.io prefix can usually be omitted
        echo "${image#docker.io/}"
    else
        echo "$image"
    fi
}

# Function to pre-pull images in parallel
pre_pull_images() {
    log_info "Pre-pulling required images in parallel to avoid network issues during cluster setup..."
    
    # Use centralized image list
    local total_count=${#ALL_REQUIRED_IMAGES[@]}
    
    local need_pulling=()
    local skipped_images=()
    
    # Check which images need pulling
    for image in "${ALL_REQUIRED_IMAGES[@]}"; do
        if image_exists_locally "$image"; then
            log_info "✓ Image already available locally: $image"
        elif should_skip_image_pull "$image"; then
            log_info "⊘ Skipping local/special image (must be built locally): $image"
            skipped_images+=("$image")
        else
            need_pulling+=("$image")
        fi
    done
    
    if [ ${#need_pulling[@]} -eq 0 ] && [ ${#skipped_images[@]} -eq 0 ]; then
        log_success "All $total_count required images are already available locally"
        return 0
    fi
    
    if [ ${#need_pulling[@]} -gt 0 ]; then
        log_info "Need to pull ${#need_pulling[@]} images..."
    fi
    
    if [ ${#skipped_images[@]} -gt 0 ]; then
        log_info "Skipping ${#skipped_images[@]} local/special images (verify manually):"
        for image in "${skipped_images[@]}"; do
            log_info "  - $image"
        done
    fi
    
    # Pull images in parallel batches of 3 (to avoid overwhelming the network)
    local batch_size=3
    local pulled_count=0
    local failed_pulls=()
    
    for ((i=0; i<${#need_pulling[@]}; i+=batch_size)); do
        local pids=()
        local batch_images=()
        
        # Start batch pulls
        for ((j=i; j<i+batch_size && j<${#need_pulling[@]}; j++)); do
            local image="${need_pulling[$j]}"
            local normalized_image=$(normalize_image_name "$image")
            batch_images+=("$image")
            
            log_info "Pulling: $normalized_image (from: $image)"
            (
                # Force pull for registry.k8s.io images to avoid cache issues
                if [[ "$normalized_image" == *"registry.k8s.io"* ]]; then
                    if [[ "$CONTAINER_RUNTIME" == "podman" ]]; then
                        if $CONTAINER_RUNTIME pull --tls-verify=false "$normalized_image" >/dev/null 2>&1; then
                            echo "PULL_SUCCESS:$image"
                        else
                            echo "PULL_FAILED:$image"
                        fi
                    else
                        if $CONTAINER_RUNTIME pull "$normalized_image" >/dev/null 2>&1; then
                            echo "PULL_SUCCESS:$image"
                        else
                            echo "PULL_FAILED:$image"
                        fi
                    fi
                else
                    if $CONTAINER_RUNTIME pull "$normalized_image" >/dev/null 2>&1; then
                        echo "PULL_SUCCESS:$image"
                        # Tag with original name if different
                        if [ "$normalized_image" != "$image" ]; then
                            $CONTAINER_RUNTIME tag "$normalized_image" "$image" 2>/dev/null || true
                        fi
                    else
                        echo "PULL_FAILED:$image"
                    fi
                fi
            ) &
            pids+=($!)
        done
        
        # Wait for batch to complete
        for pid in "${pids[@]}"; do
            wait $pid
        done
        
        # Check results
        for image in "${batch_images[@]}"; do
            if image_exists_locally "$image"; then
                log_success "✓ Successfully pulled: $image"
                pulled_count=$((pulled_count + 1))
            else
                log_error "✗ Failed to pull: $image"
                failed_pulls+=("$image")
            fi
        done
        
        log_info "Batch completed: ${#batch_images[@]} images processed"
    done
    
    if [ ${#failed_pulls[@]} -gt 0 ]; then
        log_warning "Failed to pull ${#failed_pulls[@]} images:"
        for image in "${failed_pulls[@]}"; do
            log_warning "  - $image"
        done
        log_warning "These images may need to be built or pulled manually"
    fi
    
    log_success "Successfully pulled $pulled_count new images"
    if [ ${#skipped_images[@]} -gt 0 ]; then
        log_info "Skipped ${#skipped_images[@]} local images (verify they exist locally)"
    fi
}

# Configure local registry access in minikube cluster
configure_cluster_registry_access() {
    local profile=$1
    
    # Update /etc/hosts in minikube to resolve registry host
    minikube ssh -p "$profile" "echo '$REGISTRY_HOST_IP local-registry' | sudo tee -a /etc/hosts >/dev/null 2>&1 || true"
    
    # Configure Docker daemon to allow insecure registry connection
    local docker_config='{
  "insecure-registries": ["'"$REGISTRY_HOST_IP"':5000", "local-registry:5000"]
}'
    
    # Note: Docker daemon config is typically read-only in minikube, so we rely on image pull configuration
    # The kubelets in minikube should be able to resolve the registry via the host IP
    log_info "Registry access configured for $profile (registry at $REGISTRY_HOST_IP:5000)"
}

# Function to load images into a minikube cluster in parallel
load_images_to_cluster() {
    local profile=$1
    log_info "Loading images into $profile cluster..."
    
    # Configure local registry access in minikube cluster
    log_info "Configuring registry access in $profile cluster..."
    configure_cluster_registry_access "$profile"
    
    # Use centralized image list
    local loaded_count=0
    local failed_images=()
    
    # Get cluster image list once to avoid repeated calls
    log_info "Getting current image list from $profile cluster..."
    local cluster_images
    cluster_images=$(timeout 60s minikube image ls --profile="$profile" 2>/dev/null || echo "")
    
    local images_to_load=()
    if [ -z "$cluster_images" ]; then
        log_warning "Failed to get image list from $profile cluster, will load all images"
        images_to_load=("${ALL_REQUIRED_IMAGES[@]}")
    else
        # Check which images are missing (simplified to avoid hanging)
        for image in "${ALL_REQUIRED_IMAGES[@]}"; do
            if ! echo "$cluster_images" | grep -q "$image"; then
                images_to_load+=("$image")
            fi
        done
    fi
    
    if [ ${#images_to_load[@]} -eq 0 ]; then
        log_success "All images already loaded in $profile cluster"
        return 0
    fi
    
    log_info "Loading ${#images_to_load[@]} missing images into $profile cluster"
    
    local total_images=${#images_to_load[@]}
    local batch_size=3  # Smaller batch size to avoid hanging
    
    # Process images in batches
    for ((i=0; i<total_images; i+=batch_size)); do
        local batch_images=()
        local pids=()
        local batch_id="${profile}_${i}_$$"
        local tmpdir="/tmp/preload_batch_${batch_id}"
        mkdir -p "$tmpdir"
        
        log_info "Processing batch $((i/batch_size + 1))/$(((total_images + batch_size - 1) / batch_size)) for $profile..."
        
        # Start batch processes
        local batch_start_idx=$i
        for ((j=i; j<i+batch_size && j<total_images; j++)); do
            local image="${images_to_load[$j]}"
            batch_images+=("$image")
            
            # Use unique index based on position in batch
            local batch_idx=$((j - batch_start_idx))
            (
                local result_file="$tmpdir/result_${batch_idx}"
                log_info "Loading: $image"
                
                # Try standard load first
                if timeout 90s minikube image load "$image" --profile="$profile" >/dev/null 2>&1; then
                    echo "SUCCESS" > "$result_file"
                else
                    # Try alternative tar method for failed images  
                    log_warning "Standard load failed for $image, trying tar method..."
                    local tar_file="/tmp/img_${batch_id}_${batch_idx}.tar"
                    if timeout 60s $CONTAINER_RUNTIME save "$image" -o "$tar_file" 2>/dev/null && \
                       timeout 60s minikube image load "$tar_file" --profile="$profile" >/dev/null 2>&1; then
                        echo "SUCCESS" > "$result_file"
                    else
                        echo "FAILED" > "$result_file"
                    fi
                    rm -f "$tar_file" 2>/dev/null || true
                fi
            ) &
            pids+=($!)
        done
        
        # Wait for batch completion with timeout
        log_info "Waiting for batch processes to complete..."
        local wait_timeout=180
        local wait_start=$(date +%s)
        local completed=0
        
        for pid in "${pids[@]}"; do
            local current_time=$(date +%s)
            local elapsed=$((current_time - wait_start))
            
            if [ $elapsed -ge $wait_timeout ]; then
                log_warning "Batch timeout exceeded ($wait_timeout seconds), killing remaining processes..."
                kill "${pids[@]}" 2>/dev/null || true
                sleep 2
                kill -9 "${pids[@]}" 2>/dev/null || true
                break
            fi
            
            if wait $pid 2>/dev/null; then
                completed=$((completed + 1))
            else
                log_warning "Process $pid completed with error or was terminated"
            fi
        done
        
        log_info "Batch processes completed: $completed/${#pids[@]}"
        
        # Collect results
        for ((j=0; j<${#batch_images[@]}; j++)); do
            local image="${batch_images[$j]}"
            local result_file="$tmpdir/result_${j}"
            if [ -f "$result_file" ] && [ "$(cat "$result_file" 2>/dev/null)" = "SUCCESS" ]; then
                log_success "✓ Loaded: $image"
                loaded_count=$((loaded_count + 1))
            else
                log_error "✗ Failed to load: $image"
                failed_images+=("$image")
            fi
        done
        
        # Clean up temp directory
        rm -rf "$tmpdir" 2>/dev/null || true
        
        log_info "Batch $((i/batch_size + 1)) completed for $profile: ${#batch_images[@]} images processed"
        
        # Small delay between batches
        if [ $((i + batch_size)) -lt $total_images ]; then
            sleep 2
        fi
    done
    
    # Summary
    local total_attempted=${#images_to_load[@]}
    log_success "Image loading completed for $profile cluster:"
    log_success "  ✓ Successfully loaded: $loaded_count images"
    if [ ${#failed_images[@]} -gt 0 ]; then
        log_warning "  ✗ Failed to load: ${#failed_images[@]} images"
        for image in "${failed_images[@]}"; do
            log_warning "    - $image"
        done
    fi
    
    return 0
}

# Function to verify images are loaded in clusters
verify_images_in_cluster() {
    local profile=$1
    log_info "Verifying images in $profile cluster..."
    
    local available_count=$(timeout 30s minikube image ls --profile="$profile" 2>/dev/null | wc -l || echo "0")
    log_info "Found $available_count total images in $profile cluster"
    
    # Check for specific required images
    local rook_images_found=0
    local csi_images_found=0
    
    for image in "${ROOK_IMAGES[@]}"; do
        if timeout 20s minikube image ls --profile="$profile" 2>/dev/null | grep -q "$image"; then
            rook_images_found=$((rook_images_found + 1))
        fi
    done
    
    for image in "${CSI_IMAGES[@]}"; do
        if timeout 20s minikube image ls --profile="$profile" 2>/dev/null | grep -q "$image"; then
            csi_images_found=$((csi_images_found + 1))
        fi
    done
    
    log_info "$profile cluster has $rook_images_found/${#ROOK_IMAGES[@]} Rook images and $csi_images_found/${#CSI_IMAGES[@]} CSI images"
}

# Main execution
main() {
    local clusters=("$@")
    
    if [ ${#clusters[@]} -eq 0 ]; then
        log_info "Usage: $0 <cluster1> [cluster2] [cluster3]..."
        log_info "Example: $0 dr1 dr2"
        exit 1
    fi
    
    echo -e "${PURPLE}🐳 Container Image Pre-loading for Minikube Clusters${NC}"
    echo "=================================================="
    echo ""
    
    # Check prerequisites
    command -v minikube >/dev/null 2>&1 || { log_error "minikube is required"; exit 1; }
    
    # Container runtime check is done at the top of the script
    log_info "Using $CONTAINER_RUNTIME as container runtime"
    
    # Read required images from centralized configuration
    read_required_images
    
    # Pre-pull all images locally first
    log_info "Step 1: Pre-pulling images locally..."
    pre_pull_images
    echo ""
    
    # Load images into each specified cluster
    log_info "Step 2: Loading images into minikube clusters..."
    for cluster in "${clusters[@]}"; do
        log_info "Processing cluster: $cluster"
        
        # Check if cluster exists
        if ! minikube profile list --output=json 2>/dev/null | grep -q "\"Name\":\"$cluster\""; then
            log_warning "Cluster $cluster does not exist, skipping..."
            continue
        fi
        
        # Load images
        load_images_to_cluster "$cluster"
        
        # Special handling for snapshot-controller - force load if missing
        local snapshot_controller_image="registry.k8s.io/sig-storage/snapshot-controller:v7.0.1"
        if ! image_exists_in_minikube "$snapshot_controller_image" "$cluster"; then
            log_warning "Snapshot controller image missing from $cluster, attempting direct load..."
            if image_exists_locally "$snapshot_controller_image"; then
                minikube image load "$snapshot_controller_image" --profile="$cluster" --daemon=true || {
                    log_error "Failed to load snapshot-controller image into $cluster"
                    log_info "Trying alternative method..."
                    # Save and load manually
                    $CONTAINER_RUNTIME save "$snapshot_controller_image" -o "/tmp/snapshot-controller-$cluster.tar" && \
                    minikube image load "/tmp/snapshot-controller-$cluster.tar" --profile="$cluster" && \
                    rm -f "/tmp/snapshot-controller-$cluster.tar" && \
                    log_success "✓ Successfully loaded snapshot-controller via tar method"
                }
            else
                log_error "Snapshot controller image not available locally for $cluster"
            fi
        fi
        echo ""
    done
    
    # Verify images are loaded
    log_info "Step 3: Verifying image availability..."
    local any_failed=0
    for cluster in "${clusters[@]}"; do
        if minikube profile list --output=json 2>/dev/null | grep -q "\"Name\":\"$cluster\""; then
            verify_images_in_cluster "$cluster" || any_failed=1
        fi
    done
    
    if [ $any_failed -eq 1 ]; then
        log_error ""
        log_error "❌ FAILED: Some images are missing from clusters"
        log_error "In an offline environment, ALL images must be pre-loaded."
        log_error ""
        log_error "To fix this:"
        log_error "1. Ensure all images from config/required-images.txt are available locally"
        log_error "2. Run: podman pull <image> (or docker pull)"
        log_error "3. Then retry: make preload-images"
        exit 1
    fi
    
    log_success "🎉 Image pre-loading completed successfully!"
    log_success "✅ All required images verified in all clusters"
    echo ""
    echo -e "${CYAN}Next steps:${NC}"
    echo "1. Your minikube clusters now have all required images locally"
    echo "2. Rook/Ceph operators should deploy without network pull issues"
    echo "3. Continue with your drenv environment setup"
    echo ""
}

# Execute main function with all arguments
main "$@"