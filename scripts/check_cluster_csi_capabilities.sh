#!/usr/bin/env bash
# SPDX-FileCopyrightText: The RamenDR authors
# SPDX-License-Identifier: Apache-2.0
#
# Check cluster CSI capabilities: NetworkFence, CSI replication addon, VolumeGroupReplication.
#
# DESCRIPTION:
#   This script analyzes a Kubernetes cluster to detect and validate CSI (Container Storage Interface)
#   capabilities required for disaster recovery operations. It checks for NetworkFence capabilities,
#   CSI Replication Addon support, and VolumeGroupReplication functionality.
#
# PREREQUISITES:
#   - kubectl: Kubernetes command-line tool must be installed and configured
#   - kubeconfig: Valid Kubernetes configuration with cluster access
#   - Cluster access: Read permissions for CRDs, pods, deployments, and CSIAddonsNode objects
#   - jq: JSON processor for parsing kubectl output
#   - Standard Unix tools: awk, sort, sed
#
# CLUSTER REQUIREMENTS:
#   - Kubernetes cluster with CSI drivers deployed
#   - For NetworkFence: NetworkFence/NetworkFenceClass CRDs, CSIAddonsNode CRD
#   - For Replication: kubernetes-csi-addons controller, VolumeReplication CRDs
#   - For VolumeGroupReplication: VGR CRDs, csi-addons sidecar containers
#
# USAGE:
#   ./check_cluster_csi_capabilities.sh [OPTIONS]
#
# OPTIONS:
#   --mode MODE     Specify which capabilities to check:
#                   networkfence           - Check NetworkFence capabilities (default)
#                   replication           - Check CSI Replication Addon
#                   volumegroupreplication - Check VolumeGroupReplication
#                   all                   - Check all capabilities
#   --detailed      Show detailed information (CSIAddonsNode details, container images, etc.)
#   --help, -h      Display this help message
#
# ENVIRONMENT VARIABLES:
#   CHECK_MODE      Override --mode option (networkfence|replication|volumegroupreplication|all)
#   POD_HINT        Filter pods by regex pattern to reduce output (optional)
#
# EXAMPLES:
#   # Check NetworkFence capabilities (default)
#   ./check_cluster_csi_capabilities.sh
#
#   # Check all capabilities with detailed output
#   ./check_cluster_csi_capabilities.sh --mode all --detailed
#
#   # Check only VolumeGroupReplication
#   ./check_cluster_csi_capabilities.sh --mode volumegroupreplication
#
#   # Use environment variable to set mode
#   CHECK_MODE=replication ./check_cluster_csi_capabilities.sh
#
# EXIT CODES:
#   0 - All checks passed successfully
#   1 - One or more capability checks failed
#   2 - Invalid arguments or missing prerequisites

set -euo pipefail

DETAILED=false

show_help() {
  cat << 'EOF'
check_cluster_csi_capabilities.sh - CSI Capability Detection Tool

DESCRIPTION:
  Analyzes a Kubernetes cluster to detect and validate CSI capabilities required
  for disaster recovery operations including NetworkFence, CSI Replication, and
  VolumeGroupReplication functionality.

PREREQUISITES:
  Before running this script, ensure you have:

  1. kubectl installed and in PATH
     - Install: https://kubernetes.io/docs/tasks/tools/

  2. Valid kubeconfig with cluster access
     - Set context: kubectl config use-context <context-name>
     - Verify access: kubectl get nodes

  3. Required cluster permissions:
     - Read access to: CRDs, pods, deployments, CSIAddonsNode objects
     - Namespace access: all namespaces (or specific CSI/storage namespaces)

  4. Additional tools (usually pre-installed):
     - jq (JSON processor)
     - awk, sort, sed (standard Unix tools)

CLUSTER SETUP:
  The script detects capabilities in clusters with:

  - CSI drivers deployed (e.g., Rook/Ceph, other storage providers)
  - kubernetes-csi-addons controller (for replication features)
  - CSI-addons sidecar containers (for advanced capabilities)
  - Relevant CRDs installed (NetworkFence, VolumeReplication, etc.)

USAGE:
  check_cluster_csi_capabilities.sh [OPTIONS]

OPTIONS:
  --mode MODE        Capabilities to check:
                     networkfence (default) - NetworkFence support
                     replication           - CSI Replication Addon
                     volumegroupreplication - VolumeGroupReplication
                     all                   - All capabilities

  --detailed         Show additional details:
                     - Full CSIAddonsNode capability strings
                     - Container image information
                     - Controller deployment status

  --help, -h         Show this help message

ENVIRONMENT:
  CHECK_MODE         Override --mode (networkfence|replication|volumegroupreplication|all)
  POD_HINT          Filter pods by regex pattern (reduces output)

EXAMPLES:
  # Basic NetworkFence check
  ./check_cluster_csi_capabilities.sh

  # Comprehensive check with details
  ./check_cluster_csi_capabilities.sh --mode all --detailed

  # Check specific capability
  ./check_cluster_csi_capabilities.sh --mode volumegroupreplication

  # Filter pods during check
  POD_HINT="rook" ./check_cluster_csi_capabilities.sh --mode all

TROUBLESHOOTING:
  - "kubectl has no current context": Run 'kubectl config use-context <context>'
  - "kubectl cannot reach API server": Check network connectivity and credentials
  - "missing required command": Install missing tools (kubectl, jq)
  - Empty results: Verify CSI drivers and addons are deployed in cluster

EXIT CODES:
  0  Success - All requested capabilities detected and configured
  1  Failure - Missing capabilities, CRDs, or configuration issues
  2  Error   - Invalid arguments, missing tools, or cluster connectivity

For more information, visit:
  https://github.com/RamenDR/ramen/tree/main/docs

EOF
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing required command: $1" >&2; exit 1; }; }
need_cmd kubectl
need_cmd jq
need_cmd awk
need_cmd sort
need_cmd sed

# Optional: set to reduce pod output (regex-like string used by jq test(...;"i"))
POD_HINT="${POD_HINT:-}"

# CSI-Addons capability patterns (used in jq with ascii_downcase, so patterns are lowercase)
CAP_REPLICATION="replication"
CAP_NETWORK_FENCE="network_fence"
CAP_GET_CLIENTS_TO_FENCE="get_clients_to_fence"
CAP_VOLUME_GROUP="volume_group\\.volume_group"
CAP_VOLUME_REPLICATION="volume_replication\\.volume_replication"

# Parse arguments
CHECK_MODE="${CHECK_MODE:-networkfence}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      CHECK_MODE="$2"
      shift 2
      ;;
    --detailed)
      DETAILED=true
      shift
      ;;
    --help|-h)
      show_help
      exit 0
      ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      echo "Usage: $0 [--mode networkfence|replication|volumegroupreplication|all] [--detailed] [--help]" >&2
      echo "Run '$0 --help' for detailed usage information." >&2
      exit 2
      ;;
  esac
done

case "$CHECK_MODE" in
  networkfence|replication|volumegroupreplication|all) ;;
  *)
    echo "ERROR: invalid --mode '$CHECK_MODE'. Must be: networkfence, replication, volumegroupreplication, or all" >&2
    exit 2
    ;;
esac

EXIT_CODE=0

# Helper: Detect capabilities in CSIAddonsNode objects
# Usage: detect_capability_in_csiaddonsnode <capability_pattern> <csiaddonsnode_crd>
# Returns: JSON array with {capability, driver} objects, empty array if none found
detect_capability_in_csiaddonsnode() {
  local cap_pattern="$1"
  local csiaddonsnode_crd="$2"

  if [[ -z "${csiaddonsnode_crd}" || "${csiaddonsnode_crd}" == "null" ]]; then
    echo "WARNING: csiaddonsnode_crd parameter is empty or null. Cannot detect capabilities." >&2
    echo "[]"
    return 0
  fi

  local nodes_json
  nodes_json="$(kubectl get "${csiaddonsnode_crd}" -A -o json 2>/dev/null)"

  # Emit a single JSON array (not NDJSON) so callers can pipe to jq '.[]'
  echo "$nodes_json" | jq -c --arg pattern "$cap_pattern" '
    [
      .items[]
      | . as $n
      | ($n.status.capabilities // [])
      | map(
          if type == "string" then
            {capability: ., driver: ($n.spec.driver.name // "-")}
          else
            {capability: (.name // . | tostring), driver: ($n.spec.driver.name // "-")}
          end
        )
      | map(select(.capability | ascii_downcase | test($pattern)))
      | .[]
    ]
  ' 2>/dev/null
}

# RBD CSI pods (node DaemonSet and provisioner Deployment) that include a csi-addons container
list_rbd_pods_with_csi_addons_sidecar() {
  kubectl get pods -A -o json 2>/dev/null | jq -r '
    .items[]
    | select(.metadata.name | test("csi-rbdplugin"))
    | . as $p
    | ($p.spec.containers // []) | map(.name) as $names
    | select($names | length > 0)
    | select($names | map(ascii_downcase) | any(test("csi-addons")))
    | "\($p.metadata.namespace)\t\($p.metadata.name)\t\($names | join(","))"
  ' 2>/dev/null | sort -u
}

print_vgr_sidecar_summary() {
  echo
  echo "## RBD CSI pods: csi-addons sidecar (node + provisioner)"
  local lines
  lines="$(list_rbd_pods_with_csi_addons_sidecar)"
  if [[ -z "${lines}" ]]; then
    echo "RESULT: No pod matching name /csi-rbdplugin/i with a csi-addons container."
    echo "        VolumeGroupReplication needs the csi-addons sidecar next to rook-ceph.rbd.csi.ceph.com."
    EXIT_CODE=1
  else
    echo "OK: Pods with csi-rbdplugin name and csi-addons container:"
    echo "${lines}" | while IFS=$'\t' read -r ns name containers; do
      echo "  - ${ns}/${name} :: ${containers}"
    done
  fi
}

print_csiaddonsnode_vgr_table() {
  local csiaddonsnode_crd="$1"
  echo
  echo "## CSIAddonsNode objects (controller discovers sidecars here)"
  if [[ -z "${csiaddonsnode_crd}" || "${csiaddonsnode_crd}" == "null" ]]; then
    echo "SKIP: CSIAddonsNode CRD not installed."
    return
  fi
  local count
  count="$(kubectl get "${csiaddonsnode_crd}" -A -o json 2>/dev/null | jq '.items | length')"
  if [[ "${count}" -eq 0 ]]; then
    echo "RESULT: 0 CSIAddonsNode — kubernetes-csi-addons cannot route VolumeReplication/VGR RPCs."
    echo "        Fix: ensure sidecar registers nodes (RBAC, TLS), or apply valid CSIAddonsNode + restart CSI pods."
    EXIT_CODE=1
    return
  fi
  echo "OK: ${count} CSIAddonsNode object(s). Summary:"
  kubectl get "${csiaddonsnode_crd}" -A -o custom-columns=\
'NAMESPACE:.metadata.namespace,NAME:.metadata.name,DRIVER:.spec.driver.name,STATE:.status.state,ENDPOINT:.spec.driver.endpoint' \
    2>/dev/null | sed 's/^/  /'
  echo
  echo "  Per-node capabilities (replication / volume_group + volume_replication):"
  kubectl get "${csiaddonsnode_crd}" -A -o json 2>/dev/null | jq -r \
    --arg cap_repl "$CAP_REPLICATION" \
    --arg cap_vg "$CAP_VOLUME_GROUP" \
    --arg cap_vgr "$CAP_VOLUME_REPLICATION" '
    .items[]
    | . as $n
    | ($n.status.capabilities // []) as $caps
    | ($caps | map(ascii_downcase)) as $lc
    | [
        ($n.metadata.namespace // "-"),
        ($n.metadata.name // "-"),
        ($n.spec.driver.name // "-"),
        (($lc | any(test($cap_repl))) | tostring),
        ((($lc | any(test($cap_vg))) and ($lc | any(test($cap_vgr)))) | tostring)
      ]
    | @tsv
  ' | awk -F'\t' 'BEGIN{printf "  %-20s %-40s %-35s %-12s %s\n","NAMESPACE","NAME","DRIVER","REPLICATION","VGR_CAP"; print "  " "------------------------------------------------------------------------------------------"}
{printf "  %-20s %-40s %-35s %-12s %s\n",$1,$2,$3,$4,$5}'
}

print_vgr_detailed_extras() {
  local csiaddonsnode_crd="$1"
  if [[ -z "${csiaddonsnode_crd}" || "${csiaddonsnode_crd}" == "null" ]]; then
    echo
    echo "## Detailed: skipped (CSIAddonsNode CRD not installed)"
    return
  fi
  echo
  echo "## Detailed: full capability strings per CSIAddonsNode"
  kubectl get "${csiaddonsnode_crd}" -A -o json 2>/dev/null | jq -r '
    .items[]
    | "--- \(.metadata.namespace)/\(.metadata.name) driver=\(.spec.driver.name // "-") ---",
      (.status.capabilities // [])[]?
  ' | sed 's/^/  /'

  echo
  echo "## Detailed: csi-addons container image(s) on RBD CSI pods"
  while IFS=$'\t' read -r ns name _containers; do
    [[ -z "${ns}" ]] && continue
    img="$(kubectl get pod -n "$ns" "$name" -o jsonpath='{range .spec.containers[*]}{.name}{"="}{.image}{"\n"}{end}' 2>/dev/null | grep -i 'csi-addons' || true)"
    [[ -n "${img}" ]] && echo "  ${ns}/${name}: ${img}"
  done < <(list_rbd_pods_with_csi_addons_sidecar)

  echo
  echo "## Detailed: kubernetes-csi-addons controller"
  local found=false
  for ns in csi-addons-system openshift-storage; do
    if kubectl get deploy -n "$ns" csi-addons-controller-manager >/dev/null 2>&1; then
      found=true
      echo "  OK: deployment/csi-addons-controller-manager in namespace ${ns}"
      kubectl get deploy -n "$ns" csi-addons-controller-manager -o jsonpath='    images: {.spec.template.spec.containers[*].image}{"\n"}' 2>/dev/null
    fi
  done
  if [[ "${found}" == "false" ]]; then
    echo "  RESULT: csi-addons-controller-manager not found in csi-addons-system or openshift-storage."
    echo "           VGR CRs are reconciled by kubernetes-csi-addons; install the controller if missing."
    EXIT_CODE=1
  fi
}

print_vgr_configuration_verdict() {
  local csiaddonsnode_crd="$1"
  echo
  echo "## VolumeGroupReplication configuration verdict"
  if [[ -z "${csiaddonsnode_crd}" || "${csiaddonsnode_crd}" == "null" ]]; then
    echo "  FAIL: CSIAddonsNode CRD missing."
    return
  fi
  local ncount rbd_nodes repl_nodes vgr_nodes pod_lines
  ncount="$(kubectl get "${csiaddonsnode_crd}" -A -o json 2>/dev/null | jq '.items | length')"
  rbd_nodes="$(kubectl get "${csiaddonsnode_crd}" -A -o json 2>/dev/null | jq '[.items[] | select(.spec.driver.name == "rook-ceph.rbd.csi.ceph.com")] | length')"
  repl_nodes="$(kubectl get "${csiaddonsnode_crd}" -A -o json 2>/dev/null | jq '
    [.items[] | select((.status.capabilities // []) | map(ascii_downcase) | any(test("replication")))] | length
  ')"
  vgr_nodes="$(kubectl get "${csiaddonsnode_crd}" -A -o json 2>/dev/null | jq \
    --arg cap_vg "$CAP_VOLUME_GROUP" \
    --arg cap_vgr "$CAP_VOLUME_REPLICATION" '
    [.items[] | select(((.status.capabilities // []) | map(ascii_downcase) | any(test($cap_vg))) and ((.status.capabilities // []) | map(ascii_downcase) | any(test($cap_vgr))))] | length
  ')"
  pod_lines="$(list_rbd_pods_with_csi_addons_sidecar | wc -l)"

  if [[ "${pod_lines}" -gt 0 ]]; then
    echo "  OK: RBD CSI pod(s) include csi-addons sidecar (${pod_lines})."
  else
    echo "  FAIL: No RBD CSI pod with csi-addons sidecar."
  fi
  if [[ "${ncount}" -gt 0 ]]; then
    echo "  OK: ${ncount} CSIAddonsNode object(s) registered."
  else
    echo "  FAIL: No CSIAddonsNode objects (sidecar not publishing or wrong API/TLS/RBAC)."
  fi
  if [[ "${rbd_nodes}" -gt 0 ]]; then
    echo "  OK: ${rbd_nodes} CSIAddonsNode for rook-ceph.rbd.csi.ceph.com."
  else
    echo "  WARN: No CSIAddonsNode for rook-ceph.rbd.csi.ceph.com (driver name mismatch or not registered)."
  fi
  if [[ "${repl_nodes}" -gt 0 ]]; then
    echo "  OK: ${repl_nodes} node(s) advertise replication capability."
  else
    echo "  FAIL: No CSIAddonsNode advertises replication (VGR depends on replication RPCs)."
  fi
  if [[ "${vgr_nodes}" -gt 0 ]]; then
    echo "  OK: ${vgr_nodes} node(s) advertise both volume_group.VOLUME_GROUP and volume_replication.VOLUME_REPLICATION."
  else
    echo "  FAIL: No CSIAddonsNode advertises both required capabilities (volume_group + volume_replication)."
  fi
}

check_kubectl_connectivity() {
  echo
  echo "## 0) kubectl connectivity"
  
  # Check if kubeconfig exists
  if [[ ! -f "${KUBECONFIG:-$HOME/.kube/config}" ]]; then
    echo "ERROR: kubeconfig file not found."
    echo "Expected location: ${KUBECONFIG:-$HOME/.kube/config}"
    echo "Fix: Ensure kubectl is configured with 'kubectl config use-context <context>'"
    exit 2
  fi
  
  # Check current context
  ctx="$(kubectl config current-context 2>/dev/null || true)"
  if [[ -z "${ctx}" ]]; then
    echo "ERROR: kubectl has no current context."
    echo "Available contexts:"
    kubectl config get-contexts --no-headers 2>/dev/null | awk '{print "  - " $2}' || echo "  (none found)"
    echo "Fix: kubectl config use-context <context>"
    exit 2
  fi
  echo "Context: ${ctx}"
  
  # Check API server connectivity
  echo "Testing API server connectivity..."
  if ! kubectl version --request-timeout=10s >/dev/null 2>&1; then
    echo "ERROR: kubectl cannot reach the API server for context '${ctx}'."
    echo "Possible causes:"
    echo "  - Network connectivity issues"
    echo "  - Invalid or expired credentials"
    echo "  - Cluster is down or unreachable"
    echo "  - Firewall blocking access"
    echo "Debug: Try 'kubectl cluster-info' for more details"
    exit 2
  fi
  echo "OK: API reachable."
  
  # Check basic permissions
  if ! kubectl auth can-i get crd >/dev/null 2>&1; then
    echo "WARNING: Limited permissions detected. Some checks may fail."
    echo "Required permissions: get access to CRDs, pods, deployments"
  fi
}

check_networkfence() {
  echo
  echo "== NetworkFence / CSI-Addons detection =="
  echo
  echo "## 1) Installed CSI drivers (CSIDriver objects)"
  if kubectl get csidriver >/dev/null 2>&1; then
    kubectl get csidriver -o json \
      | jq -r '.items[] | [.metadata.name, (.spec.attachRequired|tostring), (.spec.podInfoOnMount|tostring)] | @tsv' \
      | awk -F'\t' '
BEGIN{printf "%-50s %-14s %-14s\n","DRIVER","attachRequired","podInfoOnMount"; print "-------------------------------------------------------------------------------------------"}
{printf "%-50s %-14s %-14s\n",$1,$2,$3}
'
  else
    echo "RESULT: No CSIDriver objects found."
  fi

  echo
  echo "## 2) CRD presence (NetworkFence, NetworkFenceClass, CSIAddonsNode)"
  crds_json="$(kubectl get crd -o json)"

  nf_crds="$(echo "$crds_json" | jq -r '.items[] | select(.metadata.name|test("(^|\\.)networkfences\\."; "i")) | .metadata.name')"
  nfc_crds="$(echo "$crds_json" | jq -r '.items[] | select(.metadata.name|test("(^|\\.)networkfenceclasses\\."; "i")) | .metadata.name')"
  csiaddonsnode_crd="$(echo "$crds_json" | jq -r '.items[] | select(.metadata.name|test("(^|\\.)csiaddonsnodes\\."; "i")) | .metadata.name' | head -n 1)"

  if [[ -z "${nf_crds}" && -z "${nfc_crds}" ]]; then
    echo "RESULT: NetworkFence CRDs not found."
    EXIT_CODE=1
  else
    echo "OK: NetworkFence CRD(s):"
    [[ -n "${nf_crds}" ]]  && echo "${nf_crds}"  | sed 's/^/  - /'
    [[ -n "${nfc_crds}" ]] && echo "${nfc_crds}" | sed 's/^/  - /'
  fi

  if [[ -z "${csiaddonsnode_crd}" || "${csiaddonsnode_crd}" == "null" ]]; then
    echo "RESULT: CSIAddonsNode CRD not found."
    EXIT_CODE=1
  else
    echo "OK: CSIAddonsNode CRD: ${csiaddonsnode_crd}"
  fi

  echo
  echo "## 3) Heuristic check: is csi-addons sidecar deployed in any pods?"
  pods_json="$(kubectl get pods -A -o json)"

  if [[ -n "${POD_HINT}" ]]; then
    pods_json="$(echo "$pods_json" | jq --arg hint "${POD_HINT}" '
      .items |= map(select((.metadata.name//"")|test($hint;"i") or (.metadata.namespace//"")|test($hint;"i")))
    ')"
    echo "Applied POD_HINT filter: ${POD_HINT}"
  fi

  sidecar_pods="$(echo "$pods_json" | jq -r '
    .items[]
    | . as $p
    | ($p.spec.containers // []) | map(.name) as $names
    | select($names | any(test("csi(-|)?addons"; "i")))
    | "\($p.metadata.namespace)/\($p.metadata.name) :: containers=" + ($names | join(","))
  ' | sort -u)"

  if [[ -z "${sidecar_pods}" ]]; then
    echo "RESULT: No pods found with container name matching /csi[-]?addons/i."
    EXIT_CODE=1
  else
    echo "OK: Found pods with csi-addons sidecar:"
    echo "${sidecar_pods}" | sed 's/^/  - /'
  fi

  echo
  echo "## 4) Per-driver NetworkFence summary via CSIAddonsNode"
  if [[ -z "${csiaddonsnode_crd}" || "${csiaddonsnode_crd}" == "null" ]]; then
    echo "SKIP: CSIAddonsNode CRD is not installed."
  else
    resource="${csiaddonsnode_crd}"
    nodes_json="$(kubectl get "${resource}" -A -o json)"
    count="$(echo "$nodes_json" | jq '.items | length')"

    if [[ "$count" -eq 0 ]]; then
      echo "RESULT: ${resource} exists but there are 0 CSIAddonsNode objects."
      EXIT_CODE=1
    else
      echo "OK: Found ${count} CSIAddonsNode object(s)."
      echo "$nodes_json" | jq -r '
        .items[]
        | {
            driver: (.spec.driver.name // "-"),
            caps: (.status.capabilities // [])
          }
        | .driver as $d
        | [
            $d,
            ((.caps | map(ascii_downcase) | any(test("network_fence\\.network_fence|network_fence.*network_fence"))) | tostring),
            ((.caps | map(ascii_downcase) | any(test("network_fence\\.get_clients_to_fence|get_clients_to_fence"))) | tostring)
          ]
        | @tsv
      ' | awk -F'\t' '
      {
        d=$1; nf=$2; gc=$3;
        if (!(d in seen)) { seen[d]=1; has_nf[d]=nf; has_gc[d]=gc; }
        else {
          if (nf=="true") has_nf[d]="true";
          if (gc=="true") has_gc[d]="true";
        }
      }
      END{
        printf "%-45s %-18s %-22s\n","DRIVER","NETWORK_FENCE_RPC","GET_CLIENTS_TO_FENCE"
        print "---------------------------------------------------------------------------------------------------------------"
        for (d in seen) printf "%-45s %-18s %-22s\n", d, has_nf[d], has_gc[d]
      }
      ' | sort
    fi
  fi

  echo
  echo "== NetworkFence notes =="
  echo "- NETWORK_FENCE_RPC=true means the driver advertises fence/unfence support via CSI-Addons."
  echo "- GET_CLIENTS_TO_FENCE=true means the driver advertises client discovery for NetworkFenceClass workflow."
}

check_csi_replication() {
  echo
  echo "== CSI Replication Addon detection =="

  echo
  echo "## Replication CRDs"
  if kubectl get crd volumereplications.replication.storage.openshift.io >/dev/null 2>&1; then
    echo "OK: volumereplications.replication.storage.openshift.io"
  else
    echo "RESULT: volumereplications.replication.storage.openshift.io not found."
    echo "        Install from kubernetes-csi-addons (e.g. deploy/controller/crds.yaml)"
    EXIT_CODE=1
  fi

  if kubectl get crd volumereplicationclasses.replication.storage.openshift.io >/dev/null 2>&1; then
    echo "OK: volumereplicationclasses.replication.storage.openshift.io"
  else
    echo "RESULT: volumereplicationclasses.replication.storage.openshift.io not found."
    EXIT_CODE=1
  fi

  echo
  echo "## CSIAddonsNode replication capability"
  csiaddonsnode_crd="$(kubectl get crd -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name|test("(^|\\.)csiaddonsnodes\\."; "i")) | .metadata.name' | head -n 1)"
  if [[ -z "${csiaddonsnode_crd}" || "${csiaddonsnode_crd}" == "null" ]]; then
    echo "SKIP: CSIAddonsNode CRD not installed."
    EXIT_CODE=1
  else
    has_replication="$(detect_capability_in_csiaddonsnode "$CAP_REPLICATION" "$csiaddonsnode_crd")"
    
    if [[ "${has_replication}" != "[]" && -n "${has_replication}" ]]; then
      drivers_repl="$(echo "$has_replication" | jq -r '.[] | .driver' | sort -u | tr '\n' ', ' | sed 's/,$//')"
      echo "OK: Driver(s) advertise replication capability: $drivers_repl"
    else
      echo "RESULT: No CSIAddonsNode advertises replication capability."
      echo "        CSI driver may not support replication; or install CRDs from kubernetes-csi-addons."
      EXIT_CODE=1
    fi
  fi
}

check_volumegroupreplication() {
  echo
  echo "== VolumeGroupReplication detection =="

  echo
  echo "## VGR CRDs"
  for crd in volumegroupreplications.replication.storage.openshift.io \
             volumegroupreplicationclasses.replication.storage.openshift.io \
             volumegroupreplicationcontents.replication.storage.openshift.io; do
    if kubectl get crd "$crd" >/dev/null 2>&1; then
      echo "OK: $crd"
    else
      echo "RESULT: $crd not found."
      echo "        Install from kubernetes-csi-addons. Rook/Ceph may not ship these CRDs."
      EXIT_CODE=1
    fi
  done

  echo
  echo "## Replication capability (backend support)"
  csiaddonsnode_crd="$(kubectl get crd -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name|test("(^|\\.)csiaddonsnodes\\."; "i")) | .metadata.name' | head -n 1)"
  if [[ -z "${csiaddonsnode_crd}" || "${csiaddonsnode_crd}" == "null" ]]; then
    echo "SKIP: CSIAddonsNode CRD not installed."
    EXIT_CODE=1
  else
    has_replication="$(detect_capability_in_csiaddonsnode "$CAP_REPLICATION" "$csiaddonsnode_crd")"
    
    if [[ "${has_replication}" != "[]" && -n "${has_replication}" ]]; then
      drivers_repl="$(echo "$has_replication" | jq -r '.[] | .driver' | sort -u | tr '\n' ', ' | sed 's/,$//')"
      echo "OK: Driver advertises replication (VGR uses same gRPC APIs): $drivers_repl"
    else
      echo "RESULT: No driver advertises replication. VGR requires replication capability."
      echo "        If CRDs are installed but capability missing: CSI driver may need update."
      EXIT_CODE=1
    fi
  fi

  echo
  echo "## Per-driver VOLUME_GROUP and VOLUME_REPLICATION capabilities"
  if [[ -z "${csiaddonsnode_crd}" || "${csiaddonsnode_crd}" == "null" ]]; then
    echo "SKIP: CSIAddonsNode CRD is not installed."
  else
    has_volume_group="$(detect_capability_in_csiaddonsnode "$CAP_VOLUME_GROUP" "$csiaddonsnode_crd")"
    has_volume_replication_for_vgr="$(detect_capability_in_csiaddonsnode "$CAP_VOLUME_REPLICATION" "$csiaddonsnode_crd")"

    vg_found=false
    repl_found=false
    
    if [[ "${has_volume_group}" != "[]" && -n "${has_volume_group}" ]]; then
      vg_found=true
      drivers_vg="$(echo "$has_volume_group" | jq -r '.[] | .driver' | sort -u | tr '\n' ', ' | sed 's/,$//')"
      echo "OK: Driver(s) advertise volume_group.VOLUME_GROUP: $drivers_vg"
    else
      echo "RESULT: No driver advertises volume_group.VOLUME_GROUP capability."
      echo "        VGR requires both replication and volume group support."
    fi
    
    if [[ "${has_volume_replication_for_vgr}" != "[]" && -n "${has_volume_replication_for_vgr}" ]]; then
      repl_found=true
      drivers_repl_vgr="$(echo "$has_volume_replication_for_vgr" | jq -r '.[] | .driver' | sort -u | tr '\n' ', ' | sed 's/,$//')"
      echo "OK: Driver(s) advertise volume_replication.VOLUME_REPLICATION: $drivers_repl_vgr"
    else
      echo "RESULT: No driver advertises volume_replication.VOLUME_REPLICATION capability."
      echo "        VGR requires both replication and volume group support."
    fi
    
    if [[ "${vg_found}" == "false" || "${repl_found}" == "false" ]]; then
      EXIT_CODE=1
    fi
  fi

  print_vgr_sidecar_summary
  print_csiaddonsnode_vgr_table "${csiaddonsnode_crd}"
  print_vgr_configuration_verdict "${csiaddonsnode_crd}"
  if [[ "${DETAILED}" == "true" ]]; then
    print_vgr_detailed_extras "${csiaddonsnode_crd}"
  fi

  echo
  echo "== VolumeGroupReplication notes =="
  echo "- VGR CRDs come from kubernetes-csi-addons. Rook (v1.10+) no longer ships them."
  echo "- VGR requires BOTH CSI Replication Addon spec capabilities:"
  echo "  * volume_replication.VOLUME_REPLICATION (CSI Replication Addon)"
  echo "  * volume_group.VOLUME_GROUP (CSI VolumeGroup spec)"
  echo "- kubernetes-csi-addons v0.13+ is recommended for VGR reconciliation; match sidecar/controller versions per upstream docs."
  echo "- The CSI-addons Identity spec combines replication + volume group capabilities; no separate VOLUME_GROUP_REPLICATION capability exists."
  echo "- Check for volume_replication.* and volume_group.* capabilities on the RBD provisioner CSIAddonsNode."
}

# Main
check_kubectl_connectivity

case "$CHECK_MODE" in
  networkfence)
    check_networkfence
    ;;
  replication)
    check_csi_replication
    ;;
  volumegroupreplication)
    check_volumegroupreplication
    ;;
  all)
    check_networkfence
    check_csi_replication
    check_volumegroupreplication
    ;;
esac

exit "${EXIT_CODE}"
