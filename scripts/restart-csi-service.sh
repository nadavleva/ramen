#!/bin/bash
# SPDX-FileCopyrightText: The RamenDR authors
# SPDX-License-Identifier: Apache-2.0

# Restart CSI Replication Service
# Detects and fixes missing CSI services and leader selection failures
# Ensures csi-addons controller can properly communicate with CSI drivers

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if contexts are available
check_contexts() {
    local required_contexts=("dr1" "dr2")
    
    for ctx in "${required_contexts[@]}"; do
        if ! kubectl config get-contexts -o name | grep -q "^$ctx$"; then
            echo -e "${RED}❌ Required context '$ctx' not found${NC}"
            return 1
        fi
    done
    
    return 0
}

# Check and create missing CSI services
fix_csi_services() {
    local context="$1"
    local namespace="rook-ceph"
    
    echo -e "${BLUE}=== Checking CSI Services on $context ===${NC}"
    
    # Check RBD provisioner service
    if ! kubectl --context=$context -n $namespace get svc csi-rbdplugin-provisioner &>/dev/null; then
        echo -e "${YELLOW}⚠️  Creating missing csi-rbdplugin-provisioner service on $context...${NC}"
        kubectl --context=$context -n $namespace apply -f - << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: csi-rbdplugin-provisioner
  namespace: rook-ceph
spec:
  selector:
    app: csi-rbdplugin-provisioner
  ports:
  - name: grpc
    port: 12345
    targetPort: 12345
    protocol: TCP
  type: ClusterIP
EOF
        echo -e "${GREEN}✓ Service created${NC}"
    else
        echo -e "${GREEN}✓ csi-rbdplugin-provisioner service exists${NC}"
    fi
    
    # Check CephFS provisioner service
    if ! kubectl --context=$context -n $namespace get svc csi-cephfsplugin-provisioner &>/dev/null; then
        echo -e "${YELLOW}⚠️  Creating missing csi-cephfsplugin-provisioner service on $context...${NC}"
        kubectl --context=$context -n $namespace apply -f - << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: csi-cephfsplugin-provisioner
  namespace: rook-ceph
spec:
  selector:
    app: csi-cephfsplugin-provisioner
  ports:
  - name: grpc
    port: 12346
    targetPort: 12346
    protocol: TCP
  type: ClusterIP
EOF
        echo -e "${GREEN}✓ Service created${NC}"
    else
        echo -e "${GREEN}✓ csi-cephfsplugin-provisioner service exists${NC}"
    fi
    
    echo ""
}

# Check CSI-Addons sidecar leader status
check_sidecar_leader() {
    local context="$1"
    local namespace="rook-ceph"
    
    echo -e "${BLUE}=== Checking CSI-Addons Sidecar Leader Status on $context ===${NC}"
    
    # Get RBD provisioner pod
    local rbd_pod=$(kubectl --context=$context -n $namespace get pods -l app=csi-rbdplugin-provisioner \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [ -z "$rbd_pod" ]; then
        echo -e "${RED}❌ No RBD provisioner pod found${NC}"
        return 1
    fi
    
    echo "RBD provisioner pod: $rbd_pod"
    
    # Check if csi-addons container has leader status
    local leader_status=$(kubectl --context=$context -n $namespace logs $rbd_pod -c csi-addons 2>/dev/null | \
        grep "Obtained leader status" | tail -1 || echo "")
    
    if [ -n "$leader_status" ]; then
        echo -e "${GREEN}✓ CSI-Addons sidecar has leader status${NC}"
        echo "  Status: $leader_status"
        return 0
    else
        echo -e "${YELLOW}⚠️  CSI-Addons sidecar leader status unknown, checking pod...${NC}"
        
        # Check if pod is running
        local pod_status=$(kubectl --context=$context -n $namespace get pod $rbd_pod \
            -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        
        if [ "$pod_status" != "Running" ]; then
            echo -e "${RED}❌ Pod is not running (status: $pod_status)${NC}"
            return 1
        else
            echo -e "${YELLOW}⚠️  Pod is running, checking logs...${NC}"
            kubectl --context=$context -n $namespace logs $rbd_pod -c csi-addons --tail=20
            return 1
        fi
    fi
}

# Restart CSI provisioner pods to force leader re-election
restart_csi_provisioners() {
    local context="$1"
    local namespace="rook-ceph"
    
    echo -e "${BLUE}=== Restarting CSI Provisioners on $context ===${NC}"
    
    # Restart RBD provisioner
    echo -e "${YELLOW}Restarting csi-rbdplugin-provisioner...${NC}"
    kubectl --context=$context -n $namespace rollout restart deployment/csi-rbdplugin-provisioner
    
    # Restart CephFS provisioner
    echo -e "${YELLOW}Restarting csi-cephfsplugin-provisioner...${NC}"
    kubectl --context=$context -n $namespace rollout restart deployment/csi-cephfsplugin-provisioner
    
    # Wait for rollout
    echo -e "${YELLOW}Waiting for rollouts to complete...${NC}"
    kubectl --context=$context -n $namespace rollout status deployment/csi-rbdplugin-provisioner --timeout=120s
    kubectl --context=$context -n $namespace rollout status deployment/csi-cephfsplugin-provisioner --timeout=120s
    
    echo -e "${GREEN}✓ Provisioners restarted${NC}"
    echo ""
}

# Restart CSI-Addons controller
restart_csi_addons_controller() {
    local context="$1"
    local namespace="csi-addons-system"
    
    echo -e "${BLUE}=== Restarting CSI-Addons Controller on $context ===${NC}"
    
    echo -e "${YELLOW}Restarting csi-addons-controller-manager...${NC}"
    kubectl --context=$context -n $namespace rollout restart deployment/csi-addons-controller-manager
    
    echo -e "${YELLOW}Waiting for rollout to complete...${NC}"
    kubectl --context=$context -n $namespace rollout status deployment/csi-addons-controller-manager --timeout=120s
    
    echo -e "${GREEN}✓ Controller restarted${NC}"
    echo ""
}

# Verify fix by checking CSIAddonsNode and controller logs
verify_fix() {
    local context="$1"
    
    echo -e "${BLUE}=== Verifying Fix on $context ===${NC}"
    
    # Check for controller CSIAddonsNode (required for VGR/VR; deployment provisioner, not just daemonset)
    local rbd_controller_nodes
    rbd_controller_nodes=$(kubectl --context=$context get csiaddonsnode -A -o name 2>/dev/null | grep -c "csi-rbdplugin-provisioner" || echo "0")
    if [ "${rbd_controller_nodes:-0}" -eq 0 ]; then
        echo -e "${YELLOW}⚠️  No CSIAddonsNode for RBD controller (deployment) — creating one...${NC}"
        local prov_pod
        prov_pod=$(kubectl --context=$context -n rook-ceph get pods -l app=csi-rbdplugin-provisioner \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        if [ -n "$prov_pod" ]; then
            kubectl --context=$context apply -f - <<EOF
apiVersion: csiaddons.openshift.io/v1alpha1
kind: CSIAddonsNode
metadata:
  name: ${context}-rook-ceph-provisioner-csi-rbdplugin
  namespace: rook-ceph
spec:
  driver:
    name: rook-ceph.rbd.csi.ceph.com
    endpoint: "pod://${prov_pod}.rook-ceph:9070"
    nodeID: ${context}
EOF
            echo -e "${GREEN}✓ CSIAddonsNode created for provisioner pod ${prov_pod}${NC}"
        else
            echo -e "${RED}❌ No RBD provisioner pod found — cannot create CSIAddonsNode${NC}"
        fi
    else
        echo -e "${GREEN}✓ RBD controller CSIAddonsNode present${NC}"
    fi
    
    # Check for recent "no leader" errors
    local errors
    errors=$(kubectl --context=$context -n csi-addons-system logs deployment/csi-addons-controller-manager \
        --tail=100 2>/dev/null | grep -c "no leader for the ControllerService" || echo "0")
    
    if [ "${errors:-0}" -gt "0" ]; then
        echo -e "${YELLOW}⚠️  Still seeing leader errors (count: $errors in recent logs)${NC}"
        echo "    This may take a few moments to resolve..."
        return 1
    else
        echo -e "${GREEN}✓ No recent leader errors detected${NC}"
        return 0
    fi
}

# Main function
main() {
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}        Restarting CSI Replication Service${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # Check contexts
    if ! check_contexts; then
        echo -e "${RED}❌ Required Kubernetes contexts not found${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ All required contexts available${NC}"
    echo ""
    
    # Process each context
    for context in dr1 dr2; do
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}Processing context: $context${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        
        # Fix services
        fix_csi_services $context
        
        # Check current sidecar leader status
        if ! check_sidecar_leader $context; then
            echo -e "${YELLOW}Leader status check failed, proceeding with restart...${NC}"
        fi
        echo ""
        
        # Restart provisioners to force leader election
        restart_csi_provisioners $context
        
        # Wait for sidecars to establish leader status
        echo -e "${YELLOW}Waiting for sidecar leader election (30s)...${NC}"
        sleep 30
        
        # Verify sidecar leader status
        if check_sidecar_leader $context; then
            echo ""
            # Restart controller to reconnect to drivers
            restart_csi_addons_controller $context
            
            # Wait for controller to stabilize
            echo -e "${YELLOW}Waiting for controller to stabilize (15s)...${NC}"
            sleep 15
            
            # Verify fix
            verify_fix $context
        else
            echo -e "${RED}❌ Sidecar leader election failed on $context${NC}"
        fi
        
        echo ""
    done
    
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✓ CSI Replication Service restart completed${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${BLUE}Next steps:${NC}"
    echo "  1. Check if VolumeReplication resources now reach Primary/Secondary state"
    echo "  2. Run: kubectl --context=dr1 -n default get volumereplication"
    echo "  3. Check controller logs: kubectl --context=dr1 -n csi-addons-system logs -f deployment/csi-addons-controller-manager"
    echo ""
}

# Show usage
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    echo "Usage: $0"
    echo ""
    echo "Detects and fixes CSI replication service issues:"
    echo "  - Creates missing CSI provisioner services"
    echo "  - Restarts provisioners to force leader election"
    echo "  - Restarts CSI-Addons controller to reconnect"
    echo "  - Verifies the fix"
    echo ""
    echo "Works on both dr1 and dr2 clusters"
    exit 0
fi

main
