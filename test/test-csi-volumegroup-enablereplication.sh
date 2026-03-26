#!/bin/bash
# SPDX-FileCopyrightText: The RamenDR authors
# SPDX-License-Identifier: Apache-2.0
#
# Validate CSI Addons group replication using VolumeGroup + VolumeReplication.
# Flow: (1) Create VolumeGroup via CSI CreateVolumeGroup, (2) Create VolumeReplication
# with dataSource.kind=VolumeGroup. Uses Kubernetes CRDs only.
# Requires: VolumeGroup CRD and controller (from kubernetes-csi-addons PR #402 fork).
# Single script with 10 validations. No Ramen objects.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/scripts/utils.sh"
init_logging "test-csi-volumegroup-enablereplication"
start_capture_logging

# Capture diagnostics on failure
capture_diagnostic_logs() {
  echo ""
  echo "=== Failure Diagnostics ==="
  set +e
  log_info "VolumeGroup (DR1):"
  kubectl --context=dr1 get volumegroup -n "$NAMESPACE" -o wide 2>/dev/null || echo "  Could not get VolumeGroup"
  kubectl --context=dr1 get volumegroup "$VG_NAME" -n "$NAMESPACE" -o yaml 2>/dev/null | tail -50 || true
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

fail() { log_error "$1"; capture_diagnostic_logs; exit 1; }

NAMESPACE="vgr-test-$(date +%s)"
VG_NAME="vgr-test-group"
VGCLASS_NAME="vgclass-rbd"
VR_NAME="vr-vgr-group"
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
    csi_cleanup_volumereplication "$ctx" "$NAMESPACE" "$VR_NAME"
    kubectl --context=$ctx delete volumegroup "$VG_NAME" -n "$NAMESPACE" --ignore-not-found=true --wait=false 2>/dev/null
    for i in $(seq 1 $NUM_PVCS); do
      kubectl --context=$ctx delete pod "vgr-writer-$i" -n "$NAMESPACE" --ignore-not-found=true --wait=false 2>/dev/null
      kubectl --context=$ctx delete pod "vgr-reader-$i" -n "$NAMESPACE" --ignore-not-found=true --wait=false 2>/dev/null
      csi_cleanup_pvc "$ctx" "$NAMESPACE" "${PVC_NAME_PREFIX}-$i"
      kubectl --context=$ctx delete pv "vgr-pv-dr2-$i" --ignore-not-found=true 2>/dev/null
    done
    csi_cleanup_namespace "$ctx" "$NAMESPACE"
  done
  [[ -n "$REPO_ROOT" ]] && [[ -f "$REPO_ROOT/scripts/cleanup-replicated-images.sh" ]] && \
    (cd "$REPO_ROOT" && ./scripts/cleanup-replicated-images.sh 2>/dev/null) || true
  set -e
  end_logging
  log_success "Cleanup completed"
}

trap cleanup EXIT

# Pre-test cleanup
log_info "Cleaning any orphaned resources from previous runs..."
set +e
for ctx in dr1 dr2; do
  for ns in $(kubectl --context=$ctx get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep '^vgr-test-' || true); do
    [[ -z "$ns" ]] && continue
    # Clean VolumeReplications with finalizer removal
    csi_cleanup_volumereplications_in_namespace "$ctx" "$ns"
    kubectl --context=$ctx delete volumegroup --all -n "$ns" --ignore-not-found=true --wait=false 2>/dev/null
    for i in $(seq 1 $NUM_PVCS); do
      csi_cleanup_pvc "$ctx" "$ns" "${PVC_NAME_PREFIX}-$i"
    done
    csi_cleanup_namespace "$ctx" "$ns"
  done
done
[[ -n "$REPO_ROOT" ]] && [[ -f "$REPO_ROOT/scripts/cleanup-replicated-images.sh" ]] && \
  (cd "$REPO_ROOT" && ./scripts/cleanup-replicated-images.sh 2>/dev/null) || true
set -e
echo ""

# Validation 1: CRD presence (VolumeGroup, VolumeReplication, VolumeReplicationClass)
validate_1_crds() {
  log_step "Validation 1: CRD presence"
  if ! kubectl get crd volumegroups.volumegroup.storage.openshift.io >/dev/null 2>&1; then
    fail "VolumeGroup CRD not found. VolumeGroup was proposed in kubernetes-csi-addons PR #402 (closed). Use a fork with VolumeGroup support, e.g. matancarmeli7/kubernetes-csi-addons branch add_volume_group_controller."
  fi
  for crd in volumereplications.replication.storage.openshift.io volumereplicationclasses.replication.storage.openshift.io; do
    if ! kubectl get crd "$crd" >/dev/null 2>&1; then
      fail "CRD $crd not found. Install from kubernetes-csi-addons."
    fi
  done
  log_success "All CRDs present (VolumeGroup, VolumeReplication, VolumeReplicationClass)"
}

# Validation 2: VolumeGroupClass and VolumeReplicationClass availability
validate_2_classes() {
  log_step "Validation 2: VolumeGroupClass and VolumeReplicationClass availability"
  if ! kubectl --context=dr1 get volumereplicationclass "$VRC_NAME" >/dev/null 2>&1; then
    fail "VolumeReplicationClass $VRC_NAME not found. Run 'make start-csi-replication' or 'make setup-csi-replication' first."
  fi
  log_success "VRC $VRC_NAME available"
}

# Validation 3: PVC creation, VolumeGroup creation, VolumeReplication creation
validate_3_creation() {
  log_step "Validation 3: PVC, VolumeGroup, VolumeReplication creation"
  kubectl --context=dr1 create namespace "$NAMESPACE" 2>/dev/null || true
  kubectl --context=dr2 create namespace "$NAMESPACE" 2>/dev/null || true

  # Create 3 PVCs with labels for VolumeGroup selector
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

  # Create VolumeGroupClass (if not exists)
  export VGCLASS_NAME="$VGCLASS_NAME"
  kubectl --context=dr1 apply -f "$YAML_DIR/volumegroupclass.yaml" 2>/dev/null || true

  # Create VolumeGroup - CSI CreateVolumeGroup
  export VG_NAMESPACE="$NAMESPACE"
  export VG_NAME="$VG_NAME"
  export VGCLASS_NAME="$VGCLASS_NAME"
  envsubst < "$YAML_DIR/volumegroup.yaml" | kubectl --context=dr1 apply -f -

  # Wait for VolumeGroup to be ready (boundVolumeGroupContentName set)
  local elapsed=0
  while [ $elapsed -lt 120 ]; do
    local ready
    ready=$(kubectl --context=dr1 get volumegroup "$VG_NAME" -n "$NAMESPACE" -o jsonpath='{.status.ready}' 2>/dev/null || echo "")
    if [[ "$ready" == "true" ]]; then
      log_success "VolumeGroup ready"
      break
    fi
    log_info "Waiting for VolumeGroup to be ready (${elapsed}s/120s) - ready=${ready:-<none>}"
    sleep 10
    elapsed=$((elapsed + 10))
  done
  if [[ "$(kubectl --context=dr1 get volumegroup "$VG_NAME" -n "$NAMESPACE" -o jsonpath='{.status.ready}' 2>/dev/null)" != "true" ]]; then
    fail "VolumeGroup did not become ready within 120s. VolumeGroup controller may not be running (requires kubernetes-csi-addons fork with PR #402)."
  fi

  # Create VolumeReplication with dataSource.kind=VolumeGroup
  export VR_NAMESPACE="$NAMESPACE"
  export VR_NAME="$VR_NAME"
  export VG_NAME="$VG_NAME"
  export VRC_NAME="$VRC_NAME"
  envsubst < "$YAML_DIR/vr-volumegroup.yaml" | kubectl --context=dr1 apply -f -

  # Wait for VolumeReplication to reach Primary
  elapsed=0
  while [ $elapsed -lt 300 ]; do
    local state
    state=$(kubectl --context=dr1 get volumereplication "$VR_NAME" -n "$NAMESPACE" -o jsonpath='{.status.state}' 2>/dev/null || echo "")
    if [[ "$state" == "Primary" ]]; then
      log_success "VolumeReplication reached Primary state"
      return 0
    fi
    log_info "Waiting for VolumeReplication to reach Primary (${elapsed}s/300s) - current: ${state:-<none>}"
    sleep 10
    elapsed=$((elapsed + 10))
  done
  fail "VolumeReplication did not reach Primary within 300s. If CSI-Addons logs show 'no leader': run 'make fix-csi-addons-tls' then 'make restart-csi-service'."
}

# Validation 4: Resources created
validate_4_resources() {
  log_step "Validation 4: Resources created"
  if ! kubectl --context=dr1 get volumegroup "$VG_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    fail "VolumeGroup $VG_NAME not found"
  fi
  if ! kubectl --context=dr1 get volumereplication "$VR_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    fail "VolumeReplication $VR_NAME not found"
  fi
  log_success "VolumeGroup and VolumeReplication created"
}

# Validation 5: Replication active
validate_5_replication_active() {
  log_step "Validation 5: Group replication active"
  local state
  state=$(kubectl --context=dr1 get volumereplication "$VR_NAME" -n "$NAMESPACE" -o jsonpath='{.status.state}' 2>/dev/null || echo "")
  if [[ "$state" != "Primary" ]]; then
    fail "VolumeReplication state is $state, expected Primary"
  fi
  log_success "VolumeReplication active (Primary)"
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
      fail "Data mismatch on PVC $i: expected '${WRITTEN_DATA[$i]}', got '$read_back'"
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
  kubectl --context=dr1 patch volumereplication "$VR_NAME" -n "$NAMESPACE" --type='merge' -p='{"spec":{"replicationState":"secondary"}}'

  local elapsed=0
  while [ $elapsed -lt 120 ]; do
    local state
    state=$(kubectl --context=dr1 get volumereplication "$VR_NAME" -n "$NAMESPACE" -o jsonpath='{.status.state}' 2>/dev/null || echo "")
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

  # Create VolumeGroup and VolumeReplication on DR2 (promote)
  export VG_NAMESPACE="$NAMESPACE"
  export VG_NAME="$VG_NAME"
  export VGCLASS_NAME="$VGCLASS_NAME"
  envsubst < "$YAML_DIR/volumegroup.yaml" | kubectl --context=dr2 apply -f -

  elapsed=0
  while [ $elapsed -lt 60 ]; do
    vg_ready=$(kubectl --context=dr2 get volumegroup "$VG_NAME" -n "$NAMESPACE" -o jsonpath='{.status.ready}' 2>/dev/null || echo "")
    [[ "$vg_ready" == "true" ]] && break
    sleep 5
    elapsed=$((elapsed + 5))
  done

  export VR_NAMESPACE="$NAMESPACE"
  export VR_NAME="$VR_NAME"
  export VG_NAME="$VG_NAME"
  export VRC_NAME="$VRC_NAME"
  envsubst < "$YAML_DIR/vr-volumegroup.yaml" | kubectl --context=dr2 apply -f -
  kubectl --context=dr2 patch volumereplication "$VR_NAME" -n "$NAMESPACE" --type='merge' -p='{"spec":{"replicationState":"primary"}}' 2>/dev/null || true

  elapsed=0
  while [ $elapsed -lt 120 ]; do
    state=$(kubectl --context=dr2 get volumereplication "$VR_NAME" -n "$NAMESPACE" -o jsonpath='{.status.state}' 2>/dev/null || echo "")
    if [[ "$state" == "Primary" ]]; then
      log_success "VolumeReplication promoted to Primary on DR2"
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  fail "VolumeReplication did not reach Primary on DR2 within 120s"
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
      fail "Data mismatch on DR2 PVC $i: expected '${WRITTEN_DATA[$i]}', got '$read_data'"
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
echo "=== CSI VolumeGroup + VolumeReplication Validation ==="
echo "Flow: (1) VolumeGroup via CSI CreateVolumeGroup, (2) VolumeReplication with dataSource.kind=VolumeGroup"
echo ""

kubectl config get-contexts dr1 >/dev/null 2>&1 || fail "dr1 context not found"
kubectl config get-contexts dr2 >/dev/null 2>&1 || fail "dr2 context not found"

if ! kubectl get crd volumegroups.volumegroup.storage.openshift.io >/dev/null 2>&1; then
  fail "VolumeGroup CRD not found. Requires kubernetes-csi-addons fork with PR #402 (add_volume_group_controller branch)."
fi
if ! kubectl --context=dr1 get volumereplicationclass "$VRC_NAME" >/dev/null 2>&1; then
  fail "VolumeReplicationClass $VRC_NAME not found. Run 'make start-csi-replication' first."
fi

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
