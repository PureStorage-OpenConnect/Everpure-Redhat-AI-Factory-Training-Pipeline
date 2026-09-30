import io
import json
import math
import os
import shutil
import time

import boto3
import deepspeed
import ray
import ray.train
import torch
from botocore.client import Config
from ray.train import RunConfig, ScalingConfig
from ray.train.torch import TorchTrainer

# Run telemetry.
#
# Every RayJob manifest in this tree sets `RAY_enable_open_telemetry: "false"`. Ray 2.52 (the
# version this pipeline pins) switched its metrics backend to OpenTelemetry by default. This
# cluster's KubeRay operator injects RAY_USE_TLS on every Ray pod (a create-cert init
# container), and the OTEL exporter does not pick up those TLS credentials when reaching the
# dashboard agent's now-TLS gRPC server (see https://github.com/ray-project/ray/issues/59968).
# With OpenTelemetry disabled, Ray falls back to its legacy metrics backend, which has no such
# TLS dependency, and a GPU worker pod's /metrics endpoint exports `ray_*` series — including
# the custom `ray_training_*` gauges below — instead of none.
#
# A worker pod exporting `ray_*` series is not sufficient on its own for Prometheus to scrape
# them. Two more pieces are required: base/30-pipeline/podmonitor-ray-metrics.yaml selects Ray
# pods by the `ray.io/cluster` label and the `metrics` container port, and
# base/30-pipeline/networkpolicy-ray-metrics-scrape.yaml grants the ingress that KubeRay's own
# per-RayCluster NetworkPolicy does not (it admits only openshift-monitoring, not
# openshift-user-workload-monitoring). Both the PodMonitor and the NetworkPolicy must exist for
# these metrics to reach Prometheus.
#
# TRAINING_DEADLINE_EPOCH (see the note near its definition below) supplies the UNIX epoch
# second at which this run's activeDeadlineSeconds expires. No manifest in this tree sets it,
# so `training_deadline_timestamp` is not exported unless one does.
#
# The per-step loss also goes to STDOUT (see the training loop). That path needs none of this
# machinery, and it is the signal that survives Prometheus, MLflow, and the tracking server all
# being down at once.
#
# Two facts control what this file exports:
#
#   * ray.train.report() metrics do not reach Prometheus. They go to Ray Train's result object
#     and the dashboard only. ray.util.metrics is the only API here whose values reach the Ray
#     metrics endpoint (as `ray_<name>`) at all. Reaching that endpoint does not guarantee
#     Prometheus scrapes it — see above.
#   * Every metric here is recorded on rank 0 only. Ray tags each series with
#     WorkerId/NodeAddress, so the same gauge set on 8 ranks becomes 8 series. Any sum() over
#     them reads world_size times the true value — for example, 480 steps for a 60-step run.
#
# The import below is inside a try/except. Telemetry must never stop a run from starting. An
# older or trimmed Ray build without ray.util.metrics disables metrics, not the whole run.
try:
    from ray.util.metrics import Counter, Gauge
except ImportError:  # pragma: no cover - depends on the runtime image's Ray build
    Counter = None
    Gauge = None

BUCKET = os.environ.get("S3_DATA_BUCKET", "my-models")
MODEL_PREFIX = "base-models/qwen3-32b"
DATASET_KEY = "datasets/nemotron-agentic-v1/data/interactive_agent.jsonl"
# RUN_ID names the checkpoint directory and the S3 prefix. A wrong but plausible value makes
# two runs silently overwrite each other: a run destroys its predecessor's checkpoint, and
# nothing reports it. This code rejects two silent failure cases instead of allowing them:
#
#   - An empty string. The downward API returns an empty string, not an error, when the
#     referenced label is missing. os.environ.get() then returns "" instead of the default.
#     Every run then gets the same shared path (/mnt/fbda/ckpt-) and prefix (checkpoints/).
#   - "PLACEHOLDER". A manifest templating value that a manifest did not substitute.
#
# Both cases share one path across runs. Fail at import time, before 8 GPUs spend two hours
# writing a checkpoint to the wrong place.
_run_id = os.environ.get("RUN_ID", "smoke-001")
if not _run_id.strip() or _run_id == "PLACEHOLDER":
    raise SystemExit(
        f"RUN_ID is {_run_id!r} — it was not substituted. Refusing to run: this value is shared "
        "by every run, so the checkpoint would overwrite another run's. Check that the pod label "
        "referenced by the RUN_ID downward-API fieldRef actually exists on the pod."
    )
RUN_ID = _run_id
CHECKPOINT_PREFIX = f"checkpoints/{RUN_ID}"
# An explicit CKPT_DIR overrides the RUN_ID-derived path. The worker container also has
# `envFrom: pipeline-config`. Do not add a CKPT_DIR key to that ConfigMap — it would silently
# point every run at the same directory again.
CKPT_DIR = os.environ.get("CKPT_DIR", f"/mnt/fbda/ckpt-{RUN_ID}")
LOCAL_MODEL_DIR = "/tmp/qwen3-32b"
MAX_STEPS = int(os.environ.get("MAX_STEPS", "60"))
MAX_SEQ_LEN = 128
NUM_SAMPLES = 256
# RESUME_FROM points at a DeepSpeed checkpoint directory (the one holding `latest`). If set, the
# engine loads the model and optimizer shards and restores global_steps. Training then continues
# from the saved step instead of step 0. Empty by default, so normal runs from scratch are
# unchanged. SKIP_SAVE lets a resume test skip rewriting the checkpoint (about 393 GB).
RESUME_FROM = os.environ.get("RESUME_FROM", "")
SKIP_SAVE = os.environ.get("SKIP_SAVE", "0") == "1"
# EVAL_ONLY runs a forward-only pass over a held-out data slice instead of training. It writes a
# real perplexity value to eval-report.json and to MLflow. It makes no promote-or-fail decision
# itself. That decision is a separate step with no GPU need
# (base/50-stages/eval-gate-job.yaml), so you can test the fail path without a GPU run.
# Use RESUME_FROM together with EVAL_ONLY to evaluate a trained checkpoint.
EVAL_ONLY = os.environ.get("EVAL_ONLY", "0") == "1"
EVAL_SAMPLES = int(os.environ.get("EVAL_SAMPLES", "64"))
EVAL_REPORT_PATH = os.environ.get("EVAL_REPORT_PATH", "/mnt/fbda/eval-report.json")

# WARNING: an eval without a checkpoint is not a real eval. This guard exists for the same
# reason as the RUN_ID check above: without it, EVAL_ONLY with no RESUME_FROM runs the forward
# pass against the untrained base model and writes a plausible-looking perplexity to the report
# and to MLflow. The eval gate (base/50-stages/eval-gate-job.yaml) does read `global_step` and
# `resume_from` as well as `perplexity`, and correctly marks a report like this INCONCLUSIVE
# rather than promoting it — but the report should never be created in the first place — by the
# time the gate sees it, eight GPUs have already spent an hour measuring the base model.
#
# The check below also rejects the shipped placeholder value. The file
# base/40-workloads/rayjob-eval-v8.yaml ships RESUME_FROM as a placeholder that a manifest must
# substitute, because the checkpoint directory comes from RUN_ID and no fixed value is correct.
# Without this check, an unsubstituted value would fail later, at load_checkpoint, after the
# cluster has formed and the model has downloaded.
if EVAL_ONLY:
    _resume = RESUME_FROM.strip()
    if not _resume:
        raise SystemExit(
            "EVAL_ONLY=1 with no RESUME_FROM. This would evaluate the UNTRAINED base model and emit "
            "a real-looking perplexity for it. Set RESUME_FROM to the checkpoint directory being "
            "evaluated — /mnt/fbda/ckpt-"
            "<RUN_ID> if the run kept its local copy with KEEP_LOCAL_CKPT=1."
        )
    if "SUBSTITUTE" in _resume.upper() or "PLACEHOLDER" in _resume.upper():
        raise SystemExit(
            f"RESUME_FROM is {_resume!r} — the shipped placeholder, not substituted. Refusing to "
            "run: there is no correct fixed checkpoint path, because the training code derives it "
            "per run from RUN_ID. See the header of base/40-workloads/rayjob-eval-v8.yaml for how "
            "to find the RUN_ID of the run you mean to evaluate."
        )

# Checkpoint integrity. Ray Train registers a checkpoint if one or more workers report one. It
# does not count shards. So 7 of 8 ranks uploading gives a checkpoint that looks valid but fails
# at load time, possibly days later. For DeepSpeed ZeRO-3 with world_size=8 in bf16, the correct
# shape is exactly 2 * world_size + 2 = 18 objects: one model-states shard and one optim-states
# shard per rank inside the tag directory, plus the top-level `latest` and `zero_to_fp32.py`.
CKPT_MODEL_SHARD_FMT = "zero_pp_rank_{rank}_mp_rank_00_model_states.pt"
CKPT_OPTIM_SHARD_FMT = "bf16_zero_pp_rank_{rank}_mp_rank_00_optim_states.pt"
CKPT_MANIFEST_NAME = "checkpoint-manifest.json"
# ZeRO-3 partitions parameters evenly, so shards of the same class stay within a fraction of a
# percent of each other in size. A rank that hit ENOSPC or a truncated write is off by much more.
CKPT_SIZE_TOLERANCE = 0.05

# Deadline telemetry. This value is UNIX epoch seconds — an absolute point in time, not a
# duration. The deadline that matters is the RayJob's activeDeadlineSeconds, measured from
# submission. The worker process starts minutes after that (placement-group formation took
# about 5 minutes in past runs). A relative value based on worker start would over-report the
# remaining margin by exactly the queueing delay — the same drift this metric is meant to catch.
#
# No manifest in this tree sets this value today. So on every run, this is an empty string,
# _deadline_epoch() returns None, and `training_deadline_timestamp` is never exported. The code
# is correct; the input is missing.
#
# Whoever supplies this value must compute an absolute epoch at submission time. A Sensor
# trigger can compute one. An entrypoint wrapper can derive one from the RayJob's
# creationTimestamp plus activeDeadlineSeconds. Do not derive it inside this process from
# time() plus the deadline — that re-bases on worker start and reports back exactly the
# queueing delay this metric exists to measure.
TRAINING_DEADLINE_EPOCH = os.environ.get("TRAINING_DEADLINE_EPOCH", "")

# Rank 0 logs parameters and per-step loss to MLflow, so you can track the run live and check
# it later. This is optional. If MLFLOW_TRACKING_URI is unset or the server is unreachable,
# training continues unaffected — telemetry must never break training.
MLFLOW_TRACKING_URI = os.environ.get("MLFLOW_TRACKING_URI")
MLFLOW_EXPERIMENT = os.environ.get("MLFLOW_EXPERIMENT", "qwen3-fbda")

DS_CONFIG = {
    "train_micro_batch_size_per_gpu": 1,
    "gradient_accumulation_steps": 4,
    "gradient_clipping": 1.0,
    "bf16": {"enabled": True},
    # Without an explicit optimizer, deepspeed.initialize() has nothing to wrap in
    # DeepSpeedZeroOptimizer_Stage3, the object that installs the backward-time
    # gather/reduce/release hooks. zero.Init() during from_pretrained() still installs
    # forward hooks unconditionally. That is why forward stays lean (about 3 GB across
    # all 64 layers) while backward pulls in the full unsharded model (about 44 GB) without
    # this: nothing releases parameters after use.
    # torch_adam=True skips DeepSpeedCPUAdam's JIT-compiled C++/CUDA extension. That
    # extension failed to build here, because the installed CUDA toolkit is 12.8 but
    # torch was compiled against CUDA 13.0. Instead, this uses the pure-PyTorch AdamW
    # fallback on the offloaded CPU parameter shards.
    "optimizer": {
        "type": "AdamW",
        "params": {"lr": 1e-5, "betas": [0.9, 0.999], "eps": 1e-8, "weight_decay": 0.0, "torch_adam": True},
    },
    "zero_optimization": {
        "stage": 3,
        "offload_optimizer": {"device": "cpu", "pin_memory": True},
        "offload_param": {"device": "cpu", "pin_memory": True},
        "overlap_comm": True,
        "contiguous_gradients": True,
        "reduce_bucket_size": 5e7,
        "stage3_prefetch_bucket_size": 5e7,
        "stage3_param_persistence_threshold": 1e5,
        "stage3_max_live_parameters": 5e7,
        "stage3_max_reuse_distance": 0,
    },
    "activation_checkpointing": {
        "partition_activations": True,
        "cpu_checkpointing": False,
        "contiguous_memory_optimization": False,
    },
    # tag_validation controls what DeepSpeed does when ranks do not agree on the tag they just
    # wrote (each rank all-gathers its tag and compares). The default, "Warn", prints a message
    # and continues. A partial save then still gets a `latest` pointer and reads as a good
    # checkpoint — the same class of defect as Ray registering a checkpoint when only one worker
    # reports one. "Fail" raises an error at save time, next to the cause, instead of at load
    # time days later.
    "checkpoint": {"tag_validation": "Fail"},
    "steps_per_print": 1,
    "wall_clock_breakdown": False,
}


def s3_client():
    return boto3.client(
        "s3",
        endpoint_url=os.environ["S3_ENDPOINT"],
        aws_access_key_id=os.environ["AWS_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["AWS_SECRET_ACCESS_KEY"],
        # WARNING: TLS verification is disabled here. The storage array this pipeline was
        # validated against uses a self-signed certificate. This is not a recommendation.
        # Supply a CA bundle instead.
        verify=False,
        config=Config(
            signature_version="s3v4",
            request_checksum_calculation="when_required",
            response_checksum_validation="when_required",
        ),
    )


def download_model(local_dir):
    marker = os.path.join(local_dir, ".download_complete")
    if os.path.exists(marker):
        return
    os.makedirs(local_dir, exist_ok=True)
    s3 = s3_client()
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=BUCKET, Prefix=MODEL_PREFIX + "/"):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            rel = os.path.relpath(key, MODEL_PREFIX)
            dest = os.path.join(local_dir, rel)
            if os.path.exists(dest) and os.path.getsize(dest) == obj["Size"]:
                continue
            print(f"[rank download] {key} -> {dest}", flush=True)
            s3.download_file(BUCKET, key, dest)
    with open(marker, "w") as f:
        f.write("ok")


def load_training_samples(tokenizer, n=NUM_SAMPLES, skip=0):
    # skip>0 gives a held-out slice. The eval gate reads samples after the training window, so
    # it measures perplexity on data the run did not train on.
    s3 = s3_client()
    obj = s3.get_object(Bucket=BUCKET, Key=DATASET_KEY)
    lines = []
    seen = 0
    for line in io.TextIOWrapper(obj["Body"], encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        seen += 1
        if seen <= skip:
            continue
        lines.append(line)
        if len(lines) >= n:
            break
    texts = []
    for line in lines:
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        text = rec.get("text") or rec.get("conversations") or json.dumps(rec)
        if not isinstance(text, str):
            text = json.dumps(text)
        texts.append(text)
    enc = tokenizer(
        texts,
        truncation=True,
        max_length=MAX_SEQ_LEN,
        padding="max_length",
        return_tensors="pt",
    )
    return enc["input_ids"], enc["attention_mask"]


def _init_mlflow():
    # Rank 0 only. Returns the mlflow module with an active run, or None. Every failure path
    # returns None, so a missing or unreachable tracking server never stops training.
    if not MLFLOW_TRACKING_URI:
        return None
    try:
        import mlflow

        mlflow.set_tracking_uri(MLFLOW_TRACKING_URI)
        mlflow.set_experiment(MLFLOW_EXPERIMENT)
        mlflow.start_run(run_name=RUN_ID)
        mlflow.log_params(
            {
                "run_id": RUN_ID,
                "base_model": MODEL_PREFIX,
                "dataset_key": DATASET_KEY,
                "max_steps": MAX_STEPS,
                "max_seq_len": MAX_SEQ_LEN,
                "num_samples": NUM_SAMPLES,
                "zero_stage": DS_CONFIG["zero_optimization"]["stage"],
                "micro_batch_per_gpu": DS_CONFIG["train_micro_batch_size_per_gpu"],
                "grad_accum": DS_CONFIG["gradient_accumulation_steps"],
                "lr": DS_CONFIG["optimizer"]["params"]["lr"],
                "num_workers": int(os.environ.get("NUM_WORKERS", "4")),
            }
        )
        print(f"[mlflow] tracking to {MLFLOW_TRACKING_URI} experiment={MLFLOW_EXPERIMENT} run={RUN_ID}", flush=True)
        return mlflow
    except Exception as e:  # noqa: BLE001
        print(f"[mlflow] disabled (init failed: {e})", flush=True)
        return None


def _deadline_epoch():
    # Returns float epoch seconds, or None. A malformed value is reported and dropped, not
    # raised as an error. A typo in a manifest env var must not cost an 8-GPU run.
    raw = TRAINING_DEADLINE_EPOCH.strip()
    if not raw:
        return None
    try:
        return float(raw)
    except ValueError:
        print(f"[metrics] TRAINING_DEADLINE_EPOCH={raw!r} is not a number — deadline gauge not exported", flush=True)
        return None


def _init_run_metrics():
    # Rank 0 only. See the import comment above: these are per-worker series, and summing them
    # multiplies by world_size. Returns a dict of ray.util.metrics instruments, or None if
    # unavailable.
    if Gauge is None or Counter is None:
        print("[metrics] ray.util.metrics unavailable — run telemetry disabled", flush=True)
        return None
    try:
        tag_keys = ("run_id",)
        tags = {"run_id": RUN_ID}
        metrics = {
            "global_step": Gauge(
                "training_global_step",
                description="DeepSpeed engine.global_steps on rank 0. Flat while pods are Running = hang signature.",
                tag_keys=tag_keys,
            ),
            "total_steps": Gauge(
                "training_total_steps",
                description=(
                    "Optimizer steps this run intends to execute (MAX_STEPS / "
                    "gradient_accumulation_steps). Denominator for progress against "
                    "global_step: global_step tracks engine.global_steps, DeepSpeed's "
                    "optimizer-step counter, which advances once per "
                    "gradient_accumulation_steps micro-batches. This gauge is pre-divided "
                    "by that same factor so global_step / total_steps reaches 1.0 at "
                    "completion. (training_steps_completed_total instead counts raw "
                    "micro-batches, so it does not share these units with either gauge.)"
                ),
                tag_keys=tag_keys,
            ),
            "steps_completed": Counter(
                "training_steps_completed",
                description="Monotonic completed-step count on rank 0. rate() over it is the step rate.",
                tag_keys=tag_keys,
            ),
            "deadline_timestamp": Gauge(
                "training_deadline_timestamp",
                description="UNIX epoch at which this run's activeDeadlineSeconds expires; margin = this - time().",
                tag_keys=tag_keys,
            ),
        }
        # global_step (recorded via engine.global_steps in _record_step) is DeepSpeed's
        # optimizer-step counter, which advances once every gradient_accumulation_steps
        # micro-batches — it never reaches MAX_STEPS. Divide here so the two gauges share
        # units and global_step / total_steps reaches 1.0 at run completion.
        metrics["total_steps"].set(
            float(MAX_STEPS) / DS_CONFIG["gradient_accumulation_steps"], tags=tags
        )
        deadline = _deadline_epoch()
        if deadline is not None:
            metrics["deadline_timestamp"].set(deadline, tags=tags)
        print(f"[metrics] ray.util.metrics enabled (run_id={RUN_ID}, deadline={deadline})", flush=True)
        return metrics
    except Exception as e:  # noqa: BLE001
        print(f"[metrics] disabled (init failed: {e})", flush=True)
        return None


# Set once, read once. Keeps _record_step's logging to one line per outcome per run, instead of
# one line per step. A line per step would bury the run's real output.
_METRICS_STATE = {"failed": False, "first_ok": False}


def _record_step(metrics, global_step):
    # Best-effort by design. An unreachable metrics agent must not stop training.
    #
    # Best-effort must not mean silent. An exception swallowed with no message looks exactly
    # like success: _init_run_metrics() can print "ray.util.metrics enabled" and build the
    # gauges, and set() can run every step, while the values reach nothing. Log the failure
    # instead of passing silently, so telemetry that is not actually landing is distinguishable
    # from telemetry that is.
    try:
        tags = {"run_id": RUN_ID}
        metrics["global_step"].set(float(global_step), tags=tags)
        metrics["steps_completed"].inc(1, tags=tags)
    except Exception as e:  # noqa: BLE001
        if not _METRICS_STATE["failed"]:
            _METRICS_STATE["failed"] = True
            print(
                f"[metrics] WARNING: step recording failed — {type(e).__name__}: {e}. "
                "Training continues; run telemetry will be incomplete. "
                "This message appears once per run.",
                flush=True,
            )
    else:
        if not _METRICS_STATE["first_ok"]:
            _METRICS_STATE["first_ok"] = True
            # This is a narrow claim on purpose. It proves the ray.util.metrics API call
            # returned, and nothing more. It does not prove the series reached a scrapeable
            # endpoint: an API call can succeed on every invocation while no `ray_training_*`
            # series ever appears on any pod's metrics port. To check the endpoint itself, run:
            #   oc exec <rank-0 pod> -- curl -s localhost:8080/metrics | grep ray_training_
            print(
                f"[metrics] first step recorded without error (global_step={global_step}). "
                "This proves the API call only — verify ray_training_* on the pod's metrics port.",
                flush=True,
            )


def verify_checkpoint(ckpt_dir, world_size, step):
    """Rank-0 check of a just-written DeepSpeed ZeRO-3 checkpoint. Returns a manifest dict.

    This is the only durability check in the path, for two reasons:

      * NFS reports ENOSPC at close() or fsync(), not at write(). A save to a full volume can
        run to completion and report success. Each checkpoint is about 366 GiB (~393 GB) on
        an 800 GiB volume.
      * DeepSpeed's TorchCheckpointEngine.commit() just returns True. No code past this point
        checks that the bytes landed.

    No code before this point checks it either. Ray Train registers a checkpoint when any one
    worker reports one, without counting shards. So 7 of 8 shards look the same as 8 of 8, until
    you load the checkpoint.

    Raises RuntimeError listing every problem found. Call this before the S3 upload and before
    the local cleanup (rmtree). That way, a failed check:

      - never lets a partial checkpoint reach the bucket, where it would look complete enough
        for someone to try loading
      - leaves the local copy on the volume, so you can investigate it
    """
    latest_path = os.path.join(ckpt_dir, "latest")
    if not os.path.isfile(latest_path):
        raise RuntimeError(
            f"checkpoint verification FAILED: {latest_path} missing — save_checkpoint() returned but "
            "wrote no 'latest' pointer, so nothing can ever load this directory."
        )
    with open(latest_path) as f:
        tag = f.read().strip()
    if not tag:
        raise RuntimeError(f"checkpoint verification FAILED: {latest_path} is empty")
    tag_dir = os.path.join(ckpt_dir, tag)
    if not os.path.isdir(tag_dir):
        raise RuntimeError(
            f"checkpoint verification FAILED: 'latest' names tag {tag!r} but {tag_dir} does not exist"
        )

    problems = []
    for label, fmt in (("model_states", CKPT_MODEL_SHARD_FMT), ("optim_states", CKPT_OPTIM_SHARD_FMT)):
        sizes = {}
        for r in range(world_size):
            path = os.path.join(tag_dir, fmt.format(rank=r))
            if os.path.isfile(path):
                sizes[r] = os.path.getsize(path)
        missing = [r for r in range(world_size) if r not in sizes]
        if missing:
            problems.append(
                f"{label}: {len(sizes)} of {world_size} shards present in {tag}/ — missing ranks {missing}. "
                "Ray does not count shards, so this would have been recorded as a successful save and "
                "then failed at load, possibly days from now."
            )
            continue
        empty = sorted(r for r, b in sizes.items() if b == 0)
        smallest, largest = min(sizes.values()), max(sizes.values())
        if empty:
            problems.append(f"{label}: ranks {empty} wrote a 0-byte shard")
        elif (largest - smallest) / largest > CKPT_SIZE_TOLERANCE:
            problems.append(
                f"{label}: shard sizes disagree by more than {CKPT_SIZE_TOLERANCE:.0%} "
                f"(smallest={smallest} largest={largest}, per rank {dict(sorted(sizes.items()))}). "
                "ZeRO-3 partitions evenly, so a short shard is a truncated or ENOSPC-killed write."
            )

    if not os.path.isfile(os.path.join(ckpt_dir, "zero_to_fp32.py")):
        problems.append(
            f"top-level zero_to_fp32.py missing from {ckpt_dir} — the checkpoint cannot be consolidated"
        )

    inventory = []
    for root, _, names in os.walk(ckpt_dir):
        for name in names:
            if name == CKPT_MANIFEST_NAME:
                continue
            path = os.path.join(root, name)
            inventory.append({"name": os.path.relpath(path, ckpt_dir), "bytes": os.path.getsize(path)})
    inventory.sort(key=lambda entry: entry["name"])

    if problems:
        raise RuntimeError(
            f"checkpoint verification FAILED for {ckpt_dir} (tag={tag}, world_size={world_size}):\n  - "
            + "\n  - ".join(problems)
        )

    expected_objects = 2 * world_size + 2
    if len(inventory) != expected_objects:
        # This is a warning, not a failure. The checks above already proved every shard is
        # present and whole. An unexpected extra file — for example, a future DeepSpeed release
        # adding one — must not throw away two hours of 8-GPU time. But it does mean the
        # "exactly 18 objects" count that the downstream S3-side check relies on has changed,
        # and someone needs to know.
        print(
            f"[rank 0] WARNING checkpoint has {len(inventory)} objects, expected {expected_objects} "
            f"(2*world_size + 2). Shards all verified present; the object-count contract has drifted.",
            flush=True,
        )

    return {
        "run_id": RUN_ID,
        "step": step,
        "world_size": world_size,
        "tag": tag,
        "expected_objects": expected_objects,
        "object_count": len(inventory),
        "s3_prefix": f"s3://{BUCKET}/{CHECKPOINT_PREFIX}",
        "files": inventory,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }


def write_checkpoint_manifest(ckpt_dir, manifest):
    # Written and uploaded last, after every shard. Its presence, and nothing else, is the
    # completion signal. This makes a complete checkpoint identifiable, but no code in this repo
    # today refuses to load a checkpoint without a manifest. So the manifest is evidence, not a
    # gate, until a consumer checks for it. The fsync() call here is deliberate: it is the one
    # place that forces ENOSPC on this volume to surface as an exception. NFS raises ENOSPC at
    # fsync or close, never at write.
    path = os.path.join(ckpt_dir, CKPT_MANIFEST_NAME)
    with open(path, "w") as f:
        json.dump(manifest, f, indent=2)
        f.flush()
        os.fsync(f.fileno())
    return path


def train_loop_per_worker(config):
    from transformers import AutoModelForCausalLM, AutoTokenizer
    from transformers.integrations.deepspeed import HfDeepSpeedConfig

    rank = ray.train.get_context().get_world_rank()
    local_rank = ray.train.get_context().get_local_rank()

    # Ray Train already initializes torch.distributed. DeepSpeed tracks its own communicator
    # state separately. Without this call, zero.Init() below cannot see the real world_size and
    # silently skips parameter partitioning — each rank keeps a full replica of the model,
    # causing a GPU out-of-memory error at about 44 GB.
    deepspeed.init_distributed(dist_backend="nccl")

    if rank == 0:
        print(
            f"[diag] world_size={torch.distributed.get_world_size()} "
            f"ds_world_size={deepspeed.comm.get_world_size()}",
            flush=True,
        )

    download_model(LOCAL_MODEL_DIR)

    tokenizer = AutoTokenizer.from_pretrained(LOCAL_MODEL_DIR)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    dschf = HfDeepSpeedConfig(DS_CONFIG)  # noqa: F841  # this call turns on zero.Init for from_pretrained

    model = AutoModelForCausalLM.from_pretrained(
        LOCAL_MODEL_DIR,
        torch_dtype=torch.bfloat16,
    )
    # use_reentrant=True is Hugging Face's historical default. It runs a second forward pass
    # inside backward, through a custom autograd Function whose module hooks do not reliably
    # retrigger ZeRO-3's parameter-release logic. Gathered layers then pile up unreleased through
    # the whole backward pass, instead of being freed per layer, driving GPU memory to about
    # 44 GB even though forward stays under 5 GB.
    model.gradient_checkpointing_enable(gradient_checkpointing_kwargs={"use_reentrant": False})
    model.config.use_cache = False

    local_param_bytes = sum(p.data.numel() * p.data.element_size() for p in model.parameters())
    print(f"[diag rank={rank}] local resident param bytes = {local_param_bytes / 1e9:.2f} GB", flush=True)

    engine, _, _, _ = deepspeed.initialize(
        model=model,
        model_parameters=[p for p in model.parameters() if p.requires_grad],
        config=DS_CONFIG,
    )

    torch.cuda.synchronize()
    print(
        f"[diag rank={rank}] post-init GPU allocated = {torch.cuda.memory_allocated() / 1e9:.2f} GB, "
        f"reserved = {torch.cuda.memory_reserved() / 1e9:.2f} GB",
        flush=True,
    )

    # Resume: restore the model and ZeRO-3 optimizer shards from a snapshot-restored checkpoint.
    # This step is load-critical, not best-effort. If a resume was requested but no checkpoint is
    # found, this fails loudly instead of silently restarting at step 0. A silent restart would
    # falsely report the resume as successful.
    if RESUME_FROM:
        # Time this call. It is the longest interval in the job that this code cannot see inside
        # of — nothing inside engine.load_checkpoint() can be instrumented from here. A 366 GiB
        # (~393 GB) ZeRO-3 checkpoint read cold from flash takes about 80 seconds, out of about
        # 13 minutes between job start and the RESUMED line; the rest is the runtime_env pip
        # install. Printing the elapsed time tells you whether the read is slow or the
        # environment build is slow, without a separate measurement. Each problem needs a
        # different fix.
        print(f"[resume rank={rank}] load_checkpoint from {RESUME_FROM}", flush=True)
        _resume_t0 = time.time()
        load_path, _client_state = engine.load_checkpoint(RESUME_FROM)
        _resume_elapsed = time.time() - _resume_t0
        if load_path is None:
            raise RuntimeError(f"RESUME_FROM={RESUME_FROM} set but no loadable checkpoint (missing 'latest'?)")
        if rank == 0:
            print(
                f"[resume rank=0] RESUMED from {load_path} at engine.global_steps={engine.global_steps} "
                f"(load_checkpoint took {_resume_elapsed:.0f}s)",
                flush=True,
            )

    # Eval gate: forward-only perplexity on a held-out slice, then write eval-report.json. This
    # does no training and no checkpoint write, and it makes no gate decision. It only produces a
    # real metric for the downstream gate.
    if EVAL_ONLY:
        eval_ids, eval_mask = load_training_samples(tokenizer, n=EVAL_SAMPLES, skip=NUM_SAMPLES)
        eval_ids = eval_ids.to(engine.local_rank)
        eval_mask = eval_mask.to(engine.local_rank)
        engine.eval()
        bs = DS_CONFIG["train_micro_batch_size_per_gpu"]
        loss_sum = 0.0
        n_batches = 0
        # This prints progress because 64 sequential passes with no progress output look
        # identical to a hang.
        #
        # `bs` is the training micro-batch size, 1, so this loop runs EVAL_SAMPLES sequential
        # collective forward passes. Each pass is an all-gather of the sharded parameters. A
        # healthy run and a stuck run look the same on stdout without this print; the only
        # other proof of "healthy" is a separate DCGM query showing GPU use.
        #
        # This uses a rank-0 print instead of ray.train.report() on purpose. report() is a
        # synchronization barrier that every worker must call. Putting one inside a 64-iteration
        # collective loop adds a barrier per batch, to feed a Ray Train reporting surface this
        # deployment does not use. The training loop uses report() instead, where the step
        # boundary is already a sync point — see the report() call there.
        eval_total = math.ceil(eval_ids.shape[0] / bs) if bs else 0
        eval_t0 = time.time()
        with torch.no_grad():
            for i in range(0, eval_ids.shape[0], bs):
                b_ids = eval_ids[i : i + bs]
                b_mask = eval_mask[i : i + bs]
                if b_ids.shape[0] == 0:
                    continue
                out = engine(input_ids=b_ids, attention_mask=b_mask, labels=b_ids)
                loss_sum += out.loss.item()
                n_batches += 1
                if rank == 0 and (n_batches % 8 == 0 or n_batches == eval_total):
                    el = time.time() - eval_t0
                    rate = el / n_batches
                    print(
                        f"[eval rank=0] progress {n_batches}/{eval_total} batches "
                        f"running_mean_loss={loss_sum / n_batches:.4f} "
                        f"elapsed={el:.0f}s ~{rate:.1f}s/batch "
                        f"eta={(eval_total - n_batches) * rate:.0f}s",
                        flush=True,
                    )
        agg = torch.tensor([loss_sum, float(n_batches)], device=engine.local_rank)
        torch.distributed.all_reduce(agg, op=torch.distributed.ReduceOp.SUM)
        mean_loss = (agg[0] / agg[1]).item()
        perplexity = math.exp(mean_loss)
        mlf = _init_mlflow() if rank == 0 else None
        if rank == 0:
            report = {
                "run_id": RUN_ID,
                "global_step": int(engine.global_steps),
                "eval_samples": EVAL_SAMPLES,
                "mean_loss": mean_loss,
                "perplexity": perplexity,
                "resume_from": RESUME_FROM,
                "volume_snapshot_id": os.environ.get("VOLUME_SNAPSHOT_ID", ""),
                "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            }
            print(
                f"[eval rank=0] EVAL n={EVAL_SAMPLES} mean_loss={mean_loss:.4f} "
                f"perplexity={perplexity:.4f} global_step={engine.global_steps}",
                flush=True,
            )
            os.makedirs(os.path.dirname(EVAL_REPORT_PATH), exist_ok=True)
            with open(EVAL_REPORT_PATH, "w") as f:
                json.dump(report, f, indent=2)
            print(f"[eval rank=0] wrote {EVAL_REPORT_PATH}: {json.dumps(report)}", flush=True)
            if mlf is not None:
                try:
                    mlf.log_metric("eval_loss", mean_loss)
                    mlf.log_metric("eval_perplexity", perplexity)
                    mlf.set_tag("eval_report_path", EVAL_REPORT_PATH)
                    mlf.end_run()
                except Exception:  # noqa: BLE001
                    pass
        return

    # Diagnostic: track GPU memory per decoder layer during forward. This shows whether ZeRO-3
    # releases gathered parameters after each layer, or silently accumulates them. Accumulation
    # would explain the about-44 GB out-of-memory error, despite tight
    # stage3_max_live_parameters and reuse_distance settings.
    if rank == 0:
        try:
            decoder_layers = engine.module.model.layers
        except AttributeError:
            decoder_layers = []
        print(f"[diag rank=0] found {len(decoder_layers)} decoder layers to hook", flush=True)

        def _make_pre_hook(i):
            def _hook(module, inp):
                torch.cuda.synchronize()
                print(
                    f"[diag rank=0] pre-layer {i} allocated={torch.cuda.memory_allocated() / 1e9:.2f}GB "
                    f"reserved={torch.cuda.memory_reserved() / 1e9:.2f}GB",
                    flush=True,
                )
            return _hook

        for i, layer in enumerate(decoder_layers):
            layer.register_forward_pre_hook(_make_pre_hook(i))

    input_ids, attention_mask = load_training_samples(tokenizer)
    input_ids = input_ids.to(engine.local_rank)
    attention_mask = attention_mask.to(engine.local_rank)
    batch_size = DS_CONFIG["train_micro_batch_size_per_gpu"]
    n = input_ids.shape[0]

    mlf = _init_mlflow() if rank == 0 else None
    metrics = _init_run_metrics() if rank == 0 else None

    # Every rank calls load_training_samples() with the same NUM_SAMPLES/skip=0, so every rank
    # reads the identical n samples above — deliberately, not fetching world_size times the S3
    # data just to shard it. Without a per-rank starting offset, every rank would walk this
    # shared window with the same idx=0 start and the same stride, computing an identical batch
    # at every step: DeepSpeed's ZeRO-3 gradient all-reduce would then average world_size copies
    # of the same gradient, which is mathematically a no-op, not real data parallelism. Starting
    # each rank at rank*batch_size instead gives every rank a distinct phase of the same cyclic
    # walk — at world_size=8 and batch_size=1 (this config), that's 8 distinct starting indices
    # 0-7, and two ranks can only ever land on the same index if they are the same rank, for any
    # step count. This does not change what data is fetched from S3, only which of it each rank
    # starts on, so it carries no risk of a rank running out of samples.
    step = 0
    idx = (rank * batch_size) % max(n - batch_size, 1)
    while step < MAX_STEPS:
        b_ids = input_ids[idx : idx + batch_size]
        b_mask = attention_mask[idx : idx + batch_size]
        idx = (idx + batch_size) % max(n - batch_size, 1)
        if b_ids.shape[0] == 0:
            idx = 0
            continue

        try:
            outputs = engine(input_ids=b_ids, attention_mask=b_mask, labels=b_ids)
            loss = outputs.loss
            engine.backward(loss)
            engine.step()
        except torch.cuda.OutOfMemoryError:
            print(f"[diag rank={rank}] OOM at step={step}\n{torch.cuda.memory_summary(abbreviated=True)}", flush=True)
            raise

        if rank == 0:
            # One .item() call per step. Both sinks that need the loss value — MLflow and the
            # print below — share this one call. (_record_step takes engine.global_steps, not
            # this value.) Pulling a scalar out of a CUDA tensor forces a device sync, so sharing
            # this one call is what keeps the unconditional print from adding a second sync.
            #
            # The cost is lower than it looks. The obvious objection is that printing every step
            # must cost more. It does not, here. Per step on rank 0, with MLflow enabled — the
            # shipped configuration, because the pipeline sets MLFLOW_TRACKING_URI:
            #
            #   - before: 1 sync every step for MLflow, plus 1 more on the 1 step in 5 that
            #     printed
            #   - after: 1 sync every step, and no more
            #
            # So this is a reduction, not a regression. Only with MLflow disabled does the count
            # go up, from 0 to 1 sync on 4 steps out of 5. Each step already takes about 2.4
            # minutes of 8-GPU compute, so this added cost is too small to measure. Keep the
            # shared call if you change this block.
            loss_value = loss.item()
            if mlf is not None:
                try:
                    mlf.log_metric("loss", loss_value, step=step)
                except Exception:  # noqa: BLE001
                    pass
            if metrics is not None:
                # Use engine.global_steps, not the local `step` variable. On a resumed run,
                # `step` restarts at 0, and the gauge would then show the run going backwards.
                _record_step(metrics, int(engine.global_steps))
            # This prints progress to stdout on every step. Do not add a modulus check back in
            # front of this print: `oc logs` is the first place anyone looks, and the only one
            # needing no port-forward, no route, and no separate tracking server, so it must show
            # progress on its own. Each step already takes minutes of 8-GPU compute, so throttling
            # the print to, say, one line in five leaves gaps of many minutes between lines —
            # indistinguishable from a stuck run on any human timescale.
            #
            # The volume argument does not hold up here. Sixty lines is small next to what is
            # already in the log: Ray's autoscaler prints `infeasible resource requests` every few
            # seconds for the whole run, and that message carries no useful information. One line
            # per micro-batch is the cheapest real signal in this file.
            #
            # `step` and `global_step` are different counters — read them as one and the log is
            # useless. `step` counts micro-batches and bounds this loop (MAX_STEPS=60).
            # `global_step` is DeepSpeed's optimizer-step counter. It advances once every
            # gradient_accumulation_steps=4 steps, so a full run ends at global_step=15 — the
            # number the checkpoint tag carries. Both values are printed for that reason.
            #
            # The log line has a fixed shape: a `[train] ` prefix and key=value fields. This
            # makes a run greppable with `grep '^\[train\] '`, with no regex needed per field.
            # This is not decoration: grepping the job log for `Error` can match advisory text
            # inside Ray's own messages (for example, "raise an error instead of hanging") and
            # bury the real step output.
            #
            # The loss prints with six decimals, not four. This workload is bit-deterministic
            # across full rebuilds — the same final loss at full precision across three separate
            # runs. Four decimals would round that away, hiding a real divergence. MLflow still
            # gets the unrounded value above.
            #
            # flush=True is required here. stdout is a pipe in this environment, so Python
            # block-buffers it by default. Buffered progress would arrive in bursts, minutes
            # late — the one thing progress output must not do.
            print(
                f"[train] step={step} global_step={int(engine.global_steps)} "
                f"loss={loss_value:.6f}",
                flush=True,
            )
        # Do not call ray.train.report() here. It is a collective call that every worker must
        # reach, and in Ray Train v2 it also persists the reported result to the run's storage
        # path. This trainer's RunConfig sets only `name=` and no storage_path, so that persist
        # step has nothing configured to write to that all workers share — the call blocks
        # inside the barrier instead of raising an error, which deadlocks the run.
        #
        # To use the Ray-native surface instead, give RunConfig a storage_path that all workers
        # can reach — the shared RWX volume is the obvious choice — and validate that in its own
        # run, because it puts checkpoint-sized writes on the barrier path.
        #
        # The stdout line above already solves the observability problem this would address. It
        # needs no barrier, and `oc logs` alone can read it.
        step += 1

    if SKIP_SAVE:
        if rank == 0:
            print(
                f"[rank 0] SKIP_SAVE=1 → not writing checkpoint (final engine.global_steps={engine.global_steps})",
                flush=True,
            )
            if mlf is not None:
                try:
                    mlf.end_run()
                except Exception:  # noqa: BLE001
                    pass
        return

    if rank == 0:
        ckpt_dir = CKPT_DIR
        os.makedirs(ckpt_dir, exist_ok=True)
        print(f"[rank 0] saving checkpoint to {ckpt_dir}", flush=True)

    engine.save_checkpoint(CKPT_DIR)
    ray.train.torch.get_device()  # no-op call; marks a barrier point for readability

    if rank == 0:
        ckpt_dir = CKPT_DIR

        # Checkpoint check. Everything above this point can report success on a partial
        # checkpoint: save_checkpoint() has no durability check, Ray registers a checkpoint if
        # any single worker reports one without counting shards, and the upload loop below walks
        # whatever files are on disk.
        #
        # This check runs before the upload, on purpose. Verifying after the upload would still
        # fail the job, but by then the partial checkpoint is already in the bucket, where the
        # next reader would find an object set that looks complete enough to try. Failing here
        # means a bad checkpoint never leaves this pod. The check also runs before the local
        # cleanup (rmtree) below, so the local copy survives for investigation.
        world_size = torch.distributed.get_world_size()
        manifest = verify_checkpoint(ckpt_dir, world_size, int(engine.global_steps))

        s3 = s3_client()
        for root, _, files in os.walk(ckpt_dir):
            for f in files:
                local_path = os.path.join(root, f)
                rel = os.path.relpath(local_path, ckpt_dir)
                key = f"{CHECKPOINT_PREFIX}/{rel}"
                print(f"[rank 0] upload {local_path} -> s3://{BUCKET}/{key}", flush=True)
                s3.upload_file(local_path, BUCKET, key)
        print("=== TRAINING COMPLETE, CHECKPOINT UPLOADED ===", flush=True)

        # The manifest is written and uploaded last, after every shard, so its presence in the
        # bucket is the completion signal. Nothing consumes it yet — no stage in base/50-stages
        # and no code outside this file checks for it. Today it is evidence a person can read,
        # not a gate that stops a bad load. A consumer that refuses to load a checkpoint without
        # a matching manifest would turn it into one.
        manifest_path = write_checkpoint_manifest(ckpt_dir, manifest)
        manifest_key = f"{CHECKPOINT_PREFIX}/{CKPT_MANIFEST_NAME}"
        s3.upload_file(manifest_path, BUCKET, manifest_key)
        print(
            f"[rank 0] checkpoint VERIFIED tag={manifest['tag']} step={manifest['step']} "
            f"world_size={world_size} objects={manifest['object_count']} — manifest uploaded LAST to "
            f"s3://{BUCKET}/{manifest_key} (its presence is the completion signal)",
            flush=True,
        )

        # Reclaim the local copy. S3 now holds the checkpoint. Without this cleanup, the shared
        # RWX volume would grow a new directory per run, because RUN_ID is unique per run and
        # nothing else deletes them. One checkpoint uses about 366 GiB (~393 GB) on an
        # 800 GiB volume. Without cleanup, a third run would fail with ENOSPC inside
        # save_checkpoint() after two hours of 8-GPU time, leaving a partial checkpoint behind.
        # Making RUN_ID unique without this cleanup would trade silent overwrites for a
        # guaranteed later hard failure.
        #
        # Set KEEP_LOCAL_CKPT=1 to keep the local copy. This is needed when a downstream stage
        # reads the checkpoint from the volume instead of from S3.
        if os.environ.get("KEEP_LOCAL_CKPT", "").strip() not in ("", "0", "false"):
            print(f"[rank 0] KEEP_LOCAL_CKPT set — retaining {ckpt_dir}", flush=True)
        else:
            try:
                shutil.rmtree(ckpt_dir)
                print(f"[rank 0] reclaimed local checkpoint {ckpt_dir}", flush=True)
            except OSError as exc:
                # Non-fatal: the durable copy is already in S3. Report this loudly, so a
                # filling volume is easy to trace instead of a mystery.
                print(f"[rank 0] WARNING could not remove {ckpt_dir}: {exc}", flush=True)

        if mlf is not None:
            try:
                mlf.log_param("checkpoint_s3_prefix", f"s3://{BUCKET}/{CHECKPOINT_PREFIX}")
                mlf.log_param("checkpoint_dir", CKPT_DIR)
                mlf.set_tag("volume_snapshot_id", os.environ.get("VOLUME_SNAPSHOT_ID", "pending-v9"))
                mlf.end_run()
            except Exception:  # noqa: BLE001
                pass


def main():
    trainer = TorchTrainer(
        train_loop_per_worker,
        scaling_config=ScalingConfig(num_workers=int(os.environ.get("NUM_WORKERS", "4")), use_gpu=True),
        run_config=RunConfig(name=f"qwen3-deepspeed-{RUN_ID}"),
    )
    result = trainer.fit()
    print(f"=== RAY TRAIN RESULT: {result} ===", flush=True)


if __name__ == "__main__":
    main()
