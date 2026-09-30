# Getting started

Prerequisites through a first training run. Read
[ENVIRONMENT-CONTRACT.md](../ENVIRONMENT-CONTRACT.md) first if you have not — it states what this
needs from your cluster and what it deliberately does not give you. New to GPU/AI-ML terms like
checkpoint, LoRA, or world size? See [docs/glossary.md](glossary.md).

---

## 1. Check the cluster before applying anything

```bash
./preflight.sh -n ml-training
```

Read-only. It checks the platform floor, the nine required CRDs, GPU node labels and allocatable
count, StorageClass reclaim policy, Secret keys (names only — never values), and Kueue quota
admission. Every failure it reports would otherwise surface later in a form that is harder to read.

If it passes, your cluster satisfies the contract. If not, fix what it names before continuing.

## 2. The Red Hat pull secret

Every Ray image comes from `registry.redhat.io` and needs Red Hat credentials:

```bash
oc get secret/pull-secret -n openshift-config -o json \
  | jq -r '.data[".dockerconfigjson"]' | base64 -d | jq '.auths | keys[]'
```

If `registry.redhat.io` is missing, add it from
<https://console.redhat.com/openshift/downloads> → Pull Secret. A missing entry surfaces much later
as `ImagePullBackOff` on driver pods.

## 3. Copy the example overlay

```bash
cp -r overlays/example overlays/mine
```

`overlays/example/` is the template to copy. Each phase directory carries a header explaining what
it expects you to change, with the patches written out and commented.

**Read `overlays/<yours>/30-pipeline/kustomization.yaml` before applying it.** Setting `namespace:`
relocates most resources, but it does **not** rewrite four things that must change with it:
in-cluster DNS (`mlflow.<ns>.svc.cluster.local`), the namespace *inside* the Sensor's RayJob
template, the S3 bucket names, and the Kueue queue-name label. Changing `namespace` alone yields a
deployment that applies cleanly and does not work.

## 4. The three buckets

Create them however your object store is normally administered — the array UI, its REST API, or
`aws s3 mb`. Names, purposes and required settings are in
[contract §4](../ENVIRONMENT-CONTRACT.md#4-object-storage). Two things matter most:

- the **trigger inbox** and the **dataset source** must be *different* buckets, or every dataset
  upload fires a training run;
- the **registry** bucket wants versioning and object lock, because model lineage is write-once.

Bucket names are not hard-coded — set them in your overlay via the `pipeline-config` ConfigMap.

> **On a FlashBlade there is a runnable path for this.** `ansible/flashblade-prepare.yml` creates
> the object-store account, all three buckets (registry with versioning and object lock) and the
> pipeline user, and verifies the array-side settings the StorageClasses assume. It takes its
> credentials from `PUREFB_URL` / `PUREFB_API` and carries none of its own. Start with `--check`; it
> refuses to write without an explicit opt-in. See [`../ansible/README.md`](../ansible/README.md) and
> [contract §4.1](../ENVIRONMENT-CONTRACT.md#41-preparing-the-array-and-the-playbook-that-does-most-of-it).
>
> It stops short of minting the S3 access key, and that is a decision rather than an omission: the
> array returns a key's secret exactly once, so automating it would leave the only copy of a live
> credential in Ansible's output. The README names the three manual steps and the reason for each.

## 5. Apply the phases, in order

**Do this before creating the Secret in the next section.** `base/30-pipeline/namespace.yaml` is
the only thing in this repo that creates the `ml-training` namespace, and it is applied here, as
part of phase 30. `oc create secret ... -n ml-training` fails with `namespaces "ml-training" not
found` if you run it before this section instead of after.

> **If your cluster already runs Portworx, stop here.** `base/10-storage` ships a StorageCluster
> named `px-csi-example`. Applying this phase onto a cluster that already has one under a
> different name **creates a second StorageCluster** in the same namespace, against the same
> nodes, and leaves the operator reconciling both. `./preflight.sh` reports the mismatch as an
> advisory. Either skip this phase — its StorageClasses and VolumeSnapshotClass may already exist,
> check with `oc get sc` — or rename the StorageCluster in your overlay to match yours. Do not
> apply it unchanged.

```bash
OV=overlays/mine

make apply-phase OVERLAY=$OV PHASE=00-platform
#  Applies a MachineConfig and MachineConfigPool for storage-role nodes. Reboots any node you have
#  labelled node-role.kubernetes.io/px-storage — on a fresh install that is none, and nothing
#  reboots. If you have labelled storage nodes, wait for the pool: Portworx cannot install onto a
#  node that is mid-reboot.
oc get mcp px-storage -w          # UPDATED=True, UPDATING=False, DEGRADED=False — on a fresh
                                   # install MACHINECOUNT is 0 and this returns immediately; that
                                   # is expected, not a failure

make apply-phase OVERLAY=$OV PHASE=10-storage
oc -n portworx get storagecluster -w        # Running, 5–10 min

make apply-phase OVERLAY=$OV PHASE=20-events
oc -n argo-events wait --for=jsonpath='{.status.conditions[?(@.type=="Deployed")].status}'=True eventbus/default --timeout=120s

make apply-phase OVERLAY=$OV PHASE=30-pipeline
```

Preview any phase without applying it:

```bash
make render OVERLAY=$OV PHASE=30-pipeline | less
oc apply -k $OV/30-pipeline --dry-run=server     # validates against the live API
```

**The `s3-poller` CronJob ships suspended.** Applying phase 30 — or re-applying it later — resets
`suspend` to the tree's value, which is `true`, so a fresh install cannot fire a red
`FbdaJobFailed` alert every five minutes against an unconfigured bucket. This does **not** block
firing a run below: forcing a poll by hand works whether or not the CronJob is suspended, because
`suspend` blocks only *scheduled* creation.

Once your buckets are configured and confirmed (see "The three buckets" above, and the bucket
check in `preflight.sh`), un-suspend it to get autonomous, on-schedule polling:

```bash
oc -n ml-training patch cronjob s3-poller -p '{"spec":{"suspend":false}}'
```

Re-applying phase 30 for any later change resets this back to suspended — re-run the command
above afterward if you want the schedule live again.

## 6. The Secret

The `ml-training` namespace exists now — phase 30, applied above, created it — so this Secret can
actually be created in it:

```bash
oc create secret generic flashblade-s3 -n ml-training \
  --from-literal=AWS_ACCESS_KEY_ID=... \
  --from-literal=AWS_SECRET_ACCESS_KEY=... \
  --from-literal=S3_ENDPOINT=https://your-s3-endpoint
```

Any mechanism is fine — sealed secrets, an external secrets operator, whatever your platform uses.
The manifests reference it by name and key only.

Verify with `aws s3 ls s3://<your-bucket>/`, **never a bare `aws s3 ls`**: a bucket-scoped key
cannot enumerate the account and returns `AccessDenied` on a perfectly good credential.

## 7. Stage the base model and dataset

```bash
oc create secret generic hf-token -n ml-training --from-literal=HF_TOKEN=<your-hf-token>
oc -n ml-training logs -f job/model-staging
```

The staging Job is part of phase 30 and runs on apply: 60–120 minutes for Qwen3-32B (~65 GB) plus
the dataset. It writes a `.staging_complete` marker and skips on subsequent runs.

**The staging Job needs an HF token regardless of the dataset.** `model-staging-job.yaml` reads
`HF_TOKEN` as a required environment variable with no default, and passes it to both the model and
dataset downloads. The default dataset, `nvidia/Nemotron-Agentic-v1`, is CC BY 4.0 and **not
gated** — but the secret must still exist for staging to run. Override `MODEL_ID` / `DATASET_ID` to
use your own.

## 8. Confirm the volume

```bash
oc -n ml-training get pvc fbda-shared     # expect: Bound
```

## 9. Fire a run

Firing a run means writing one object under the inbox prefix in the validation bucket. That write
has to happen from inside the cluster — the data VIP is usually not routable from a workstation,
and the credential lives in a Secret — so `scripts/trigger-validation-object.yaml` is a Job that
does it. **Polling alone will not fire anything on a fresh install**: with an empty inbox, forcing
a poll correctly reports `new-objects-fired=0` and nothing happens.

```bash
oc -n ml-training delete job trigger-validation-object --ignore-not-found
```

Edit `OBJECT_NAME` and `RUN_LABEL` in `scripts/trigger-validation-object.yaml` first — it ships
`REPLACE-ME.json` / `REPLACE-ME` and refuses to run with either left in place, because an
unidentifiable object still costs a full training run. Then:

```bash
oc -n ml-training create -f scripts/trigger-validation-object.yaml
oc -n ml-training logs job/trigger-validation-object   # expect: trigger-object-written=1
```

A completed Job's spec is immutable, which is why this is `delete` then `create`, never `apply`.
`backoffLimit: 0` and the fixed key/bytes make re-running this Job harmless: a retry never writes a
second object.

Then force one poll rather than waiting for the schedule, so the run starts now instead of on the
next tick:

```bash
oc -n ml-training create job trigger-poll --from=cronjob/s3-poller
oc -n ml-training logs job/trigger-poll        # expect: new-objects-fired=1
oc -n ml-training get rayjob -w
```

Forcing a poll works whether or not the CronJob is suspended — `suspend` blocks only *scheduled*
creation, which is exactly why this works even before you decide to un-suspend it (see "Apply the
phases, in order" above).

Expect, in order: model download, the 60-step training loop, then the checkpoint barrier and
upload. A complete run took **~122 minutes** end to end against a 240-minute
`activeDeadlineSeconds` — see [docs/results.md](results.md) for the full timing breakdown.

## 10. Watch it

```bash
# progress, from the submitter pod — the head pod carries only Ray infrastructure logs
SUB=$(oc -n ml-training get pods --no-headers | awk '/qwen3-fbda-auto-[a-z0-9]+-[a-z0-9]+ /{print $1}' | head -1)
oc -n ml-training logs "$SUB" | grep -oE '\[train\] step=[0-9]+ .*'
```

**This regex assumes a Sensor-fired job.** The Sensor's RayJob template carries a `generateName`,
so a fired job's submitter pod gets two random suffixes — `qwen3-fbda-auto-<a>-<b>` — which is what
the two `[a-z0-9]+` groups match. A RayJob applied directly from `base/40-workloads/` (see "Optional
phases" below) has a fixed `metadata.name` and only one suffix, so this regex matches its **head**
pod instead — `qwen3-fbda-auto-head-<b>` also satisfies two groups — and you end up reading Ray
infrastructure logs while believing you're watching training. For a standalone RayJob, match the
job's own fixed name with exactly one trailing suffix. Excluding `-head-` is not enough on its own
— the RayCluster name appears in worker-pod names too (`<rayjob>-<rc-suffix>-<groupName>-worker-<c>`),
so that filter alone lands on a worker pod instead of the submitter:

```bash
JOB=qwen3-fbda-auto
SUB=$(oc -n ml-training get pods --no-headers | awk -v job="$JOB" '$1 ~ ("^"job"-[a-z0-9]+$"){print $1}' | head -1)
oc -n ml-training logs "$SUB" | grep -oE '\[train\] step=[0-9]+ .*'
```

In the console, **Observe → Dashboards → AI Training Run** shows GPU engine activity, checkpoint
volume headroom, NFS operations to the array, and pod phase. The default window is *Last 30
minutes*, which is shorter than a run — set it to a custom range covering the whole thing.

## Optional phases

**`40-workloads`** holds a standing RayCluster and example RayJobs. It is **not** part of the
sequence above: applying it consumes GPU quota immediately and starves the autonomous pipeline,
which creates its own RayJobs when an object arrives.

**`50-stages`** holds the evaluation gate and model-registration Jobs, which need artifacts from a
completed run.

**The environment variable you must substitute here is `GIT_SHA`.** `base/50-stages/v9-register-job.yaml`
ships it as the placeholder `REPLACE-ME`. Set it to a real commit SHA before applying this phase:
the register job's S3 upload is under SafeMode object-lock, so the lineage record it writes is
immutable once written, and the job refuses to run (`SystemExit`) on the placeholder rather than
baking `REPLACE-ME` into that record permanently.

A completed run is **not** enough on its own for the eval job. The training code uploads the
checkpoint to S3 and then deletes the local copy, so the shared volume holds no checkpoint once the
run finishes, and the eval reads from the volume.

**There is one supported way to have a checkpoint on the volume, and it is not mounting a restored PVC.**
Set `KEEP_LOCAL_CKPT=1` on the **training** run, so the local copy survives. Set it on the run, not
in your Sensor: each retained checkpoint is ~366 GiB (~393 GB), so on an 800Gi volume the third run fails with
ENOSPC inside `save_checkpoint()` after two hours of GPU time. Delete the previous one first.
Do not create a PVC from the VolumeSnapshot to get one.
On this CSI driver a restore does not clone: it reverts the source filesystem and discards everything
written since the snapshot. That was measured three separate times — every restore produced a
PersistentVolume carrying the source's own backend id — and the environment contract's recovery
section records the measurement and the three recovery tiers it leaves you.
The header of `base/40-workloads/rayjob-eval-v8.yaml` says the same thing in stronger terms.

**The environment variable you must substitute is `RESUME_FROM`.** Both
`base/40-workloads/rayjob-eval-v8.yaml` and `base/40-workloads/rayjob-resume-v5.yaml` ship it as the
placeholder `/mnt/fbda/ckpt-SUBSTITUTE-THE-TRAINING-RUN-ID`, and applying either without replacing it
is refused by the training code at start-up, before any training begins — though after the Ray
cluster has formed, not at `oc apply` time. Those two headers also give the
`oc get rayjob -l ckpt-run-id -o jsonpath='{.items[-1:].metadata.labels.ckpt-run-id}'` lookup that
prints the run id to put there — that label is set only by the Sensor's RayJob template, though, so
the lookup fails (a raw jsonpath array-index error, not an empty string) for a directly-applied
`rayjob-train-ephemeral.yaml` run; use that file's own `RUN_ID`/`CKPT_DIR` value instead. The
headers also explain why the eval's worker count is fixed by the checkpoint's world size rather
than by your quota — the shard count is 2 x world_size + 2.

**`rayjob-train-ephemeral.yaml`'s worker count does not match `rayjob-resume-v5.yaml` or
`rayjob-eval-v8.yaml`.** The shipped defaults are `NUM_WORKERS=4`/`replicas=4` for training and `8`
for both resume and eval. A ZeRO-3 checkpoint is sharded per rank and cannot be resharded, so if you
plan to resume or evaluate a manually-fired training run, set `NUM_WORKERS`/`replicas` to `8` in
`rayjob-train-ephemeral.yaml` before you fire it, not after — there is no way to reshard a
checkpoint once training has produced it.

## Keeping the training code in sync

`base/30-pipeline/train-code-configmap.yaml` is generated from
`train/train_qwen3_deepspeed.py`. They must move together:

```bash
make validate-train-configmap
```

A drifted pair deploys cleanly and runs the wrong code.

## Secrets reference

| Secret | Namespace | Keys | Created by |
|---|---|---|---|
| `flashblade-s3` | your application namespace | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `S3_ENDPOINT` | you |
| `px-pure-secret` | `portworx` | `pure.json` | you — see [contract §12.2](../ENVIRONMENT-CONTRACT.md#122-the-purejson-schema--the-block-storage-one-will-not-work) |
| `hf-token` | your application namespace | `HF_TOKEN` | you, one-time |
| cluster pull secret | `openshift-config` | — | OCP install + Red Hat portal |

## What is not in these manifests

- **OpenShift install.** The installer assets are yours; this repo starts from a running cluster.
- **Operators.** Pinned OLM channels go stale with every platform release, so they are a documented
  prerequisite instead — [contract §2](../ENVIRONMENT-CONTRACT.md#2-operators-and-crds--install-these-first).
- **SSH credentials of any kind.** Hold them in your own secret store.
- **Portworx licensing.** A Trial expires and the pipeline stops provisioning volumes when it does:
  ```bash
  PXPOD=$(oc -n portworx get pod -l name=portworx -o name | head -1)
  oc -n portworx exec $PXPOD -- /opt/pwx/bin/pxctl license list
  ```

## Next

- [docs/what-to-expect.md](what-to-expect.md) — screenshots of a real run, so you know what a
  healthy dashboard, loss curve and eval result look like before you fire your own.
- [docs/results.md](results.md) — the measured numbers this run produced, for comparison against
  yours.
- [docs/troubleshooting.md](troubleshooting.md) — if a run applies cleanly and then does nothing,
  or something else does not match what this guide describes.
- [docs/rollback-runbook.md](rollback-runbook.md) — the one destructive operation in this pipeline,
  for when you need to revert the checkpoint volume from a snapshot.
