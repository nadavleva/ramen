#!/bin/bash
# SPDX-FileCopyrightText: The RamenDR authors
# SPDX-License-Identifier: Apache-2.0
#
# Validate CSI Addons VolumeGroupReplication (VGR) flow.
# Flow: Create VolumeGroupReplication with source.selector; controller creates
# VolumeGroupReplicationContent and per-volume VolumeReplication.
# Uses: VolumeGroupReplication, VolumeGroupReplicationClass, VolumeGroupReplicationContent.
# Requires: CSI Addons v0.13+ with working VGR controller.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/scripts/utils.sh"
init_logging "test-csi-volumegroupreplication"
start_capture_logging

# Capture diagnostics on failure
capture_diagnostic_logs() {
  echo ""
  echo "=== Failure Diagnostics ==="
  set +e
  log_info "VolumeGroupReplication (DR1):"
  kubectl --context=dr1 get volumegroupreplication -n "$NAMESPACE" -o wide 2>/dev/null || echo "  Could not get VGR"
  kubectl --context=dr1 get volumegroupreplication "$VGR_NAME" -n "$NAMESPACE" -o yaml 2>/dev/null | tail -50 || true
  echo ""
  log_info "VolumeGroupReplicationContent (DR1):"
  kubectl --context=dr1 get volumegroupreplicationcontent -o wide 2>/dev/null || echo "  Could not get VGRC"
  echo ""
  log_info "VolumeReplication (DR1):"
  kubectl --context=dr1 get volumereplication -n "$NAMESPACE" -o wide 2>/dev/null || echo "  Could not get VR"
  echo ""
  log_info "CSI Addons Controller (DR1):"
  kubectl --context=dr1 logs -n csi-addons-system deploy/csi-addons-controller-manager --tail=50 2>/dev/null || echo "  Could not get logs"
  set -e
  echo "=== End Diagnostics ==="
  echo ""
}

# Elaborate failure message: identifies failure point, cause, and remediation
fail() {
  local msg="$1"
  local step="${2:-unknown}"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_error "VGR TEST FAILURE [step: $step]"
  echo ""
  echo "  What failed: $msg"
  echo ""
  echo "  Remediation:"
  case "$step" in
    prerequisite) echo "    • Run: make reset-csi-replication-state   # full env setup (VGRClasses, VRCs, RBD mirroring)"; echo "    • Or:  make start-csi-replication          # if clusters already exist" ;;
    crd)         echo "    • Run: make reset-csi-replication-state   # installs VGR CRDs via setup-csi-storage-resources" ;;
    class)       echo "    • Run: make reset-csi-replication-state   # creates vgrc-2m, vgrc-1m, vgrc-5m via rbd-mirror addon" ;;
    vgr_primary) echo "    • Check CSI Addons logs for 'no leader' → run: make restart-csi-service"; echo "    • VGR state Unknown / 'image not found' → stale images or cleanup race; run: make reset-csi-replication-state"; echo "    • Stale VRs referencing deleted images → run: make reset-csi-replication-state" ;;
    vgrc)        echo "    • VGR controller may not be reconciling; requires CSI Addons v0.13+"; echo "    • Run: make restart-csi-service   # restart CSI pods to re-establish leader" ;;
    failover)    echo "    • VGR may not promote on DR2; check CSI Addons controller logs on dr2"; echo "    • Ensure RBD mirror sync completed before demote (replication wait: ${REPLICATION_WAIT_SEC}s)" ;;
    data)        echo "    • Replication may not have synced; increase REPLICATION_WAIT_SEC or check RBD mirror status" ;;
    *)           echo "    • See diagnostics below; run: make reset-csi-replication-state to reset env" ;;
  esac
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  capture_diagnostic_logs
  exit 1
}

NAMESPACE="vgr-test-$(date +%s)"
VGR_NAME="vgr-test"
VGRCLASS_NAME="vgrc-2m"
VRC_NAME="rbd-volumereplicationclass"
STORAGE_CLASS="rook-ceph-block"
PVC_NAME_PREFIX="vgr-pvc"
NUM_PVCS=3
YAML_DIR="$REPO_ROOT/test/yaml/vgr"
REPLICATION_WAIT_SEC=150

declare -a WRITTEN_DATA

cleanup() {
  log_info "Cleaning up..."
  set +e
  for ctx in dr1 dr2; do
    csi_cleanup_volumegroupreplication "$ctx" "$NAMESPACE" "$VGR_NAME"
    csi_cleanup_volumegroupreplicationcontents "$ctx"
    # Clean up all VolumeReplications created by VGR (they have generated names)
    csi_cleanup_volumereplications_in_namespace "$ctx" "$NAMESPACE"
    for i in $(seq 1 $NUM_PVCS); do
      kubectl --context=$ctx delete pod "vgr-writer-$i" -n "$NAMESPACE" --ignore-not-found=true --wait=false 2>/dev/null
      kubectl --context=$ctx delete pod "vgr-reader-$i" -n "$NAMESPACE" --ignore-not-found=true --wait=false 2>/dev/null
      csi_cleanup_pvc "$ctx" "$NAMESPACE" "${PVC_NAME_PREFIX}-$i"
      kubectl --context=$ctx delete pv "vgr-pv-dr2-$i" --ignore-not-found=true 2>/dev/null
    done
    csi_cleanup_namespace "$ctx" "$NAMESPACE"
  done
  sleep 5
  [[ -n "$REPO_ROOT" ]] && [[ -f "$REPO_ROOT/scripts/cleanup-replicated-images.sh" ]] && \
    (cd "$REPO_ROOT" && ./scripts/cleanup-replicated-images.sh 2>/dev/null) || true
  set -e
  end_logging
  log_success "Cleanup completed"
}

trap cleanup EXIT

# Fail fast: check prerequisites before expensive cleanup
kubectl config get-contexts dr1 >/dev/null 2>&1 || fail "Kubernetes context 'dr1' not found. The test requires two clusters (dr1, dr2) from make setup-csi-replication." "prerequisite"
kubectl config get-contexts dr2 >/dev/null 2>&1 || fail "Kubernetes context 'dr2' not found. The test requires two clusters (dr1, dr2) from make setup-csi-replication." "prerequisite"
if ! kubectl get crd volumegroupreplications.replication.storage.openshift.io >/dev/null 2>&1; then
  fail "VolumeGroupReplication CRD is not installed. This CRD is required for the VGR flow (source.selector over PVCs)." "crd"
fi
if ! kubectl --context=dr1 get volumegroupreplicationclass "$VGRCLASS_NAME" >/dev/null 2>&1; then
  fail "VolumeGroupReplicationClass '$VGRCLASS_NAME' not found on dr1. VGRClass defines replication params (pool, interval); created by rbd-mirror addon during setup." "class"
fi
if ! kubectl --context=dr1 get volumereplicationclass "$VRC_NAME" >/dev/null 2>&1; then
  fail "VolumeReplicationClass '$VRC_NAME' not found on dr1. VRC is used by VGR for per-volume replication; created during setup." "class"
fi
# Check CSIAddonsNode exists for RBD driver (controller needs this to reach sidecar; "no leader" when missing)
# Note: grep -c exits 1 when 0 matches; avoid "|| echo 0" which appends and causes "0\n0" syntax error
rbd_node_count=$(kubectl --context=dr1 get csiaddonsnode -A -o jsonpath='{range .items[*]}{.spec.driver.name}{"\n"}{end}' 2>/dev/null | grep -c "rook-ceph.rbd.csi.ceph.com" 2>/dev/null) || true
rbd_node_count=${rbd_node_count:-0}
if [[ "$rbd_node_count" -eq 0 ]]; then
  fail "No CSIAddonsNode for rook-ceph.rbd.csi.ceph.com on dr1. Controller cannot reach sidecar (causes 'no leader'). Run: make restart-csi-service" "prerequisite"
fi

# Pre-test cleanup
log_info "Cleaning any orphaned resources from previous runs..."
set +e
for ctx in dr1 dr2; do
  for ns in $(kubectl --context=$ctx get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep '^vgr-test-' || true); do
    [[ -z "$ns" ]] && continue
    csi_cleanup_volumegroupreplication "$ctx" "$ns" "vgr-test"
    csi_cleanup_volumegroupreplicationcontents "$ctx"
    csi_cleanup_volumereplications_in_namespace "$ctx" "$ns"
    for i in $(seq 1 $NUM_PVCS); do
      csi_cleanup_pvc "$ctx" "$ns" "${PVC_NAME_PREFIX}-$i"
    done
    csi_cleanup_namespace "$ctx" "$ns"
  done
done
# Allow provisioner to process PV deletions before image cleanup
sleep 5
# Pre-test: only fix error/unknown state images (avoids deleting in-use images; full cleanup runs in trap)
[[ -n "$REPO_ROOT" ]] && [[ -f "$REPO_ROOT/scripts/cleanup-replicated-images.sh" ]] && \
  (cd "$REPO_ROOT" && ./scripts/cleanup-replicated-images.sh --error-state-only 2>/dev/null) || true
set -e
echo ""

# Validation 1: CRD presence (VolumeGroupReplication, VolumeGroupReplicationClass, VolumeGroupReplicationContent)
validate_1_crds() {
  log_step "Validation 1: CRD presence"
  for crd in volumegroupreplications.replication.storage.openshift.io volumegroupreplicationclasses.replication.storage.openshift.io volumegroupreplicationcontents.replication.storage.openshift.io; do
    if ! kubectl get crd "$crd" >/dev/null 2>&1; then
      fail "CRD '$crd' is not installed. VGR test requires all three VGR CRDs (VGR, VGRClass, VGRContent)." "crd"
    fi
  done
  log_success "All VGR CRDs present"
}

# Validation 2: VolumeGroupReplicationClass and VolumeReplicationClass availability
validate_2_classes() {
  log_step "Validation 2: VolumeGroupReplicationClass and VolumeReplicationClass availability"
  if ! kubectl --context=dr1 get volumegroupreplicationclass "$VGRCLASS_NAME" >/dev/null 2>&1; then
    fail "VolumeGroupReplicationClass '$VGRCLASS_NAME' not found on dr1. Created by rbd-mirror addon (make reset-csi-replication-state)." "class"
  fi
  if ! kubectl --context=dr1 get volumereplicationclass "$VRC_NAME" >/dev/null 2>&1; then
    fail "VolumeReplicationClass '$VRC_NAME' not found on dr1. Created during setup (make reset-csi-replication-state)." "class"
  fi
  log_success "VGRClass $VGRCLASS_NAME and VRC $VRC_NAME available"
}

# Validation 3: PVC creation, VolumeGroupReplication creation
validate_3_creation() {
  log_step "Validation 3: PVC and VolumeGroupReplication creation"
  kubectl --context=dr1 create namespace "$NAMESPACE" 2>/dev/null || true
  kubectl --context=dr2 create namespace "$NAMESPACE" 2>/dev/null || true

  # Create 3 PVCs with labels for VGR selector
  for i in $(seq 1 $NUM_PVCS); do
    export VGR_NAMESPACE="$NAMESPACE"
    export VGR_PVC_NAME="${PVC_NAME_PREFIX}-$i"
    export VGR_STORAGE_CLASS="$STORAGE_CLASS"
    export VGR_STORAGE_SIZE="1Gi"
    envsubst < "$YAML_DIR/vgr-pvc.yaml" | kubectl --context=dr1 apply -f -
  done

  kubectl --context=dr1 wait --for=jsonpath='{.status.phase}'=Bound "pvc/${PVC_NAME_PREFIX}-1" -n "$NAMESPACE" --timeout=120s
  kubectl --context=dr1 wait --for=jsonpath='{.status.phase}'=Bound "pvc/${PVC_NAME_PREFIX}-2" -n "$NAMESPACE" --timeout=120s
  kubectl --context=dr1 wait --for=jsonpath='{.status.phase}'=Bound "pvc/${PVC_NAME_PREFIX}-3" -n "$NAMESPACE" --timeout=120s

  log_info "Waiting 30s for RBD metadata to settle..."
  sleep 30

  # Create VolumeGroupReplication with source.selector
  export VGR_NAMESPACE="$NAMESPACE"
  export VGR_NAME="$VGR_NAME"
  export VGRCLASS_NAME="$VGRCLASS_NAME"
  export VRC_NAME="$VRC_NAME"
  envsubst < "$YAML_DIR/vgr.yaml" | kubectl --context=dr1 apply -f -

  # Wait for VGR to reach Primary
  local elapsed=0
  while [ $elapsed -lt 300 ]; do
    local state
    state=$(kubectl --context=dr1 get volumegroupreplication "$VGR_NAME" -n "$NAMESPACE" -o jsonpath='{.status.state}' 2>/dev/null || echo "")
    if [[ "$state" == "Primary" ]]; then
      log_success "VolumeGroupReplication reached Primary state"
      return 0
    fi
    log_info "Waiting for VolumeGroupReplication to reach Primary (${elapsed}s/300s) - current: ${state:-<none>}"
    sleep 10
    elapsed=$((elapsed + 10))
  done
  fail "Validation 3: VolumeGroupReplication '$VGR_NAME' did not reach Primary within 300s. Current state: '${state:-<none>}'. VGR controller may not be reconciling (CSI Addons v0.13+ required)." "vgr_primary"
}

# Validation 4: Resources created (VGRC, VRs)
validate_4_resources() {
  log_step "Validation 4: Resources created"
  if ! kubectl --context=dr1 get volumegroupreplication "$VGR_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    fail "Validation 4: VolumeGroupReplication '$VGR_NAME' not found in namespace $NAMESPACE. VGR may have been deleted or never created." "vgrc"
  fi
  local vgrc_count
  vgrc_count=$(kubectl --context=dr1 get volumegroupreplicationcontent -o name 2>/dev/null | wc -l)
  if [[ "${vgrc_count:-0}" -eq 0 ]]; then
    fail "Validation 4: No VolumeGroupReplicationContent (VGRC) found on dr1. VGR controller should create VGRC when reconciling VGR; controller may not be running or not watching VGR." "vgrc"
  fi
  log_success "VolumeGroupReplication and VolumeGroupReplicationContent created"
}

# Validation 5: Replication active
validate_5_replication_active() {
  log_step "Validation 5: Group replication active"
  local state
  state=$(kubectl --context=dr1 get volumegroupreplication "$VGR_NAME" -n "$NAMESPACE" -o jsonpath='{.status.state}' 2>/dev/null || echo "")
  if [[ "$state" != "Primary" ]]; then
    fail "VolumeGroupReplication '$VGR_NAME' state is '$state', expected 'Primary'. Replication may have degraded or been demoted." "vgr_primary"
  fi
  log_success "VolumeGroupReplication active (Primary)"
}

# Validation 6: Data write and read
validate_6_data_write() {
  log_step "Validation 6: Data write and read"
  for i in $(seq 1 $NUM_PVCS); do
    data="VGR Test Data - pvc-$i - $(date)"
    WRITTEN_DATA[$i]="$data"
    kubectl --context=dr1 run "vgr-writer-$i" -n "$NAMESPACE" --restart=Never \
      --image=registry.k8s.io/busybox:1.35 \
      --overrides="{\"spec\":{\"containers\":[{\"name\":\"w\",\"image\":\"registry.k8s.io/busybox:1.35\",\"command\":[\"/bin/sh\",\"-c\",\"echo '$data' > /data/test-file.txt && cat /data/test-file.txt && sleep 3600\"],\"volumeMounts\":[{\"name\":\"data\",\"mountPath\":\"/data\"}]}],\"volumes\":[{\"name\":\"data\",\"persistentVolumeClaim\":{\"claimName\":\"${PVC_NAME_PREFIX}-$i\"}}]}}"
  done

  sleep 15
  for i in $(seq 1 $NUM_PVCS); do
    kubectl --context=dr1 wait --for=condition=Ready "pod/vgr-writer-$i" -n "$NAMESPACE" --timeout=120s || true
    read_back=$(kubectl --context=dr1 exec "vgr-writer-$i" -n "$NAMESPACE" -- cat /data/test-file.txt 2>/dev/null || echo "FAILED")
    if [[ "$read_back" != "${WRITTEN_DATA[$i]}" ]]; then
      fail "Data mismatch on primary PVC ${PVC_NAME_PREFIX}-$i: write/read verification failed. Expected: '${WRITTEN_DATA[$i]}', got: '$read_back'. Pod may not have started or volume not mounted." "data"
    fi
  done
  log_success "Data written and verified on primary"
}

# Validation 7: Cross-cluster replication wait
validate_7_cross_cluster() {
  log_step "Validation 7: Cross-cluster replication"
  log_info "Waiting ${REPLICATION_WAIT_SEC}s for RBD snapshot replication..."
  sleep "$REPLICATION_WAIT_SEC"
  log_success "Replication wait completed"
}

# Validation 8: Failover
validate_8_failover() {
  log_step "Validation 8: Failover"
  kubectl --context=dr1 patch volumegroupreplication "$VGR_NAME" -n "$NAMESPACE" --type='merge' -p='{"spec":{"replicationState":"secondary"}}'

  local elapsed=0
  while [ $elapsed -lt 120 ]; do
    local state
    state=$(kubectl --context=dr1 get volumegroupreplication "$VGR_NAME" -n "$NAMESPACE" -o jsonpath='{.status.state}' 2>/dev/null || echo "")
    if [[ "$state" == "Secondary" ]]; then
      break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  local dr1_pv_name dr1_cluster dr2_cluster
  dr1_pv_name=$(kubectl --context=dr1 get pvc "${PVC_NAME_PREFIX}-1" -n "$NAMESPACE" -o jsonpath='{.spec.volumeName}' 2>/dev/null)
  dr1_cluster=$(kubectl --context=dr1 get pv "$dr1_pv_name" -o jsonpath='{.spec.csi.volumeAttributes.clusterID}' 2>/dev/null)
  dr2_cluster=$(kubectl --context=dr2 -n rook-ceph get configmap rook-ceph-mon-endpoints -o jsonpath='{.data.data}' 2>/dev/null | grep -oP '"clusterID":\s*"\K[^"]+' || echo "")
  if [[ -z "$dr2_cluster" ]]; then
    dr2_cluster=$(kubectl --context=dr2 -n rook-ceph get cephcluster my-cluster -o jsonpath='{.status.ceph.fsid}' 2>/dev/null || echo "")
  fi
  [[ -z "$dr2_cluster" ]] && dr2_cluster="${dr1_cluster:-rook-ceph}"

  for i in $(seq 1 $NUM_PVCS); do
    local pv_name pv_size img vol_handle
    pv_name=$(kubectl --context=dr1 get pvc "${PVC_NAME_PREFIX}-$i" -n "$NAMESPACE" -o jsonpath='{.spec.volumeName}' 2>/dev/null)
    pv_size=$(kubectl --context=dr1 get pv "$pv_name" -o jsonpath='{.spec.capacity.storage}' 2>/dev/null)
    img=$(kubectl --context=dr1 get pv "$pv_name" -o jsonpath='{.spec.csi.volumeAttributes.imageName}' 2>/dev/null)
    vol_handle=$(kubectl --context=dr1 get pv "$pv_name" -o jsonpath='{.spec.csi.volumeHandle}' 2>/dev/null)

    export VGR_DR2_PV_NAME="vgr-pv-dr2-$i"
    export VGR_NAMESPACE="$NAMESPACE"
    export VGR_PVC_NAME="${PVC_NAME_PREFIX}-$i"
    export VGR_STORAGE_SIZE="$pv_size"
    export VGR_DR2_CLUSTER_ID="$dr2_cluster"
    export VGR_RBD_IMAGE_NAME="$img"
    export VGR_VOLUME_HANDLE="$vol_handle"
    export VGR_STORAGE_CLASS="$STORAGE_CLASS"
    export VGR_POOL="replicapool"
    envsubst < "$YAML_DIR/vgr-dr2-pv-pvc.yaml" | kubectl --context=dr2 apply -f -
  done

  kubectl --context=dr2 wait --for=jsonpath='{.status.phase}'=Bound "pvc/${PVC_NAME_PREFIX}-1" -n "$NAMESPACE" --timeout=60s
  kubectl --context=dr2 wait --for=jsonpath='{.status.phase}'=Bound "pvc/${PVC_NAME_PREFIX}-2" -n "$NAMESPACE" --timeout=60s
  kubectl --context=dr2 wait --for=jsonpath='{.status.phase}'=Bound "pvc/${PVC_NAME_PREFIX}-3" -n "$NAMESPACE" --timeout=60s

  # Create VolumeGroupReplication on DR2 (promote)
  export VGR_NAMESPACE="$NAMESPACE"
  export VGR_NAME="$VGR_NAME"
  export VGRCLASS_NAME="$VGRCLASS_NAME"
  export VRC_NAME="$VRC_NAME"
  envsubst < "$YAML_DIR/vgr.yaml" | kubectl --context=dr2 apply -f -
  kubectl --context=dr2 patch volumegroupreplication "$VGR_NAME" -n "$NAMESPACE" --type='merge' -p='{"spec":{"replicationState":"primary"}}' 2>/dev/null || true

  elapsed=0
  while [ $elapsed -lt 120 ]; do
    state=$(kubectl --context=dr2 get volumegroupreplication "$VGR_NAME" -n "$NAMESPACE" -o jsonpath='{.status.state}' 2>/dev/null || echo "")
    if [[ "$state" == "Primary" ]]; then
      log_success "VolumeGroupReplication promoted to Primary on DR2"
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
    fail "Validation 8: VolumeGroupReplication '$VGR_NAME' did not reach Primary on dr2 within 120s (current: '${state:-<none>}'). Failover promote may have failed; check CSI Addons controller on dr2." "failover"
}

# Validation 9: Data consistency
validate_9_data_consistency() {
  log_step "Validation 9: Data consistency"
  for i in $(seq 1 $NUM_PVCS); do
    kubectl --context=dr2 run "vgr-reader-$i" -n "$NAMESPACE" --restart=Never \
      --image=registry.k8s.io/busybox:1.35 \
      --overrides="{\"spec\":{\"containers\":[{\"name\":\"r\",\"image\":\"registry.k8s.io/busybox:1.35\",\"command\":[\"sh\",\"-c\",\"cat /data/test-file.txt && sleep 3600\"],\"volumeMounts\":[{\"name\":\"data\",\"mountPath\":\"/data\"}]}],\"volumes\":[{\"name\":\"data\",\"persistentVolumeClaim\":{\"claimName\":\"${PVC_NAME_PREFIX}-$i\"}}]}}"
  done

  sleep 15
  for i in $(seq 1 $NUM_PVCS); do
    kubectl --context=dr2 wait --for=condition=Ready "pod/vgr-reader-$i" -n "$NAMESPACE" --timeout=120s || true
    read_data=$(kubectl --context=dr2 exec "vgr-reader-$i" -n "$NAMESPACE" -- cat /data/test-file.txt 2>/dev/null || echo "FAILED")
    if [[ "$read_data" != "${WRITTEN_DATA[$i]}" ]]; then
      fail "Data mismatch on DR2 PVC ${PVC_NAME_PREFIX}-$i: expected '${WRITTEN_DATA[$i]}', got '$read_data'. Replication may not have synced before failover, or wrong image promoted." "data"
    fi
  done
  log_success "Data identical on secondary after failover"
}

# Validation 10: Cleanup
validate_10_cleanup() {
  log_step "Validation 10: Cleanup"
  log_success "Cleanup will run on exit"
}

# Main
echo "=== CSI VolumeGroupReplication (VGR) Validation ==="
echo "Flow: VolumeGroupReplication with source.selector; controller creates VGRC and per-volume VRs"
echo ""

validate_1_crds
validate_2_classes
validate_3_creation
validate_4_resources
validate_5_replication_active
validate_6_data_write
validate_7_cross_cluster
validate_8_failover
validate_9_data_consistency
validate_10_cleanup

echo ""
log_success "All 10 validations passed!"
echo ""
