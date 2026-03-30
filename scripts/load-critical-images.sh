#!/bin/bash
# Load only the most critical images directly to both clusters for immediate startup
# Other images will be pulled from local registry mirror automatically

# Get the directory of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}Loading only critical startup images directly to clusters...${NC}"
echo -e "${YELLOW}(Other images will be pulled from registry mirror automatically)${NC}"

# Only the most critical images that are needed for immediate cluster startup
CRITICAL_IMAGES=(
    "registry.k8s.io/sig-storage/snapshot-controller:v7.0.1"
    "alpine:3.19"
)

# Function to load image with timeout and fallback
load_image_with_timeout() {
    local image=$1
    local profile=$2
    local timeout=60
    
    echo "Loading $image to $profile (timeout: ${timeout}s)..."
    if timeout $timeout minikube image load "$image" --profile="$profile" 2>/dev/null; then
        echo -e "${GREEN}✓ Loaded $image to $profile${NC}"
        return 0
    else
        echo "⚠ Failed to load $image to $profile (will use registry mirror instead)"
        return 1
    fi
}

# Load critical images in parallel to both clusters
for image in "${CRITICAL_IMAGES[@]}"; do
    load_image_with_timeout "$image" "dr1" &
    load_image_with_timeout "$image" "dr2" &
done

# Wait for all background processes
wait

echo -e "${GREEN}Critical image loading completed.${NC}"
echo "Note: Other images will be pulled from http://localhost:5000 registry mirror automatically"

echo -e "${GREEN}Critical image loading completed.${NC}"
echo "Note: Other images will be pulled from http://localhost:5000 registry mirror automatically"