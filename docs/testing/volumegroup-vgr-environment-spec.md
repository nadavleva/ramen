# VolumeGroup and VolumeGroupReplication: Local Environment Specification

This document records how the RamenDR CSI replication test environment enables **VolumeGroupReplication** (VGR) and how that relates to **volume groups** on the storage side, where CRDs are loaded from, which CRDs are required, and what fixes apply to **Kubernetes Services** and **CSIAddonsNode** (and the CSI controller vs node path).

**Terminology:** In [kubernetes-csi-addons](https://github.com/csi-addons/kubernetes-csi-addons), the **CSI volume group** (driver-backed group of volumes) is **not** the same thing as the optional Kubernetes **`VolumeGroup`** CR (`volumegroup.storage.openshift.io`). The VGR flow uses **`VolumeGroupReplication`** → **`VolumeGroupReplicationContent`** and CSI **VolumeGroup** gRPC calls; the content object carries the group identity in **`spec.volumeGroupReplicationHandle`** and **`spec.volumeGroupAttributes`**.

For broader setup and troubleshooting, see [local-environment-setup.md](./local-environment-setup.md), [SetupCSICluster.md](./SetupCSICluster.md), [replication-parameters.md](./replication-parameters.md), and [csi-addons-troubleshooting.md](./csi-addons-troubleshooting.md). For replication method comparison, see [csi-replication-methods-and-status.md](./csi-replication-methods-and-status.md).

## Steps to enable VolumeGroupReplication (VGR)

These steps are what **`make setup-csi-replication`** orchestrates; run them in order on a fresh or broken env. Each item is **2–3 sentences**. For a denser matrix and file paths, see the **Executive summary** and **§2–§4** below.

### 1. Install upstream kubernetes-csi-addons (controller + CRDs)

Point [`test/addons/csi-addons/kustomization.yaml`](../../test/addons/csi-addons/kustomization.yaml) at **[kubernetes-csi-addons](https://github.com/csi-addons/kubernetes-csi-addons) `main`**: `deploy/controller/crds.yaml`, `rbac.yaml`, and `setup-controller.yaml`. When **`drenv start`** runs the csi-addons addon, the cluster gets the **CSI Addons controller** and the **full replication CRD bundle** (including **VolumeGroupReplication** APIs). This replaces older fork-based URLs that could break **VolumeReplication** or omit a consistent controller.

### 2. Apply (or re-apply) the three VGR CRDs from this repo

[`scripts/setup-csi-storage-resources.sh`](../../scripts/setup-csi-storage-resources.sh) runs **`kubectl apply -f`** on **`hack/test/replication.storage.openshift.io_volumegroupreplications.yaml`**, **`hack/test/replication.storage.openshift.io_volumegroupreplicationclasses.yaml`**, and **`hack/test/replication.storage.openshift.io_volumegroupreplicationcontents.yaml`** for **dr1** and **dr2**. That keeps the **OpenAPI schema** on the cluster aligned with the **pinned copies** in RamenDR even if the remote **`crds.yaml`** revision drifted. Treat **`hack/test/`** as the in-tree reference; canonical YAML is generated upstream under **`config/crd/bases/`** (see §2.2).

### 3. Fix controller ↔ sidecar connectivity (TLS / auth mismatch)

Run [`scripts/fix-csi-addons-tls.sh`](../../scripts/fix-csi-addons-tls.sh) (**`make fix-csi-addons-tls`**): set **`--enable-auth=false`** on **`csi-addons-controller-manager`** so it speaks **plain gRPC** like the **csi-addons** sidecars on **9070**. Patch **NODE_ID** and **csi-addons** container **args** on **RBD/CephFS provisioner** deployments (staging path, leader-election timings), then refresh pods. Without this, the manager often hits **TLS handshake errors**, drops **CSIAddonsNode**, and **VGR** status never reconciles.

### 4. Restore **CSIAddonsNode** registration (“missing node”)

After TLS/sidecar fixes, **delete stale CSIAddonsNode** and **restart** CSI plugin pods so sidecars re-register with the controller (**same script** as step 3). If no **CSIAddonsNode** exists for **`rook-ceph.rbd.csi.ceph.com`**, the controller cannot reach the driver and **VolumeGroupReplication** stays empty or **Unknown**. Use **`kubectl get csiaddonsnode -A`** to confirm; **`make restart-csi-service`** helps recycle connections (§4).

### 5. Add missing **Service** objects for provisioners (if needed)

[`scripts/restart-csi-service.sh`](../../scripts/restart-csi-service.sh) creates **ClusterIP** **Services** for **`csi-rbdplugin-provisioner`** and **`csi-cephfsplugin-provisioner`** in **`rook-ceph`** when they are absent (**gRPC** ports **12345** / **12346**). Rook does not always create these; without a stable Service, some discovery paths fail. The script also restarts provisioners and the CSI Addons controller so endpoints come up cleanly.

### 6. Fix **“no leader for the ControllerService”** (provisioner path)

**VolumeGroup** CSI RPCs need the **csi-addons** sidecar on the **provisioner Deployment** to win **leader election** for **ControllerService**, not only the node **DaemonSet**. **`fix-csi-addons-tls`** sets the sidecar **leader-election** args; **`restart-csi-service`** forces rollout and checks logs / **CSIAddonsNode** for **`csi-rbdplugin-provisioner`**. If this step fails, the controller logs **no leader** and **VGR** cannot complete group operations.

### 7. Pin compatible CSI Addons controller and sidecar images

Run [`hack/fix-csi-addons-versions.sh`](../../hack/fix-csi-addons-versions.sh) (**`make fix-csi-addons-versions`**): align **`quay.io/csiaddons/k8s-controller:latest`** and **`quay.io/csiaddons/k8s-sidecar:v0.11.0`** on the manager and on all **csi-addons** containers in RBD/CephFS workloads. **Version skew** between manager and sidecar causes silent gRPC or capability mismatches and stalled **status**. Preload/mirror images via **`config/required-images.txt`** and **`scripts/preload-images.sh`** so pulls succeed offline.

### 8. Storage classes, **VolumeReplicationClass**, **VolumeGroupReplicationClass**, and RBD mirroring

**`setup-csi-storage-resources`** creates pools / storage classes and applies **VolumeReplicationClass** YAML; **`setup-rbd-mirroring`** configures mirroring and applies **VRC** / **VGRC** manifests (e.g. **`vgrc-2m`** from **`test/addons/rbd-mirror/start-data/vgrc.yaml`**). A **VolumeGroupReplication** object must reference a valid **VolumeGroupReplicationClass** and a **VolumeReplicationClass** for per-volume **VolumeReplication** children. **`make test-csi-volumegroupreplication`** exercises this path end-to-end.

### CRDs required for VGR (group **`replication.storage.openshift.io`**)

All are defined in **[kubernetes-csi-addons](https://github.com/csi-addons/kubernetes-csi-addons)** (generated under **`config/crd/bases/`**, shipped in **`deploy/controller/crds.yaml`**). Ramen also keeps copies of the VGR triple under **`hack/test/`** for **`kubectl apply`** in **`setup-csi-storage-resources.sh`**.

| CRD name | Kind | Origin |
|----------|------|--------|
| `volumegroupreplications.replication.storage.openshift.io` | **VolumeGroupReplication** | Upstream: `config/crd/bases/replication.storage.openshift.io_volumegroupreplications.yaml` → bundle **`deploy/controller/crds.yaml`** |
| `volumegroupreplicationclasses.replication.storage.openshift.io` | **VolumeGroupReplicationClass** | Upstream: `..._volumegroupreplicationclasses.yaml` → same bundle |
| `volumegroupreplicationcontents.replication.storage.openshift.io` | **VolumeGroupReplicationContent** | Upstream: `..._volumegroupreplicationcontents.yaml` → same bundle |

**Also required in practice** for the selector-based VGR flow (same upstream bundle): **`volumereplications.replication.storage.openshift.io`** (**VolumeReplication**) and **`volumereplicationclasses.replication.storage.openshift.io`** (**VolumeReplicationClass**), because the **VolumeGroupReplication** reconciler creates or updates **per-volume VolumeReplication** objects.

---

## Executive summary: Activating VolumeGroupReplication (what had to work)

**VolumeGroupReplication** only works when the **kubernetes-csi-addons controller** (`csi-addons-system/csi-addons-controller-manager`) can drive the **CSI driver** through the **csi-addons sidecar** (gRPC on **9070**) and when the **VGR / VGRC CRDs** exist. The table below is the **intentional activation sequence** baked into **`make setup-csi-replication`**; details follow in §1–§4.

| Layer | Steps taken | Why it matters for VGR |
|-------|-------------|-------------------------|
| **CRDs** | (1) Apply **`deploy/controller/crds.yaml`** from [kubernetes-csi-addons `main`](https://github.com/csi-addons/kubernetes-csi-addons) via `test/addons/csi-addons/kustomization.yaml` during **`drenv start`**. (2) Re-apply the three **VGR CRDs** from **`hack/test/`** in **`setup-csi-storage-resources.sh`** (§2.2). | Without **`VolumeGroupReplication`**, **`VolumeGroupReplicationClass`**, and **`VolumeGroupReplicationContent`**, the API server rejects objects; without **VolumeReplication** CRDs (same bundle), the VGR reconciler cannot create per-volume **VolumeReplication**. |
| **Images** | Local registry mirror from **`config/required-images.txt`** + **`preload-images.sh`**; then **`fix-csi-provisioners`** (SIG-Storage sidecars, log-collector); **`fix-csi-addons-versions`** pins **`quay.io/csiaddons/k8s-controller:latest`** and **`quay.io/csiaddons/k8s-sidecar:v0.11.0`**. | **Version skew** or **ImagePullBackOff** leaves no healthy sidecar for the controller to dial; wrong **cephcsi** images break the plugin before gRPC matters. §2.5 lists registries and upstream repos. |
| **Controller ↔ sidecar (gRPC)** | **`fix-csi-addons-tls`**: **`--enable-auth=false`** on the manager (TLS was **on** by default while sidecars speak **plain gRPC** → handshake failures); **`NODE_ID`** on the controller; **csi-addons** container args on **RBD/CephFS provisioner** deployments (**staging path**, **leader-election** timings); delete stale **CSIAddonsNode**; restart CSI pods. | **Primary blocker:** `transport: authentication handshake failed: tls: first record does not look like a TLS handshake` — controller deleted **CSIAddonsNode** after failed connects; **VolumeReplication** / **VGR** stay **Unknown**. See [csi-addons-troubleshooting.md](./csi-addons-troubleshooting.md). |
| **ControllerService / “no leader”** | Same TLS/sidecar args ensure the **provisioner** deployment’s sidecar wins **leader election** for **ControllerService** (not only the node **DaemonSet**). **`restart-csi-service`** restarts provisioners + controller and checks logs / **CSIAddonsNode** for **`csi-rbdplugin-provisioner`**. | **VGR** path needs **VolumeGroup** CSI RPCs on the **controller** endpoint; errors like **`no leader for the ControllerService`** mean the controller cannot call the driver for group operations. |
| **Kubernetes Services (optional)** | **`restart-csi-service.sh`** creates **`csi-rbdplugin-provisioner`** / **`csi-cephfsplugin-provisioner`** ClusterIP Services (ports **12345** / **12346**) if missing. | Some flows expect a **Service** fronting provisioner gRPC; Rook may not create it on every profile. |
| **Storage + classes** | **`setup-csi-storage-resources`** (pools, **VolumeReplicationClass**), **`setup-rbd-mirroring`** (**VRC** / **VGRC** e.g. `vgrc-2m`). | VGR objects need a **VolumeGroupReplicationClass** and backend mirroring consistent with your test (**`make test-csi-volumegroupreplication`**). |

**Manual recovery (if something still fails):** `make fix-csi-provisioners && make fix-csi-addons-versions && make fix-csi-addons-tls` then `make restart-csi-service` (or run the underlying scripts with **`dr1`/`dr2`** contexts available).

---

## 1. End-to-end setup steps

The entry point is **`make setup-csi-replication`**, which runs `scripts/setup-csi-replication.sh`. Order of operations:

| Step | What runs | Purpose |
|------|-----------|---------|
| 1 | Local registry (`registry:2` on port 5000) + `config/required-images.txt` | Reduce image pull failures; align images with `hack/fix-csi-addons-versions.sh` |
| 2 | `drenv setup envs/rook.yaml` | Host/minikube preparation |
| 3 | `drenv start envs/rook.yaml --skip-addons --skip-tests` | Empty clusters first |
| 4 | `scripts/preload-images.sh dr1 dr2` | Preload images into minikube before Rook |
| 5 | `drenv start envs/rook.yaml` | Rook/Ceph + **csi-addons** addon (controller from upstream kustomization) |
| 6 | `scripts/fix-csi-provisioners.sh` → `hack/fix-csi-provisioners.sh` | Ceph CSI / sidecar compatibility (images, log-collector, etc.) |
| 7 | `scripts/fix-csi-addons-versions.sh` → `hack/fix-csi-addons-versions.sh` | Controller `quay.io/csiaddons/k8s-controller:latest`, sidecar `v0.11.0` on RBD/CephFS provisioners + daemonsets |
| 8 | `make fix-csi-addons-tls` → `scripts/fix-csi-addons-tls.sh` | Plain gRPC vs TLS; **NODE_ID**; **csi-addons sidecar args** (leader election, staging path) |
| 9 | `scripts/setup-csi-storage-resources.sh` | Pools/storage classes, VolumeReplicationClasses, **VGR + VolumeGroup CRDs** |
| 10 | `scripts/setup-rbd-mirroring.sh` | Cross-cluster RBD mirroring, VRC/VGRC manifests from rbd-mirror addon |

After setup, **VGR** is exercised with `make test-csi-volumegroupreplication` (`test/test-csi-volumegroupreplication.sh`). The alternate **`VolumeGroup` CR + `VolumeReplication` with `dataSource.kind=VolumeGroup`** path is `make test-csi-volumegroup-enablereplication` — that path depends on a **`VolumeGroup` CR controller**, which is **not** part of the standard VGR implementation (see §2.3 and [csi-replication-methods-and-status.md](./csi-replication-methods-and-status.md)).

Other useful targets: `make start-csi-replication`, `make stop-csi-replication`, `make delete-csi-replication`, `make reset-csi-replication-state` (cleanup + re-apply storage/VGR state), `make restart-csi-service` (Services + leader election + controller restart).

### 1.1 How kubernetes-csi-addons models the volume group (VGR path)

Upstream splits work across **two reconcilers** (see `internal/controller/replication.storage/volumegroupreplication_controller.go` and `volumegroupreplicationcontent_controller.go` in [kubernetes-csi-addons](https://github.com/csi-addons/kubernetes-csi-addons)):

1. **`VolumeGroupReplicationReconciler`** reconciles **`VolumeGroupReplication`**: finds PVCs via **`spec.source`**, builds the list of backend volume handles, **creates or updates `VolumeGroupReplicationContent`**, and manages the related **`VolumeReplication`** objects for group replication.
2. **`VolumeGroupReplicationContentReconciler`** reconciles **`VolumeGroupReplicationContent`**: uses the CSI **VolumeGroup** gRPC client (`CreateVolumeGroup`, `ModifyVolumeGroupMembership`, `DeleteVolumeGroup`, etc.) and writes the driver’s group identity back onto the content object as **`spec.volumeGroupReplicationHandle`** and **`spec.volumeGroupAttributes`**.

The **Kubernetes representation of the CSI volume group** for VGR is **`VolumeGroupReplicationContent.spec`** (handle + attributes + source volume handles), **bound to** **`VolumeGroupReplication`** via **`spec.volumeGroupReplicationRef`** on the content object and **`spec.volumeGroupReplicationContentName`** on the VGR. This path does **not** require a separate **`VolumeGroup`** CR (`volumegroup.storage.openshift.io`).

---

## 2. Where CRDs are loaded from

### 2.1 CSI Addons controller bundle (VolumeReplication and related)

The **csi-addons** drenv addon uses `test/addons/csi-addons/kustomization.yaml`, which references **upstream** manifests:

- `https://raw.githubusercontent.com/csi-addons/kubernetes-csi-addons/main/deploy/controller/crds.yaml`
- `.../rbac.yaml`
- `.../setup-controller.yaml`

That `crds.yaml` carries the kubernetes-csi-addons API definitions (including **VolumeReplication**, **VolumeReplicationClass**, and, on current `main`, group-replication CRDs as upstream evolves). The kustomization comment states that a **cg-support fork was avoided** because it broke single-VolumeReplication flow.

### 2.2 VolumeGroupReplication CRDs (explicit apply)

#### Where the files live in this repository

All three CRDs are **committed under the repo root** in **`hack/test/`**:

| In-repo path (relative to RamenDR repo root) | `CustomResourceDefinition` `.metadata.name` | Kubernetes kind |
|-----------------------------------------------|---------------------------------------------|-----------------|
| [`hack/test/replication.storage.openshift.io_volumegroupreplications.yaml`](../../hack/test/replication.storage.openshift.io_volumegroupreplications.yaml) | `volumegroupreplications.replication.storage.openshift.io` | `VolumeGroupReplication` |
| [`hack/test/replication.storage.openshift.io_volumegroupreplicationclasses.yaml`](../../hack/test/replication.storage.openshift.io_volumegroupreplicationclasses.yaml) | `volumegroupreplicationclasses.replication.storage.openshift.io` | `VolumeGroupReplicationClass` |
| [`hack/test/replication.storage.openshift.io_volumegroupreplicationcontents.yaml`](../../hack/test/replication.storage.openshift.io_volumegroupreplicationcontents.yaml) | `volumegroupreplicationcontents.replication.storage.openshift.io` | `VolumeGroupReplicationContent` |

They are **OpenAPI schemas generated by kubebuilder/controller-gen** (see `metadata.annotations.controller-gen.kubebuilder.io/version` inside each file). The **API group** is **`replication.storage.openshift.io`** (naming convention shared with other replication CRDs in kubernetes-csi-addons).

#### Where and how they are loaded onto the clusters

**Script:** [`scripts/setup-csi-storage-resources.sh`](../../scripts/setup-csi-storage-resources.sh) (invoked from **`make setup-csi-replication`** / `scripts/setup-csi-replication.sh`, with **current working directory = repo root**).

**Mechanism:** For each context **`dr1`** and **`dr2`**, the script runs:

`kubectl --context=<ctx> apply -f hack/test/<file>.yaml`

for the three paths in the `VGR_CRDS` variable (see lines 26–34 of that script). Errors are ignored (`2>/dev/null || true`) so a repeat apply stays idempotent.

#### Canonical upstream source (same CRDs)

The **authoritative project** for these definitions is **[kubernetes-csi-addons](https://github.com/csi-addons/kubernetes-csi-addons)**:

| What | Upstream location |
|------|-------------------|
| **Go API types** (source of the OpenAPI schema) | [`api/replication.storage/v1alpha1/volumegroupreplication_types.go`](https://github.com/csi-addons/kubernetes-csi-addons/tree/main/api/replication.storage/v1alpha1) (and `volumegroupreplicationclass_types.go`, `volumegroupreplicationcontent_types.go`) |
| **Per-CRD YAML** (generated; same content shape as `hack/test/` files) | [`config/crd/bases/replication.storage.openshift.io_volumegroupreplications.yaml`](https://github.com/csi-addons/kubernetes-csi-addons/blob/main/config/crd/bases/replication.storage.openshift.io_volumegroupreplications.yaml) and the matching `*_volumegroupreplicationclasses.yaml` / `*_volumegroupreplicationcontents.yaml` files |
| **Aggregated bundle** (includes these three among other CRDs) | Built into [`deploy/controller/crds.yaml`](https://github.com/csi-addons/kubernetes-csi-addons/blob/main/deploy/controller/crds.yaml) on branch **`main`** — this is what **`test/addons/csi-addons/kustomization.yaml`** applies during **`drenv start`** (§2.1) |

So **one logical source**: kubernetes-csi-addons **generates** CRDs from the **`api/replication.storage/v1alpha1`** types and ships them as **`config/crd/bases/*.yaml`** and as part of **`deploy/controller/crds.yaml`**.

#### Why `hack/test/` copies exist if `crds.yaml` already includes VGR

- **Re-apply after cluster bring-up:** `setup-csi-storage-resources` runs later in the pipeline and **re-applies** the three files so the schema on the cluster matches the **pinned in-tree** YAML even if the remote `crds.yaml` revision or merge order differed.
- **CI and other workflows:** `.github/workflows/ramen.yaml` applies the whole **`hack/test/`** directory; having VGR CRDs there keeps them **discoverable and versioned with RamenDR**.
- **Possible drift:** The `controller-gen` version comment in a given `hack/test/` file may be **older or newer** than current upstream `main`; treat **upstream `config/crd/bases/`** as the reference when reconciling diffs.

These `hack/test/` copies were added in RamenDR commit **`0e1a5446`** (“VolumeGroup replication support…”).

### 2.3 VolumeGroup CRDs (optional — different API from VGR)

The same script applies **if the files exist**:

| File | API |
|------|-----|
| `hack/test/volumegroup.storage.openshift.io_volumegroups.yaml` | `VolumeGroup` |
| `hack/test/volumegroup.storage.openshift.io_volumegroupclasses.yaml` | `VolumeGroupClass` |
| `hack/test/volumegroup.storage.openshift.io_volumegroupcontents.yaml` | `VolumeGroupContent` |

**Group:** `volumegroup.storage.openshift.io`. These CRDs support the **user creates `VolumeGroup`** → controller calls CSI **`CreateVolumeGroup`** → user creates **`VolumeReplication` with `dataSource.kind=VolumeGroup`** pattern (Method 2 in [csi-replication-methods-and-status.md](./csi-replication-methods-and-status.md)). That is **orthogonal** to **VolumeGroupReplication**: VGR does its grouping via **VGRC + CSI RPCs** (§1.1), not via this `VolumeGroup` CR.

A working Method 2 flow still needs a **`VolumeGroup` CR reconciler** (not merged as the primary approach in kubernetes-csi-addons; see PR history in the methods doc). Sample manifests under `test/yaml/vgr/` (`volumegroup.yaml`, `vr-volumegroup.yaml`) target that pattern when a controller is available.

### 2.4 CI / full hack bundle

`.github/workflows/ramen.yaml` applies `kubectl apply -f hack/test/` for broader CRD coverage in CI; local CSI setup relies on the **subset** above plus the csi-addons kustomization.

### 2.5 Container images: URLs, registries, and upstream repos

**Authoritative list in this repo:** [`config/required-images.txt`](../../config/required-images.txt) — URLs pulled and mirrored to **`localhost:5000/...`** during **`scripts/setup-csi-replication.sh`**. **`scripts/preload-images.sh`** loads a subset directly into **minikube** (**dr1** / **dr2**). Minikube may use **`MINIKUBE_REGISTRY_MIRROR=http://localhost:5000`**.

| Image URL prefix / examples | Published by | Upstream source repository / project |
|-----------------------------|--------------|--------------------------------------|
| **`quay.io/rook/ceph:*`** (e.g. `v1.18.9`) | [Rook](https://quay.io/organization/rook) | [rook/rook](https://github.com/rook/rook) |
| **`quay.io/ceph/ceph:*`** (e.g. `v19`) | Red Hat / Ceph | [ceph/ceph-container](https://github.com/ceph/ceph-container) |
| **`quay.io/cephcsi/cephcsi:*`** (e.g. `v3.11.0`, `v3.15.0`) | Ceph CSI | [ceph/ceph-csi](https://github.com/ceph/ceph-csi) |
| **`registry.k8s.io/sig-storage/*`** | Kubernetes **SIG Storage** | [kubernetes-csi](https://github.com/kubernetes-csi) (external-provisioner, external-attacher, etc.) |
| **`quay.io/csiaddons/k8s-controller:*`**, **`quay.io/csiaddons/k8s-sidecar:*`** | CSI Addons | [csi-addons/kubernetes-csi-addons](https://github.com/csi-addons/kubernetes-csi-addons) |
| **`quay.io/nladha/csiaddons-*:cg`** | Third-party registry | Experimental / preload-only; not official CSI Addons releases |
| **`registry.k8s.io/kubebuilder/kube-rbac-proxy:*`** | kubebuilder | [brancz/kube-rbac-proxy](https://github.com/brancz/kube-rbac-proxy) |
| **`alpine:*`**, **`docker.io/registry:*`**, **`registry.k8s.io/e2e-test-images/busybox:*`** | Library / test images | Standard public images (see `required-images.txt`) |

**Scripts that pin or repair images on live clusters:** [`hack/fix-csi-provisioners.sh`](../../hack/fix-csi-provisioners.sh), [`hack/fix-csi-addons-versions.sh`](../../hack/fix-csi-addons-versions.sh), [`scripts/fix-csi-addons-tls.sh`](../../scripts/fix-csi-addons-tls.sh) (may restore **`quay.io/cephcsi/cephcsi:v3.15.0`** on **`csi-rbdplugin`**). The CSI Addons **Deployment** image comes from upstream **`setup-controller.yaml`** and is then aligned by **`fix-csi-addons-versions`**.

---

## 3. Required CRDs (by feature)

### 3.1 VolumeGroupReplication (Method 3) — supported test path

**Required:**

- `VolumeGroupReplication`, `VolumeGroupReplicationClass`, `VolumeGroupReplicationContent` — §2.2.
- `VolumeReplication`, `VolumeReplicationClass` — from CSI Addons §2.1 (**VolumeGroupReplication** reconciler creates per-volume **VolumeReplication** objects; **VolumeGroupReplicationContent** reconciler drives CSI **VolumeGroup** RPCs — §1.1).

**Operational requirements (not CRDs):**

- CSI Addons **v0.13+** with working **VolumeGroupReplication** and **VolumeGroupReplicationContent** controllers (`test/test-csi-volumegroupreplication.sh` header).
- Ceph CSI / RBD with group replication support; see [csi-replication-methods-and-status.md](./csi-replication-methods-and-status.md) for Identity API / capability nuances and known issues (e.g. ceph-csi#6190).

**VolumeGroupReplicationClass** resources such as `vgrc-1m`, `vgrc-2m`, `vgrc-5m` are created by the **rbd-mirror** addon data (`test/addons/rbd-mirror/start-data/vgrc.yaml` and related flow).

### 3.2 `VolumeGroup` CR + `VolumeReplication` (Method 2) — separate from VGR

**Required CRDs (manifests in repo):**

- `VolumeGroup`, `VolumeGroupClass`, `VolumeGroupContent` — §2.3.
- `VolumeReplication`, `VolumeReplicationClass` — §2.1.

**Not satisfied by VGR:** this pattern needs a **`VolumeGroup` CR controller** that reconciles `VolumeGroup` / `VolumeGroupContent` (kubernetes-csi-addons [PR #402](https://github.com/csi-addons/kubernetes-csi-addons/pull/402) was closed; upstream group replication for this repo’s tests is **VolumeGroupReplication** — [PR #588](https://github.com/csi-addons/kubernetes-csi-addons/pull/588)). **Do not confuse** with the CSI volume group state held on **`VolumeGroupReplicationContent`** (§1.1).

---

## 4. Fixes involving Service and “Node” (CSIAddonsNode / controller path)

### 4.0 Issues that blocked the CSI Addons **controller** ↔ **sidecar** path

These are the failures that prevented **VolumeReplication** / **VolumeGroupReplication** from making CSI calls until the Makefile/scripts pipeline was applied:

| Symptom / log | Root cause | Mitigation in this repo |
|---------------|------------|-------------------------|
| **`tls: first record does not look like a TLS handshake`**; repeated failed connections; **CSIAddonsNode** deleted after 3 attempts | CSI Addons **manager** defaulted to **TLS + auth** (`--enable-auth`); Ceph CSI **csi-addons** sidecars expose **plain gRPC** on **9070**. | **`fix-csi-addons-tls`**: set **`--enable-auth=false`** on **`csi-addons-controller-manager`**. Full narrative: [csi-addons-troubleshooting.md](./csi-addons-troubleshooting.md). |
| **gRPC** errors, unstable **CSIAddonsNode**, or protocol mismatch after upgrades | **Controller vs sidecar** image/tag skew. | **`fix-csi-addons-versions`**: **`quay.io/csiaddons/k8s-controller:latest`** + **`quay.io/csiaddons/k8s-sidecar:v0.11.0`** on all RBD/CephFS **csi-addons** containers; delete stale **CSIAddonsNode**. |
| CSI pods **CrashLoopBackOff**, wrong flags, bad **socket** paths | Rook defaults vs **cephcsi** / **external-provisioner** expectations (images, **log-collector**, snapshotter **command**). | **`fix-csi-provisioners`** (and TLS script’s restore path for **csi-rbdplugin**). See [CSI_PROVISIONER_FIXES.md](./CSI_PROVISIONER_FIXES.md). |
| **`no leader for the ControllerService`**; VGR stuck; only **DaemonSet** **CSIAddonsNode** | **ControllerService** leader must run on **provisioner** **Deployment** sidecar; leader-election args / readiness. | **`fix-csi-addons-tls`** sidecar **args** (leader-election timings, **`--stagingpath=...`**); **`restart-csi-service`** to recycle provisioners and controller. |
| Discovery / clients expect a **Service** for provisioner gRPC | Missing **Service** in **`rook-ceph`**. | **`restart-csi-service.sh`** creates **ClusterIP** **Services** for **csi-rbdplugin-provisioner** / **csi-cephfsplugin-provisioner** if absent (§4.1). |

### 4.1 Kubernetes **Service** resources

**Script:** `scripts/restart-csi-service.sh` (also referenced from VGR test remediation).

If missing, it creates **ClusterIP** services in `rook-ceph`:

- `csi-rbdplugin-provisioner` — selector `app: csi-rbdplugin-provisioner`, gRPC port **12345**.
- `csi-cephfsplugin-provisioner` — selector `app: csi-cephfsplugin-provisioner`, gRPC port **12346**.

These align provisioner pods with expected service-based discovery where Rook did not create a Service.

### 4.2 **CSIAddonsNode** and CSI **ControllerService** (“no leader” class of failures)

VolumeGroupReplication and VolumeReplication need the CSI Addons controller to talk to a sidecar that holds **ControllerService** leadership on the **provisioner** (deployment), not only on the node **daemonset**.

**`scripts/fix-csi-addons-tls.sh`:**

- Sets **`--enable-auth=false`** on `csi-addons-controller-manager` and **`NODE_ID`** on the manager (per context: `dr1` / `dr2`).
- Patches the **`csi-addons`** container on RBD/CephFS **provisioner** deployments with explicit **args**: node id, CSIADDONS endpoint, controller port 9070, pod metadata, **`--stagingpath=/var/lib/kubelet/plugins/kubernetes.io/csi/`**, and **shorter leader-election** timings so ControllerService leadership is acquired reliably (comment in script: required for VGR “no leader” behavior).
- Optionally restores **csi-rbdplugin** / **csi-provisioner** containers if a previous bad patch left alpine/sleep or wrong flags.
- Fixes **log-collector** on RBD/CephFS **daemonsets** (long sleep loop) so pods stay healthy.
- Deletes **CSIAddonsNode** objects in `rook-ceph` and restarts CSI pods to force clean registration.

**`scripts/restart-csi-service.sh`:**

- Verifies **csi-addons** logs for “Obtained leader status”.
- Restarts **csi-rbdplugin-provisioner** and **csi-cephfsplugin-provisioner**, then **csi-addons-controller-manager**.
- **verify_fix** checks that a **CSIAddonsNode** exists for **`csi-rbdplugin-provisioner`** (controller path) and scans controller logs for **`no leader for the ControllerService`**.

### 4.3 CSIAddonsNode API field fix (capability / driver identification)

Commit **`37b1a255`**: scripts and tests use **`spec.driver.name`** on **CSIAddonsNode** (kubernetes-csi-addons API), not `spec.driverName`. **`check_cluster_csi_capabilities.sh`** was fixed so capability detection parses **JSON arrays** correctly for replication / VGR checks.

### 4.4 Provisioner image / sidecar alignment (related, not Service)

**`hack/fix-csi-provisioners.sh`:** corrects `csi-provisioner` / `csi-attacher` images, **log-collector** on provisioner deployments, and **csi-snapshotter** command issues on CephFS — see [CSI_PROVISIONER_FIXES.md](./CSI_PROVISIONER_FIXES.md) and [csi-addons-troubleshooting.md](./csi-addons-troubleshooting.md).

**`hack/fix-csi-addons-versions.sh`:** aligns controller and **csi-addons** sidecar images and clears stale **CSIAddonsNode** objects after rollout.

---

## 5. Recent commits (reference)

| Commit | Summary |
|--------|---------|
| `0e1a5446` | VGR tests, YAML under `test/yaml/vgr/`, VolumeGroup + VGR CRDs in `hack/test/`, `setup-csi-storage-resources.sh` extensions, csi-addons kustomization toward upstream `main`, docs and monitoring |
| `37b1a255` | VGR-focused capability checks; CSIAddonsNode JSON / `spec.driver.name` fixes |
| `6defc010` | Docs: VGR capabilities, Identity API, ceph-csi#6190 notes in `csi-replication-methods-and-status.md` |

---

## 6. Quick verification commands

```bash
# CRDs present
kubectl --context=dr1 get crd | grep -E 'volumegroupreplication|volumegroup\.storage'

# CSI Addons + controller path
kubectl --context=dr1 get csiaddonsnode -A
kubectl --context=dr1 -n csi-addons-system get deploy csi-addons-controller-manager -o jsonpath='{.spec.template.spec.containers[0].args}'; echo

# VGR smoke (after setup)
make test-csi-volumegroupreplication
```

---

**Summary:** **VolumeGroupReplication** is activated by: **(1)** installing **CSI Addons** CRDs + controller (**§2.1**) and **re-applying VGR CRDs** from **`hack/test/`** (**§2.2**); **(2)** mirroring and pinning **container images** (**§2.5**, **`fix-csi-provisioners`**, **`fix-csi-addons-versions`**); **(3)** fixing **controller→sidecar gRPC** (**TLS off**, **NODE_ID**, sidecar **args**, **CSIAddonsNode** refresh — **§4.0**, **`fix-csi-addons-tls`**); **(4)** optional **provisioner Services** and **`restart-csi-service`** for leader / connectivity (**§4**); **(5)** storage, **VRC**/**VGRC**, and **RBD mirroring** (**§1**, **`setup-rbd-mirroring`**). The **CSI volume group** for VGR is recorded on **`VolumeGroupReplicationContent`**, not via the optional **`VolumeGroup`** CR API (**§2.3**).
