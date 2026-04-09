# SPDX-FileCopyrightText: The RamenDR authors
# SPDX-License-Identifier: Apache-2.0

# Use bash shell for all commands
SHELL := /bin/bash

# Enable GOPROXY. This speeds up a lot of vendoring operations.
export GOPROXY=https://proxy.golang.org

# VERSION defines the project version for the bundle.
# Update this value when you upgrade the version of your project.
# To re-generate a bundle for another specific version without changing the standard setup, you can:
# - use the VERSION as arg of the bundle target (e.g make bundle VERSION=0.0.2)
# - use environment variables to overwrite this value (e.g export VERSION=0.0.2)
VERSION ?= 0.0.1

# CHANNELS define the bundle channels used in the bundle.
# Add a new line here if you would like to change its default config. (E.g CHANNELS = "preview,fast,stable")
# To re-generate a bundle for other specific channels without changing the standard setup, you can:
# - use the CHANNELS as arg of the bundle target (e.g make bundle CHANNELS=preview,fast,stable)
# - use environment variables to overwrite this value (e.g export CHANNELS="preview,fast,stable")
ifneq ($(origin CHANNELS), undefined)
BUNDLE_CHANNELS := --channels=$(CHANNELS)
endif

# DEFAULT_CHANNEL defines the default channel used in the bundle.
# Add a new line here if you would like to change its default config. (E.g DEFAULT_CHANNEL = "stable")
# To re-generate a bundle for any other default channel without changing the default setup, you can:
# - use the DEFAULT_CHANNEL as arg of the bundle target (e.g make bundle DEFAULT_CHANNEL=stable)
# - use environment variables to overwrite this value (e.g export DEFAULT_CHANNEL="stable")
ifneq ($(origin DEFAULT_CHANNEL), undefined)
BUNDLE_DEFAULT_CHANNEL := --default-channel=$(DEFAULT_CHANNEL)
else
DEFAULT_CHANNEL := alpha
endif
BUNDLE_METADATA_OPTS ?= $(BUNDLE_CHANNELS) $(BUNDLE_DEFAULT_CHANNEL)

IMAGE_REGISTRY ?= quay.io
IMAGE_REPOSITORY ?= ramendr
IMAGE_NAME ?= ramen
IMAGE_TAG ?= latest
PLATFORM ?= k8s
IMAGE_TAG_BASE = $(IMAGE_REGISTRY)/$(IMAGE_REPOSITORY)/$(IMAGE_NAME)
RBAC_PROXY_IMG ?= "gcr.io/kubebuilder/kube-rbac-proxy:v0.13.1"
OPERATOR_SUGGESTED_NAMESPACE ?= ramen-system
RAMEN_OPS_NAMESPACE ?= ramen-ops
AUTO_CONFIGURE_DR_CLUSTER ?= true
VELERO_NAMESPACE ?= velero

HUB_NAME ?= $(IMAGE_NAME)-hub-operator
ifeq (dr,$(findstring dr,$(IMAGE_NAME)))
	DRCLUSTER_NAME ?= $(IMAGE_NAME)-cluster-operator
	BUNDLE_IMG_DRCLUSTER ?= $(IMAGE_TAG_BASE)-cluster-operator-bundle:$(IMAGE_TAG)
	BUNDLE_PLATFORM = ocp
else
	DRCLUSTER_NAME ?= $(IMAGE_NAME)-dr-cluster-operator
	BUNDLE_IMG_DRCLUSTER ?= $(IMAGE_TAG_BASE)-dr-cluster-operator-bundle:$(IMAGE_TAG)
	BUNDLE_PLATFORM = k8s
endif

# SKIP_RANGE is a build time var, that provides a valid value for:
# - olm.skipRange annotation, in the olm bundle CSV
SKIP_RANGE ?=

# REPLACES is a build time var, that provides a valid value for:
# - spec.replaces value, in the olm bundle CSV
REPLACES ?=


BUNDLE_IMG_HUB ?= $(IMAGE_TAG_BASE)-hub-operator-bundle:$(IMAGE_TAG)

# Image URL to use all building/pushing image targets
IMG ?= $(IMAGE_TAG_BASE)-operator:$(IMAGE_TAG)

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# Set sed command appropriately
SED_CMD:=sed
ifeq ($(GOHOSTOS),darwin)
	ifeq ($(GOHOSTARCH),amd64)
		SED_CMD:=gsed
	endif
endif


DOCKERCMD ?= podman

all: build

##@ General

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk commands is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Development

manifests: controller-gen ## Generate WebhookConfiguration, ClusterRole and CustomResourceDefinition objects.
	$(CONTROLLER_GEN) rbac:roleName=operator-role crd:generateEmbeddedObjectMeta=true webhook paths="./..." output:crd:artifacts:config=config/crd/bases

generate: controller-gen ## Generate code containing DeepCopy, DeepCopyInto, and DeepCopyObject method implementations.
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."


# golangci-lint has a limitation that it doesn't lint subdirectories if
# they are a different module.
# see https://github.com/golangci/golangci-lint/issues/828

.PHONY: lint
lint: golangci-bin lint-config-verify lint-e2e lint-api ## Run configured golangci-lint and pre-commit.sh linters against the code.
	testbin/golangci-lint run ./... --config=./.golangci.yaml
	hack/pre-commit.sh

lint-config-verify: golangci-bin ## Verify golangci-lint configuration file
	testbin/golangci-lint config verify --config=./.golangci.yaml

lint-e2e: golangci-bin ## Run configured golangci-lint for e2e module
	cd e2e && ../testbin/golangci-lint run ./... --config=../.golangci.yaml

lint-api: golangci-bin ## Run configured golangci-lint for api module
	cd api && ../testbin/golangci-lint run ./... --config=../.golangci.yaml

.PHONY: fmt
fmt: golangci-bin ## Run golangci-lint formatting on the codebase.
	testbin/golangci-lint fmt
	cd e2e && ../testbin/golangci-lint fmt
	cd api && ../testbin/golangci-lint fmt

.PHONY: create-rdr-env
create-rdr-env: drenv-prereqs ## Create a new rdr environment.
	./hack/dev-env.sh create

destroy-rdr-env: drenv-prereqs ## Destroy the existing rdr environment.
	./hack/dev-env.sh destroy

.PHONY: drenv-prereqs
drenv-prereqs: ## Check the prerequisites for the drenv tool.
	./hack/check-drenv-prereqs.sh

.PHONY: preload-images
preload-images: ## Pre-load container images into CSI replication clusters (dr1 dr2). Run after clusters exist.
	./scripts/preload-images.sh dr1 dr2

.PHONY: setup-csi-replication
setup-csi-replication: drenv-prereqs venv ## Setup DR clusters with Ceph SDS Storage for CSI Replication testing using rook environment. Uses podman by default; set CONTAINER_RUNTIME=docker to use docker.
	./scripts/setup-csi-replication.sh

.PHONY: test-registry-mirror
test-registry-mirror: ## Test if the local registry mirror is working properly with minikube clusters.
	./scripts/test-registry-mirror.sh

.PHONY: stop-csi-replication  
stop-csi-replication: venv ## Stop CSI Replication clusters (keep VMs).
	@echo "Cleaning up old replicated images from both clusters..."
	-./scripts/cleanup-replicated-images.sh
	@echo "Cleaning up Ceph replication state (pools and peer configs)..."
	-./scripts/cleanup-ceph-replication-state.sh
	cd test && source ../venv && drenv stop envs/rook.yaml
	@echo "✅ CSI replication clusters stopped successfully"

.PHONY: start-csi-replication
start-csi-replication: venv ## Start existing CSI Replication clusters.
	./scripts/start-csi-replication.sh

.PHONY: cleanup-replicated-images
cleanup-replicated-images: ## Clean up old replicated images from both CSI clusters.
	@./scripts/cleanup-replicated-images.sh

.PHONY: reset-csi-replication  
reset-csi-replication: ## Reset CSI Replication environment for clean setup (delete + cleanup).
	@echo "Resetting CSI Replication environment..."
	-$(MAKE) delete-csi-replication 2>/dev/null || true
	@echo "Cleaning up any remaining minikube profiles..."
	-minikube delete --profile=dr1 2>/dev/null || true
	-minikube delete --profile=dr2 2>/dev/null || true
	@echo "Cleaning up local registry..."
	-$(MAKE) clean-local-registry 2>/dev/null || true
	@echo "✅ Environment reset complete. Ready for fresh setup."

.PHONY: reset-csi-replication-state
reset-csi-replication-state: ## Fast reset of CSI replication state (~2-5 min). Assumes dr1/dr2 clusters running. Cleans VRs/VGRs/PVCs, re-applies storage + RBD mirroring.
	./scripts/reset-csi-replication-state.sh

.PHONY: fix-csi-provisioners
fix-csi-provisioners: ## Apply container image and flag format fixes to CSI provisioner deployments (required for Ceph CSI compatibility).
	./scripts/fix-csi-provisioners.sh

.PHONY: fix-csi-addons-versions
fix-csi-addons-versions: ## Update CSI Addons controller and sidecar to compatible official versions (required for gRPC connectivity).
	./scripts/fix-csi-addons-versions.sh

.PHONY: setup-csi-storage-resources
setup-csi-storage-resources: ## Setup storage classes, pools, and volume replication classes on both clusters.
	./scripts/setup-csi-storage-resources.sh

.PHONY: setup-rbd-mirroring
setup-rbd-mirroring: ## Setup RBD mirroring between dr1 and dr2 clusters.
	./scripts/setup-rbd-mirroring.sh

.PHONY: fix-rook-operator-images
fix-rook-operator-images: ## Update Rook operator to use quay.io images instead of docker.io (fixes image pull timeouts).
	@echo "Updating Rook operator to use quay.io images..."
	@# Check and update dr1 Rook operator image
	@if kubectl --context=dr1 -n rook-ceph get deployment rook-ceph-operator -o jsonpath='{.spec.template.spec.containers[0].image}' | grep -q "docker.io"; then \
		kubectl --context=dr1 -n rook-ceph patch deployment rook-ceph-operator --type='json' -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/image", "value": "quay.io/rook/ceph:v1.18.9"}]' && \
		echo "✓ Updated dr1 Rook operator to use quay.io/rook/ceph:v1.18.9"; \
	else \
		echo "✓ dr1 Rook operator already using correct image"; \
	fi
	@# Check and update dr2 Rook operator image
	@if kubectl --context=dr2 -n rook-ceph get deployment rook-ceph-operator -o jsonpath='{.spec.template.spec.containers[0].image}' | grep -q "docker.io"; then \
		kubectl --context=dr2 -n rook-ceph patch deployment rook-ceph-operator --type='json' -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/image", "value": "quay.io/rook/ceph:v1.18.9"}]' && \
		echo "✓ Updated dr2 Rook operator to use quay.io/rook/ceph:v1.18.9"; \
	else \
		echo "✓ dr2 Rook operator already using correct image"; \
	fi

.PHONY: fix-snapshot-controller-images
fix-snapshot-controller-images: ## Fix snapshot-controller to use working image version and compatible args.
	./scripts/fix-snapshot-controller-images.sh

.PHONY: fix-csi-addons-tls
fix-csi-addons-tls: ## Apply TLS configuration fix to CSI Addons controllers and sidecars.
	./scripts/fix-csi-addons-tls.sh

.PHONY: fix-rbd-mirror-health
fix-rbd-mirror-health: ## Fix RBD mirror daemon health WARNING (e.g. after failed NetworkFence tests). Re-applies peer config when possible; restarts daemon if setup would hang.
	./scripts/fix-rbd-mirror-health.sh

.PHONY: delete-csi-replication
delete-csi-replication: venv ## Delete CSI Replication clusters completely.
	@echo "Cleaning up old replicated images from both clusters..."
	-./scripts/cleanup-replicated-images.sh
	@echo "Cleaning up Ceph replication state (pools and peer configs)..."
	-./scripts/cleanup-ceph-replication-state.sh
	@echo "Deleting CSI Replication environment..."
	cd test && source ../venv && drenv delete envs/rook.yaml
	@echo "✅ CSI Replication environment deleted successfully"
	@echo "Note: Local registry is preserved for faster future setups. Use 'make clean-local-registry' to remove it."

.PHONY: clean-local-registry
clean-local-registry: ## Clean up local registry used for CSI replication. Uses podman by default; set CONTAINER_RUNTIME=docker to use docker.
	./scripts/cleanup-local-registry.sh

.PHONY: clean-pvc-vr
clean-pvc-vr: ## Clean all VolumeReplications and PVCs for fresh CSI replication testing.
	./scripts/cleanup-pvc-vr.sh -y

.PHONY: restart-csi-service
restart-csi-service: ## Restart CSI replication service - detects and fixes missing services and leader election failures.
	./scripts/restart-csi-service.sh

.PHONY: diagnose-csi-replication
diagnose-csi-replication: ## Run comprehensive diagnostics on CSI replication setup - identifies configuration and connectivity issues.
	./scripts/diagnose-csi-replication.sh

.PHONY: status-csi-replication
status-csi-replication: ## Check status of CSI Replication clusters.
	@echo "Checking cluster contexts..."
	@kubectl config get-contexts | grep -E "(dr1|dr2)" || echo "No CSI replication clusters found"

.PHONY: logs-csi-replication
logs-csi-replication: ## View recent CSI replication logs.
	@echo "Recent CSI replication logs (last 10 files):"
	@if [ -d Logs ]; then \
		ls -lt Logs/setup-csi-replication-*.log Logs/start-csi-replication-*.log Logs/stop-csi-replication-*.log Logs/delete-csi-replication-*.log Logs/test-*.log 2>/dev/null | head -10 || echo "No log files found"; \
		echo ""; \
		echo "To view a specific log file: tail -f Logs/<filename>"; \
		echo "To view all setup logs: ls Logs/setup-*"; \
		echo "To view all test logs: ls Logs/test-*"; \
	else \
		echo "No Logs directory found. Logs will be created when running targets."; \
	fi

.PHONY: verify-snapshot-controller
verify-snapshot-controller: ## Verify and fix snapshot-controller image issues in CSI clusters.
	@echo "Verifying snapshot-controller images in CSI clusters..."
	./scripts/verify-snapshot-controller.sh dr1 dr2

.PHONY: test-csi-replication
test-csi-replication: ## Run CSI replication functionality test.
	@echo "Running CSI replication test..."
	test/test-csi-replication.sh

.PHONY: test-csi-failover
test-csi-failover: ## Run CSI volume replication failover test (demote/promote flow).
	@echo "Running CSI volume replication failover test..."
	@echo "This test demonstrates the volume state change workflow:"
	@echo "  1. Creates primary volume with cross-cluster replication"
	@echo "  2. Demotes volume to secondary (simulates DR event)"
	@echo "  3. Promotes volume back to primary (simulates recovery)"
	@echo "  4. Shows detailed status before/after each operation"
	@echo "Expected duration: 2-3 minutes"
	@echo ""
	test/test-csi-failover.sh

.PHONY: test-dr-flow
test-dr-flow: ## Run complete DR failover flow test with K8s object recreation on DR2.
	@echo "Running complete DR failover flow test..."
	@echo "This test demonstrates a full DR scenario:"
	@echo "  1. Primary workload on DR1 with data"
	@echo "  2. RBD image replication to DR2"
	@echo "  3. Disaster simulation and DR1 demotion"
	@echo "  4. K8s objects (PVC/VR) recreated on DR2"
	@echo "  5. Application recovery on DR2 with data verification"
	@echo "Expected duration: 3-5 minutes"
	@echo ""
	@mkdir -p test/Logs
	@LOGFILE="test/Logs/test-dr-flow-$$(date +%Y%m%d-%H%M%S).log"; \
	echo "Logging output to $$LOGFILE"; \
	test/test-dr-flow.sh 2>&1 | tee $$LOGFILE; \
	echo ""; \
	echo "Log saved to $$LOGFILE"

.PHONY: test-csi-volumegroupreplication
test-csi-volumegroupreplication: ## Validate VolumeGroupReplication (VGR). One VGR CR with source.selector; controller creates VGRC and per-volume VRs. Requires CSI Addons v0.13+.
	@test/test-csi-volumegroupreplication.sh

.PHONY: test-csi-volumegroup-enablereplication
test-csi-volumegroup-enablereplication: ## Validate VolumeGroupEnableReplication. (1) VolumeGroup via CSI CreateVolumeGroup, (2) VolumeReplication with dataSource.kind=VolumeGroup. Blocked: requires VolumeGroup CRD/controller from kubernetes-csi-addons PR #402 fork.
	@test/test-csi-volumegroup-enablereplication.sh

.PHONY: check-csi-capabilities
check-csi-capabilities: ## Check cluster CSI capabilities. Use CHECK_MODE=all for all checks (default: networkfence).
	@./scripts/check_cluster_csi_capabilities.sh $(if $(CHECK_MODE),--mode $(CHECK_MODE),)

##@ Tests

test: generate manifests envtest ## Run all the tests.
	 go test ./... -coverprofile cover.out

test-pvrgl: generate manifests envtest ## Run ProtectedVolumeReplicationGroupList tests.
	 go test ./internal/controller -coverprofile cover.out  -ginkgo.focus ProtectedVolumeReplicationGroupList

test-obj: generate manifests envtest ## Run ObjectStorer tests.
	 go test ./internal/controller -coverprofile cover.out  -ginkgo.focus FakeObjectStorer

test-vs: generate manifests envtest ## Run VolumeSync tests.
	 go test ./internal/controller/volsync -coverprofile cover.out

test-vs-cg: generate manifests envtest ## Run VGS VolumeSync tests.
	 go test ./internal/controller/cephfscg -coverprofile cover.out -ginkgo.focus Volumegroupsourcehandler

test-vrg: generate manifests envtest ## Run VolumeReplicationGroup tests.
	 go test ./internal/controller -coverprofile cover.out  -ginkgo.focus VolumeReplicationGroup

test-vrg-pvc: generate manifests envtest ## Run VolumeReplicationGroupPVC tests.
	 go test ./internal/controller -coverprofile cover.out  -ginkgo.focus VolumeReplicationGroupPVC

test-vrg-vr: generate manifests envtest ## Run VolumeReplicationGroupVolRep tests.
	 go test ./internal/controller -coverprofile cover.out  -ginkgo.focus VolumeReplicationGroupVolRep

test-vrg-vs: generate manifests envtest ## Run VolumeReplicationGroupVolSync tests.
	 go test ./internal/controller -coverprofile cover.out  -ginkgo.focus VolumeReplicationGroupVolSync

test-vrg-recipe: generate manifests envtest ## Run VolumeReplicationGroupRecipe tests.
	 go test ./internal/controller -coverprofile cover.out  -ginkgo.focus VolumeReplicationGroupRecipe

test-vrg-kubeobjects: generate manifests envtest ## Run VolumeReplicationGroupKubeObjects tests.
	 go test ./internal/controller -coverprofile cover.out  -ginkgo.focus VRG_KubeObjectProtection

test-drpc: generate manifests envtest ## Run DRPlacementControl tests.
	 go test ./internal/controller -coverprofile cover.out  -ginkgo.focus DRPlacementControl

test-scheduler: generate manifests envtest ## Run DRPlacementControl tests.
	 go test ./internal/controller -coverprofile cover.out  -ginkgo.focus DRPlacementControl_Reconciler_Test_Scheduler

test-drcluster: generate manifests envtest ## Run DRCluster tests.
	 go test ./internal/controller -coverprofile cover.out  -ginkgo.focus DRClusterController

test-drpolicy: generate manifests envtest ## Run DRPolicy tests.
	 go test ./internal/controller -coverprofile cover.out  -ginkgo.focus DRPolicyController

test-drclusterconfig: generate manifests envtest ## Run DRClusterConfig tests.
	 go test ./internal/controller -coverprofile cover.out  -ginkgo.focus DRClusterConfig

test-util: generate manifests envtest ## Run util tests.
	 go test ./internal/controller/util -coverprofile cover.out

test-util-pvc: generate manifests envtest ## Run util-pvc tests.
	 go test ./internal/controller/util -coverprofile cover.out  -ginkgo.focus PVCS_Util

test-kubeobjects: ## Run kubeobjects tests.
	 go test ./internal/controller/kubeobjects -coverprofile cover.out  -ginkgo.focus Kubeobjects

test-cephfs-cg: generate manifests envtest ## Run util-pvc tests.
	 go test ./internal/controller/util -coverprofile cover.out  -ginkgo.focus CephfsCg


test-drenv: ## Run drenv tests.
	$(MAKE) -C test

test-ramendev: ## Run ramendev tests.
	$(MAKE) -C ramendev

e2e-rdr: generate manifests ## Run rdr-e2e tests.
	cd e2e && ./run.sh

coverage:
	go tool cover -html=cover.out

.PHONY: venv
venv:
	hack/make-venv

##@ Build

# Build manager binary
build: generate manifests  ## Build manager binary.
	go build -o bin/manager cmd/main.go

# Run against the configured Kubernetes cluster in ~/.kube/config
run-hub: generate manifests ## Run DR Orchestrator controller from your host.
	go run ./cmd/main.go --config=examples/dr_hub_config.yaml

run-dr-cluster: generate manifests ## Run DR manager controller from your host.
	go run ./cmd/main.go --config=examples/dr_cluster_config.yaml

docker-build: ## Build docker image with the manager.
	$(DOCKERCMD) build -t ${IMG} .

docker-push: ## Push docker image with the manager.
	$(DOCKERCMD) push ${IMG}

##@ Deployment

resources: manifests hub-config dr-cluster-config ## Prepare resources for deployment

install: install-hub install-dr-cluster ## Install hub and dr-cluster CRDs into the K8s cluster specified in ~/.kube/config.

uninstall: uninstall-hub uninstall-dr-cluster ## Uninstall hub and dr-cluster CRDs from the K8s cluster specified in ~/.kube/config.

deploy: deploy-hub deploy-dr-cluster ## Deploy hub and dr-cluster controller to the K8s cluster specified in ~/.kube/config.

undeploy: undeploy-hub undeploy-dr-cluster ## Undeploy hub and dr-cluster controller from the K8s cluster specified in ~/.kube/config.

install-hub: manifests kustomize ## Install hub CRDs into the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build --load-restrictor LoadRestrictionsNone config/hub/crd | kubectl apply -f -

uninstall-hub: manifests kustomize ## Uninstall hub CRDs from the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build --load-restrictor LoadRestrictionsNone config/hub/crd | kubectl delete -f -

hub-config: kustomize
	cd config/hub/default/$(PLATFORM) && $(KUSTOMIZE) edit set image kube-rbac-proxy=$(RBAC_PROXY_IMG)
	cd config/hub/manager && $(KUSTOMIZE) edit set image controller=${IMG}

deploy-hub: manifests kustomize hub-config ## Deploy hub controller to the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build --load-restrictor LoadRestrictionsNone config/hub/default/$(PLATFORM) | kubectl apply -f -

undeploy-hub: kustomize ## Undeploy hub controller from the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build --load-restrictor LoadRestrictionsNone config/hub/default/$(PLATFORM) | kubectl delete -f - --ignore-not-found

install-dr-cluster: manifests kustomize ## Install dr-cluster CRDs into the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build --load-restrictor LoadRestrictionsNone config/dr-cluster/crd | kubectl apply -f -

uninstall-dr-cluster: manifests kustomize ## Uninstall dr-cluster CRDs from the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build --load-restrictor LoadRestrictionsNone config/dr-cluster/crd | kubectl delete -f -

dr-cluster-config: kustomize
	cd config/dr-cluster/default && $(KUSTOMIZE) edit set image kube-rbac-proxy=$(RBAC_PROXY_IMG)
	cd config/dr-cluster/manager && $(KUSTOMIZE) edit set image controller=${IMG}

deploy-dr-cluster: manifests kustomize dr-cluster-config ## Deploy dr-cluster controller to the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build --load-restrictor LoadRestrictionsNone config/dr-cluster/default | kubectl apply -f -

undeploy-dr-cluster: kustomize ## Undeploy dr-cluster controller from the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build --load-restrictor LoadRestrictionsNone config/dr-cluster/default | kubectl delete -f - --ignore-not-found

##@ Tools

CONTROLLER_GEN = $(shell pwd)/bin/controller-gen
controller-gen: ## Download controller-gen locally.
	@hack/install-controller-gen.sh

.PHONY: kustomize
KUSTOMIZE = $(shell pwd)/bin/kustomize
kustomize: ## Download kustomize locally.
	@hack/install-kustomize.sh

.PHONY: opm
OPM = ./bin/opm
opm: ## Download opm locally.
	@./hack/install-opm.sh

.PHONY: operator-sdk
OSDK = ./bin/operator-sdk
operator-sdk: ## Download operator-sdk locally.
	@hack/install-operator-sdk.sh

.PHONY: golangci-bin
golangci-bin: ## Download golangci-lint locally.
	@hack/install-golangci-lint.sh

.PHONY: envtest
envtest: ## Download envtest locally.
	hack/install-setup-envtest.sh


##@ Bundle

.PHONY: bundle
bundle: bundle-hub bundle-dr-cluster ## Generate all bundle manifests and metadata, then validate generated files.

.PHONY: bundle-build
bundle-build: bundle-hub-build bundle-dr-cluster-build ## Build all bundle images.

.PHONY: bundle-push
bundle-push: bundle-hub-push bundle-dr-cluster-push ## Push all bundle images.

.PHONY: bundle-hub
bundle-hub: manifests kustomize operator-sdk ## Generate hub bundle manifests and metadata, then validate generated files.
	cd config/hub/default/$(BUNDLE_PLATFORM) && $(KUSTOMIZE) edit set image kube-rbac-proxy=$(RBAC_PROXY_IMG)
	cd config/hub/manager && $(KUSTOMIZE) edit set image controller=$(IMG)
	cd config/hub/manifests/$(IMAGE_NAME) && $(KUSTOMIZE) edit add patch --name ramen-hub-operator.v0.0.0 --kind ClusterServiceVersion\
		--patch '[{"op": "add", "path": "/metadata/annotations/olm.skipRange", "value": "$(SKIP_RANGE)"}]' && \
		$(KUSTOMIZE) edit add patch --name ramen-hub-operator.v0.0.0 --kind ClusterServiceVersion\
		--patch '[{"op": "replace", "path": "/spec/replaces", "value": "$(REPLACES)"}]'
	$(SED_CMD) -e "s,ramenOpsNamespace: ramen-ops,ramenOpsNamespace: $(RAMEN_OPS_NAMESPACE)," -i config/hub/manager/ramen_manager_config.yaml
	$(SED_CMD) -e "s,veleroNamespaceName: velero,veleroNamespaceName: $(VELERO_NAMESPACE)," -i config/hub/manager/ramen_manager_config.yaml
	$(SED_CMD) -e "s,channelName: alpha,channelName: $(DEFAULT_CHANNEL)," -i config/hub/manifests/$(IMAGE_NAME)/ramen_manager_config_append.yaml
	$(SED_CMD) -e "s,packageName: ramen-dr-cluster-operator,packageName: $(DRCLUSTER_NAME)," -i config/hub/manifests/$(IMAGE_NAME)/ramen_manager_config_append.yaml
	$(SED_CMD) -e "s,namespaceName: ramen-system,namespaceName: $(OPERATOR_SUGGESTED_NAMESPACE)," -i config/hub/manifests/$(IMAGE_NAME)/ramen_manager_config_append.yaml
	$(SED_CMD) -e "s,clusterServiceVersionName: ramen-dr-cluster-operator.v0.0.1,clusterServiceVersionName: $(DRCLUSTER_NAME).v$(VERSION)," -i config/hub/manifests/$(IMAGE_NAME)/ramen_manager_config_append.yaml
	$(SED_CMD) -e "s,deploymentAutomationEnabled: true,deploymentAutomationEnabled: $(AUTO_CONFIGURE_DR_CLUSTER)," -i config/hub/manifests/$(IMAGE_NAME)/ramen_manager_config_append.yaml
	$(SED_CMD) -e "s,s3SecretDistributionEnabled: true,s3SecretDistributionEnabled: $(AUTO_CONFIGURE_DR_CLUSTER)," -i config/hub/manifests/$(IMAGE_NAME)/ramen_manager_config_append.yaml
	cat config/hub/manifests/$(IMAGE_NAME)/ramen_manager_config_append.yaml >> config/hub/manager/ramen_manager_config.yaml
	$(KUSTOMIZE) build --load-restrictor LoadRestrictionsNone config/hub/manifests/$(IMAGE_NAME) | $(OSDK) generate bundle -q --package=$(HUB_NAME) --overwrite --output-dir=config/hub/bundle --version $(VERSION) $(BUNDLE_METADATA_OPTS)
	$(OSDK) bundle validate config/hub/bundle

.PHONY: bundle-hub-build
bundle-hub-build: bundle-hub ## Build the hub bundle image.
	$(DOCKERCMD) build -f bundle.Dockerfile -t $(BUNDLE_IMG_HUB) .

.PHONY: bundle-hub-push
bundle-hub-push: ## Push the hub bundle image.
	$(MAKE) docker-push IMG=$(BUNDLE_IMG_HUB)

.PHONY: bundle-dr-cluster
bundle-dr-cluster: manifests kustomize dr-cluster-config operator-sdk ## Generate dr-cluster bundle manifests and metadata, then validate generated files.
	cd config/dr-cluster/manifests/$(IMAGE_NAME) && $(KUSTOMIZE) edit add patch --name ramen-dr-cluster-operator.v0.0.0 --kind ClusterServiceVersion\
		--patch '[{"op": "add", "path": "/metadata/annotations/olm.skipRange", "value": "$(SKIP_RANGE)"}]' && \
		$(KUSTOMIZE) edit add patch --name ramen-dr-cluster-operator.v0.0.0 --kind ClusterServiceVersion\
		--patch '[{"op": "replace", "path": "/spec/replaces", "value": "$(REPLACES)"}]'
	$(SED_CMD) -e "s,ramenOpsNamespace: ramen-ops,ramenOpsNamespace: $(RAMEN_OPS_NAMESPACE)," -i config/dr-cluster/manager/ramen_manager_config.yaml
	$(SED_CMD) -e "s,veleroNamespaceName: velero,veleroNamespaceName: $(VELERO_NAMESPACE)," -i config/dr-cluster/manager/ramen_manager_config.yaml
	$(KUSTOMIZE) build --load-restrictor LoadRestrictionsNone config/dr-cluster/manifests/$(IMAGE_NAME) | $(OSDK) generate bundle -q --package=$(DRCLUSTER_NAME) --overwrite --output-dir=config/dr-cluster/bundle --version $(VERSION) $(BUNDLE_METADATA_OPTS)
	$(OSDK) bundle validate config/dr-cluster/bundle

.PHONY: bundle-dr-cluster-build
bundle-dr-cluster-build: bundle-dr-cluster ## Build the dr-cluster bundle image.
	$(DOCKERCMD) build -f bundle.Dockerfile -t $(BUNDLE_IMG_DRCLUSTER) .

.PHONY: bundle-dr-cluster-push
bundle-dr-cluster-push: ## Push the dr-cluster bundle image.
	$(MAKE) docker-push IMG=$(BUNDLE_IMG_DRCLUSTER)

# A comma-separated list of bundle images (e.g. make catalog-build BUNDLE_IMGS=example.com/operator-bundle:v0.1.0,example.com/operator-bundle:v0.2.0).
# These images MUST exist in a registry and be pull-able.
BUNDLE_IMGS ?= $(BUNDLE_IMG_HUB),$(BUNDLE_IMG_DRCLUSTER)

# The image tag given to the resulting catalog image (e.g. make catalog-build CATALOG_IMG=example.com/operator-catalog:v0.2.0).
CATALOG_IMG ?= $(IMAGE_TAG_BASE)-operator-catalog:$(IMAGE_TAG)

# Set CATALOG_BASE_IMG to an existing catalog image tag to add $BUNDLE_IMGS to that image.
ifneq ($(origin CATALOG_BASE_IMG), undefined)
FROM_INDEX_OPT := --from-index $(CATALOG_BASE_IMG)
endif

BUNDLE_PULL_TOOL ?= $(DOCKERCMD)

# Build a catalog image by adding bundle images to an empty catalog using the operator package manager tool, 'opm'.
# This recipe invokes 'opm' in 'semver' bundle add mode. For more information on add modes, see:
# https://github.com/operator-framework/community-operators/blob/7f1438c/docs/packaging-operator.md#updating-your-existing-operator
.PHONY: catalog-build
catalog-build: opm ## Build a catalog image.
	$(OPM) index add\
		--mode semver\
		--tag $(CATALOG_IMG)\
		--bundles $(BUNDLE_IMGS) $(FROM_INDEX_OPT)\
		--pull-tool $(BUNDLE_PULL_TOOL)\
		--build-tool $(DOCKERCMD)\

# Push the catalog image.
.PHONY: catalog-push
catalog-push: ## Push a catalog image.
	$(MAKE) docker-push IMG=$(CATALOG_IMG)

# PLATFORMS defines the target platforms for  the manager image be build to provide support to multiple
# architectures. (i.e. make docker-buildx IMG=myregistry/mypoperator:0.0.1). To use this option you need to:
# - able to use docker buildx . More info: https://docs.docker.com/build/buildx/
# - have enable BuildKit, More info: https://docs.docker.com/develop/develop-images/build_enhancements/
.PHONY: docker-buildx
docker-buildx: # Build and push docker image for the manager for cross-platform support
ifeq ($(DOCKERCMD),docker)
	# copy existing Dockerfile and insert --platform=${BUILDPLATFORM} and
	# replace GOARCH value to ${TARGETARCH} into Dockerfile.cross, and preserve the original Dockerfile
	$(eval PLATFORMS="linux/arm64,linux/amd64,linux/s390x,linux/ppc64le")
	$(SED_CMD) \
		-e '1 s/\(^FROM\)/FROM --platform=\$$\{BUILDPLATFORM\}/; t' \
		-e ' 1,// s//FROM --platform=\$$\{BUILDPLATFORM\}/' \
		Dockerfile > Dockerfile.cross
	$(SED_CMD) -e 's/GOARCH=amd64/GOARCH=$${TARGETARCH}/' -i Dockerfile.cross
	- $(DOCKERCMD) buildx create --name $(IMAGE_NAME)-builder
	$(DOCKERCMD) buildx use $(IMAGE_NAME)-builder
	- $(DOCKERCMD) buildx build --push --platform="${PLATFORMS}" --tag ${IMG} -f Dockerfile.cross .
	- $(DOCKERCMD) buildx rm $(IMAGE_NAME)-builder
	rm Dockerfile.cross
else
	@echo "docker-buildx is supported only with docker"
endif

.PHONY: clean-stuck-namespaces
clean-stuck-namespaces: ## Clean up stuck namespaces (workaround for terminating namespace issues).
	@echo "Cleaning up stuck test namespaces..."
	@# Try to remove finalizers from stuck namespaces
	@for ns in rook-cephfs-test rook-cephfs-test-new; do \
		for context in dr1 dr2; do \
			if kubectl --context=$$context get namespace $$ns 2>/dev/null | grep -q Terminating; then \
				echo "Fixing stuck namespace $$ns in $$context..."; \
				kubectl --context=$$context patch namespace $$ns --type='merge' -p='{"metadata":{"finalizers":[]}}' || true; \
			fi; \
		done; \
	done
	@echo "✓ Namespace cleanup attempted"

.PHONY: clean-csi-duplicates
clean-csi-duplicates: ## Clean up duplicate CSI replication resources.
	@echo "Cleaning up duplicate CSI replication resources..."
	@# Remove duplicate storage classes (keep only one of each type)
	@for context in dr1 dr2; do \
		echo "Checking $$context for duplicates..."; \
		kubectl --context=$$context get storageclass -o name | grep rook-ceph-block | tail -n +2 | xargs -r kubectl --context=$$context delete || true; \
		kubectl --context=$$context get cephblockpool -n rook-ceph -o name | grep replicapool | tail -n +2 | xargs -r kubectl --context=$$context delete || true; \
		kubectl --context=$$context get deployment -n rook-ceph -o name | grep rook-ceph-operator | tail -n +2 | xargs -r kubectl --context=$$context delete || true; \
		kubectl --context=$$context get deployment -n kube-system -o name | grep snapshot-controller | tail -n +2 | xargs -r kubectl --context=$$context delete || true; \
	done
	@echo "✓ Duplicate resource cleanup completed"
