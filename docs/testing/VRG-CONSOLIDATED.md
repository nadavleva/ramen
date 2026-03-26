<!--
SPDX-FileCopyrightText: The RamenDR authors
SPDX-License-Identifier: Apache-2.0
-->

# VolumeReplicationGroup (VRG): Complete Documentation

Comprehensive guide to RamenDR's VolumeReplicationGroup and how it handles PersistentVolumeClaim (PVC) replication across disaster recovery clusters.

## Quick Navigation

### By Role
- **Operators**: [Architecture Overview](#architecture) → [StorageClass Role](#storage-class-role) → [Configuration Examples](#examples)
- **Developers**: [Code Flow & Implementation](#code-flow) → [PVC Selection Logic](#selection-logic) → [VGRMapFunc & Watching](#vgr-watching)
- **Testers/QA**: [Decision Diagram](#decision-tree) → [StorageClass Verification](#storage-class-role) → [Test Scenarios](#test-scenarios)

### By Task
- **"How does VRG pick VolRep vs VolSync?"** → [Selection Logic](#selection-logic) + [StorageClass Role](#storage-class-role)
- **"What StorageClass configuration do I need?"** → [StorageClass Role](#storage-class-role)
- **"What's the difference between Primary and Secondary?"** → [Primary/Secondary Operations](#operations)
- **"How do consistency groups work?"** → [Consistency Groups](#consistency-groups)
- **"How do I test VRG?"** → [Testing Guide](#test-scenarios)
- **"What's the code architecture?"** → [Code Flow](#code-flow)

---

## Architecture Overview {#architecture}

### VRG Structure

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    VolumeReplicationGroup (VRG)                         │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  Spec:                                                                   │
│  ├─ ReplicationState: Primary | Secondary                               │
│  ├─ PVCSelector:                                                        │
│  │  ├─ MatchLabels / MatchExpressions                                   │
│  │  └─ NamespaceNames                                                  │
│  ├─ Sync Mode (MetroDR - Synchronous):                                 │
│  │  ├─ PeerClasses                                                      │
│  │  └─ Enabled: true/false                                             │
│  └─ Async Mode (RegionalDR - Asynchronous):                            │
│     ├─ PeerClasses (optional)                                           │
│     ├─ ReplicationClassSelector                                         │
│     └─ Enabled: true/false                                             │
│                                                                         │
│  Status:                                                                │
│  ├─ State: Primary | Secondary | Unknown                               │
│  ├─ ProtectedPVCs: [list of protected PVC info]                        │
│  ├─ Conditions: [DataReady, DataProtected, ...]                        │
│  └─ LastGroupSyncTime, LastGroupSyncDuration                           │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Key Responsibilities

1. **PVC Discovery** - Identifies PVCs that need replication using selectors
2. **Replication Method Selection** - Determines VolRep (CSI) vs VolSync (app-level) for each PVC
3. **Consistency Grouping** - Groups PVCs for atomic replication
4. **State Management** - Manages Primary/Secondary cluster replication states
5. **Lifecycle Management** - Protects and cleans up PVCs with finalizers

---

## PVC Replication Method Selection {#selection-logic}

### Overview

The VRG controller evaluates each selected PVC and decides whether to use **VolRep** (CSI-based, storage-native replication) or **VolSync** (application-level, storage-agnostic replication). This decision is made by checking a series of conditions in a specific order. The first matching condition determines the replication method.

**Key Principle**: PVCs are evaluated sequentially, and decisions cascade - each negative result moves to the next decision point until a replication method is determined or an error occurs.

### Decision Factors Table

This table shows all decision points, where the decision data comes from, what triggers each decision, and the resulting action:

| # | Decision Point | Data Source | Where to Find | Trigger Condition | Outcome if YES | Outcome if NO |
|---|---|---|---|---|---|---|
| **1** | Is PVC marked for VolSync? | VRG Annotation | `VRG.spec.volumeReplicationGroupAnnotations[]` or `VRG.status.annotations` | Annotation `volsync-enabled: "true"` on PVC or `volsync-force-all: "true"` on VRG | **→ USE VOLSYNC** (immediate, bypass all other checks) | Continue to Decision 2 |
| **2** | Is Sync Mode enabled? | VRG Spec | `VRG.spec.sync != nil` | MetroDR (synchronous replication) configured | **→ USE VOLREP** (mandatory, no fallback) | Check Async Mode (Decision 3) |
| **3** | Is Async Mode enabled? | VRG Spec | `VRG.spec.async != nil` | RegionalDR (asynchronous replication) configured | Continue to Decision 4 | ERROR: No replication mode configured |
| **4** | Are PeerClasses defined? | VRG Spec | `VRG.spec.async.peerClasses[]` | Length > 0 | Use PeerClass matching (Decision 5) | Use simple SC matching (Decision 6) |
| **5** | Does PeerClass match StorageClass? | PeerClass Config + SC Name | `peerClass.storageClassName` matches PVC's `storageClassName` | PeerClass found with matching SC name | Continue to Decision 7 | ERROR: No matching PeerClass |
| **6** | Does SC provisioner match VRC? | StorageClass + VolumeReplicationClass | `StorageClass.provisioner` vs `VolumeReplicationClass.provisioner` | Provisioner values match | **→ USE VOLREP** | **→ USE VOLSYNC** (fallback) |
| **7** | Has ReplicationID in PeerClass? | PeerClass Config | `peerClass.replicationId` or `peerClass.groupReplicationId` | ReplicationID field not empty | Continue to Decision 8 | Continue to Decision 9 |
| **8** | Does VRC exist with matching labels? | VolumeReplicationClass Resources | `VolumeReplicationClass.labels[storageid]`, `labels[replicationid]`, `provisioner` | All labels match PeerClass and SC | **→ USE VOLREP** | ERROR: VRC not found |
| **9** | Does VolumeSnapshotClass exist? | VolumeSnapshotClass Resources | `VolumeSnapshotClass.driver` and `labels[storageid]` | SnapshotClass matches SC provisioner | **→ USE VOLSYNC** | ERROR: No SnapshotClass |

### Key Decision Triggers & Data Sources

**Decision 1 - VolSync Override**:
- **Data Source**: PVC/VRG Annotations
- **Specific Fields**:
  - `VRG.metadata.annotations["volsync-force-all"]` (affects all PVCs)
  - PVC-specific annotations (if supported)
- **Priority**: Highest - overrides all other decisions

**Decision 2 - Replication Mode**:
- **Data Source**: VRG Specification
- **Specific Fields**:
  - `VRG.spec.sync` (MetroDR mode)
  - `VRG.spec.async` (RegionalDR mode)
- **Behavior**: Exactly one must be configured, never both

**Decision 3-4 - PeerClass Configuration**:
- **Data Source**: VRG Async Spec
- **Specific Fields**:
  - `VRG.spec.async.peerClasses[]` (array of peer class definitions)
  - `peerClasses[].storageClassName` (matches SC name)
  - `peerClasses[].replicationId` (triggers VolRep decision)
  - `peerClasses[].groupReplicationId` (for consistency groups)
- **Behavior**: Optional but determines matching strategy

**Decision 5-9 - Resource Matching**:
- **Data Source**: Kubernetes Resources
- **Specific Fields**:
  - StorageClass: `provisioner`, `labels[ramendr.openshift.io/storageid]`
  - VolumeReplicationClass: `provisioner`, `labels[ramendr.openshift.io/storageid]`, `labels[ramendr.openshift.io/replicationid]`
  - VolumeGroupReplicationClass: `provisioner`, `labels[ramendr.openshift.io/storageid]`, `labels[ramendr.openshift.io/groupreplicationid]`
  - VolumeSnapshotClass: `driver`, `labels[ramendr.openshift.io/storageid]`

---

### Decision Tree {#decision-tree}

```
┌──────────────────────────────────────────────────────────────────────┐
│                                                                       │
│  START: Evaluate PVC for replication                                 │
│                                                                       │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │ Decision 1: Is PVC marked for VolSync?                         │  │
│  │ (VRG annotation or VRG.spec.volSync.disabled)                 │  │
│  └────┬─────────────────────────────────────────────────┬────────┘  │
│       │ YES: Force VolSync                     NO: Check Mode       │
│       │                                                │             │
│       ├──────────────────────────────────────────────┘             │
│       │                                                │             │
│       ▼                                                ▼             │
│  ┌────────────────────────────────────┐  ┌──────────────────────┐   │
│  │ Decision 2: Is Async mode enabled? │  │ Is Sync mode?        │   │
│  │ (VRG.spec.async != nil)            │  │ (for MetroDR)        │   │
│  └────┬──────────────────────┬────────┘  └──────────────────────┘   │
│       │ YES: Use Async Logic │ NO: Use Sync Logic             │       │
│       │                      │                      │                │
│       ▼                      ▼                      ▼                │
│  ┌─────────────────┐   ┌────────────────┐   ┌────────────────┐     │
│  │ Async Logic:    │   │ Sync Logic:    │   │ Sync Logic:    │     │
│  │ (Regional DR)   │   │ (MetroDR)      │   │ (MetroDR)      │     │
│  │                 │   │                │   │                │     │
│  │ Check PeerClass │   │ All VolRep     │   │ No Async       │     │
│  │ or SC match     │   │ (no fallback)  │   │                │     │
│  │                 │   │                │   │ → Use VolRep   │     │
│  └────┬────────────┘   └────────────────┘   └────────────────┘     │
│       │                                                │             │
│       ▼                                                │             │
│  ┌────────────────────────────────────┐               │             │
│  │ Decision 3: Has ReplicationID?     │               │             │
│  │ (peerClass.replicationId or        │               │             │
│  │  peerClass.groupReplicationId)     │               │             │
│  └────┬──────────────────────┬────────┘               │             │
│       │ YES: Use VolRep │ NO: Check VolumeSnapClass  │             │
│       │                 │                            │             │
│       ▼                 ▼                            ▼             │
│  ┌──────────────┐  ┌─────────────────────────────┐  │             │
│  │ → USE VOLREP │  │ VolumeSnapshotClass exists? │  │             │
│  │              │  │ (for VolSync)               │  │             │
│  │ - CSI Based  │  └────┬──────────────┬──────────┘  │             │
│  │ - Grouped    │       │ YES          │ NO          │             │
│  │ - Atomic     │       │              │             │             │
│  └──────────────┘       ▼              ▼             │             │
│                    ┌──────────┐  ┌──────────────┐   │             │
│                    │ USE      │  │ ERROR:       │   │             │
│                    │ VOLSYNC  │  │ No valid     │   │             │
│                    │          │  │ replication  │   │             │
│                    │ - App    │  │ method       │   │             │
│                    │ - Level  │  └──────────────┘   │             │
│                    │ - Flex   │                     │             │
│                    └──────────┘                     │             │
│                                                     ▼             │
│                                              ┌──────────────┐    │
│                                              │ → USE VOLREP │    │
│                                              │              │    │
│                                              │ - CSI Based  │    │
│                                              │ - Atomic     │    │
│                                              └──────────────┘    │
│                                                                   │
└──────────────────────────────────────────────────────────────────────┘
```

### Selection Criteria Details

#### 1. Explicit VolSync Marking
- **PVC Annotation**: `volsync-enabled: "true"` (if set on PVC)
- **VRG Annotation**: `volsync-force-all: "true"` (affects all PVCs)
- **Result**: **Use VolSync immediately** (bypasses all other checks)

#### 2. Sync vs Async Mode
- **Sync Mode** (MetroDR): `VRG.spec.sync != nil`
  - **All PVCs → VolRep** (no fallback, must have VolumeReplicationClass)
  - Requires synchronous replication capability
  
- **Async Mode** (RegionalDR): `VRG.spec.async != nil`
  - **Mixed selection** (can use VolRep or VolSync)
  - Has fallback options

#### 3. PeerClass Matching (Async mode)

**No PeerClasses** (`len(peerClasses) == 0`):
```
For each PVC:
  Get StorageClass
  Match SC.provisioner to VolumeReplicationClass.provisioner
    ├─ MATCH → Use VolRep
    └─ NO MATCH → Use VolSync (fallback)
```

**With PeerClasses** (`len(peerClasses) > 0`):
```
For each PVC:
  Get StorageClass
  Find PeerClass matching SC name
    ├─ NOT FOUND → ERROR
    └─ FOUND:
       Check ReplicationID/GroupReplicationID
       ├─ Has ID → Find matching VolumeReplicationClass
       │            ├─ FOUND → Use VolRep
       │            └─ NOT FOUND → ERROR
       └─ No ID → Check VolumeSnapshotClass
                   ├─ EXISTS → Use VolSync
                   └─ NOT EXISTS → ERROR
```

#### 4. StorageClass Impact on Selection

**StorageClass is CRITICAL** - it directly determines replication method through multiple decision points:

**Decision Point 1: Provisioner Matching** (Simple case, no PeerClasses)
```
StorageClass.provisioner (e.g., "rook-ceph.rbd.csi.ceph.com")
    ↓
Compare against ALL VolumeReplicationClass.provisioner values
    ├─ MATCH FOUND → Use VolRep
    └─ NO MATCH → Use VolSync (fallback)
```

**Decision Point 2: StorageID Label Required** (Advanced case, with PeerClasses)
```
StorageClass must have label: ramendr.openshift.io/storageid
    ├─ MISSING → ERROR: Cannot proceed
    └─ PRESENT:
        ├─ StorageID value must exist in PeerClass.storageId[] array
        │  ├─ YES → Can continue to next decision
        │  └─ NO → ERROR: StorageID mismatch
        │
        └─ StorageID must match replication class label
           ├─ YES → Correct replication class found
           └─ NO → ERROR: Cannot find matching replication class
```

**Decision Point 3: Provisioner Must Match** (Finding replication classes)
```
StorageClass.provisioner must match:
  - VolumeReplicationClass.provisioner (for VolRep)
  - VolumeGroupReplicationClass.provisioner (for VolRep groups)
  - VolumeSnapshotClass.driver (for VolSync)
    
Any mismatch → ERROR: No compatible replication class
```

#### 5. Label Requirements

**StorageClass (REQUIRED)**:
```yaml
metadata:
  labels:
    ramendr.openshift.io/storageid: "ceph-cluster-1"
```

**VolumeReplicationClass** (for VolRep):
```yaml
metadata:
  labels:
    ramendr.openshift.io/storageid: "ceph-cluster-1"      # Must match SC
    ramendr.openshift.io/replicationid: "rep-1"           # Must match peerClass.replicationId
provisioner: rook-ceph.rbd.csi.ceph.com                   # Must match SC.provisioner
```

**VolumeGroupReplicationClass** (for consistency groups):
```yaml
metadata:
  labels:
    ramendr.openshift.io/storageid: "ceph-cluster-1"           # Must match SC
    ramendr.openshift.io/groupreplicationid: "group-rep-1"    # Must match peerClass.groupReplicationId
provisioner: rook-ceph.rbd.csi.ceph.com                        # Must match SC.provisioner
```

---

## Primary and Secondary Operations {#operations}

### Primary Cluster (Active)

**State**: `VRG.spec.replicationState = Primary`

**PVC Handling**:
```
Primary Cluster Operations
├─ Discover PVCs matching selector
├─ Separate into VolRep and VolSync groups
├─ For VolRep PVCs:
│  ├─ Create VolumeReplication resource
│  ├─ CSI Addon syncs to secondary (read-only copy)
│  └─ Label with consistency group (if enabled)
├─ For VolSync PVCs:
│  ├─ Create ReplicationSource (VolSync)
│  ├─ Takes snapshots and sends to secondary
│  └─ Label with consistency group (if enabled)
├─ Workload active and reading/writing PVCs
└─ Monitor replication status
```

**VRG Status**:
- `state: Primary` (desired state achieved)
- `conditions.DataReady: True` (PVCs ready for use)
- `conditions.DataProtected: True` (replication working)

### Secondary Cluster (Standby)

**State**: `VRG.spec.replicationState = Secondary` (before failover)

**PVC Handling**:
```
Secondary Cluster Operations (Standby)
├─ VRG created in Secondary namespace (typically)
├─ PVCs NOT automatically created on secondary
│  (created during failover promotion)
├─ For VolRep:
│  ├─ Create VolumeReplication resource
│  ├─ CSI Addon receives replicated data
│  └─ Storage remains read-only
├─ For VolSync:
│  ├─ Create ReplicationDestination (VolSync)
│  ├─ Receives snapshots from primary
│  └─ Maintains point-in-time copies
├─ Workload NOT running (waiting for failover)
└─ Monitor replication status
```

**VRG Status**:
- `state: Secondary` (standby mode)
- `conditions.DataReady: True` (replicated data available)
- `conditions.DataProtected: Nil` (ignored on secondary)

### Failover: Secondary → Primary

**Trigger**: `VRG.spec.replicationState = Secondary → Primary` on secondary cluster

**Process**:
```
1. Update VRG on secondary:
   spec.replicationState = Primary

2. VRG Reconciler on secondary:
   ├─ Separate PVCs (same logic as before)
   ├─ Promote storage to read-write
   │  ├─ VolRep: CSI Addon handles promotion
   │  └─ VolSync: Promote destination volumes
   ├─ Create missing PVCs/PVs on secondary
   ├─ Update labels and annotations
   └─ Update conditions to Primary-like state

3. Workload application starts:
   ├─ Applications can now use PVCs
   ├─ PVCs become read-write
   └─ Secondary is now the new Primary

4. Time to recover (if needed):
   ├─ Fix original primary
   ├─ Failback: Update VRG on original primary to Secondary
   └─ Resume replication
```

---

## Consistency Groups {#consistency-groups}

### What Are Consistency Groups?

**Definition**: Multiple PVCs replicated together as a single atomic unit

**Purpose**: Ensure point-in-time consistency across multiple volumes

**Use Cases**:
- Database + logs volumes (must be in sync)
- Multi-tier applications (must be consistent)
- Complex workloads with multiple storage tiers

### How Consistency Groups Work

**Labeling**:
```yaml
# VolRep consistency group
metadata:
  labels:
    csi.io/group: "group-rep-1"  # GroupReplicationID

# VolSync consistency group
metadata:
  labels:
    csi.io/group: "app-ns-ceph-cluster-1"  # {namespace}-{storageId}
```

**CSI Addon Behavior**:
- Groups PVCs with same `csi.io/group` label
- Replicates all PVCs in group together
- Ensures atomic snapshots
- Reports unified group status

### Enabling Consistency Groups

**In VRG PeerClass**:
```yaml
spec:
  async:
    peerClasses:
    - storageClassName: rook-ceph-block
      grouping: true  # ← Enable consistency groups
      replicationId: "rep-1"
```

**Result**:
- PVCs labeled with group ID before replication starts
- CSI Addon treats them as atomic unit
- All PVCs synced at same point-in-time

---

## Code Flow & Implementation {#code-flow}

### Reconciliation Entry Point

```
volumereplicationgroup_controller.go
│
└─ Reconcile() [line 403]
   ├─ Fetch VolumeReplicationGroup instance
   ├─ Initialize VRGInstance struct
   └─ Call processVRG()
      │
      └─ processVRG() [line 558]
         ├─ validateVRGState()
         ├─ validateVRGMode()
         ├─ updatePVCList()
         │  │
         │  └─► Calls either:
         │      ├─ updateSyncPVCs() → All VolRep (Sync/MetroDR mode)
         │      └─ updateAsyncPVCs() → Mixed VolRep/VolSync selection
         │
         └─ processAsPrimary() or processAsSecondary()
```

### updateAsyncPVCs() Function

**Location**: `volumereplicationgroup_controller.go:732`

```go
func (v *VRGInstance) updateAsyncPVCs(pvcList *corev1.PersistentVolumeClaimList) error {
    // STEP 1: Fetch all VolumeReplicationClass resources
    if err := v.updateReplicationClassList(); err != nil {
        return err  // Can't proceed without replication class catalog
    }

    // STEP 2: Special handling for VRG being deleted
    if util.ResourceIsDeleted(v.instance) {
        v.separatePVCsUsingVRGStatus(pvcList)
        return nil
    }

    // STEP 3: Check for offloaded replication (handled by storage, not K8s)
    offloaded, err := v.processOffloadedPVCs(pvcList)
    if err != nil {
        return err
    }
    if offloaded {
        return nil  // All PVCs handled by storage layer
    }

    // STEP 4: Main separation logic - classify each PVC
    return v.separateAsyncPVCs(pvcList)
}
```

### separateAsyncPVCs() - Main Separation Logic

**Location**: `volumereplicationgroup_controller.go:1095`

```go
func (v *VRGInstance) separateAsyncPVCs(pvcList *corev1.PersistentVolumeClaimList) error {
    peerClasses := v.instance.Spec.Async.PeerClasses

    // Process each PVC
    for idx := range pvcList.Items {
        pvc := &pvcList.Items[idx]
        scName := pvc.Spec.StorageClassName

        // Get and validate StorageClass
        storageClass, err := v.validateAndGetStorageClass(scName, pvc)
        if err != nil {
            return err
        }

        // BRANCH 1: No PeerClasses defined - simple matching
        if len(peerClasses) == 0 {
            v.separatePVCsUsingOnlySC(storageClass, pvc)
        } else {
            // BRANCH 2: PeerClasses defined - advanced matching
            err = v.separatePVCUsingPeerClassAndSC(peerClasses, storageClass, pvc)
            if err != nil {
                return err
            }
        }
    }

    // Validation: every PVC must be classified
    if len(pvcList.Items) != (len(v.volRepPVCs) + len(v.volSyncPVCs)) {
        return fmt.Errorf("not all PVCs protected")
    }

    v.log.Info(fmt.Sprintf("Found %d PVCs targeted for VolRep and %d for VolSync",
        len(v.volRepPVCs), len(v.volSyncPVCs)))

    return nil
}
```

### Case 1: Simple StorageClass Matching

**Location**: `volumereplicationgroup_controller.go:1003`

**When Used**: `len(peerClasses) == 0`

```go
func (v *VRGInstance) separatePVCsUsingOnlySC(
    storageClass *storagev1.StorageClass, 
    pvc *corev1.PersistentVolumeClaim,
) {
    replicationClassMatchFound := false
    pvcEnabledForVolSync := util.IsPVCMarkedForVolSync(v.instance.GetAnnotations())

    if !pvcEnabledForVolSync {
        // Try to match StorageClass provisioner with VolumeReplicationClass
        for _, replicationClass := range v.replClassList.Items {
            if storageClass.Provisioner == replicationClass.Spec.Provisioner {
                v.volRepPVCs = append(v.volRepPVCs, *pvc)
                replicationClassMatchFound = true
                break
            }
        }
    }

    if !replicationClassMatchFound {
        v.volSyncPVCs = append(v.volSyncPVCs, *pvc)
    }
}
```

### Case 2: Advanced PeerClass Matching

**Location**: `volumereplicationgroup_controller.go:1027`

**When Used**: `len(peerClasses) > 0`

```go
func (v *VRGInstance) separatePVCUsingPeerClassAndSC(
    peerClasses []ramendrv1alpha1.PeerClass,
    storageClass *storagev1.StorageClass,
    pvc *corev1.PersistentVolumeClaim,
) error {
    // STEP 1: Find matching PeerClass
    peerClass, err := v.findPeerClassMatchingSC(storageClass, peerClasses, pvc)
    if err != nil {
        return err
    }
    if peerClass == nil {
        return fmt.Errorf("peerClass matching storageClass %s not found", storageClass.GetName())
    }

    // STEP 2: Check if PVC is explicitly forced to VolSync
    pvcEnabledForVolSync := util.IsPVCMarkedForVolSync(v.instance.GetAnnotations())

    if !pvcEnabledForVolSync {
        // STEP 3: Check if PeerClass has ReplicationID
        if peerClass.ReplicationID != "" || peerClass.GroupReplicationID != "" {
            // STEP 4: Find matching VolumeReplicationClass
            replicationClass := v.findReplicationClassUsingPeerClass(peerClass, storageClass)
            if replicationClass != nil {
                // Add consistency group label if enabled
                if peerClass.Grouping {
                    if err := v.addVolRepConsistencyGroupLabel(pvc); err != nil {
                        return err
                    }
                }
                // ► CLASSIFY AS VOLREP
                v.volRepPVCs = append(v.volRepPVCs, *pvc)
                return nil
            }
            return fmt.Errorf("failed to find replicationClass for PVC %s/%s", 
                pvc.Namespace, pvc.Name)
        }
    }

    // STEP 5: Fallback to VolSync
    if v.instance.Spec.VolSync.Disabled {
        return fmt.Errorf("VolSync disabled but needed for PVC %s/%s", pvc.Namespace, pvc.Name)
    }

    snapClass, err := v.findVolSnapClass(storageClass)
    if err != nil || snapClass == nil {
        return fmt.Errorf("failed to find snapshotClass for PVC %s/%s", pvc.Namespace, pvc.Name)
    }

    if peerClass.Grouping && !v.instance.Spec.RunFinalSync {
        if err := v.addConsistencyGroupLabel(pvc); err != nil {
            return err
        }
    }

    // ► CLASSIFY AS VOLSYNC
    v.volSyncPVCs = append(v.volSyncPVCs, *pvc)
    return nil
}
```

### Helper Functions

#### findReplicationClassUsingPeerClass()

**Location**: `volumereplicationgroup_controller.go:1128`

**Purpose**: Match VolumeReplicationClass to PeerClass + StorageClass

```go
func (v *VRGInstance) findReplicationClassUsingPeerClass(
    peerClass *ramendrv1alpha1.PeerClass,
    storageClass *storagev1.StorageClass,
) client.Object {
    // Matching criteria:
    // 1. StorageID label must match
    // 2. ReplicationID or GroupReplicationID must match
    // 3. Provisioner must match
    
    if peerClass.Grouping {
        // Search for VolumeGroupReplicationClass
        for _, grc := range v.grpReplClassList.Items {
            if grc.Spec.Provisioner != storageClass.Provisioner {
                continue
            }
            if grc.Labels[StorageIDLabel] != storageClass.Labels[StorageIDLabel] {
                continue
            }
            if grc.Labels[GroupReplicationIDLabel] == peerClass.GroupReplicationID {
                return &grc
            }
        }
    } else {
        // Search for regular VolumeReplicationClass
        for _, rc := range v.replClassList.Items {
            if rc.Spec.Provisioner != storageClass.Provisioner {
                continue
            }
            if rc.Labels[StorageIDLabel] != storageClass.Labels[StorageIDLabel] {
                continue
            }
            if rc.Labels[ReplicationIDLabel] == peerClass.ReplicationID {
                return &rc
            }
        }
    }
    return nil
}
```

#### findVolSnapClass()

**Location**: `volumereplicationgroup_controller.go:1181`

**Purpose**: Validate VolumeSnapshotClass exists for VolSync

```go
func (v *VRGInstance) findVolSnapClass(storageClass *storagev1.StorageClass,
) (*snapv1.VolumeSnapshotClass, error) {
    snapClasses, err := v.volSyncHandler.GetVolumeSnapshotClasses()
    if err != nil {
        return nil, err
    }

    for _, snapClass := range snapClasses {
        // Matching: StorageID label + Driver (provisioner)
        if snapClass.Labels[StorageIDLabel] == storageClass.Labels[StorageIDLabel] &&
            snapClass.Driver == storageClass.Provisioner {
            return &snapClass, nil
        }
    }
    return nil, nil
}
```

---

## VolumeGroupReplication Watching & Event Handling {#vgr-watching}

### VGRMapFunc: Map VGR Events to VRG Reconciliation

**Location**: `volumereplicationgroup_controller.go:2260`

**Purpose**: Convert VolumeGroupReplication resource changes into VRG reconciliation requests

```go
func (r *VolumeReplicationGroupReconciler) VGRMapFunc(ctx context.Context, obj client.Object) []reconcile.Request {
    log := ctrl.Log.WithName("vgrmap").WithName("VolumeReplicationGroup")

    // Type assertion: verify this is a VolumeGroupReplication resource
    vgr, ok := obj.(*volrep.VolumeGroupReplication)
    if !ok {
        log.Info("map function received non-vgr resource")
        return []reconcile.Request{}  // Not a VGR, ignore
    }

    // Find all VRGs that depend on this VGR
    return filterVRGDependentObjects(r.Client, obj,
        log.WithValues("vgr", types.NamespacedName{Name: vgr.Name, Namespace: vgr.Namespace}))
}
```

### Event Flow

```
VGR Event (Create/Update/Delete)
    │
    ▼
VGRMapFunc is invoked
    │
    ├─ Type check: Is it a VolumeGroupReplication?
    │  ├─ YES ─────────┐
    │  └─ NO → Return empty list (ignore)
    │
    ▼
filterVRGDependentObjects(vgr)
    │
    ├─ Find all VRGs in cluster
    │
    ├─ For each VRG:
    │  ├─ Does VRG.spec.protectedNamespaces contain VGR's namespace?
    │  │  ├─ YES → Add VRG to reconcile requests
    │  │  └─ NO → Skip VRG
    │
    ▼
Return list of VRG reconciliation requests
    │
    ▼
VRG Reconciler.Reconcile() called for each VRG
    │
    ├─ Separate PVCs into VolRep/VolSync groups
    ├─ Update consistency group status
    └─ Report conditions
```

### filterVRGDependentObjects Helper

**Location**: `volumereplicationgroup_controller.go:2223`

**Purpose**: Find all VRGs that should be notified of a resource change

```go
func filterVRGDependentObjects(reader client.Reader, obj client.Object, log logr.Logger,
) []reconcile.Request {
    req := []reconcile.Request{}

    // Step 1: List all VRGs in the cluster
    var vrgs ramendrv1alpha1.VolumeReplicationGroupList
    err := reader.List(context.TODO(), &vrgs)
    if err != nil {
        log.Error(err, "Failed to get list of VolumeReplicationGroup resources")
        return req
    }

    // Step 2: Check each VRG
    for _, vrg := range vrgs.Items {
        // Filter 1: Must have protected namespaces defined
        if vrg.Spec.ProtectedNamespaces == nil || len(*vrg.Spec.ProtectedNamespaces) == 0 {
            continue
        }

        // Filter 2: Check if resource's namespace is in VRG's protected namespaces
        if slices.Contains(*vrg.Spec.ProtectedNamespaces, obj.GetNamespace()) {
            // Found a VRG that depends on this resource!
            req = append(req, reconcile.Request{
                NamespacedName: types.NamespacedName{
                    Name:      vrg.Name,
                    Namespace: vrg.Namespace,
                },
            })
        }
    }

    return req
}
```

### Watch Registration

**Location**: `volumereplicationgroup_controller.go:SetupWithManager()`

```go
// Watch VolumeGroupReplication (CSI Addon) resources
ctrlBuilder.Watches(
    &volrep.VolumeGroupReplication{},
    handler.EnqueueRequestsFromMapFunc(r.VGRMapFunc),
    builder.WithPredicates(util.CreateOrDeleteOrResourceVersionUpdatePredicate{}),
)
```

**Watch Triggers**:
- Create: New VGR created when CSI Addon initiates group replication
- Delete: VGR deleted when group replication completes
- Update: Resource version changes indicate status updates from CSI Addon

---

## StorageClass Role in PVC Replication Selection {#storage-class-role}

### Overview

**StorageClass is the PRIMARY DECISION FACTOR** for determining which replication method (VolRep or VolSync) is used for each PVC. Without proper StorageClass configuration, correct replication method selection is impossible.

### How StorageClass Drives Selection

```
PVC is selected by VRG selector
    │
    ▼
Read PVC.spec.storageClassName
    │
    ▼
Fetch StorageClass resource
    │
    ├─ REQUIRED: Check provisioner field
    │  └─ Value: "rook-ceph.rbd.csi.ceph.com" (example)
    │
    ├─ REQUIRED: Check StorageID label
    │  └─ Value: "ceph-cluster-1" (for advanced matching)
    │
    ▼
Use StorageClass attributes to make replication decision
    │
    ├─ Match provisioner against VolumeReplicationClass list
    │  └─ If match found → Can use VolRep
    │     If no match → Must use VolSync
    │
    ├─ Match StorageID label against PeerClass configuration
    │  └─ If match → PeerClass determines VolRep vs VolSync
    │     If no match → ERROR
    │
    ▼
Final Decision: VolRep or VolSync
```

### Simple Case: StorageClass Provisioner Matching

**Scenario**: No PeerClasses defined in VRG (`peerClasses: []`)

**Decision Logic**:
```
For each PVC:
    1. Get its StorageClass
    2. Extract: StorageClass.provisioner
       Example: "rook-ceph.rbd.csi.ceph.com"
    
    3. Search all VolumeReplicationClass resources:
       for each VolumeReplicationClass in cluster:
           if VRC.spec.provisioner == SC.provisioner:
               ► USE VOLREP ✓
               (Stop searching)
    
    4. If no VRC found with matching provisioner:
       ► USE VOLSYNC (fallback)
```

**Example Matching**:
```
PVC1: storageClassName = "ceph-rbd"
  └─ StorageClass ceph-rbd:
     provisioner: "rook-ceph.rbd.csi.ceph.com"
     
  └─ Check VolumeReplicationClass list:
     VRC1: provisioner = "rook-ceph.rbd.csi.ceph.com" ✓ MATCH
     
  └─ Result: PVC1 → VolRep

PVC2: storageClassName = "nfs"
  └─ StorageClass nfs:
     provisioner: "nfs-provisioner"
     
  └─ Check VolumeReplicationClass list:
     VRC1: provisioner = "rook-ceph.rbd.csi.ceph.com" (no match)
     VRC2: provisioner = "other-provisioner" (no match)
     
  └─ Result: PVC2 → VolSync (fallback)
```

### Advanced Case: StorageClass Label & PeerClass Matching

**Scenario**: PeerClasses defined in VRG

**StorageID Label is MANDATORY**:
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: rook-ceph-block
  labels:
    ramendr.openshift.io/storageid: "ceph-cluster-1"  # ← REQUIRED
provisioner: rook-ceph.rbd.csi.ceph.com
```

**Decision Logic**:
```
For each PVC:
    1. Get its StorageClass
    
    2. MANDATORY: Check for StorageID label
       if label missing → ERROR: Cannot proceed
       
    3. Match StorageClass.name to PeerClass.storageClassName:
       for each PeerClass:
           if PeerClass.storageClassName == SC.name:
               Verify: SC.label[storageid] in PeerClass.storageId[]
               if NO → ERROR: StorageID mismatch
               if YES → Continue to step 4
    
    4. Check PeerClass configuration:
       if PeerClass.replicationId defined:
           ► Find VolumeReplicationClass with matching labels
           if found → USE VOLREP ✓
           if not found → ERROR
       else (no replicationId):
           ► Check VolumeSnapshotClass
           if exists → USE VOLSYNC ✓
           if not exists → ERROR
```

**Example Advanced Matching**:
```
VRG Config:
  async:
    peerClasses:
    - storageClassName: "rook-ceph-block"
      replicationId: "rep-1"
      storageId: ["ceph-cluster-1", "ceph-cluster-2"]

PVC1: storageClassName = "rook-ceph-block"
  └─ StorageClass rook-ceph-block:
     labels:
       ramendr.openshift.io/storageid: "ceph-cluster-1"
     provisioner: "rook-ceph.rbd.csi.ceph.com"
     
  └─ Step 1: Find matching PeerClass
     PeerClass.storageClassName = "rook-ceph-block" ✓
     
  └─ Step 2: Verify StorageID
     PeerClass.storageId = ["ceph-cluster-1", "ceph-cluster-2"]
     SC.label[storageid] = "ceph-cluster-1" ✓ (in list)
     
  └─ Step 3: Check ReplicationID
     PeerClass.replicationId = "rep-1" ✓ (has value)
     
  └─ Step 4: Find VolumeReplicationClass
     Search for VRC with labels:
     - label[storageid] = "ceph-cluster-1"
     - label[replicationid] = "rep-1"
     - provisioner = "rook-ceph.rbd.csi.ceph.com"
     
  └─ Result: VRC found → PVC1 → VolRep ✓

PVC2: storageClassName = "rook-ceph-block"
  └─ StorageClass rook-ceph-block:
     labels:
       ramendr.openshift.io/storageid: "ceph-cluster-3"  # Not in list!
     provisioner: "rook-ceph.rbd.csi.ceph.com"
     
  └─ Verify StorageID:
     PeerClass.storageId = ["ceph-cluster-1", "ceph-cluster-2"]
     SC.label[storageid] = "ceph-cluster-3" ✗ (NOT in list)
     
  └─ Result: ERROR - StorageID not in PeerClass configuration
```

### StorageClass Attributes That Matter

| Attribute | Impact | Example |
|-----------|--------|---------|
| **provisioner** | **CRITICAL** - used to match against VolumeReplicationClass/VolumeSnapshotClass | `rook-ceph.rbd.csi.ceph.com` |
| **labels[ramendr.openshift.io/storageid]** | **REQUIRED** (when using PeerClasses) - must be in PeerClass.storageId[] | `ceph-cluster-1` |
| **allowVolumeExpansion** | No impact on method selection | `true` / `false` |
| **volumeBindingMode** | No impact on method selection | `Immediate` / `WaitForFirstConsumer` |
| **reclaimPolicy** | No impact on method selection | `Delete` / `Retain` |
| **parameters** | No impact on method selection | Storage-specific params |

### Common StorageClass Mistakes

**Mistake 1: Missing StorageID Label**
```yaml
# ❌ WRONG - Will fail when using PeerClasses
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: rook-ceph-block
provisioner: rook-ceph.rbd.csi.ceph.com
```
→ Error: "label (ramendr.openshift.io/storageid) not found in storageClass"

**Mistake 2: Provisioner Mismatch**
```yaml
# ❌ WRONG - VRC provisioner doesn't match
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph
provisioner: rook-ceph.rbd.csi.ceph.com  # ← SC provisioner

---
apiVersion: replication.storage.openshift.io/v1alpha1
kind: VolumeReplicationClass
metadata:
  name: replication
provisioner: some-other-provisioner  # ← VRC provisioner (MISMATCH!)
```
→ Result: PVC will use VolSync (no VRC match), even if VolRep was desired

**Mistake 3: StorageID Value in PeerClass Wrong**
```yaml
# ❌ WRONG - StorageID value doesn't match
spec:
  async:
    peerClasses:
    - storageClassName: rook-ceph-block
      storageId: ["ceph-1"]  # Only allows "ceph-1"

# But StorageClass has:
metadata:
  labels:
    ramendr.openshift.io/storageid: "ceph-2"  # "ceph-2" NOT in list!
```
→ Error: "storageID mismatch between peerClass and StorageClass"

### Storage Capabilities and Method Selection

**Different storage systems have different replication capabilities**:

| Storage Backend | VolRep Support | VolSync Support | Recommendation |
|-----------------|----------------|-----------------|-----------------|
| **Ceph RBD** | ✓ Yes | ✓ Yes | Use VolRep for better performance |
| **NFS** | ✗ No | ✓ Yes | Must use VolSync |
| **AWS EBS** | ✓ Yes (via CSI) | ✓ Yes | Use VolRep for metro, VolSync for regional |
| **Persistent.io (Datera)** | ✓ Yes | ✓ Yes | Use VolRep for consistency |
| **vSAN** | ✓ Yes | ✓ Yes | Use VolRep for synchronous |

**Selection Based on Storage Capability**:
```
If storage supports VolRep:
  └─ Define VolumeReplicationClass
  └─ Add to PeerClass.replicationId
  └─ StorageClass.provisioner MUST match VRC.provisioner
  └─ Result: VolRep selected ✓

If storage does NOT support VolRep:
  └─ Leave PeerClass.replicationId empty
  └─ Define VolumeSnapshotClass (for VolSync)
  └─ StorageClass.provisioner MUST match SnapshotClass.driver
  └─ Result: VolSync selected ✓
```

### Verification: Checking StorageClass Configuration

```bash
# List all StorageClasses with their provisioner
kubectl get sc -o custom-columns=NAME:.metadata.name,PROVISIONER:.provisioner

# Check specific StorageClass labels
kubectl get sc rook-ceph-block -o jsonpath='{.metadata.labels}' | jq .

# Check if StorageID label exists
kubectl get sc rook-ceph-block -L ramendr.openshift.io/storageid

# Find all VolumeReplicationClasses and their provisioner
kubectl get volumereplicationclass -o custom-columns=NAME:.metadata.name,PROVISIONER:.provisioner

# Find all VolumeSnapshotClasses and their driver
kubectl get volumesnapshotclass -o custom-columns=NAME:.metadata.name,DRIVER:.driver

# Check which VolumeReplicationClass matches a StorageClass provisioner
PROVISIONER=$(kubectl get sc rook-ceph-block -o jsonpath='{.provisioner}')
kubectl get volumereplicationclass -o json | jq ".items[] | select(.provisioner==\"$PROVISIONER\")"
```

---



### Example 1: Simple Async Mode (Regional DR)

```yaml
apiVersion: ramendr.openshift.io/v1alpha1
kind: VolumeReplicationGroup
metadata:
  name: mysql-vrg
  namespace: database
spec:
  replicationState: Primary
  pvcSelector:
    matchLabels:
      app: mysql
  async:
    peerClasses: []  # Empty - use StorageClass matching only
    replicationClassSelector:
      matchLabels:
        storage: ceph
```

**Result**: PVCs automatically selected based on SC provisioner matching

### Example 2: Advanced Async with PeerClasses

```yaml
apiVersion: ramendr.openshift.io/v1alpha1
kind: VolumeReplicationGroup
metadata:
  name: app-vrg
  namespace: app-ns
spec:
  replicationState: Primary
  pvcSelector:
    matchLabels:
      tier: data
  async:
    peerClasses:
    - storageClassName: rook-ceph-block
      replicationId: "rep-1"
      grouping: true
      storageId: ["ceph-cluster-1", "ceph-cluster-2"]
    replicationClassSelector:
      matchLabels:
        ceph: replication
```

**Result**: 
- PVCs on `rook-ceph-block` SC use VolRep
- Grouped into consistency groups
- Supports 2 different Ceph clusters

### Example 3: Sync Mode (Metro DR - all VolRep)

```yaml
apiVersion: ramendr.openshift.io/v1alpha1
kind: VolumeReplicationGroup
metadata:
  name: metro-vrg
  namespace: production
spec:
  replicationState: Primary
  pvcSelector:
    matchExpressions:
    - key: app
      operator: In
      values: [critical, ecommerce]
  sync:
    peerClasses:
    - storageClassName: fast-ceph-rbd
      replicationId: "metro-1"
      grouping: true
      storageId: ["ceph-metro"]
```

**Result**: 
- All PVCs must support VolRep
- No VolSync fallback
- Metro-grade synchronous replication

---

## Testing Guide {#test-scenarios}

### Test Scenario 1: Mixed VolRep/VolSync

**Setup**:
```yaml
# StorageClass 1 - supports VolRep
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph-rbd
  labels:
    ramendr.openshift.io/storageid: "ceph-1"
provisioner: rook-ceph.rbd.csi.ceph.com

---
# StorageClass 2 - no VolRep support (VolSync only)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs
  labels:
    ramendr.openshift.io/storageid: "nfs-1"
provisioner: nfs-provisioner

---
# VolumeReplicationClass for Ceph
apiVersion: replication.storage.openshift.io/v1alpha1
kind: VolumeReplicationClass
metadata:
  name: ceph-replication
  labels:
    ramendr.openshift.io/storageid: "ceph-1"
    ramendr.openshift.io/replicationid: "rep-1"
provisioner: rook-ceph.rbd.csi.ceph.com

---
# VRG
apiVersion: ramendr.openshift.io/v1alpha1
kind: VolumeReplicationGroup
metadata:
  name: mixed-vrg
spec:
  replicationState: Primary
  pvcSelector:
    matchLabels:
      app: myapp
  async:
    peerClasses: []
```

**Expected Results**:
- Ceph-backed PVCs → VolRep
- NFS-backed PVCs → VolSync

**Verify**:
```bash
# Check replication methods
kubectl get vrg mixed-vrg -o jsonpath='{.status.protectedPVCs[*].protectedByVolSync}'

# Check VolumeReplication resources created
kubectl get volumereplication

# Check ReplicationSource resources created
kubectl get replicationsource
```

### Test Scenario 2: Consistency Groups

**Setup**:
```yaml
# PeerClass with grouping enabled
apiVersion: ramendr.openshift.io/v1alpha1
kind: VolumeReplicationGroup
metadata:
  name: db-vrg
spec:
  replicationState: Primary
  pvcSelector:
    matchLabels:
      db: postgres
  async:
    peerClasses:
    - storageClassName: rook-ceph-block
      replicationId: "rep-1"
      grouping: true  # ← Enable consistency groups
      storageId: ["ceph-1"]
```

**Expected Results**:
- All PVCs get `csi.io/group` label
- CSI Addon treats as atomic unit

**Verify**:
```bash
# Check PVC labels
kubectl get pvc -o jsonpath='{range .items[*]}{.metadata.name}{" → "}{.metadata.labels.csi\.io/group}{"\n"}{end}'

# Check VolumeGroupReplication
kubectl get volumegroupreplication
```

### Test Scenario 3: Failover

**Setup**:
```bash
# On primary cluster
kubectl apply -f vrg-primary.yaml

# Simulate disaster - wait for replication
sleep 60

# Switch to secondary cluster
kubectl config use-context secondary
kubectl apply -f vrg-secondary.yaml
```

**Failover Steps**:
```bash
# 1. On secondary, update VRG to Primary
kubectl patch vrg app-vrg -p '{"spec":{"replicationState":"Primary"}}' --type merge

# 2. Wait for reconciliation
kubectl wait --for=condition=DataReady vrg/app-vrg --timeout=300s

# 3. Start workload
kubectl apply -f app-deployment.yaml

# 4. Verify PVCs are read-write
kubectl get pvc -o wide
```

**Verify**:
```bash
# Check VRG status is Primary
kubectl get vrg app-vrg -o jsonpath='{.status.state}'

# Check all PVCs ready
kubectl get pvc -o jsonpath='{.items[*].status.phase}'

# Check replication working (if replication continues)
kubectl get volumereplication -o jsonpath='{.items[*].status.state}'
```

---

## Verification Commands {#verification}

### Check Replication Method Selection

```bash
# See what method was selected for each PVC
kubectl get vrg my-vrg -o jsonpath='{.status.protectedPVCs[*]}'

# More detailed: check protectedByVolSync field
kubectl get vrg my-vrg -o json | jq '.status.protectedPVCs[] | {name: .pvcName, volSync: .protectedByVolSync}'
```

### Verify Label Matching

```bash
# Check StorageClass labels
kubectl get sc rook-ceph-block -o jsonpath='{.metadata.labels}'

# Check VolumeReplicationClass labels
kubectl get volumereplicationclass -o jsonpath='{range .items[*]}{.metadata.labels}{"\n"}{end}'

# Check PVC CG labels
kubectl get pvc -o jsonpath='{range .items[*]}{.metadata.name}{" → "}{.metadata.labels.csi\.io/group}{"\n"}{end}'
```

### Enable Verbose Logging

```bash
# Check VRG controller logs
kubectl logs -n ramen-system deployment/ramen-dr-controller -f | grep "separate PVC"

# Look for decision points:
# "separating PVC using only sc provisioner"
# "separate PVC using peerClasses"
# "Found X PVCs targeted for VolRep and Y targeted for VolSync"
```

### Check Replication Status

```bash
# VolRep status
kubectl get volumereplication -o wide

# VolSync status (Replication Source)
kubectl get replicationsource -o wide

# VolSync status (Replication Destination)
kubectl get replicationdestination -o wide

# VRG conditions
kubectl describe vrg my-vrg
```

---

## Error Conditions & Troubleshooting

| Condition | Error Message | Cause | Resolution |
|-----------|---------------|-------|-----------|
| PeerClass not found | "peerClass matching storageClass X not found" | StorageClass doesn't match any PeerClass | Define matching PeerClass or use simple SC matching |
| StorageID mismatch | "storageID mismatch between peerClass and StorageClass" | SC label doesn't match PeerClass | Add `ramendr.openshift.io/storageid` label to SC |
| No VRC found | "failed to find replicationClass matching peerClass" | VolumeReplicationClass missing or mismatched labels | Create VRC with correct labels matching peerClass |
| No VolumeSnapshotClass | "failed to find snapshotClass for PVC" | VolSync needs snapshot support, class missing | Create VolumeSnapshotClass for the storage driver |
| VolSync disabled | "VolSync is disabled" | VolSync needed but explicitly disabled | Enable VolSync in VRG spec |
| No valid method | "no PVCs are protected" | Can't use VolRep or VolSync for any PVC | Verify SC labels and replication classes |

---

## Related Source Code

**Main File**: `internal/controller/volumereplicationgroup_controller.go`
- Lines 732-1200+: PVC selection logic
- Lines 2223+: Map functions and watching
- Lines 2260+: VGRMapFunc implementation

**Related Files**:
- `api/v1alpha1/volumereplicationgroup_types.go` - VRG CRD definition
- `internal/controller/volsync/volsync_handler.go` - VolSync integration
- `internal/controller/replication/replication.go` - VolRep handling

---

**Last Updated**: March 2026
**RamenDR Version**: Latest
**Status**: Complete & Consolidated

