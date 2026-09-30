#!/bin/bash
# This script submits the Qwen3-32B DeepSpeed ZeRO-3 fine-tune to the qwen3-fbda
# RayCluster.
#
# Run this from inside the head pod. If no Ray CLI is available in your environment outside the
# cluster (for example on a jump host or bastion with no direct network path to the Ray
# dashboard), copy the files in and run it from there instead:
#   oc -n ml-training cp train_qwen3_deepspeed.py qwen3-fbda-head-xxxx:/tmp/train_job/
#   oc -n ml-training cp submit_fbda.sh          qwen3-fbda-head-xxxx:/tmp/train_job/
#   oc -n ml-training exec qwen3-fbda-head-xxxx -c ray-head -- bash /tmp/train_job/submit_fbda.sh
#
# The job runs as `python -c "import ...; m.main()"`, not as a script path. Ray
# serializes the entrypoint by module. A bare `python train_qwen3_deepspeed.py`
# fails to load on the workers.
#
# RUN_ID sets both the S3 prefix (checkpoints/<RUN_ID>) and the checkpoint
# directory on FlashBlade. CKPT_DIR must point at the shared RWX mount (/mnt/fbda),
# so all four ZeRO-3 ranks write their shards to the same FlashBlade volume.
set -e
cd /tmp/train_job
# A fixed, reusable default here would reopen the checkpoint-overwrite failure mode described
# in train_qwen3_deepspeed.py's own RUN_ID guard: a run destroys its predecessor's checkpoint
# because both share one RUN_ID, and nothing reports it. So the default below is never the
# same value twice: it appends the submission time to the base name. Pass RUN_ID explicitly
# yourself if you want a stable, human-chosen name instead.
RUN_ID="${RUN_ID:-example-run-$(date +%s)}"
# PACKAGE VERSIONS BELOW ARE PINNED ON PURPOSE — same set as train/Dockerfile and the
# runtimeEnvYAML.pip block in every manifest in base/40-workloads. Do not drop the pins or the
# torch entry: an unpinned install lets pip resolve a different torch/CUDA build at every run,
# which changes a run's numeric results. Keep this list in step with those files by hand.
#
# RAY_TRAIN_WORKER_GROUP_START_TIMEOUT_S: Ray's default worker-group startup timeout is 30
# seconds. Installing the pip packages above on every pod can take minutes, so without this,
# Ray Train aborts with:
#   ray.train.ControllerError: The worker group startup timed out after 30.0 seconds
# Every RayJob manifest in base/40-workloads sets this to 600; this manual-submit path needs
# the same value for the same reason.
RAY_ADDRESS=http://127.0.0.1:8265 ray job submit \
  --working-dir /tmp/train_job \
  --runtime-env-json "{\"pip\": [\"deepspeed==0.19.5\", \"transformers==5.15.0\", \"accelerate==1.14.0\", \"torch==2.13.0\", \"torchvision==0.28.0\", \"nvidia-nccl-cu12==2.29.7\", \"mlflow-skinny==3.15.1\"], \"pip_check\": false, \"env_vars\": {\"LD_LIBRARY_PATH\": \"/usr/lib64\", \"RUN_ID\": \"${RUN_ID}\", \"CKPT_DIR\": \"/mnt/fbda/ckpt-${RUN_ID}\", \"RAY_TRAIN_WORKER_GROUP_START_TIMEOUT_S\": \"600\"}}" \
  --no-wait \
  -- python -c "import train_qwen3_deepspeed as m; m.main()"
