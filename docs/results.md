# Results

What this pipeline actually did on the configuration it was validated against, and what it did not.

These figures come from a full teardown back to before phase 00, followed by a fresh rebuild from
this repo's own published instructions, then training, checkpoint rollback + resume, and held-out
eval fired in sequence — on the hardware described in
[contract §1](../ENVIRONMENT-CONTRACT.md#1-platform): 2 GPU nodes,
8 × NVIDIA L40S, OpenShift 4.18, an NFS-capable flash array behind Portworx CSI. **They are a
record, not a benchmark and not a promise.** Your numbers will differ with your hardware, your
model and your data.

For screenshots of what produced these numbers — the dashboards, the loss curve, the eval metrics —
see [docs/what-to-expect.md](what-to-expect.md).

---

## The run

| | |
|---|---|
| Workload | Qwen3-32B, full-parameter fine-tuning via DeepSpeed ZeRO-3 with full CPU offload, 8 GPUs |
| Trigger | one object written to the validation bucket; no human in the loop after that |
| Training run | **~122 minutes** end to end, against a 240-minute deadline. Final loss **`0.6574476957321167`** — bit-identical to prior runs. A separate 60-step run with `KEEP_LOCAL_CKPT=1` — which retains the checkpoint instead of reclaiming it — took **130 min 40 s**; it is not the same work and is not comparable to the figure above. |
| Result | `SUCCEEDED`; checkpoint written, verified and registered |
| Checkpoint verification | `world_size=8`, 18 objects, manifest uploaded **last** as the completion signal |
| Checkpoint rollback + resume | **~27 minutes.** Reverted the checkpoint volume from a snapshot and resumed training, continuing from checkpoint step 15 rather than restarting — see [rollback-runbook.md](rollback-runbook.md) |
| Held-out eval | **~50 minutes** on 8 GPUs, resuming the checkpoint at its saved global step: `eval_loss=0.6886380314826965`, **perplexity 1.9910020037446772** over 64 held-out sequences (an earlier run of the same shape measured 2.0032; see [base/50-stages/eval-gate-job.yaml](../base/50-stages/eval-gate-job.yaml)) |
| Eval gate | decided on that number: promote at a loose bar, stop-and-alert at a tight one, exit 0 and exit 1 |

Every duration here is a RayJob's own `status.startTime` → `status.endTime`, read with
`oc get rayjob <name> -o jsonpath='{.status.startTime} {.status.endTime}'`. The determinism count
is the number of runs whose final-step loss matched at full precision, read from MLflow's
`metrics/get-history` — **not** from the six-decimal log lines, which agree more often than the
numbers do.

**On the eval number:** it averages loss over 64 independent 128-token sequences, so each sequence's
opening tokens are predicted with almost no context. That makes it a usable *relative* gate — the
bias is constant from run to run — and **not** comparable to any published perplexity, which is
normally measured with a strided sliding window over long text. It is also slower than it should be:
ZeRO-3 re-gathers parameters on every forward pass, which earns nothing under `no_grad()`, and the
eval inherits the training micro-batch size of 1, so it runs 64 passes sequentially. Consolidating
the checkpoint with the `zero_to_fp32.py` script it already contains would let eval run on one GPU.

The pipeline was **torn down to nothing and rebuilt from these manifests immediately before the
run** — namespace deleted, volumes deleted, array filesystems eradicated, then reapplied. That is
the normal way this tree is exercised, not a special case.

## Storage, during the checkpoint barrier

The interesting moment is the checkpoint write: every GPU goes idle while a multi-hundred-gigabyte
checkpoint lands on the shared volume. Peaks over the run:

| Measurement | Peak |
|---|---:|
| Array write bandwidth (NFS) | **7,123 MB/s** |
| Array write IOPS | **13,589/s** |
| Array read IOPS | **12,461/s** |
| Client-side NFSv4 write operations | **2,645/s** |
| Shared volume occupancy at peak | **444.8 GiB** of 800 GiB |
| Shared volume after checkpoint reclaim | **18.9 GB** |

**The array was not the constraint.** Throughput of this order was sustained while the GPUs sat
idle waiting on the write — the bottleneck in this pipeline is the upload path, not the filer. The
same shape appeared in the two runs for which array-side data was captured (7,123 and
6,755 MB/s peak write); the run-to-run *determinism* below has held across repeated runs.

**Size your volume against one checkpoint, not against a percentage.** Peak occupancy was 444.8 GiB
for a single checkpoint plus accrued logs. A platform default that alerts at "3% free" fires at
24 GB on an 800 GiB volume — an order of magnitude below one checkpoint, which is to say, after the
write it was meant to warn you about has already failed.

## Reproducibility

Final training loss was **`0.6574476957321167`** across eight rebuilds of a namespace, freshly
provisioned volumes, and a rebuilt MLflow store — bit-identical every time. All eight ran with
every rank reading the same fixed sample window from index 0.

The most demanding of these reproductions ran with the dependency set pinned end to end — `torch`
moved from `2.7.1+cu128` to `2.13.0+cu130`, pulling in the whole CUDA 13 runtime, while every other
reproduction ran the unpinned set. The loss did not move at any of its 60 steps.

**No random seed exists anywhere in the training script.** Reproducibility instead comes from the
loop having no randomness to fix: a fixed, unshuffled data walk, pretrained weights, and no new
random initialization. That is worth stating because it is the thing that makes a change to this
pipeline *reviewable*: if the loss moves, something moved.

**Each rank now reads a distinct offset into the data walk.** `rank` determines which phase of the
fixed sample window a worker starts at, so all 8 workers compute distinct batches at every step,
and the ZeRO-3 gradient all-reduce averages 8 different gradients rather than 8 identical copies of
one — genuine 8-way data-parallel training. A run under this data-parallel walk trains on different
data at every step than the eight reproductions above did, and produces its own baseline loss
value, not the one recorded here.

## What did not work

Stated because a results page that only lists successes is marketing.

- **`ray_training_*` metrics need a Ray-version-specific workaround.** See
  [Limitations](../README.md#limitations) — the run stays fully observable through GPU, storage,
  volume and pod-phase metrics regardless, and this works on this cluster's Ray build.
- **The shared volume's session directory keeps a low, bounded file count by design** — `277 files`
  on a 7-second mount, using a sidecar that copies logs off a pod-local `emptyDir` rather than
  mounting the volume directly. If you mount this volume from a pod of your own, set
  `fsGroupChangePolicy: OnRootMismatch` on it too, and keep its own file count low: that setting
  speeds up a remount of an already-correct volume, but cannot rescue a first mount by itself.
- **Snapshot restore does not give you a second copy — it rewinds the one you have.** Creating a PVC
  from a `VolumeSnapshot` yields a PersistentVolume that shares the **source's** volume handle, and no
  new filesystem appears on the array — measured three independent times. The restore **reverts the
  source** and hands you another name for it. Two things to know before relying on it: mounting a
  "restored" PVC alongside its source mounts one filesystem read-write twice, which hangs; and creating
  the PVC at all discards anything written since the snapshot. There is no experiment branching and no
  clone. See [contract §3.3](../ENVIRONMENT-CONTRACT.md#33-snapshot-behaviour-you-must-design-around)
  for the method and the measurements, and [rollback-runbook.md](rollback-runbook.md) for the
  procedure itself.

  **Rewinding is recovery for the common case, and it works:**

  | Failure | Recovery | Status |
  |---|---|---|
  | Volume **contents** are bad — corrupted, diverged, a run went wrong and you need to go back | **Snapshot rollback.** Metadata-only, effectively instant | **proven, byte-exact** |
  | Volume or array is **gone** | **S3 archive** — every verified checkpoint is uploaded | **restore script exists** — see below |
  | Site or array **lost** | replication to a second array | **not implemented — see Limitations** |

  **Restoring from S3 (tier 2) is done by a script, not just an upload path.**
  `scripts/restore-checkpoint-from-s3.sh` downloads a checkpoint's `checkpoint-manifest.json`
  first — the same file the upload path writes and uploads LAST as its own completion signal —
  and only reports the restore complete once every file that manifest lists has come back at its
  recorded size. A synthetic checkpoint-shaped fixture restored byte-for-byte (checksums matched
  the originals); a second fixture with one shard deliberately left out of the upload was
  correctly rejected, naming the missing file instead of reporting success; and the script's
  manifest parsing and small-object download path were run against a real checkpoint's manifest
  and its small files (the kilobyte-sized model-state shards, `latest`, `zero_to_fp32.py`),
  without moving that checkpoint's ~393 GB of optimizer-state data.

  Snapshot rollback and resume were measured end to end: snapshot a 366 GiB (~393 GB) ZeRO-3
  checkpoint, revert the filesystem to it, then resume training. The revert was confirmed by two files written *after* the snapshot
  disappearing while the checkpoint and all 16 rank shards survived. The resumed run then reproduced
  **all eight** per-step losses bit-identically against an earlier resume of the same checkpoint read
  from the volume before it was reverted — including the first step after an optimizer update, which
  is the one that depends on the restored ZeRO-3 **optimizer** shards rather than only the model
  weights. So the rollback returns the checkpoint exactly, not merely loadably.

  **Why this is worth the storage being a filesystem.** The rollback is a metadata operation on storage
  the GPUs already have mounted. The equivalent on object storage is re-downloading the checkpoint —
  366 GiB (~393 GB) here — before training can start again.
- **Alert-expression satisfiability is checked, not just syntax.** `scripts/check-alert-satisfiability.sh`
  confirms every metric name a shipped alert expression references is actually registered on your
  cluster's Prometheus — a rule can evaluate cleanly and still be dead if it references a metric
  that is never emitted. Run the script against your own cluster before you depend on any rule it
  did not check.

See [Limitations](../README.md#limitations) for the full list, and
[contract §9](../ENVIRONMENT-CONTRACT.md#9-what-this-contract-does-not-give-you) for what the contract
deliberately does not give you.
