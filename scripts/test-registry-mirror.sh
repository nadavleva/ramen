#!/bin/bash
# Test script to verify that minikube clusters can pull from local registry mirror

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo -e "${YELLOW}Testing registry mirror functionality...${NC}"

# Get the host IP (for minikube to access the local registry)
HOST_IP=$(hostname -I | awk '{print $1}')
if [ -z "$HOST_IP" ] || [ "$HOST_IP" = "127.0.0.1" ]; then
    # Fallback to docker bridge gateway IP that minikube can access
    HOST_IP=$(docker network inspect bridge --format='{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || echo "172.17.0.1")
fi

# Test registry accessibility
echo "1. Testing local registry accessibility..."
echo "   Using registry at http://localhost:5000 (from host)"
echo "   Clusters will use http://$HOST_IP:5000 (from cluster network)"
if curl -sf "http://localhost:5000/v2/_catalog" >/dev/null 2>&1; then
    echo -e "${GREEN}✓ Local registry is accessible${NC}"
    CATALOG=$(curl -s "http://localhost:5000/v2/_catalog" 2>/dev/null)
    REPO_COUNT=$(echo "$CATALOG" | jq -r '.repositories | length' 2>/dev/null || echo "0")
    echo "   Registry contains $REPO_COUNT repositories"
    
    if [ "$REPO_COUNT" -gt 0 ]; then
        echo "   Repositories and tags:"
        echo "$CATALOG" | jq -r '.repositories[]' 2>/dev/null | while read -r repo; do
            if [ -n "$repo" ]; then
                echo "     📦 $repo"
                # Get tags for this repository
                TAGS=$(curl -s "http://localhost:5000/v2/$repo/tags/list" 2>/dev/null)
                if [ $? -eq 0 ] && [ -n "$TAGS" ]; then
                    echo "$TAGS" | jq -r '.tags[]?' 2>/dev/null | while read -r tag; do
                        if [ -n "$tag" ]; then
                            echo "        🏷️  $repo:$tag"
                        fi
                    done
                else
                    echo "        🏷️  (no tags or tags unavailable)"
                fi
            fi
        done
    else
        echo "   No repositories found in registry"
    fi
    
    # Check specifically for iptables-manager image
    echo ""
    echo "   Checking for iptables-manager image:"
    if echo "$CATALOG" | jq -r '.repositories[]' 2>/dev/null | grep -q "csi-addons/iptables-manager"; then
        log_success "✓ csi-addons/iptables-manager repository found in registry"
    else
        log_warning "⚠ csi-addons/iptables-manager repository NOT found in registry"
        echo "     This image should be available as localhost/csi-addons/iptables-manager:latest"
        echo "     You may need to push it to the registry first"
    fi
else
    log_error "Local registry is NOT accessible at http://localhost:5000"
    exit 1
fi

echo ""
echo "2. Listing current images in each cluster..."

for context in dr1 dr2; do
    echo "Images in $context cluster:"
    if minikube profile list --output=json 2>/dev/null | grep -q "\"Name\":\"$context\""; then
        CLUSTER_IMAGES=$(minikube image ls -p "$context" 2>/dev/null || echo "Failed to get images")
        if [ "$CLUSTER_IMAGES" = "Failed to get images" ]; then
            log_warning "  ⚠ Could not retrieve image list from $context"
        else
            IMAGE_COUNT=$(echo "$CLUSTER_IMAGES" | wc -l)
            echo "  📊 Total images in $context: $IMAGE_COUNT"
            echo "  🔍 CSI-related images:"
            echo "$CLUSTER_IMAGES" | grep -E "(csi|iptables|rook|ceph)" | sed 's/^/    /' || echo "    (no CSI-related images found)"
            
            # Check specifically for iptables-manager
            if echo "$CLUSTER_IMAGES" | grep -q "iptables-manager"; then
                log_success "  ✓ iptables-manager image found in $context"
            else
                log_warning "  ⚠ iptables-manager image NOT found in $context"
            fi
        fi
    else
        log_warning "  ⚠ $context cluster not found or not running"
    fi
    echo ""
done

# Test a simple image pull from registry in both clusters using 'docker load' method
TEST_IMAGE="alpine:3.19"
IPTABLES_IMAGE="localhost/csi-addons/iptables-manager:latest"

echo "3. Testing image availability and loading..."

for context in dr1 dr2; do
    echo "Testing $context cluster..."
    
    # Try to load the image into minikube using docker save + minikube image load
    # This bypasses network issues by using local images
    if docker image inspect "$TEST_IMAGE" >/dev/null 2>&1; then
        log_info "Loading pre-downloaded image into $context..."
        if minikube image load "$TEST_IMAGE" -p "$context" >/dev/null 2>&1; then
            if minikube image ls -p "$context" 2>/dev/null | grep -q "$TEST_IMAGE"; then
                echo -e "${GREEN}✓ $context has $TEST_IMAGE available${NC}"
            else
                echo -e "${YELLOW}⚠ $context may have issues with $TEST_IMAGE${NC}"
            fi
        else
            log_warning "Failed to load image into $context"
        fi
    else
        # Try pulling from registry via insecure endpoint
        echo -e "${YELLOW}ℹ Testing registry pull from $context...${NC}"
        
        # Create insecure registry config in minikube
        minikube ssh -p "$context" "sudo bash -c 'mkdir -p /etc/docker && echo \"{\\\"insecure-registries\\\":[\\\"$HOST_IP:5000\\\"]}\" > /etc/docker/daemon.json'" >/dev/null 2>&1 || true
        
        # Try to create a test pod
        cat <<EOF | kubectl --context=$context apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: registry-test
  namespace: default
spec:
  containers:
  - name: test
    image: $HOST_IP:5000/$TEST_IMAGE
    imagePullPolicy: IfNotPresent
    command: ['sh', '-c', 'echo "Registry test successful" && sleep 10']
  restartPolicy: Never
EOF

        # Wait and check
        sleep 3
        POD_STATUS=$(kubectl --context=$context get pod registry-test -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
        
        if [ "$POD_STATUS" = "Running" ] || [ "$POD_STATUS" = "Succeeded" ]; then
            log_success "$context successfully pulled image from registry"
        else
            log_warning "$context had issues pulling from registry (status: $POD_STATUS)"
        fi
        
        # Cleanup
        kubectl --context=$context delete pod registry-test >/dev/null 2>&1 || true
    fi
    
    echo "Testing iptables-manager image loading for $context..."
    
    # Try to load the iptables-manager image if it exists locally
    if podman image inspect "$IPTABLES_IMAGE" >/dev/null 2>&1 || docker image inspect "$IPTABLES_IMAGE" >/dev/null 2>&1; then
        log_info "iptables-manager image found locally, attempting to load into $context..."
        
        # Try with podman first, then docker
        if command -v podman >/dev/null 2>&1; then
            if podman save "$IPTABLES_IMAGE" | minikube image load --profile="$context" - 2>/dev/null; then
                log_success "✓ Successfully loaded iptables-manager image into $context via podman"
            else
                log_warning "⚠ Failed to load iptables-manager via podman into $context"
            fi
        elif command -v docker >/dev/null 2>&1; then
            if minikube image load "$IPTABLES_IMAGE" --profile="$context" 2>/dev/null; then
                log_success "✓ Successfully loaded iptables-manager image into $context via docker"
            else
                log_warning "⚠ Failed to load iptables-manager via docker into $context"
            fi
        fi
        
        # Verify the image is now in the cluster
        if minikube image ls -p "$context" 2>/dev/null | grep -q "iptables-manager"; then
            log_success "✓ iptables-manager image confirmed in $context cluster"
        else
            log_warning "⚠ iptables-manager image not found in $context cluster after loading attempt"
        fi
    else
        log_warning "iptables-manager image not found locally with podman or docker"
        echo "   Try: podman build -t localhost/csi-addons/iptables-manager:latest <path-to-dockerfile>"
    fi
    
    echo ""
done

echo ""
echo -e "${GREEN}Registry mirror test completed.${NC}"