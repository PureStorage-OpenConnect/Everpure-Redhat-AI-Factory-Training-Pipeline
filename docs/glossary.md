# Glossary

Terms used across this repo that come from GPU and AI/ML infrastructure, not from Kubernetes
itself. Each definition is written for how the term is actually used here, not as a general
textbook definition. Kubernetes/OpenShift basics (Pod, Secret, Operator, CRD, StorageClass, CSI)
are assumed knowledge and not included.

## Model and training concepts

- **Fine-tuning** — continuing to train an already-trained ("pretrained") model on your own data,
  instead of training a model from nothing. This whole pipeline exists to fine-tune one base model,
  `Qwen/Qwen3-32B`.
- **SFT (Supervised Fine-Tuning)** — fine-tuning on labeled input/output examples, as opposed to
  further pretraining on raw unlabeled text. A more realistic SFT recipe than this pipeline's
  validated run — a larger dataset, shuffling, dropout — is the kind of change that would need an
  explicit random seed added, since none is wired in today (see "Reproducibility / determinism").
- **Full-parameter fine-tuning** — the fine-tuning method used here: every trainable weight of the
  base model is updated, under DeepSpeed ZeRO-3 with both optimizer state and parameters offloaded
  to CPU. This, not a small adapter, is why the checkpoint and the optimizer state are so large —
  see "Optimizer state" below.
- **LoRA (Low-Rank Adaptation)** — a fine-tuning method **not used by this pipeline**, defined here
  because readers may expect it. LoRA trains a small set of additional weights instead of every
  weight in the model, which is why it needs far less GPU memory than the full-parameter fine-tuning
  this pipeline actually does.
- **Checkpoint** — a saved snapshot of the model's weights and the optimizer's internal state,
  written to shared storage during and after training so a run can be resumed, evaluated, or rolled
  back to.
- **Loss** — the number training tries to minimize at every step; it measures how wrong the model's
  predictions are. A falling loss curve is the basic evidence that training is working.
- **Step** — one training iteration. The validated run does 60 steps.
- **Global step** — the step number recorded inside a checkpoint. Resuming a checkpoint continues
  counting from this number rather than restarting at zero.
- **Micro-batch size** — how many examples one GPU processes at once, per step. It is 1 in this
  pipeline, which is why the evaluation step (see "held-out evaluation") runs slower than it
  should — see [docs/results.md](results.md).
- **Held-out data / held-out evaluation** — data the model never saw during training, used
  afterward to check how well it generalizes. This pipeline's eval gate is decided on a held-out
  evaluation score.
- **Perplexity** — the eval-gate metric used here. It is `exp(cross-entropy loss)`: a number
  measuring how surprised the model is by the correct next word in text it has not seen before.
  **Lower is better.** See [docs/results.md](results.md) for why this repo's perplexity number is
  not directly comparable to a perplexity you might see published elsewhere.
- **Cross-entropy loss** — the underlying measurement perplexity is calculated from.
- **World size** — the number of GPUs (training processes) a run uses — 8, in the validated
  configuration. This number matters a great deal: a checkpoint saved at one world size cannot
  simply be resumed at a different one. See [contract §3.3](../ENVIRONMENT-CONTRACT.md#33-snapshot-behaviour-you-must-design-around).
- **Rank** — one training process, one per GPU. Rank 0 is the process that does bookkeeping work
  the others do not, such as uploading the finished checkpoint.
- **Shard / sharding** — splitting a large piece of data (in this pipeline, the checkpoint) into
  several smaller pieces, one per rank, instead of holding the whole thing in one place.
- **Optimizer state** — extra numbers the training algorithm keeps per model weight, beyond the
  weight itself. This is why a full checkpoint is much bigger than the model alone — see the
  Capacity section of [contract §3](../ENVIRONMENT-CONTRACT.md#3-storage).
- **Reproducibility / determinism** — running the same training job again, with the same data and
  step count, and getting the exact same final loss value. No random seed is set anywhere in this
  pipeline's training code; the training loop has no randomness to seed — a fixed, unshuffled data
  walk over pretrained weights with no new random initialization. This repo tracks the resulting
  loss value as its main correctness signal.

## Distributed training frameworks

- **Ray** — the distributed-computing framework this pipeline uses to run training across multiple
  GPUs and machines as one job.
- **RayJob** — the Kubernetes object representing one Ray job — training, evaluation, or resume.
- **RayCluster** — the set of Ray pods (one head, one worker per GPU) that runs a Ray job. Most
  RayJobs here create their own RayCluster for the duration of the job and remove it when the job
  ends, but `base/40-workloads/raycluster-fbda-checkpoint.yaml` ships a **standing** RayCluster that
  nothing tears down — it holds its GPU quota indefinitely, which is why phase `40-workloads` is
  opt-in.
- **KubeRay** — the Kubernetes operator that provides the RayJob and RayCluster objects to the
  cluster. It ships as part of OpenShift AI.
- **DeepSpeed** — the training-optimization library that does the actual fine-tuning work in this
  pipeline.
- **ZeRO-3** — short for "Zero Redundancy Optimizer, stage 3," a DeepSpeed feature that splits
  (shards) a model's weights and optimizer state across every GPU in a run, instead of keeping a
  full copy on each one. This is why a checkpoint here is many separate shard files, not one file.
- **NCCL** — the library GPUs use to talk to each other during distributed training. A GPU "stuck
  in an NCCL wait" can show 100% utilization while doing no useful work — see
  [docs/what-to-expect.md](what-to-expect.md).
- **Checkpoint barrier** — the point in training where every GPU pauses and waits while the sharded
  checkpoint is written to storage. This pipeline treats the length of that pause as its key
  storage-performance measurement.
- **`zero_to_fp32.py`** — a script DeepSpeed includes inside every ZeRO-3 checkpoint that combines
  all the shards back into one plain model file.

## GPU and hardware

- **GPU framebuffer** — a GPU's own memory. Watching framebuffer usage climb is one way to tell a
  job is actually loading the model, rather than stuck.
- **GPU utilization (`GPU_UTIL`)** — the standard metric for "is this GPU doing work." This repo
  specifically warns that it can read 100% even while a GPU is idle and waiting (see NCCL, above),
  so it is not enough on its own to confirm a GPU is being useful.
- **DCGM (Data Center GPU Manager)** — NVIDIA's tool for reporting GPU health and usage metrics
  (utilization, memory, power, temperature). The NVIDIA GPU Operator installs it, and this pipeline
  ships a console dashboard built on it.
- **CUDA** — NVIDIA's platform for running general-purpose code on a GPU. "CUDA-capable" describes
  any GPU that can run it.
- **NVIDIA GPU Operator** — the operator that installs GPU drivers, the Kubernetes device plugin,
  and DCGM onto GPU nodes. This pipeline requires it but does not install it.
- **Node Feature Discovery (NFD)** — the operator that labels a node with hardware facts, including
  `nvidia.com/gpu.present`, which this pipeline's default GPU selection depends on.
- **VRAM** — a GPU's own memory capacity. The floor for this pipeline is "enough VRAM for
  full-parameter fine-tuning of a 32B-parameter model under ZeRO-3 with full CPU offload," tested
  on NVIDIA L40S GPUs.

## ML infrastructure and orchestration

- **Kueue** — the system that decides when a job is actually allowed to start using GPUs, based on
  a quota. A job that asks for more than the available quota does not fail — it waits, silently,
  forever, with no pod created and no error. See [docs/troubleshooting.md](troubleshooting.md).
- **ClusterQueue** — the cluster-wide object holding the GPU/CPU/memory quota a job must fit
  inside to be admitted by Kueue.
- **ResourceFlavor** — the Kueue object that names which nodes count toward a ClusterQueue's quota.
  On a cluster with more than one GPU model, this is where you restrict a job to a specific one.
- **LocalQueue** — the namespace-scoped Kueue object a workload actually submits to
  (`base/30-pipeline/localqueue.yaml`); it forwards admission to a cluster-wide `ClusterQueue`. If a
  workload lands in a namespace with no `LocalQueue`, Kueue finds nothing to admit against and
  suspends the job — silently, with the object still reported as created.
- **MLflow** — the tool this pipeline uses to record every run (training, resume, evaluation) and
  its metrics, and to register a model once it passes the eval gate.
- **Model registry** — the part of MLflow that tracks named, versioned models. A model that passes
  the eval gate gets registered here.
- **Experiment / experiment tracking** — MLflow's way of grouping related runs together so they can
  be compared. Every run in this pipeline lands in one experiment.
- **Eval gate** — the pass/fail decision made after held-out evaluation: promote the model if its
  score clears a bar, or stop and alert if it does not.
- **Argo Events (EventBus, EventSource, Sensor)** — the components that turn a new file landing in
  an S3 bucket into a running training job, with no person clicking anything in between.
- **Model staging** — the one-time job that downloads the base model and dataset onto shared
  storage before any training run can use them.

## Storage

- **RWX (ReadWriteMany)** — a volume access mode letting many pods mount and write to the same
  volume at once. This pipeline depends on it: every training-worker pod writes its shard of the
  same checkpoint to one shared RWX volume, which only an NFS-backed StorageClass can provide. It
  is the single most-used storage term in this repo's docs.
- **RWO (ReadWriteOnce)** — a volume access mode allowing only one node to mount the volume for
  writing at a time. Used here for Prometheus's own storage — the `volumeClaimTemplate` in
  `base/00-platform/cluster-monitoring-config.yaml` — where nothing needs to share the volume
  across pods. (The MLflow tracking store, by contrast, is RWX — see above — because it too can be
  reached by more than one pod.)
- **KVDB** — Portworx's internal key-value metadata store (its cluster state and quorum). This
  pipeline runs Portworx in **CSI-only mode**, which removes the storage data plane and, with it,
  the local-block-device KVDB requirement of a full Portworx Enterprise install — see
  [contract §2](../ENVIRONMENT-CONTRACT.md#2-operators-and-crds--install-these-first).
- **Purity//FB** — the operating software FlashBlade runs, versioned independently of Portworx.
  FlashBlade's S3 service is a native Purity//FB feature that Portworx does not proxy; the two are
  compatible at specific version pairs — check the Portworx support matrix before upgrading either.
- **Per-run residue** — the small amount of data (session logs, NCCL flight-recorder dumps) each
  training run leaves behind on the shared RWX volume after its checkpoint is reclaimed. Measured
  at roughly 140 MB for a full 9-pod run — three orders of magnitude below one 366 GiB checkpoint —
  so it is not a meaningful factor when sizing the volume; size for the checkpoint and margin
  instead.

## Repo-specific terms

- **FBDA (FlashBlade Direct Access)** — the specific storage mode this pipeline's checkpoint and
  dataset storage depends on. The name persists as a naming convention inside the manifests
  themselves: resource names like `fbda-shared` and `fbda-ckpt-v9`, labels, and so on. This
  repository is published as `everpure-openshift-ai-training-pipeline`.
- **SafeMode** — FlashBlade's write-once, tamper-resistant storage mode (versioning plus object
  lock). This pipeline uses it to protect the record of which model version was promoted and why.
- **`KEEP_LOCAL_CKPT`** — a setting on the training job that keeps a checkpoint on shared storage
  after upload, instead of deleting the local copy. Needed before an evaluation or resume job can
  read that checkpoint directly.
- **`RESUME_FROM`** — the setting on an evaluation or resume job naming which training run's
  checkpoint to load.
