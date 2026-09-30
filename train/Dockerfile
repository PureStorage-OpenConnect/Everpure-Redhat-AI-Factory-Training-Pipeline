# This is the baked training image. It resolves the pinned dependency set once, at build
# time, instead of on every pod at every run.
#
# ============================================================================================
# THIS FILE IS A RECIPE, NOT A REQUIREMENT. THE PIPELINE RUNS WITHOUT IT.
# ============================================================================================
# The manifests keep `runtimeEnvYAML.pip` populated, so the pipeline works for a user with no
# registry and no build pipeline. This is the default because it runs anywhere. Building this
# image is the recommended step for production, but the manifests do not reference it. Point
# them at your own registry yourself. See "Adopting it" at the bottom of this file.
#
# WHY BAKE THE IMAGE AT ALL. There are four reasons, in order of importance:
#
#   1. RESULTS DO NOT DEPEND ON PyPI. The pip set below is resolved once, here, instead
#      of on every pod at every pod start, and every package — including `torch`, not just
#      its declared dependents — is pinned deliberately. Do not remove these pins: an
#      unpinned install lets pip resolve a different package set at every run, and the
#      project's main claim is a bit-identical final loss across runs. That claim cannot
#      depend on a package resolver.
#
#   2. IT SAVES ABOUT TWELVE MINUTES PER RUN. Installing this set on a head node and eight
#      workers dominates job start-up time. A resume job took 13 minutes 29 seconds from
#      start to its first training step. Of that time, the cold 366 GiB (~393 GB) checkpoint
#      read took about 80 seconds. Almost all the rest was pip install time.
#
#   3. THE RUN HAS NO NETWORK DEPENDENCY ON PyPI. Today every GPU pod must reach the
#      internet before a run can start. On a disconnected or restricted network, the
#      pipeline does not start at all.
#
#   4. IT KEEPS FILE COUNT OFF THE SHARED VOLUME. Ray's session directory, where a
#      runtime_env pip install writes its virtualenv, lives on a pod-local emptyDir rather
#      than the shared RWX volume. A pip virtualenv is hundreds of thousands of small
#      files; keeping it off shared storage avoids the file-count pressure that puts on
#      the volume.
#
# Baking the image also makes Ray's 30-second worker-group startup default realistic. The
# manifests currently override it to 600 seconds, because nothing here can start in 30
# seconds. That override also hides a genuinely hung worker for ten minutes.
#
# ============================================================================================
# THE BASE IMAGE ALREADY HAS A DIFFERENT PyTorch VERSION. pip REPLACES IT. READ THIS BEFORE
# YOU EDIT THE FILE.
# ============================================================================================
# The base image ships torch 2.7.1+cu128 and torchvision 0.22.1+cu128. These are CUDA-matched
# vendor builds. Installing the set below replaces both with torch 2.13.0+cu130 and
# torchvision 0.28.0+cu130 from PyPI. This pulls in the whole CUDA 13 runtime (nvidia-*-cu13,
# triton): 96 packages in total. This is an implicit CUDA major-version change. It is also
# what the validated runs actually used, so it is what this file pins.
#
# Reverting to the base image's CUDA 12.8 build would give a smaller image and a shorter
# build. But that is a BEHAVIOUR CHANGE. Re-validate it against the determinism value first;
# do not assume it is safe. Do not simplify this file without a full run to prove the change.
#
# ============================================================================================
FROM registry.redhat.io/rhoai/odh-pipeline-runtime-pytorch-cuda-py312-rhel9@sha256:f35ce6caacf4e34d8301f1867c67227cbafdcf76abd6588b09df7960a55ea869

# These versions match what the validated runs used. They come from pip's own
# `Successfully installed` line, in a proven run's Ray runtime_env_setup log. These MUST
# match `runtimeEnvYAML.pip` in the manifests exactly. Nothing in this published tree checks
# that automatically, including against this file. Keep them in step by hand.
#
# `torch` is listed here directly, even though torchvision also depends on it. It is the
# package most critical to correct numeric results. Leaving it implicit is exactly how it
# went unpinned in the first place.
#
# The cu12/cu13 pairing below looks like a mismatch, but it is not: `nvidia-nccl-cu12` next
# to a cu13 torch build is what the validated install produces.
RUN python3 -m pip install --no-cache-dir \
      torch==2.13.0 \
      torchvision==0.28.0 \
      deepspeed==0.19.5 \
      transformers==5.15.0 \
      accelerate==1.14.0 \
      nvidia-nccl-cu12==2.29.7 \
      mlflow-skinny==3.15.1

# Fail the BUILD, not the run, if this set does not import correctly. Finding this out only
# after eight GPUs are allocated is the expensive way to find it.
RUN python3 -c "import torch, torchvision, deepspeed, transformers, accelerate, mlflow; \
      print(f'baked: torch={torch.__version__} torchvision={torchvision.__version__} \
deepspeed={deepspeed.__version__} transformers={transformers.__version__}')"

# The training script is delivered by ConfigMap at run time. It is not copied into this
# image. This is on purpose: the code changes far more often than the dependency set does.
# Baking the code in would mean rebuilding and repushing this large image for a one-line
# edit. Only the slow, stable half belongs in the image.

# ============================================================================================
# Adopting it
# ============================================================================================
#   podman build -t <your-registry>/<repo>/qwen3-train:<tag> -f train/Dockerfile .
#   podman push  <your-registry>/<repo>/qwen3-train:<tag>
#
# Then, in your overlay, do the following:
#   1. Point the RayJob head and worker containers at your image.
#   2. Also edit the copy embedded in the Sensor's trigger template. Kustomize's image
#      transformer cannot reach inside a CRD field, so edit that copy by hand. Do not trust a
#      fixed count of "how many places" here — it drifts every time a manifest is added or
#      removed. Instead, grep the repo for the image reference itself (e.g. `grep -rn
#      '<your-registry>/<repo>/qwen3-train' .` once you have picked a real tag) and edit every
#      match.
#   3. Empty `runtimeEnvYAML.pip` (keep the key, with an empty list), so Ray does not
#      rebuild what the image already has. Leave `env_vars` alone.
#
# VERIFY THAT THE BAKE WORKED. Start-up time should fall by about twelve minutes, and the
# run should reproduce your recorded loss exactly. If start-up time is unchanged, `pip` is
# still populated somewhere. Check the Sensor's embedded copy first; it is the one every
# transformer misses.
