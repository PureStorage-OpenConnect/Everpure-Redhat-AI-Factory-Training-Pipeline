# AGENTS.md

Fast orientation for an agent (or a human using one) working in this repo tree with no other
context. This file is a map, not a tutorial — read the linked docs for depth.

## What this is

An event-driven, full-fine-tuning pipeline for `Qwen/Qwen3-32B` (Apache-2.0) on OpenShift. An
object landing in an S3 bucket triggers Argo Events, which creates a `RayJob`. Ray/KubeRay
schedules 8 GPU workers running DeepSpeed ZeRO-3; the workers checkpoint to a shared FlashBlade
NFS volume, upload the checkpoint to S3, get evaluated on held-out data, and (if the gate passes)
the model is registered in MLflow — no human in the loop after the upload. It proves this is
possible on GPUs without NVLink (tested: 2 nodes, NVIDIA L40S). Storage is FlashBlade, serving
both the S3 (trigger, model, checkpoint archive) and NFS (shared checkpoint volume) roles from one
array via the Portworx CSI-only (`--oem px-csi`) driver.

**The actual deliverable is [ENVIRONMENT-CONTRACT.md](ENVIRONMENT-CONTRACT.md)**, not the
manifests — that is this repo's own framing (see its README link and the contract's opening
paragraph). The manifests are one implementation of the contract; if your cluster satisfies the
contract, they will run, and if it does not, they apply cleanly and then fail confusingly. Read
the contract before touching a live cluster, and read it before the README if you only have time
for one.

## Fine-tuning method and reproducibility

This pipeline does **full-parameter fine-tuning, not LoRA**. `deepspeed.initialize()` is built with
`model_parameters=[p for p in model.parameters() if p.requires_grad]` — every trainable
parameter of the base model, not a LoRA adapter — under ZeRO Stage 3 with both optimizer state
and parameters offloaded to CPU. There is no `lora`, `peft`, `LoraConfig`, or `get_peft_model`
anywhere in this codebase. This is also why the checkpoint is so large — the optimizer state
alone is roughly 12 bytes per parameter, a shape `ENVIRONMENT-CONTRACT.md` explains and that
only makes sense for full-parameter training, not a small adapter.

**No random seed is set anywhere, and that's deliberate, not an oversight.** There is no
`torch.manual_seed`, `set_seed`, or seed config key in the training script. Reproducibility
instead comes from the training loop containing no randomness at all: `load_training_samples`
reads the dataset once into a fixed in-memory list, and the training loop walks it with a
plain modular index (`idx = (idx + batch_size) % max(n - batch_size, 1)`, no shuffling), while
the model loads straight from a pretrained checkpoint with no randomly-initialized new weights.
**Practical consequence for anyone adapting this**: a more realistic SFT recipe — a larger
dataset that needs shuffling, or dropout restored — will need an *explicit* seed added to keep
any reproducibility property, since none is wired in today. Also, resume does not restore data-walk position: `step` always starts at `0` and `idx` always
starts at `(rank * batch_size) % max(n - batch_size, 1)` at the top of the training loop
(`train_qwen3_deepspeed.py`, just before the `while step < MAX_STEPS` loop) — a fixed function of
`rank` and the sample count, not a saved position — even when `RESUME_FROM` is set. Only the model
and DeepSpeed optimizer state are restored via `engine.load_checkpoint()`. So even a seeded version
would not resume the data walk from wherever the original run had reached without further changes.

## The six phases, apply order, opt-in status

Kustomize sorts by kind, not declaration order, so phase order lives in the directory structure
and must be applied one directory at a time (`oc apply -k <overlay>/<phase>`), never as one big
`apply -k` over `base/` or the overlay root:

| # | Phase | Contains | Opt-in? |
|---|---|---|---|
| 1 | `00-platform` | MachineConfigPool/MachineConfig (storage-role reboot), Kueue ClusterQueue + ResourceFlavor, dashboards, ServiceMonitors, cluster-monitoring config | Required |
| 2 | `10-storage` | StorageCluster (Portworx CSI-only), StorageClasses, VolumeSnapshotClass | Required |
| 3 | `20-events` | Argo Events EventBus, EventSource, Sensor (the S3-trigger RayJob template) | Required |
| 4 | `30-pipeline` | The application: namespace, MLflow, RBAC, ConfigMaps, S3 poller CronJob, PVCs, alerts | Required |
| 5 | `40-workloads` | Standing RayCluster + example RayJobs (train/eval/resume) | **Opt-in** — consumes GPU quota immediately |
| 6 | `50-stages` | Eval-gate Jobs, model-registration Job | **Opt-in** — needs a completed run's artifacts; applied early, jobs fail permanently on missing input |

Full walkthrough: [docs/getting-started.md](docs/getting-started.md). Note that phase 30 contains
`model-staging-job.yaml`, which runs immediately on apply and, with no `hf-token` Secret present,
is *expected* to stop at
`CreateContainerConfigError` on a first apply.

## Cross-file consistency traps

These are places a naive edit breaks silently — no error, no event, just a wrong or hung result.

1. **GPU model pinning is absent everywhere, on purpose, and must be added everywhere at once.**
   `base/00-platform/kueue-resourceflavor-gpu.yaml` and every worker pod spec select only
   `nvidia.com/gpu.present` (true of any CUDA-capable node), never `nvidia.com/gpu.product`. On a
   single-GPU-model cluster this is fine. On a mixed fleet, pin
   `nvidia.com/gpu.product` in **all** of these together, or a job can land on the wrong hardware
   with no error (an unsatisfiable selector just leaves pods `Pending` forever):
   - `base/00-platform/kueue-resourceflavor-gpu.yaml` (the `ResourceFlavor`)
   - `base/40-workloads/raycluster-fbda-checkpoint.yaml`
   - `base/40-workloads/rayjob-train-ephemeral.yaml`
   - `base/40-workloads/rayjob-eval-v8.yaml`
   - `base/40-workloads/rayjob-resume-v5.yaml`
   - `base/20-events/s3-eventsource-sensor.yaml` (the Sensor's embedded RayJob template — two
     occurrences)
   - `base/10-storage/fbda-rwx-test.yaml` (a storage smoke-test pod)

   `overlays/example/40-workloads/kustomization.yaml` and `overlays/example/20-events/kustomization.yaml`
   carry commented JSON6902 patches showing exactly where to pin `nvidia.com/gpu.product` in the
   workload specs and the Sensor's embedded RayJob template respectively.

2. **World size / GPU count must agree across the files that actually enforce it.** `NUM_WORKERS`
   (read by `train/train_qwen3_deepspeed.py` as the Ray Train world size) must match the
   worker-group `replicas` count in the same manifest, and — for the standing Sensor path —
   must match the Sensor's own `NUM_WORKERS`:
   - `base/40-workloads/rayjob-train-ephemeral.yaml`: `NUM_WORKERS: "4"`, `replicas: 4` — deliberately
     4, different from the Sensor's 8; the file's own header explains why and warns that running at
     world size 4 against an 8-way-sharded checkpoint silently loads a partial model (no error).
   - `base/40-workloads/rayjob-eval-v8.yaml`: `NUM_WORKERS: "8"`, `replicas: 8`.
   - `base/40-workloads/rayjob-resume-v5.yaml`: `NUM_WORKERS: "8"`, `replicas: 8`.
   - `base/20-events/s3-eventsource-sensor.yaml`: the embedded RayJob template's `NUM_WORKERS` (8)
     and its worker-group `replicas` (8) must move together with the two files above.
   - `rayjob-train-ephemeral.yaml`'s header states directly that agreement between `minReplicas`,
     `maxReplicas`, `replicas`, and `NUM_WORKERS` is a **manual invariant, not machine-checked** —
     no `policy/` directory exists anywhere in this published tree to enforce it.
   - `train/train_qwen3_deepspeed.py` reads `NUM_WORKERS` only via
     `ScalingConfig(num_workers=int(os.environ.get("NUM_WORKERS", "4")))` — it does not itself
     cross-check against the checkpoint's actual shard count. A ZeRO-3 checkpoint is sharded per
     rank, so loading it at the wrong world size loads a partial model with no error —
     `ENVIRONMENT-CONTRACT.md` covers this in more depth. Every checkpoint this pipeline produces
     today is world size 8.

3. **The training source and its ConfigMap must move together.** `train/train_qwen3_deepspeed.py`
   is baked into `base/30-pipeline/train-code-configmap.yaml` as literal `data:`. Nothing generates
   this automatically at apply time — if you edit the `.py` file, the ConfigMap goes stale until
   you regenerate it. `make validate-train-configmap` (see `Makefile`) diffs the two and tells you
   exactly the regeneration command to run (`kubectl create configmap ... --dry-run=client -o yaml`),
   plus a reminder to restore the file's header comment lines afterward.

4. **`/dev/shm` sizing appears in five manifests and must match if you change it.** All currently
   ship `medium: Memory, sizeLimit: 4Gi`:
   - `base/40-workloads/raycluster-fbda-checkpoint.yaml`
   - `base/40-workloads/rayjob-train-ephemeral.yaml`
   - `base/40-workloads/rayjob-resume-v5.yaml`
   - `base/40-workloads/rayjob-eval-v8.yaml`
   - `base/20-events/s3-eventsource-sensor.yaml` (the embedded RayJob template)

   (Separately, `s3-eventsource-sensor.yaml` also sets a `ray-tmp` `emptyDir` `sizeLimit: 30Gi`,
   sized for the ~8.8 GB `runtimeEnvYAML` pip install per the file's own comment — a different
   volume, not to be confused with `/dev/shm`.)

5. **Seed/determinism caveat** — see "Fine-tuning method and reproducibility" above. If you add
   shuffling or dropout, add an explicit seed yourself; the checkpoint-resume path resets
   `step`/`idx` to 0 regardless.

## Validating before touching a live cluster

Per `Makefile` (there is no CI — nothing runs these for you):

```bash
make preflight                       # read-only: does THIS cluster satisfy the contract?
make validate                        # every phase of OVERLAY renders + schema-validates (built-in kinds only; CRD kinds are skipped, count shown)
make render PHASE=30-pipeline        # print one rendered phase without applying
make validate-train-configmap        # training source vs. its ConfigMap, see trap 3 above
make check-alerts                    # every shipped alert's metric names are real, against a live cluster
make apply-phase PHASE=<phase>       # the ONLY target that writes to a cluster
```

`./preflight.sh -n <namespace>` is the same check `make preflight` runs; it is entirely read-only
(one opt-in exception: `--probe-file-count` starts a short-lived pod). It checks platform version,
9 required CRDs, GPU node labels/allocatable count, StorageClass reclaim policy, Secret existence
and keys (names/keys only, never values), Kueue quota and admission status, and known trap
conditions (fsGroup recursive-chown exposure, placeholder ServiceMonitor endpoints, placeholder S3
bucket names, inode-metric misuse on FlashBlade NFS). Per its own header: **quota below the floor
does not error, it hangs** — a run that looks stuck with no events is usually this.

`OVERLAY` defaults to `overlays/example`; copy it (`cp -r overlays/example overlays/mine`) before
editing, per the README's "Minimum configuration" section.

## Support

This repo has a `Support` section in `README.md` — read it there rather than here. Short version:
community-supported reference architecture, not a product; no SLA; open an issue;
**pull requests cannot be merged directly** (this repository is a one-way mirror) — see
`CONTRIBUTING.md`.
