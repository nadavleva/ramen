#!/bin/bash
# SPDX-FileCopyrightText: The RamenDR authors
# SPDX-License-Identifier: Apache-2.0
#
# Unstick CephBlockPool CRs stuck in Terminating (finalizer: cephblockpool.ceph.rook.io).
# Rook waits until the pool is removed from Ceph; mirroring, peers, or leftover images
# often block that. This script (1) tears down RBD mirror state in the toolbox,
# (2) optionally deletes the empty RADOS pool, (3) optionally clears the CR finalizer.
#
# For mirrored pools, run on BOTH clusters (e.g. dr1 and dr2) with the same pool names
# if one side alone is not enough.
#
# Usage:
#   ./scripts/unstick-terminating-cephblockpools.sh <context> --terminating
#   ./scripts/unstick-terminating-cephblockpools.sh dr1 replicapool replicapool-2
#
# Environment:
#   ALLOW_OSD_POOL_DELETE=1     After images are gone, run: ceph osd pool delete <p> <p> --yes-i-really-really-mean-it
#   ALLOW_FINALIZER_PATCH=1     Patch CephBlockPool metadata.finalizers to [] (last resort; CR goes away; ensure Ceph is clean)
#   TOOLS_DEPLOY=rook-ceph-tools
#   EXEC_TIMEOUT=300            seconds for each toolbox exec
#
# Example (typical recovery):
#   ALLOW_OSD_POOL_DELETE=1 ALLOW_FINALIZER_PATCH=1 ./scripts/unstick-terminating-cephblockpools.sh dr1 --terminating
#   # repeat for dr2 if needed
#   ALLOW_OSD_POOL_DELETE=1 ALLOW_FINALIZER_PATCH=1 ./scripts/unstick-terminating-cephblockpools.sh dr2 --terminating

set -euo pipefail

NAMESPACE="${NAMESPACE:-rook-ceph}"
TOOLS_DEPLOY="${TOOLS_DEPLOY:-rook-ceph-tools}"
EXEC_TIMEOUT="${EXEC_TIMEOUT:-300}"

log() { echo "[unstick] $*"; }

tools_exec() {
	local ctx=$1
	shift
	timeout "${EXEC_TIMEOUT}s" kubectl --context="$ctx" -n "$NAMESPACE" exec "deploy/${TOOLS_DEPLOY}" -- "$@"
}

pool_names_from_terminating() {
	local ctx=$1
	kubectl --context="$ctx" get cephblockpool -n "$NAMESPACE" -o go-template='
{{range .items}}{{if .metadata.deletionTimestamp}}{{.metadata.name}}
{{end}}{{end}}' 2>/dev/null | grep -v '^builtin-mgr$' | sed '/^$/d' || true
}

teardown_ceph_pool() {
	local ctx=$1
	local pool=$2

	log "$ctx: tearing down RADOS pool \"$pool\" inside Ceph (toolbox)..."

	# Per-image: disable mirror, purge snaps, remove
	local images
	images=$(tools_exec "$ctx" rbd ls "$pool" 2>/dev/null || true)
	for img in $images; do
		[[ -z "$img" ]] && continue
		log "$ctx:  image $pool/$img"
		tools_exec "$ctx" rbd mirror image disable "${pool}/${img}" --force 2>/dev/null || true
		tools_exec "$ctx" rbd snap purge "${pool}/${img}" 2>/dev/null || true
		tools_exec "$ctx" rbd rm "${pool}/${img}" 2>/dev/null || true
	done

	# Pool-level mirror off (ignore errors if already off or unsupported)
	tools_exec "$ctx" rbd mirror pool disable "$pool" 2>/dev/null || true

	# Remove mirror peers (parse UUIDs from peer list)
	local peers
	peers=$(tools_exec "$ctx" rbd mirror pool peer ls "$pool" 2>/dev/null | awk '{print $1}' | grep -E '^[0-9a-f-]{36}$' || true)
	for u in $peers; do
		tools_exec "$ctx" rbd mirror pool peer remove "$pool" "$u" 2>/dev/null || true
	done

	if [[ "${ALLOW_OSD_POOL_DELETE:-}" == "1" ]]; then
		if tools_exec "$ctx" ceph osd pool stats "$pool" &>/dev/null; then
			log "$ctx:  ceph osd pool delete $pool (ALLOW_OSD_POOL_DELETE=1)"
			tools_exec "$ctx" ceph osd pool delete "$pool" "$pool" --yes-i-really-really-mean-it
		else
			log "$ctx:  pool $pool not in ceph osd pool ls (already gone)"
		fi
	else
		log "$ctx:  not deleting OSD pool (set ALLOW_OSD_POOL_DELETE=1 if pool is empty but CR still stuck)"
	fi
}

patch_finalizers() {
	local ctx=$1
	local pool=$2
	if [[ "${ALLOW_FINALIZER_PATCH:-}" != "1" ]]; then
		log "$ctx:  skip finalizer patch for $pool (set ALLOW_FINALIZER_PATCH=1 after Ceph pool is gone)"
		return 0
	fi
	log "$ctx:  patching finalizers empty on CephBlockPool/$pool"
	kubectl --context="$ctx" patch cephblockpool "$pool" -n "$NAMESPACE" --type=merge \
		-p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
}

usage() {
	cat <<'EOF'
Usage:
  ./scripts/unstick-terminating-cephblockpools.sh <kube-context> --terminating
  ./scripts/unstick-terminating-cephblockpools.sh <kube-context> <pool> [pool ...]

See script header for ALLOW_OSD_POOL_DELETE and ALLOW_FINALIZER_PATCH.
EOF
	exit 1
}

main() {
	local ctx=${1:-}
	[[ -n "$ctx" ]] || usage
	shift

	local pools=()
	if [[ "${1:-}" == "--terminating" ]]; then
		mapfile -t pools < <(pool_names_from_terminating "$ctx")
		if [[ ${#pools[@]} -eq 0 ]]; then
			log "no terminating CephBlockPools (except builtin-mgr) on $ctx"
			exit 0
		fi
		log "terminating pools on $ctx: ${pools[*]}"
	else
		pools=("$@")
		[[ ${#pools[@]} -gt 0 ]] || usage
	fi

	if ! kubectl --context="$ctx" get deploy "$TOOLS_DEPLOY" -n "$NAMESPACE" &>/dev/null; then
		log "ERROR: deploy/$TOOLS_DEPLOY not found in $NAMESPACE on context $ctx"
		exit 1
	fi

	echo ""
	log "=== Before: CephBlockPools ==="
	kubectl --context="$ctx" get cephblockpool -n "$NAMESPACE" -o wide 2>/dev/null || true
	echo ""

	for pool in "${pools[@]}"; do
		[[ "$pool" == "builtin-mgr" ]] && continue
		teardown_ceph_pool "$ctx" "$pool"
		patch_finalizers "$ctx" "$pool"
		echo ""
	done

	log "=== After: CephBlockPools ==="
	kubectl --context="$ctx" get cephblockpool -n "$NAMESPACE" -o wide 2>/dev/null || true

	log "If CRs remain Terminating, check: kubectl --context=$ctx -n $NAMESPACE logs deploy/rook-ceph-operator --tail=100"
	log "Restart operator if needed: kubectl --context=$ctx -n $NAMESPACE rollout restart deploy/rook-ceph-operator"
}

main "$@"
