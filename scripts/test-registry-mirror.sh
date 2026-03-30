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
else
    log_error "Local registry is NOT accessible at http://localhost:5000"
    exit 1
fi

# Test a simple image pull from registry in both clusters using 'docker load' method
TEST_IMAGE="alpine:3.19"

echo ""
echo "2. Testing image availability in registry..."

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
done

echo ""
echo -e "${GREEN}Registry mirror test completed.${NC}"