# Environment Contract

**What this pipeline needs from your cluster, and what it gives back.**

This document is the deliverable. The manifests are an implementation of it — one that has been run
end to end — but the contract is what you are actually adopting. If your environment satisfies
everything below, the pipeline will run. If it does not, the manifests will apply cleanly and then
fail in ways that are tedious to diagnose, so it is worth reading this first.

Every requirement here is stated as a **floor** (what must be true) alongside the **tested** value
(what was actually verified). A floor without a tested value would be a claim nobody checked; a
tested value without a floor reads as a hard requirement when it is not.

Unfamiliar with terms like ZeRO-3, world size, or GPU framebuffer? See
[docs/glossary.md](docs/glossary.md).

---

## The sequence, end to end

Four things have to happen before the first `oc apply`, in this order. Each one fails confusingly
rather than obviously if the one before it was skipped, which is the whole reason this list is at
the top rather than assembled by the reader from four scattered sections.

| # | Step | Read |
|---|---|---|
| 1 | **Install the operators.** This pipeline installs none of its own; the official install guide for each is linked in §2 | §2, §2.1 |
| 2 | **Prepare the FlashBlade.** Array-side object-store account and buckets, and the export settings the StorageClasses assume. `ansible/flashblade-prepare.yml` does the automatable part | §3, §4, §4.1 |
| 3 | **Create the secrets**, `px-pure-secret` above all — it is the one whose failure mode looks like something else entirely | §5, §12 |
| 4 | **Apply the Kustomize phases**, 00 → 10 → 20 → 30, phase by phase | §11 |

Sections 1 through 10 are the requirements those four steps exist to satisfy; §12 is what the
failures look like from the operator's side when one of them is not met.

**Node preparation is not a fifth step.** §7 lists node labels and a `MachineConfigPool`, and every
one of them matters *only* on the loopback storage-pool path that this pipeline does not take —
against the CSI-only StorageCluster this tree actually deploys, none of it is read. (Both terms are introduced
later and deliberately not defined here: the storage shape is §3, and why this tree is CSI-only
rather than loopback-backed is §12.8.)

---

## 1. Platform

| Requirement | Floor | Tested with |
|---|---|---|
| Platform | **Red Hat OpenShift.** Not Kubernetes-with-extras — see below | OCP 4.18.37 |
| Kubernetes version | ≥ 1.31 | v1.31.14 |
| Node OS | Red Hat CoreOS | RHCOS |
| GPU nodes | ≥ 2, CUDA-capable, enough VRAM for a 32B model in full-parameter fine-tuning via DeepSpeed ZeRO-3 with full CPU offload | 2 nodes, NVIDIA L40S |
| Storage nodes | ≥ 2 non-GPU worker nodes for the storage layer | 2 |

**This runs on OpenShift. Not on Kubernetes.** `base/00-platform/` uses `MachineConfig` and
`MachineConfigPool`; the event layer needs `runAsUser: 9731` patched out of the Argo Events
controller Deployment before OpenShift's namespace UID range will accept it; operator install
assumes OLM. None of those exist on vanilla Kubernetes. Porting is possible but is a rewrite of the
platform phase, not a configuration change. See [§9](#9-what-this-contract-does-not-give-you).

---

## 2. Operators and CRDs — install these first

The pipeline does **not** install its own operators. Manifests that pin operator channels go stale
with every platform release, so they are a documented prerequisite instead.

| Component | Floor | Tested with | Provides |
|---|---|---|---|
| NVIDIA GPU Operator | ≥ 26.3 | `gpu-operator-certified.v26.3.3` | GPU drivers, device plugin, DCGM |
| Node Feature Discovery | ≥ 4.18 | `nfd.4.18.0-202607311727` | the `nvidia.com/gpu.present` node label |
| Portworx Operator | ≥ 26.3 | `portworx-operator.v26.3.1` | the `StorageCluster` CRD |
| OpenShift AI (RHOAI) | ≥ 2.25 | `rhods-operator.2.25.10` | Kueue, KubeRay, the Ray CRDs |
| Argo Events | pinned upstream manifest | v1.9.7 | `EventBus`, `EventSource`, `Sensor` |

### Where to get each one

The vendor's own install guide, and nobody else's. Operator install instructions rot faster than
almost anything else in this stack, so these are links rather than transcribed steps — a copied
procedure is stale the moment the channel name changes, and it looks authoritative while being
wrong.

| Component | Official install guide |
|---|---|
| NVIDIA GPU Operator | <https://docs.nvidia.com/datacenter/cloud-native/openshift/latest/install-gpu-ocp.html> |
| Node Feature Discovery | <https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/specialized_hardware_and_driver_enablement/psap-node-feature-discovery-operator> |
| Portworx (PX-CSI) — install | <https://docs.portworx.com/portworx-csi/install/install-portworx-csi> |
| Portworx (PX-CSI) — FlashBlade backend | <https://docs.portworx.com/portworx-csi/install/prepare/flash-blade> |
| OpenShift AI (RHOAI) | <https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/2.25/html/installing_and_uninstalling_openshift_ai_self-managed/installing-and-deploying-openshift-ai_install> |
| Argo Events | <https://argoproj.github.io/argo-events/installation/> |

Four of the six links above — NVIDIA, both Portworx pages, and Argo Events — return HTTP 200 with
no redirect.

The two `docs.redhat.com` links return **HTTP 403**, and so does `https://docs.redhat.com/` itself:
that host refuses programmatic clients wholesale, so a 403 against it is evidence about the fetcher
and not about the page. Both pages are present, correctly titled and correctly versioned — *"Chapter
3. Node Feature Discovery Operator … OpenShift Container Platform | 4.18"* and *"Chapter 3.
Installing and deploying OpenShift AI … Red Hat OpenShift AI Self-Managed | 2.25"*. Open them in a
browser. If you point an automated link checker at this table, expect those two to come back 403 and
do not read it as a dead link.

Each page is the vendor's own documentation for the right product and the right install mechanism:
OperatorHub/OLM for the four operators, and a pinned upstream manifest for Argo Events. Two caveats
are worth having before you click, because both are cases where the documentation does not reach as
far as this contract does:

- **The NVIDIA and Portworx links track "current", not the floors in the table above.** The NVIDIA
  install page is the `latest` documentation set and states a GPU Operator version only in passing,
  for an unrelated OpenShift release. The Portworx pages *are* versioned — both were served as
  **Version 26.2**, with a selector offering 26.2, 26.1, 25.8, 25.6, 25.4, 25.2 and 25.1 — but the
  URL itself is unpinned and follows whatever is current, and 26.2 was the newest doc set on offer
  against the 26.3 operator build in the table above. Check the version you are actually installing
  against the floor yourself. The Red Hat links *are* pinned — to OpenShift 4.18 and RHOAI 2.25,
  matching the tested values.
- **The Portworx install page does not mention `--oem px-csi`, `px-pure-secret`, or the `pure.json`
  schema.** Those live on the FlashBlade-backend page linked beside it, and the `pure.json` shape
  this pipeline depends on is written out in §12.2. Reading only the install page leaves you with
  an operator and no way to reach the array.

**Two install details that are easy to miss:**

- **Argo Events' controller Deployment needs its hard-coded `runAsUser: 9731` patched out on
  OpenShift.** OpenShift's namespace UID range rejects that fixed UID, and without patching it out
  of the Deployment's `securityContext` before or during install, the controller crash-loops. This
  is a patch to the Deployment itself — no `SecurityContextConstraints` object is created or
  needed anywhere in this tree.
- **The GPU Operator needs a pull secret that includes the Red Hat registry.** Check yours before
  installing; a missing entry surfaces much later as an `ImagePullBackOff` on driver pods.

Required CRDs, once the above are installed: `kueue.x-k8s.io` (ClusterQueue, ResourceFlavor,
LocalQueue), `ray.io` (RayCluster, RayJob), `argoproj.io` (EventBus, EventSource, Sensor),
`snapshot.storage.k8s.io` (VolumeSnapshot, VolumeSnapshotClass), `core.libopenstorage.org`
(StorageCluster).

### 2.1 Monitoring — user-workload monitoring, and somewhere for alerts to go

The Cluster Monitoring Operator is already installed on your cluster; what this pipeline needs from
it is **configuration you must supply**, and both halves are prerequisites in exactly the sense §2
means. Neither is switched on by default on OpenShift.

| Requirement | Floor | Tested with |
|---|---|---|
| User-workload monitoring | **enabled** (`enableUserWorkload: true`) — without it nothing may alert on your application namespace at all | ConfigMap `cluster-monitoring-config` |
| Alertmanager receivers | **≥ 1 configured integration**, and a route that reaches it | Secret `alertmanager-main`, one placeholder receiver behind a route whose matcher **nothing satisfies** |
| Prometheus persistence | a `volumeClaimTemplate` on a class you are willing to keep 30 days of samples on | the retaining class from §3, RWO |
| CRDs | `monitoring.coreos.com` — `PrometheusRule`, `ServiceMonitor` | shipped by the operator above |

**Why this is a contract item and not an optional extra.** Every built-in workload alert on this
platform — `KubeContainerWaiting`, `KubeJobFailed`, `KubePersistentVolumeFillingUp` — is scoped to
`openshift-*`, `kube-*` and `default`. It is structurally incapable of firing for your namespace.
With user-workload monitoring off, the `PrometheusRule` this pipeline ships is not merely quiet: it
is never evaluated. A rule that cannot match is indistinguishable, in every console and every
dashboard, from a healthy system.

**The manifests ship the enablement, and it is deliberately blunt.** `base/00-platform/` contains
`cluster-monitoring-config.yaml` and `alertmanager-placeholder-receiver.yaml` so the requirement is
executable rather than a paragraph. Read their headers before applying either — this is not
boilerplate:

> **`config.yaml` is one opaque string, and `oc apply` replaces the whole of it.** There is no
> partial merge *inside* that key — apply, `--type=merge` and `--type=strategic` all overwrite it
> entirely, and Kustomize cannot reach inside it either. A cluster that already carries a
> `cluster-monitoring-config` (remote write, a telemetry proxy, node-exporter or Alertmanager
> tuning) **loses every one of those settings**, silently, on an apply that reports success. The
> same is true of `alertmanager-main`, where the casualty is your entire receiver and route
> configuration — discovered at the next incident that does not page. If either object already
> exists, **merge the keys by hand**; both files carry the exact `oc get`/`oc replace` sequence.
>
> Adding a `volumeClaimTemplate` also makes the operator recreate the Prometheus StatefulSet, so
> whatever history is on the current `emptyDir` goes with the old pods. The change that makes the
> store durable is the change that empties it. Do not make it mid-investigation.

**Choosing where alerts go is yours, and it is not guessed for you.** The shipped receiver exists
only to take `alertmanager_integrations` off zero, so that `AlertmanagerReceiversNotConfigured`
stops firing. That is all it does — **it has no bearing on whether rules evaluate**, which is
Prometheus's and Thanos Ruler's job and depends only on user-workload monitoring being enabled.
**It is routed by a matcher no alert can satisfy (`alertname = PlaceholderNeverMatches`), so
nothing is ever delivered.** The route is not optional: Alertmanager skips building integrations
for any receiver no route references, so an unrouted placeholder leaves the metric at zero and the
alert firing, visible in the console but delivered to nobody. A wrong SMTP relay or a stale webhook
shipped as a default would be worse than an obvious blank, because it looks wired up — so the
destination is named as a requirement here and left empty in the manifests. Widen that matcher and
point the webhook somewhere real before you treat silence as health.

Read-only, before and after:

```bash
# Is user-workload monitoring actually running? (the ConfigMap existing is not the same thing)
oc -n openshift-user-workload-monitoring get pods        # want prometheus-user-workload-* Running

# Does Alertmanager have any integration at all? Zero means no alert will ever leave the cluster.
oc -n openshift-monitoring get secret alertmanager-main \
  -o go-template='{{index .data "alertmanager.yaml" | base64decode}}' | grep -c '_configs:'

# Do your rules evaluate, as a user of your namespace? An empty result and a satisfied
# expression look identical — check each one once, by hand.
oc -n <your-namespace> get prometheusrule
```

---

## 3. Storage

| Requirement | Floor | Tested with |
|---|---|---|
| Storage backend | **Everpure FlashBlade**, reachable from every node | FlashBlade//S500 |
| Purity//FB | a release your Portworx version supports — check the Portworx support matrix | **Purity//FB 4.5.5** (REST API 2.17) |
| Portworx edition | **CSI-only OEM mode** (`--oem px-csi`) | driver image `px-pure-csi-driver:26.2.0` |
| RWX StorageClass | `backend: pure_file`, reclaim `Delete` | provided by `base/10-storage` |
| Retaining StorageClass | `backend: pure_file`, reclaim **`Retain`** | provided by `base/10-storage` |
| VolumeSnapshotClass | CSI snapshots against the same driver, `deletionPolicy: Retain` | provided by `base/10-storage` |

**This is a solution built on Everpure FlashBlade.** The pipeline's storage design is not
"some NFS filer" — it depends on FlashBlade Direct Access (FBDA) semantics, which is why the
StorageClasses specify `backend: pure_file`. See §3.1 for what that buys and what it requires.

**The Portworx edition matters more than the version.** This runs Portworx in CSI-only OEM mode,
which is licensed differently from Portworx Enterprise. Installing Enterprise gives you a different
product with a different support and licensing story — it will work, but you are not running what
was tested.

**Reclaim policy is a decision, not a default.** Checkpoints and the MLflow store use the `Retain`
class, so deleting the namespace leaves the PersistentVolumes behind holding your data. That is
intentional. It also means you reclaim that capacity manually.

### 3.1 Why FlashBlade, and why this shape

Not marketing — these are the engineering reasons the design landed here, and each one implies
something you must provide.

**One array, two protocols, two namespaces.** FlashBlade serves S3 object and NFS file from the same
array as **two distinct namespaces**. An object is not simultaneously readable as an NFS path. What
this buys is *data gravity on one array* — datasets arrive as objects, model state is written as
POSIX files, and neither crosses a network boundary to reach the other. It does **not** buy one copy
served two ways; sharing a given byte across both protocols is still a copy.

**RWX exists to make the checkpoint snapshottable.** ZeRO-3/FSDP checkpoints are **sharded across
ranks** — each worker writes its own shard into a shared POSIX directory. Putting that on one RWX
volume is what allows a single CSI `VolumeSnapshot` to capture the whole model state at a point in
time, and to resume in place rather than restart. Measured: 8 workers across 2 GPU nodes, all shards
landing on one volume.

> To be accurate about the alternative: per-worker S3 upload is a working sibling design, and this is
> a **tradeoff, not a necessity**. RWX is required for the *snapshot-of-model-state* mechanism, not
> for checkpointing as such.

**The snapshot is only as consistent as the fsync before it.** An array snapshot never waits for
client-buffered NFS writes. A rank barrier followed by `fsync` is the **sole** mechanism making the
snapshot application-consistent — dirty page-cache bytes are simply absent otherwise. This is a
property of your training code, not of the storage.

**FlashBlade is for durable state, never the hot path.** DeepSpeed per-step ZeRO offload must target
**local NVMe**. Offload runs per micro-step and network latency would dominate. FlashBlade holds
durable checkpoints, datasets and shared read cache. Related: FlashBlade **cannot** serve Portworx's
own system volumes — a Portworx Enterprise install still needs local block devices for KVDB.

**Every node that mounts an FBDA volume runs the Portworx CSI node driver.** That is why a GPU node
joins the storage cluster as a *storageless* member: it provides no storage, it only needs to mount.
Portworx requests **zero GPUs** — it consumes CPU and RAM only.

**Portworx does not proxy S3.** FlashBlade's S3 service is a native, independent Purity feature.
Portworx and S3 are two parallel paths onto the same physical array. Nothing in the object path
depends on Portworx being healthy.

### 3.2 Two StorageClasses, and why `Retain` is not optional

| Class | Reclaim | For |
|---|---|---|
| general RWX | `Delete` | disposable volumes; deleting the namespace reclaims the FlashBlade filesystem |
| checkpoint/registry | **`Retain`** | anything you intend to snapshot and restore |

`Retain` is **required by the snapshot/restore flow**, not merely prudent. There is no code guard
tying a snapshot's deletion policy to an in-flight restore — nothing tracks "restore pending, do not
GC this". `reclaimPolicy: Retain` on the volume and `deletionPolicy: Retain` on the snapshot content
are the *only* protection against a snapshot being garbage-collected mid-restore.

The honest cost: retained FlashBlade snapshots require **manual array-side cleanup**.

**Reclaiming a `Retain` volume takes THREE steps, not two.** Deleting the PV in Kubernetes leaves a
filesystem on the array named after a PVC UUID that no longer resolves to anything, still consuming
capacity. On Purity//FB 4.5.5 (REST 2.17) the sequence is:

1. **Disable every protocol** — `PATCH /api/2.17/file-systems?names=<fs>` with
   `{"nfs":{"v3_enabled":false,"v4_1_enabled":false},"smb":{"enabled":false},"http":{"enabled":false}}`
2. **Destroy** — `PATCH …` with `{"destroyed":true}`
3. **Eradicate** — `DELETE /api/2.17/file-systems?names=<fs>`

Step 1 is not optional and is easy to miss: step 2 fails with **`Cannot destroy a file system that
has any protocols enabled`** without it. An orphan left by a `Retain` volume still has NFS enabled,
because nothing disabled it on the way out — so this bites exactly in the case the procedure exists
for. Note also that the field is **`nfs.v3_enabled` / `nfs.v4_1_enabled`**; there is no `nfs.enabled`
at this API version, and sending one returns a misleading `Invalid body parameter: enabled` naming an
unrelated remote-array resource.

**Capture the PVC → PV mapping *before* deleting the PVCs.** Afterwards the filesystem name is the
only link back, and it contains a UUID that resolves to nothing. Capture the claim's **namespace**
along with its name — the next paragraph is why.

**Scope the reclaim by identity, never by count.** It is tempting to finish a teardown by re-listing
the array and asserting it is empty. Do not, unless you can also guarantee the array has exactly one
tenant — and an array that backs a StorageClass will not stay single-tenant, because anything else
that later uses that class lands beside you. The filesystem name carries no namespace, so from the
array side another team's volume and your orphan look identical. Reclaim exactly the UUIDs your own
PVs named, then re-list and assert the **survivors are the set you expected**. Asserting a total is
how a teardown becomes an outage for somebody who was not involved.

Do keep the re-list itself: a reclaim loop that half-completes returns a run of HTTP 400s that reads
as success, and the re-list is the only thing that catches it.

### 3.3 Snapshot behaviour you must design around

Three properties of the array that will surprise you, in rough order of how much damage they cause:

1. **Restore is most-recent-only, and a *destroyed-but-not-yet-eradicated* snapshot still counts as
   "newer".** Purity uses permission-based eradication with a **24-hour delay**. A restore blocked
   this way sat `Pending` with repeated `ProvisioningFailed` until the newer eradication-pending
   snapshots were explicitly eradicated — then bound in ~10 s. **A checkpoint you cannot restore for
   24 hours is an availability gap, not a monitoring nuisance.** Do not interleave disposable
   cadence snapshots *after* the retained checkpoint you intend to restore from, on the same
   filesystem.
2. **Destroyed snapshots stay listed.** Count with `?destroyed=false`, or your monitoring reports a
   leak that does not exist.
3. **One outstanding copy per source filesystem, and no clone-to-new-filesystem primitive.** You can
   restore once; a second restore fails until the first is deleted. There is no experiment branching.

**RESTORING A SNAPSHOT DOES NOT CLONE. It reverts the SOURCE filesystem to the snapshot, and hands
you a new PersistentVolume that is an ALIAS for that same filesystem.** There is no second copy at
any point.

Restore three times, then compare `volumeHandle` across every PV, rather than trusting either
description at face value:

```
$ oc get pv -o custom-columns=CLAIM:.spec.claimRef.name,HANDLE:.spec.csi.volumeHandle
  fbda-restore-eval-v8   <handle-A>
  fbda-shared            <handle-A>  <- IDENTICAL
  restore-test-dst       <handle-B>
  restore-test-src       <handle-B>   <- IDENTICAL
  restore-test-dst       <handle-C>
  restore-test-src       <handle-C>   <- IDENTICAL
```

(`<handle-A/B/C>` stand in for real volume UUIDs — what matters is that the two handles in each pair
are *identical*, which a placeholder preserves just as well as the real value: matching
`volumeHandle`s across a restore pair is the proof that no new volume was created.)

Three independent restores, three shared handles, and **no array filesystem exists for any restored
PV** — the array reported 9 filesystems and none of them corresponded to a restored PersistentVolume.
The driver issues `discard_non_snapshotted_data=true&overwrite=true` against the snapshot's PARENT
filesystem, which is exactly what that does.

**There is no new filesystem at any point, in either direction.** The driver reverts the source
filesystem in place, and the "restored" PersistentVolume is simply another name for that same
filesystem — not a clone sitting beside it. The one data observation that could look like a second,
independent behaviour — a file written after the snapshot disappearing from the "source" — has a
single cause, not two: source and restored PVC are one filesystem, and it was reverted.

**Three consequences, and the third is the one that wastes a GPU cycle:**

- **Anything newer than the snapshot is lost.** Restoring to recover one file loses every write since
  that snapshot, across the whole filesystem.
- **There is no experiment branching.** You cannot hold the live state and a restored state side by
  side. This is the same fact as "no clone-to-new-filesystem primitive" above, stated from the
  Kubernetes side.
- **A pod must never mount both the source PVC and a restored PVC.** They are the same filesystem
  under two names, mounted read-write twice, and the kubelet times out at ~2m3s with
  `unmounted volumes=[<source>] ... context deadline exceeded`. The source mounts in ~16 s on its
  own, so this reads as a storage fault when it is a duplicate mount.

**AND NOW THE CONSTRUCTIVE HALF, BECAUSE EVERYTHING ABOVE IS A WARNING AND IT WOULD BE EASY TO
CONCLUDE THE WRONG THING.** Because restore cannot clone, it is tempting to conclude that a recovery
demonstration is impossible. **Recovery does not require a copy.** Rewinding is recovery for the
common case, and the same in-place destructiveness that makes restore useless as a clone is precisely
what a rollback is.

End to end, on a 366 GiB (~393 GB) ZeRO-3 checkpoint:

1. Snapshot the checkpoint filesystem.
2. Create a PVC from that snapshot — the source reverts: two files written *after* the snapshot are
   gone afterwards, while the checkpoint and all 16 rank shards survive and the volume root's own
   mtime moves back.
3. Delete the aliasing PVC. Safe **only because `reclaimPolicy: Retain`** means no array call is
   issued — see the StorageClass, where this is documented as a data-loss guard rather than a
   retention preference.
4. Resume training against the reverted volume.

The resumed run reproduced **all eight** per-step losses bit-identically against an earlier resume of
the same checkpoint taken *before* the revert — including the first step after an optimizer update,
which depends on the restored ZeRO-3 **optimizer** shards and not merely the model weights. So a
rollback returns the checkpoint **exactly**, not just loadably.

**Recovery on this platform is three tiers, and only the first is proven here:**

| Failure | Recovery | Status |
|---|---|---|
| Volume **contents** bad — corrupted, diverged, a run to undo | **Snapshot rollback.** Metadata-only, effectively instant, byte-exact | **proven** |
| Volume or array **gone** | **S3 archive.** Every verified checkpoint is uploaded | **the restore script verifies file completeness against the checkpoint manifest before calling a restore complete** — see below |
| Site or array **lost** | Replication to a second array | **not attempted** |

Design for tier 1 and you get the fast path. Do not mistake it for tier 3: a rollback cannot help when
the array is gone, and neither can an S3 bucket that lives on it.

**To perform tier 1 yourself**, see [docs/rollback-runbook.md](docs/rollback-runbook.md) — the
actual procedure, as three objects applied deliberately, in order, never as a side effect of
`apply -k`. [docs/results.md](docs/results.md#what-did-not-work) has the full measurement behind
the "proven" status above: three independent restores, the shared `volumeHandle`, and the
bit-identical resumed-run losses.

**To perform tier 2**, see `scripts/restore-checkpoint-from-s3.sh` — it downloads a checkpoint's
`checkpoint-manifest.json` first (the upload path's own completion signal, uploaded last) and
verifies every file it lists came back at its recorded size before calling the restore complete,
so a partial restore fails loudly instead of silently producing a checkpoint that looks whole. A
synthetic fixture restores byte-for-byte (checksums match), and a deliberately incomplete fixture
is correctly rejected (naming the missing file, exit code 1). The script's manifest parsing and
small-object download path also run against a real full-scale checkpoint's manifest and its small
files (model-state shards, `latest`, `zero_to_fp32.py`), without moving the ~393 GB of real
optimizer-shard data.

**Match world size to the checkpoint you are resuming.** A ZeRO-3 checkpoint is sharded per rank,
and a job that loads one must run at the world size that saved it — loading at the wrong size loads
a partial model without erroring. Every checkpoint this pipeline produces today is world size 8.
Check yours before you resume:
`oc get rayjob <name> -o jsonpath='{.spec.rayClusterSpec.workerGroupSpecs[0].replicas}'`, or count the
shards against the object-count arithmetic under Capacity.

**Sequence it as three steps, deliberately.** First, the VolumeSnapshot itself, if one does not
already exist from a completed run. Then a human or a runbook creates the PVC that reverts the
volume. Only then does a separate job resume. Do not fuse them — a job that reverts a live volume
as a side effect of starting can evict a running job and waste the GPU allocation underneath it.

Verify on your own array before relying on any of it — the test is two 1Gi PVCs, a snapshot, a marker
file, and comparing `volumeHandle`.

**Concurrency ceiling:** the array limit is **512 snapshots per filesystem**. Portworx documents 64
per volume, which is its own convention, roughly 8× more conservative than the array's real limit.

### 3.4 Performance, measured

| | |
|---|---|
| Checkpoint written | ~393 GB |
| Quiesce + fsync | ~99 s → **~4 GB/s aggregate** over NFSv4.1/TCP |
| CSI snapshot commit | **~2 s** |

**The fsync is the cost; the snapshot is nearly free.** Size your expectations accordingly — if a
checkpoint cycle feels slow, it is the flush, not the array's copy-on-write.

This ran over **TCP**. NFS-over-RDMA was evaluated and deliberately deferred: FlashBlade serves
NFS-over-RDMA on **NFSv3 only**, so `vers=4.1,proto=rdma` does not mount, and taking RDMA would mean
dropping the checkpoint path to NFSv3. Checkpoint I/O is throughput-bound rather than latency-bound,
so TCP was judged adequate.

### Capacity

| Volume | Size | Access mode | Holds |
|---|---|---|---|
| shared working set | 800 Gi | RWX | base model, datasets, **checkpoints**, run outputs |
| tracking store | 20 Gi | RWX | the MLflow backend |

Roughly **820 GiB** before any object storage — and before phase 00's monitoring stack, which is
not optional. `base/00-platform/cluster-monitoring-config.yaml` provisions 2×100Gi + 2×50Gi = 300
GiB of PVCs on the same `px-fb-direct-access-nfsv4-retain` storage class, per that file's own
comment ("STORAGE IS PER REPLICA, NOT A TOTAL"). The real floor for this pipeline's storage class
is closer to **1,120 GiB**. A 32B base model alone is ~65 GB.

**Those two numbers are the tested values, not a sizing method.** They are correct for the tested
model at the tested world size, and they will be wrong for yours. The rest of this section is how to
compute your own, because the failure mode when you get it wrong is expensive and quiet: it lands at
the checkpoint barrier, after the GPUs have already done the work.

#### The volume must hold steady-state data **plus one whole checkpoint, at the same time**

The checkpoint is **transient on the file volume**. Training writes the full sharded checkpoint to
the shared RWX volume, uploads it to object storage, then reclaims the local copy. So the volume
never *keeps* a checkpoint — but for the length of the write plus the upload it holds the entire
thing on top of everything else that lives there. Size the volume for that peak:

```
volume  >=  base model
          + datasets and run outputs
          + accumulated per-run residue (below)
          + ONE FULL CHECKPOINT
          + margin
```

#### Transient checkpoint size — a function of model size, not of world size

For **DeepSpeed ZeRO-3 in bf16 with Adam**, the checkpoint is dominated by optimiser state: fp32
master weights plus Adam's first and second moments, which is 12 bytes per parameter before any
metadata. Measured end to end, three times, on the tested pipeline:

| | Measured |
|---|---|
| Model | 32B parameters, ZeRO-3, bf16, `world_size` 8 |
| Whole checkpoint | **366 GiB** (~393 GB) |
| Per optimiser shard | **~49 GB** × 8 |
| Objects uploaded | **18** = `2 × world_size + 2` (one optimiser and one model-state shard per rank, plus `latest` and `zero_to_fp32.py`) |

**The optimiser shards are effectively the whole checkpoint**, which is what makes those three rows
consistent rather than contradictory: 8 × ~49.1 GB is ~393 GB, i.e. all of it. Under ZeRO-3 the
partitioned fp32 optimiser state lives in the `*_optim_states.pt` shards and the `*_model_states.pt`
shards hold metadata, so the latter are megabytes, not gigabytes. Do not budget for them twice, and
do not carry this assumption to ZeRO-1 or ZeRO-2, where the split is entirely different.

Which gives the number to size from:

```
transient checkpoint  ≈  12.3 bytes × parameters      (fp32 master + 2 Adam moments = 12, plus
                                                       ~0.3 of framework metadata and padding)
per-rank shard        ≈  that ÷ world_size
object count          =  2 × world_size + 2      (+1 if the shipped shard verifier writes its manifest)
```

**Raising `world_size` does not shrink the checkpoint — only the shards.** This is the assumption
worth checking before you size anything: the total is a property of the model and the optimiser, and
sharding it across more ranks divides the same bytes into more, smaller files landing on the same
shared volume. More GPUs buys you speed, not headroom.

Two corollaries an adopter meets immediately:

- **A percentage-of-capacity alert is the wrong instrument.** On an 800 GiB volume the platform's
  standard 3%-free warning fires at 24 GB — an order of magnitude below one 366 GiB checkpoint, so
  by the time it fires the write it was meant to warn about has already failed. The pipeline ships an
  **absolute-bytes** headroom alert instead, and the shipped floor is a placeholder: measure one
  checkpoint, add margin, and set it to one-checkpoint-plus-margin in your overlay. The example
  overlay carries the patch and the reasoning.
- **The failure is silent.** NFS reports `ENOSPC` at `close()`/`fsync()`, not at `write()`, and
  DeepSpeed's checkpoint `commit()` returns `True` unconditionally — so a checkpoint save onto a full
  volume can run to completion and **report success**. The shipped shard verifier exists for this: it
  counts and size-checks the shards before the upload, so a partial checkpoint never reaches your
  bucket.

Object storage takes the same footprint again, per run, and **it is not transient** — each run adds a
new prefix and nothing deletes the old ones. This lands in `S3_DATA_BUCKET` (the training-data
bucket — `train_qwen3_deepspeed.py` uploads the checkpoint shards there, not to the registry
bucket), under the `checkpoints/<RUN_ID>/` prefix. Budget one checkpoint per run there, or adopt a
retention policy on that bucket deliberately. The registry bucket carries a much smaller footprint
— one lineage JSON per registered model version, written by `base/50-stages/v9-register-job.yaml`.

#### Per-run residue on the file volume

The pipeline persists each Ray pod's logs to the shared volume so they survive a hard kill (a
crash, an OOM, or a Kueue preemption all destroy the pods, and there is no log aggregation assumed
by this contract). **Nothing prunes it.** The pipeline does **not** persist each pod's materialised
`runtimeEnvYAML` pip environment (`runtime_resources/`) to this volume: `runtime_resources/` does
not accrue on the shared volume at all, at any world size — see below.

`runtime_resources/` is a sibling of the logs directory under Ray's per-pod session directory. The
pipeline's log-shipper sidecar ships only the logs subdirectory to the shared volume — it never
touches `runtime_resources/`, which lives solely on each pod's ephemeral container filesystem and
is destroyed with the pod. It does not accrue on the shared volume at all, at any world size.

Measured, real per-run residue (logs only, the actual accrual this mount holds):

| Scope | Size |
|---|---|
| Per pod | ~15 MB (session logs + any NCCL flight-recorder dump) |
| Whole 9-pod cluster, one run | ~140 MB |

That is roughly three orders of magnitude below what a full 366 GiB checkpoint requires. At this
rate, per-run residue is not a meaningful factor in sizing this volume against a 366 GiB
checkpoint — size for the checkpoint and margin, and don't budget separately for residue.

**Baking the `runtimeEnvYAML` pip set into your runtime image is still worth doing** — not for
residue (there isn't any to remove), but for two independent, still-real reasons:

1. **Public PyPI is a hard runtime dependency of every run as shipped.** Ray materialises the pip
   set on the head and every worker at pod start, so on a disconnected or proxied network the
   pipeline does not start — and it fails during Ray's worker-group setup, minutes in, rather than
   at apply time.
2. **Startup time.** The pip install this triggers costs several minutes of every run, GPUs
   allocated and idle throughout.

Whatever you choose, **plan a retention sweep for logs regardless.** Nothing in this pipeline
deletes run residue; the training code reclaims its own checkpoint directory and nothing else. At
~15 MB/pod it will take a very long time to matter, but "nothing prunes it" is still true.

### File and inode growth is unmonitorable — a known limitation

Whatever your actual per-run file count turns out to be (see the previous section — it is small,
but "small" is not the point here). **You cannot put an alert on it.** This is stated as a limitation of the tested stack rather than left for
you to discover, because every instrument that looks like it should cover this does not, and each one
fails by returning a plausible number rather than an error.

| Where you would look | What it actually gives you |
|---|---|
| The array, per filesystem | Space, performance and data-reduction metrics. **No file count.** The counter does not exist to be scraped. |
| The array, per bucket | Object counts — but that is the **S3 namespace**, and the file namespace is a different namespace on the same array (§3.1). It says nothing about the NFS volume. |
| `kubelet_volume_stats_inodes_free` | **512-byte blocks, not files, on this storage class.** See below. |
| `df -i` inside a pod | The same statfs numbers, with the same problem. |

**Why the kubelet inode counters cannot be used here.** They are real, they are present, and they are
not counting files. FlashBlade's NFS `statfs` reports `f_files`/`f_ffree` in **512-byte units**, so
the "inode" series is an exact restatement of the byte series. Measured against a real run:

```
inodes       1,677,721,600 × 512 = 858,993,459,200  =  capacity_bytes   EXACT
inodes_used    767,868,062 × 512 = 393,148,447,744  ≈  used_bytes       within 0.00002%
```

The checkpoint those numbers describe is **18 files**. The metric read 767 million.

The consequence is worth being blunt about: **an inode-exhaustion alert on this storage class cannot
fire on file growth.** It would be a second copy of the free-bytes alert wearing a different name,
and it is strictly dominated by it — a 1,000,000-free threshold is 512 MB, which an absolute-bytes
headroom rule catches hundreds of GiB earlier. Do not build one; use the absolute-bytes headroom
alert instead.

**So measure it out of band.** File-count growth on the shared volume is an operational fact you have
to go and look at — `find <mount> | wc -l` from a pod, on a schedule you choose — until either your
array exposes a per-filesystem file count or your storage class reports true inode numbers. If a
future version of either does, re-derive the arithmetic above before trusting a rule built on it.

### You do not supply per-node storage devices

Worth stating because the opposite is a reasonable assumption: the **CSI-only** StorageCluster this
pipeline ships has no `kvdb`, `storage` or `nodes` sections at all. It provisions no local storage
pool, so it never touches your nodes' disks — GPU-node NVMe included.

Per-node device assignment belongs to Portworx **Enterprise**, which this pipeline does not use
(§12.8). If you adopt Enterprise instead, you take on selecting disks by their stable
`/dev/disk/by-id/` path — never `/dev/nvmeXn1`, since enumeration order is not stable across reboots
and **Portworx wipes the device it is given.**

---

## 4. Object storage

An S3-compatible endpoint reachable from the cluster, over HTTPS, with **three buckets**:

| Bucket role | Written by | Read by |
|---|---|---|
| training data | you (upload datasets here) | the training job |
| validation drop | your pipeline, or manually | the S3 poller, which triggers runs |
| model registry | the register job | you |

They are separate on purpose. The poller watches the validation drop; the training job reads the
training bucket. Pointing both at one bucket makes every upload trigger a run.

One IAM identity needs read/write on all three. Versioning and object-lock on the registry bucket
are **not required for the pipeline to run** — registration succeeds without them — but they **are
required for the specific claim this design makes**: an immutable, object-locked lineage record (see
[README.md](README.md), architecture section, on the SafeMode-protected lineage record). Without
object lock, a written lineage record can be altered or deleted after the fact, same as any other
object. Enable both if the model's provenance record needs to survive an audit; otherwise you have a
lineage record, not an immutable one.

### 4.1 Preparing the array, and the playbook that does most of it

Everything above tells you what the array must provide. This section is how you make it so,
executable rather than prose. **`ansible/flashblade-prepare.yml`** is the runnable part;
`ansible/README.md` beside it carries the prerequisites and the run procedure.

**What the array must actually have.** Reconstructed from the manifests and measurements in this
repository rather than from vendor marketing, which is why several rows disagree with a default:

| What | Why it is here |
|---|---|
| A **management endpoint** (a `vir*` virtual interface) reachable from the Portworx control plane | REST volume create/delete/query |
| An **NFS data VIP** with `services=data`, L2-reachable from every mounting node, port 2049 open, MTU agreed end to end | the actual NFS traffic; a different network from the above, frequently with a different reachability story — §12.4 |
| The data VIP and the management endpoint on the **same array** | naming two different arrays produces `create volume: : not found`, which reads as a CSI bug — §12.1 |
| A **Storage Admin** user with a **non-expiring API token** (`T-…`) | what `px-pure-secret` carries — §12.2 |
| Export rules **`*(rw,no_root_squash)`** | load-bearing, not a permissive default: under `root_squash` the kubelet's `fsGroup` walk costs the same and the volume root is never stamped — §12.5 |
| **`snapshot_directory_enabled: false`** on provisioned filesystems | the array's own default is off; the CSI driver turns it on at create time, and a visible `.snapshot` makes every pod mount walk a read-only copy of the volume per snapshot |
| An **object-store account, three buckets and one user**, per §4 | FlashBlade's S3 service is a native, independent Purity feature — Portworx does not proxy it |

**One row above disagrees with the vendor documentation, and it is worth knowing which.** The
Portworx StorageClass reference gives the snapshot-directory parameter a documented default of
`false`, from which a reader would reasonably conclude that leaving it unset is safe. Every
filesystem here has the snapshot directory **enabled** — the driver sets it on at create time
regardless — and the consequence is evicted training pods, with no event emitted anywhere. Set the
parameter explicitly. If a later driver release makes the documented default true in practice,
setting it explicitly costs nothing.

**What the playbook does, and what it deliberately refuses to do.** It verifies the endpoint, the
token and — the check worth the most — that the data VIP you named is a data-service interface *on
the array the token authenticates against*. It creates the object-store account, the three buckets
(registry with versioning and object lock) and the pipeline user. It creates one **throwaway probe
filesystem** carrying the export rules and snapshot-directory setting above, so both can be proven
from a node before Portworx is installed, when a mistake is still cheap.

It does **not** pre-create the pipeline's data volumes, and that is a correctness point rather than
a scoping one: Portworx creates one FlashBlade filesystem per PersistentVolumeClaim at PVC-create
time, named after the claim's UUID, so a hand-made filesystem beside them is an orphan from the
moment it exists.

**Three steps stay manual, each for a stated reason rather than for lack of effort:**

- **The API token.** No module in the FlashBlade Ansible collection mints an array admin API token,
  and the array returns a token's value exactly once at creation — it can never be read back, only
  rotated.
- **The S3 access key.** Same shape, sharper edge: the secret is returned once, an object-store user
  has a maximum of **two** concurrent keys, and a creation whose secret was not captured leaves an
  orphaned, unrecoverable key holding a slot. Automating it would put the only copy of a live
  credential into Ansible's output. The playbook counts the slots and reports them instead.
- **Attaching the object-store access policy.** Without one, a valid access key still returns
  `AccessDenied`. The collection has a module for this and it does not work on a standalone array —
  see below.

The playbook is syntax-checked and lints clean under the `production` profile, and its write gate
runs in six shapes: an apply-mode run with no opt-in refuses in its first task; a `--check` run with
no credentials refuses in its second; and an apply-mode run with no opt-in refuses in its first task
under each of the four `--tags` slices the playbook offers. The preflight tasks carry `always`, so
passing `--tags` cannot skip them.

No run against a real FlashBlade has been made from this repository, not even in `--check` mode.
The module argument shapes and behaviours are read from the installed collection source; the
array's *response* to them is reasoned, not observed. Treat your own first `--check` run as the
verification, and read its diff.

**Two collection behaviours to know before you extend the playbook or write your own.**

Use the `everpure.flashblade` collection name, not the older `purestorage.flashblade` — the old
name still installs but only redirects, and the redirects are scheduled for removal at 2.0.0.

`purefb_fs` can only turn the snapshot directory **on**, never off — set it on new volumes via the
StorageClass parameter, and correct existing volumes with a direct array-side call, not this
module. `purefb_userpolicy` also does not attach a policy on a standalone (non-fleet) array despite
reporting `changed: true`; verify the policy attached with a direct check rather than trusting the
task result.

---

## 5. Secrets — by name and key

Create these before applying the pipeline phase. The manifests reference them by name; **how you
create them is entirely your choice** — sealed secrets, an external secrets operator, `kubectl
create secret`, whatever your platform already uses.

| Secret | Namespace | Keys | Contents |
|---|---|---|---|
| `flashblade-s3` | *your application namespace* | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `S3_ENDPOINT` | the object-store identity from §4. `S3_ENDPOINT` is a full URL including scheme |
| `px-pure-secret` | `portworx` | `pure.json` | a JSON document listing your filer's management endpoint, an API token, and the NFS data VIP. The token is created array-side — §4.1; the exact schema, which is *not* the block-storage one, is §12.2 |
| `hf-token` | *your application namespace* | `HF_TOKEN` | a model-hub token — required regardless of whether your base model or dataset is actually gated: `model-staging-job.yaml` reads `HF_TOKEN` as a required environment variable with no default, so the secret must exist for staging to run even against an ungated default like `nvidia/Nemotron-Agentic-v1` |

**No secret values appear anywhere in this repository, and none should.** If you find one, treat it
as a defect and report it.

---

## 6. Compute quota

The pipeline admits work through Kueue, so a `ClusterQueue` must exist with enough nominal quota for
one training run:

| Resource | Floor | Tested with |
|---|---|---|
| `nvidia.com/gpu` | 8 | 8 |
| `cpu` | 56 | 56 |
| `memory` | 1600 Gi | 1600 Gi |
| `ephemeral-storage` | 720 Gi | 720 Gi |

**`ephemeral-storage` is not optional, and it scales with GPU count, not independently.** Every
GPU-worker pod requests 90 Gi of it (the base-model download onto the pod's writable layer), so the
floor is `90 Gi × (GPU floor above ÷ GPUs per worker)` — 8 workers × 90 Gi = 720 Gi at this table's
floor. If you raise the `nvidia.com/gpu` nominal quota to admit more concurrent workers, raise
`ephemeral-storage` by the same multiple in the same change. A `ClusterQueue` whose
`coveredResources` omits this dimension entirely does not fail to admit a workload that requests it
— it fails to admit **any** workload requesting it, forever, silently: Kueue reports the workload's
own `Workload` condition as unable to assign a flavor, with no event anywhere else. `preflight.sh`
checks the ClusterQueue's `ephemeral-storage` coverage and quota against this floor.

The `ResourceFlavor` name is yours to choose; it appears in the ClusterQueue and in the
`kueue.x-k8s.io/queue-name` label on workloads. Both ship in `base/00-platform/`, where the flavor
is called `gpu` and selects `nvidia.com/gpu.present: "true"` — the NFD label from §7, true of every
CUDA-capable node whatever the model.

**Narrow it if your GPU nodes are not interchangeable.** The default admits any GPU node. On a
mixed fleet that is wrong in an expensive way: a 32B model in full-parameter fine-tuning via
DeepSpeed ZeRO-3 with full CPU offload needs the VRAM, and `gpu.present` will place it on the
smallest card you own, where it starts, runs, and fails at an allocation well into the job. Pin
`nvidia.com/gpu.product` in your overlay — in the flavor **and** in the workload pod specs, which
carry the same selector explicitly. Both are overlay patches; neither is a base-file edit. The
workload pod specs' patches are shown in `overlays/example/40-workloads/kustomization.yaml` and
`overlays/example/20-events/kustomization.yaml`. The `ResourceFlavor`'s own GPU-model selector has
no ready-made patch in `overlays/example/00-platform/kustomization.yaml`, but
`base/00-platform/kueue-resourceflavor-gpu.yaml`'s own header comment gives the exact JSON6902
patch — copy it into your overlay; the patch applies cleanly and `kubectl kustomize` renders the
pinned `nvidia.com/gpu.product` label on the ResourceFlavor.

The reverse error is quieter still: a label no node carries yields a node set of size zero, and
Kubernetes does not treat that as an error. The pods stay `Pending` indefinitely with no event
naming the cause.

**Quota below the floor does not fail — it hangs.** Kueue holds the workload as unadmitted, with no
error on the RayJob and no event on the pod, because there is no pod yet. If a run appears to do
nothing, check `ClusterQueue` admission first.

---

## 7. Node preparation

| Requirement | Why |
|---|---|
| A `MachineConfigPool` selecting your storage nodes | **only if you adopt the loopback storage-pool path, which this pipeline does not use** — the platform phase applies this pool, but the CSI-only StorageCluster it ships needs no local storage pool at all |
| Node label marking Portworx-eligible nodes | **only if you adopt the loopback storage-pool path, which this pipeline does not use** |
| Node label marking storage-role nodes | **only if you adopt the loopback storage-pool path, which this pipeline does not use** — on a fresh install nothing sets this label, so the pool has zero members |
| `nvidia.com/gpu.present` on GPU nodes | supplied by Node Feature Discovery, not by hand |

**Applying the platform phase reboots any node you have labelled `node-role.kubernetes.io/px-storage`.**
The `MachineConfigPool` rollout drains and restarts each selected node in turn — on a fresh install
that label is on no node, so the pool has zero members and nothing reboots. If you do label storage
nodes, wait for the pool to report updated before continuing — the storage layer cannot install onto
a node that is mid-reboot, and the failure is confusing rather than obvious.

---

## 8. What you get

Once the contract is satisfied and all phases are applied:

- **An event-driven training loop.** An object landing in the validation bucket triggers a `RayJob`,
  with no human in the loop and no polling on your side beyond the shipped CronJob.
- **Checkpoint durability across runs.** Training state lives on an RWX volume, snapshotted through
  CSI, so a run can resume rather than restart.
- **An evaluation gate.** A run that fails its metric threshold does not register a model. The gate
  is a Job with an explicit pass/fail contract, not a convention.
- **Model registration with lineage.** Passing runs are registered to MLflow with the metrics that
  justified them.
- **GPU observability.** A DCGM dashboard, if you have the console, and a counter set that can tell
  a busy GPU from a wedged one — `DCGM_FI_DEV_GPU_UTIL` alone cannot.
- **Alert rules that can actually match your namespace**, plus ServiceMonitors for endpoints that
  were already serving metrics and had never been scraped. All of it is inert until you satisfy
  §2.1, and it notifies nobody until you choose a receiver. Stated as what it is: the rules exist
  and are evaluated; delivery is yours.

---

## 9. What this contract does not give you

Stated plainly, because a contract that only lists successes is marketing.

- **Portability off OpenShift.** See §1.
- **Operator lifecycle.** You install and upgrade the operators in §2. A platform upgrade that
  changes a CRD schema is yours to absorb.
- **The object store, the filer or the GPUs.** This is a pipeline, not an infrastructure installer.
- **A tuned model.** The training script is a worked example, not a recommendation. Hyperparameters,
  the base model and the eval threshold are all yours to choose.
- **Multi-tenancy.** One `ClusterQueue`, one application namespace, one pipeline. Running several
  side by side needs quota partitioning this does not attempt.
- **Backup or DR.** Snapshots are for run continuity. They are not a backup strategy.
- **A network-independent run.** Every GPU pod reaches the public package index at pod start unless
  you have baked the pip set into your runtime image — see §3's "Per-run residue" for the mechanism
  and the cost.

---

## 10. Verifying you satisfy this before you apply anything

```bash
# Platform + versions
oc version                                   # server >= 1.31, OCP >= 4.18
oc get csv -A | grep -Ei 'gpu-operator|nfd|portworx|rhods'

# CRDs the pipeline needs
oc get crd | grep -E 'kueue|ray\.io|argoproj|snapshot\.storage|libopenstorage'

# GPU nodes are labelled and schedulable
oc get nodes -l nvidia.com/gpu.present=true

# Storage classes exist and have the reclaim policies above
oc get sc -o custom-columns=NAME:.metadata.name,PROVISIONER:.provisioner,RECLAIM:.reclaimPolicy

# Secrets exist with the right KEYS (this prints names only, never values)
oc get secret flashblade-s3 -n <your-namespace> -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'

# Quota is admitted, not merely present
oc get clusterqueue -o custom-columns=NAME:.metadata.name,ADMITTED:.status.admittedWorkloads
```

Every one of these is read-only.

---

## 11. Applying, once the contract is satisfied

This is step 4 of the sequence at the top of this document. Steps 1 to 3 — the operators of §2, the
array preparation of §4.1, and the secrets of §5 — are already done by the time you reach this
section. Applying the phases against an unprepared array does not fail here; it fails several
minutes later, in §12's vocabulary.

The manifests are Kustomize phases. **Order matters and Kustomize does not preserve it** — it sorts
by kind — so the sequence lives in the directory structure and must be applied phase by phase:

```bash
cp -r overlays/example overlays/<your-env>     # then edit it
OV=overlays/<your-env>

oc apply -k $OV/00-platform      # ⚠ reboots any node labelled px-storage — none, on a fresh install
oc apply -k $OV/10-storage       # wait for the StorageCluster to report Running
oc apply -k $OV/20-events        # wait for the EventBus to become Ready
oc apply -k $OV/30-pipeline
```

**Phase 30 contains one Job that runs immediately.** `model-staging` executes on apply and, on a
cluster with no model token, stops at `CreateContainerConfigError` (`secret "hf-token" not
found`) — which is §5 working as intended, failing exactly where you are told to supply
something. That is expected on a first apply; it is not a broken deployment.

`base/40-workloads/` is **not** part of that sequence. It holds a standing GPU cluster and
run-specific jobs kept as worked examples; applying it consumes GPU quota immediately and starves the
pipeline it sits beside. Apply individual files from it deliberately, if at all.

`base/50-stages/` is likewise **not** part of that sequence. It holds **three** Jobs —
`eval-gate-pass`, `eval-gate-fail`, and `v9-register` — which consume artifacts a completed run
produces. Applied before a run exists, they execute immediately and fail on missing input, leaving
Failed Jobs in an otherwise healthy namespace.

**`eval-gate-fail` is designed to fail.** It runs the same measured perplexity against a
deliberately tight threshold, so `exit 1` on a normal, successful cycle is proof the alert branch
works, not a defect — `eval-gate-pass` is the one that has to succeed. There is also a third gate
outcome, `exit 2`, meaning INCONCLUSIVE: the eval report never loaded a checkpoint (empty
`resume_from`), so there is no perplexity worth gating on — this keeps a base-model perplexity
from ever being promoted as if it were a trained model's.

Your overlay is where every environment-specific value lives. **At least seven values inside
`base/` still need your attention, and they are not overridable from an overlay** — they are
worth knowing before you apply:

| what | where | when it bites |
|---|---|---|
| `flashblade.example.com` ×4 | `base/00-platform/servicemonitor-flashblade-exporter.yaml` | phase 00. The scrape jobs point at a host that does not exist; the example overlay ships a commented JSON6902 patch and [docs/troubleshooting.md](docs/troubleshooting.md#the-flashblade-exporters-targets-are-all-down) explains the symptom |
| `RESUME_FROM: /mnt/fbda/ckpt-SUBSTITUTE-THE-TRAINING-RUN-ID` ×2 | `base/40-workloads/rayjob-eval-v8.yaml`, `base/40-workloads/rayjob-resume-v5.yaml` | opt-in phase 40. The training code refuses the placeholder at start-up, after the Ray cluster has formed |
| `GIT_SHA` (env `value:`, and the Python fallback default) | `base/50-stages/v9-register-job.yaml` | phase 50/opt-in registration step. This job's S3 upload is under SafeMode object-lock, so its lineage record is immutable once written; the job refuses to run (`SystemExit`) if `GIT_SHA` is still `REPLACE-ME`, rather than baking the placeholder into that record permanently |

Three further `REPLACE_ME` values live in `base/10-storage/cloudsnap-credential.yaml`, which is
**in no phase's `resources:` list** and is applied by nothing. It is opt-in scaffolding for a
backup target this pipeline does not use; see that phase's `kustomization.yaml`.

Anything else in `base/` that needs editing is a gap in this contract and worth reporting.

---

## 12. Connecting Portworx to the FlashBlade — what actually bites

This section covers failures that each present as something other than what they are — none of
them appear in the product documentation as failure modes. What follows is what the symptoms look
like from the operator's side.

Read as diagnosis, not as setup. The array-side preparation these failures presuppose is §4.1, and
`ansible/flashblade-prepare.yml` makes the read-only checks in §12.7 executable rather than a list
of `curl` lines to retype. If you have not done §4.1 yet, do that first — most of what follows is
what skipping it looks like.

### 12.1 `create volume: : not found` means authentication, not a missing object

The first RWX PVC on a `pure_file` StorageClass looped on:

```
failed to provision volume ... rpc error: code = Internal
  desc = Failed to create volume: : not found
```

The empty string before `not found` is the entire clue, and it points nowhere. The real cause was in
the Portworx log:

```
failed to login: HTTP error 401 / Could not authenticate to FlashBlade
```

The `MgmtEndPoint` in `px-pure-secret` named **a different FlashBlade** — one that was reachable
(`GET /api/api_version` returned 200) but rejected the token. Reachability proves nothing here;
`api_version` is unauthenticated.

**Treat `create volume: : not found` on a `pure_file` or `pure_block` StorageClass as an
auth/endpoint problem first.** It reads like a KVDB or CSI bug and it is neither.

**Verify a token before trusting it** — and note the endpoint carefully:

```bash
# CORRECT — the login endpoint is UNVERSIONED
curl -sk -X POST -H "api-token: <T-...>" https://<mgmt-endpoint>/api/login -D- -o /dev/null
#   200 + an x-auth-token response header = the token is good for this array

# WRONG — a versioned login path exists and accepts the token, but every subsequent
# call returns 403 "Access Denied", which looks exactly like an under-privileged token
curl -sk -X POST -H "api-token: <T-...>" https://<mgmt-endpoint>/api/2.17/login
```

Then confirm the data VIP actually belongs to the same array:

```bash
curl -sk https://<mgmt-endpoint>/api/<ver>/network-interfaces?filter='services=data' \
     -H "x-auth-token: <session>"
```

### 12.2 The `pure.json` schema — the block-storage one will not work

The secret **must** be named `px-pure-secret` with key `pure.json`, and the FBDA schema is not the
FlashArray/block schema. Field names and capitalisation both differ, and `NFSEndPoint` does not exist
in the block form at all:

```json
{"FlashBlades":[{"MgmtEndPoint":"<mgmt>","APIToken":"T-XXXXXXXX-...","NFSEndPoint":"<data-vip>"}]}
```

All three fields are required. `FlashBlades` is capitalised and plural. A `FlashArrays` template
reused from a block-storage deployment fails.

The API token is created array-side as a Storage Admin user with a non-expiring token.

### 12.3 Changing the secret is not enough — the runtime caches it

Under **Portworx Enterprise**, the storage runtime is a host `systemd` unit (`portworx.service`) that
parses the FlashBlade config once at start. Deleting the `oci-monitor` pod restarts the pod in
seconds and changes nothing: `systemctl show portworx.service -p ActiveEnterTimestamp` is unchanged,
and provisioning keeps using the stale endpoint. There is no `/etc/pwx/pure.json` to inspect — the
runtime reads the Kubernetes secret at boot.

The fix is a **rolling restart of the service, one node at a time**, waiting for each Portworx pod to
return `1/1` before moving on, so KVDB quorum survives:

```bash
oc debug node/<node> -- chroot /host systemctl restart portworx.service
```

**In CSI-only mode this may not apply** — the runtime there is the `px-pure-csi-*` pods, with no
`oci-monitor` and no host storage service. Re-verify before assuming either behaviour; a corrected
secret that appears to be ignored is the symptom to watch for.

### 12.4 Network path: two endpoints, two different jobs

| Endpoint | Reached by | Carries |
|---|---|---|
| Management | the Portworx control plane | REST API — volume create/delete/query |
| NFS data VIP | **every node that mounts a volume** | the actual NFS traffic |

They are frequently on different networks, and a working management path tells you nothing about the
data path. A successful `create volume` followed by pods stuck in `ContainerCreating` is the
signature of a data VIP that the nodes cannot reach.

**These often have different reachability stories.** In the tested environment the management
endpoint was reached by *routing* through a bastion, while the data VIP was **direct L2** on the
storage VLAN. That asymmetry has a consequence worth planning for: the routed hop becomes a
**storage control-plane single point of failure** — existing mounts survive its outage, but new
volume provisioning stalls. If that is unacceptable, give the nodes a routable path of their own.

A correct mount looks like this — check `vers=4.1` and the `pure-file` PV type:

```
<data-vip>:/px_<...>-pvc-<uuid>  nfs4  vers=4.1,proto=tcp
```

### 12.5 Export rules

The StorageClasses set `pure_export_rules: "*(rw,no_root_squash)"`. `no_root_squash` is required
because container processes running as root must not be squashed to `nobody` on the export. Without
it you get permission-denied on writes and `lchown` failures on `fsGroup` — both of which look like
application bugs. Narrow the `*` to your node network if your security posture requires it; the flags
matter, the wildcard does not.

### 12.6 What you do NOT need for the file path

**No multipath, no iSCSI, and therefore no node reboots for FBDA itself.** Those are the block /
cloud-drive path. A `pure_file` deployment needs only current NFS utilities on the node, and
`mount.nfs` is already present on RHCOS.

Reboots may still be incurred for other reasons — attaching a `MachineConfig` to a pool does reboot
its nodes — but not by the FlashBlade file path.

### 12.7 Preflight, before you install anything

Read-only, and each one targets a specific failure mode described above:

```bash
# 1. Management endpoint reachable AND the token accepted (two different things)
curl -sk -X POST -H "api-token: <T-...>" https://<mgmt>/api/login -D- -o /dev/null   # want 200

# 2. Data VIP reachable ON PORT 2049 from a node that will mount volumes
nc -zv <data-vip> 2049

# 3. The data VIP belongs to the SAME array as the management endpoint
curl -sk "https://<mgmt>/api/<ver>/network-interfaces?filter=services='data'" -H "x-auth-token: <s>"

# 4. MTU actually agrees end to end — a jumbo-configured array subnet against a 1500 host NIC
#    fails only under load, not on ping
ping -M do -s 8972 <data-vip>
```

Check 4 is worth running even though it looks pedantic: an array subnet configured for MTU 9000
against a host NIC still at 1500 produced `message too long, mtu=1500` — a local host config gap that
would otherwise surface much later as unexplained NFS stalls.

### 12.8 Why CSI-only, and what an edition change actually costs

Portworx **Enterprise**, in its GA release line, hard-blocks `pure_file` snapshots *in code* — the
call returns `errPureFileSnapshotNotSupported` with no feature flag, REST-version gate or
StorageClass setting that unlocks it. Since the whole pipeline depends on snapshotting an RWX
FlashBlade volume, Enterprise alone cannot deliver it today.

**PX-CSI** is a separate, released product — the CSI-only driver installed with `--oem px-csi` —
whose FBDA snapshot support is GA above a stated array floor. This tree is built and tested against
PX-CSI, and everything above assumes it.

**If you already run Portworx Enterprise, this is not necessarily a teardown-and-rebuild.** Portworx
Enterprise 3.6.0 + PX-CSI 26.1.0 ship an **in-place integration path**: an annotation
(`portworx.io/pure-csi-integration: "true"`) drives `pre-`/`post-pure-csi-migrator` Jobs that move
KVDB metadata into Kubernetes CRs while preserving `ClusterUUID` and existing volumes, and it
explicitly lists **Snapshot of FlashBlade PVC** as one of the capabilities it unlocks. **As of the
vendor docs dated 2026-05-14, this integration is Early Access** — verify its current status before
relying on it in production.

Outside that integration path, both editions still register the same cluster-scoped
`CSIDriver pxd.portworx.com` singleton, so an ad hoc side-by-side install of both remains impossible.

What CSI-only changes: no KVDB, no storage pool, no `oci-monitor` data plane. Metadata lives in
Kubernetes CRs. That also removes an entire class of hazard — with no local storage provisioning,
GPU-node NVMe is never touched.

**On OpenShift, do not install a second snapshot controller.** The platform ships its own.

**Licensing.** `--oem px-csi` selects a build whose FA/FB CSI licence is embedded in the product,
and today that is a distinct licence/SKU from Portworx Enterprise, not bundled with it — the
integration above is a technical migration path, not a licensing merge. Behaviour with no
entitlement is not documented by the vendor. If provisioning or snapshots fail and the error
mentions a licence, that is this, not a manifest defect — confirm your entitlement covers the
CSI-only OEM build before you rely on it. If it does not, Enterprise above is the fallback, with
the `pure_file` snapshot limitation already described.
