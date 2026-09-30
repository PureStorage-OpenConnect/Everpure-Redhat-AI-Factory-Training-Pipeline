#!/usr/bin/env bash
# preflight.sh — checks if this cluster meets the environment contract.
#
# Usage: ./preflight.sh [-n NAMESPACE]
# Exit codes:
#   0 — all requirements are met
#   1 — one or more requirements are not met
#   2 — the script cannot check the cluster
#
# EVERY CHECK HERE IS READ-ONLY BY DEFAULT. It creates nothing and changes nothing. It does not
# print secret values. It shows only if a Secret exists and which keys it has. The one exception
# is the opt-in --probe-file-count flag, which applies a short-lived Pod to count files on the
# checkpoint volume; see the check itself for why.
#
# WHAT THIS SCRIPT DOES. It checks every prerequisite in contract section 10 in one pass, instead
# of reading the section and running eight commands by hand. A missing prerequisite is expensive: a
# run can stay Pending forever, or it can start and fail after two hours, because one label or one
# quota is missing. Use this script first. A missing prerequisite then costs you 30 seconds, not a
# GPU cycle.
#
# This script is not a deployment tool. It answers one question: can this cluster run the pipeline.
# If not, it tells you what to fix.

set -uo pipefail

NS="ml-training"
# --probe-file-count is opt-in. It is the only check that is not read-only: it starts a short-lived
# pod to count files on the checkpoint volume. Every other check in this script creates nothing.
# See the check itself for why the script cannot get the file count another way.
PROBE_FILES=0
# The threshold and the message that reports it use ONE variable. Keep them linked: if you split
# them into two literals, the message can show a number the check does not use.
FILE_COUNT_MAX=150000
ARGS=()
for a in "$@"; do
  case "$a" in
    --probe-file-count) PROBE_FILES=1 ;;
    *) ARGS+=("$a") ;;
  esac
done
set -- ${ARGS+"${ARGS[@]}"}
while getopts ":n:h" opt; do
  case "$opt" in
    n) NS="$OPTARG" ;;
    h) echo "usage: $0 [-n NAMESPACE] [--probe-file-count]"; exit 0 ;;
    *) echo "usage: $0 [-n NAMESPACE] [--probe-file-count]" >&2; exit 2 ;;
  esac
done

command -v oc >/dev/null 2>&1 && KUBE=oc || KUBE=kubectl
command -v "$KUBE" >/dev/null 2>&1 || { echo "FATAL: neither oc nor kubectl is on PATH." >&2; exit 2; }
"$KUBE" auth can-i get nodes >/dev/null 2>&1 || {
  echo "FATAL: no working cluster connection (try: oc login ...)." >&2; exit 2; }

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[1;33m'; NC=$'\033[0m'
fail=0; warn=0

ok()   { printf '  %s✓%s %s\n' "$GRN" "$NC" "$1"; }
bad()  { printf '  %s✗%s %s\n' "$RED" "$NC" "$1"; printf '      → %s\n' "$2"; fail=$((fail+1)); }
note() { printf '  %s!%s %s\n' "$YEL" "$NC" "$1"; printf '      → %s\n' "$2"; warn=$((warn+1)); }
hdr()  { printf '\n%s== %s ==%s\n' "$YEL" "$1" "$NC"; }

echo "Preflight for the training pipeline — namespace: $NS"
echo "Read-only by default. Nothing is created, patched or printed in full, unless"
echo "--probe-file-count is passed, which applies a short-lived Pod."

# --- 1. platform ------------------------------------------------------------
hdr "platform"
if ! command -v python3 >/dev/null 2>&1; then
  bad "python3 not found on PATH — cannot check the Kubernetes version" \
      "This check pipes 'kubectl version -o json' through python3 to read serverVersion.minor. Install python3 (or check the version by hand: $KUBE version) and re-run."
else
  SRV=$("$KUBE" version -o json 2>/dev/null | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["serverVersion"]["minor"].rstrip("+"))' 2>/dev/null)
  if [[ -z "$SRV" ]]; then
    bad "could not read the Kubernetes server version" \
        "'$KUBE version -o json' did not return a parseable serverVersion.minor. Check cluster connectivity and '$KUBE version' output by hand."
  elif (( SRV >= 31 )); then
    ok "Kubernetes 1.$SRV (floor: 1.31)"
  else
    bad "Kubernetes 1.$SRV is below the 1.31 floor" \
        "The pipeline uses CRD and scheduling behaviour introduced by 1.31."
  fi
fi
if "$KUBE" get clusterversion version >/dev/null 2>&1; then
  ok "OpenShift detected ($("$KUBE" get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null))"
else
  bad "This does not look like OpenShift" \
      "base/00-platform uses MachineConfig, MachineConfigPool and an SCC required-scc annotation; installing the Argo Events operator also needs its controller Deployment's securityContext.runAsUser patched out first, to fit OpenShift's assigned UID range (see base/20-events/eventbus.yaml); and operator install assumes OLM. None exist on vanilla Kubernetes. Porting is a rewrite of that phase, not a config change."
fi

# --- 2. CRDs ----------------------------------------------------------------
hdr "required CRDs"
need_crd() {
  if "$KUBE" get crd "$1" >/dev/null 2>&1; then ok "$1"
  else bad "$1 is missing" "$2"; fi
}
need_crd clusterqueues.kueue.x-k8s.io       "Kueue. Supplied by OpenShift AI (RHOAI) >= 2.25, or install Kueue directly."
need_crd localqueues.kueue.x-k8s.io         "Kueue."
need_crd resourceflavors.kueue.x-k8s.io     "Kueue."
need_crd rayjobs.ray.io                     "KubeRay. Supplied by OpenShift AI (RHOAI)."
need_crd rayclusters.ray.io                 "KubeRay."
need_crd sensors.argoproj.io                "Argo Events v1.9.7+. NOTE: on OpenShift its controller Deployment defaults to securityContext.runAsUser: 9731, outside this namespace's assigned UID range, and crash-loops unless that field is patched out before install (see base/20-events/eventbus.yaml) so OCP assigns an in-range UID instead."
need_crd eventsources.argoproj.io           "Argo Events."
need_crd volumesnapshots.snapshot.storage.k8s.io "External snapshotter CRDs — required for checkpoint snapshots."
need_crd storageclusters.core.libopenstorage.org "Portworx Operator >= 26.3."

# --- 3. GPU nodes -----------------------------------------------------------
hdr "GPU nodes"
GPUN=$("$KUBE" get nodes -l nvidia.com/gpu.present=true --no-headers 2>/dev/null | wc -l | tr -d ' ')
if (( GPUN >= 2 )); then
  ok "$GPUN node(s) labelled nvidia.com/gpu.present=true (floor: 2)"
else
  bad "$GPUN node(s) carry nvidia.com/gpu.present=true; the pipeline expects at least 2" \
      "That label is set by Node Feature Discovery, not by hand. If NFD is installed and the nodes still lack it, the GPU Operator's driver pods are probably not ready."
fi
TOTGPU=$("$KUBE" get nodes -l nvidia.com/gpu.present=true \
  -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null \
  | awk '{s+=$1} END{print s+0}')
if (( TOTGPU >= 8 )); then
  ok "$TOTGPU allocatable GPU(s) across those nodes (a run requests 8)"
else
  bad "only $TOTGPU allocatable GPU(s); one run requests 8" \
      "Either add capacity or reduce the worker count in your overlay AND the ClusterQueue quota together."
fi
MODELS=$("$KUBE" get nodes -l nvidia.com/gpu.present=true \
  -o jsonpath='{range .items[*]}{.metadata.labels.nvidia\.com/gpu\.product}{"\n"}{end}' 2>/dev/null | sort -u | grep -v '^$' | tr '\n' ' ')
if [[ $(wc -w <<<"$MODELS") -gt 1 ]]; then
  note "mixed GPU models present: $MODELS" \
       "The base selects nvidia.com/gpu.present only, so a job may land on any of them. On a mixed fleet pin nvidia.com/gpu.product in BOTH the ResourceFlavor and the workload pod specs — overlays/example shows where."
else
  ok "GPU model: ${MODELS:-unknown}"
fi

# --- 4. storage -------------------------------------------------------------
hdr "storage classes"
check_sc() {
  local sc="$1" want="$2"
  if ! "$KUBE" get sc "$sc" >/dev/null 2>&1; then
    bad "StorageClass $sc is missing" "Applied by base/10-storage. Apply that phase, or point your overlay at the equivalent class on your cluster."
    return
  fi
  local got; got=$("$KUBE" get sc "$sc" -o jsonpath='{.reclaimPolicy}' 2>/dev/null)
  if [[ "$got" == "$want" ]]; then ok "$sc (reclaimPolicy: $got)"
  else bad "$sc has reclaimPolicy=$got, expected $want" \
           "Retain is not optional for the checkpoint volume: it is what stops a namespace delete from destroying a 366 GiB checkpoint. Reclaim is then a deliberate, separate act."
  fi
}
check_sc px-fb-direct-access-nfsv4-retain Retain

# This check tests the VolumeSnapshotClass directly, not through check_sc. check_sc reads
# .reclaimPolicy, a StorageClass-only field, so it cannot test a VolumeSnapshotClass.
# This is a note, not a failure, because only the optional volumesnapshot-ckpt.yaml uses it.
if "$KUBE" get volumesnapshotclass px-csi-fbda-class >/dev/null 2>&1; then
  ok "VolumeSnapshotClass px-csi-fbda-class exists"
else
  note "VolumeSnapshotClass px-csi-fbda-class is missing" \
       "Applied by base/10-storage. Only the opt-in volumesnapshot-ckpt.yaml consumes it, so nothing in the documented path is blocked — but the snapshot step will fail if you reach it."
fi

# AN EXISTING StorageCluster IS A COLLISION. NO OTHER CHECK REPORTS IT.
#
# Contract §11 tells you to apply base/10-storage and wait for the StorageCluster to reach Running.
# This is correct for a new cluster. It is not correct if Portworx already runs on this cluster:
# base/10-storage names its StorageCluster `px-csi-example`, so applying it creates a SECOND
# StorageCluster next to yours, in the same namespace, against the same nodes and disks. The
# operator then reconciles both.
#
# The CRD check above cannot catch this. The CRD exists in both cases.
#
# This check is advisory, not a failure. Re-applying a StorageCluster with a name that already
# matches is a normal no-op. A hard failure here would fire on correct, unchanged clusters too.
# What matters is the NAME MISMATCH below.
if "$KUBE" get crd storageclusters.core.libopenstorage.org >/dev/null 2>&1; then
  existing=$("$KUBE" get storagecluster -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {end}' 2>/dev/null)
  if [[ -n "${existing// /}" ]]; then
    if [[ "$existing" == *"/px-csi-example "* ]]; then
      ok "StorageCluster already present and named px-csi-example — phase 10 re-applies onto it"
    else
      note "StorageCluster(s) already present: ${existing% }" \
           "base/10-storage ships one named 'px-csi-example'. Applying that phase here CREATES A SECOND StorageCluster rather than updating yours, and the Portworx operator will reconcile both against the same nodes. Either skip phase 10 (its StorageClasses and VolumeSnapshotClass may already exist — check with 'oc get sc'), or rename the StorageCluster in your overlay to match the one above. Do not apply it unchanged."
    fi
  fi
fi

# --- 4b. the fsGroup recursive-chown trap -----------------------------------
#
# Three conditions must all be true for this trap to fire. Each one alone looks normal:
#
#   1. Something sets a pod fsGroup. On OpenShift, the restricted-v2 SCC sets it from the
#      namespace's supplemental-groups range. You did not ask for it and no manifest sets it.
#   2. The CSI driver sets `fsGroupPolicy: File`. This means "apply fsGroup for every fstype and
#      access mode." Kubernetes' own default, `ReadWriteOnceWithFSType`, would exempt an RWX volume.
#   3. The volume holds many files.
#
# When all three are true, the kubelet recursively runs lchown and chmod on the WHOLE volume on
# EVERY pod mount. This costs two NFS SETATTR calls per file, and every pod in the run does this at
# the same time. `subPath` does not limit this: the chown targets the volume root before subPath
# applies. Nothing reports this event. The kubelet suppresses FailedMount on a plain timeout, so you
# see a pod stuck in PodInitializing with no events, then an eviction.
#
# This script can check only conditions (1) and (2). Condition (3) needs --probe-file-count below.
hdr "fsGroup recursive-chown exposure"
fsgp=$("$KUBE" get csidriver pxd.portworx.com -o jsonpath='{.spec.fsGroupPolicy}' 2>/dev/null)
pv_modes=$("$KUBE" -n "$NS" get pvc fbda-shared -o jsonpath='{.spec.accessModes}' 2>/dev/null)
ns_fsg=$("$KUBE" get ns "$NS" -o jsonpath='{.metadata.annotations.openshift\.io/sa\.scc\.supplemental-groups}' 2>/dev/null)

pvc_exists=0
"$KUBE" -n "$NS" get pvc fbda-shared >/dev/null 2>&1 && pvc_exists=1

if [[ -z "$fsgp" ]]; then
  note "CSIDriver pxd.portworx.com not found, or declares no fsGroupPolicy" \
       "Without it this check cannot tell whether the kubelet will walk your volumes. If you use a different CSI driver, read its fsGroupPolicy and apply the same reasoning."
elif (( ! pvc_exists )); then
  note "PVC $NS/fbda-shared does not exist — cannot check its access modes" \
       "This check needs the PVC's accessModes to know whether fsGroupPolicy=File will chown it. Applied by base/30-pipeline; expected before that phase runs. Re-run this check after applying it."
elif [[ "$fsgp" == "File" ]]; then
  if [[ "$pv_modes" == *ReadWriteOnce* ]]; then
    note "CSIDriver fsGroupPolicy=File and $NS/fbda-shared includes ReadWriteOnce" \
         "The kubelet will recursively chown this volume on every pod mount. Keep the file count low (see --probe-file-count) and set securityContext.fsGroupChangePolicy: OnRootMismatch on the pod templates."
  else
    note "CSIDriver fsGroupPolicy=File, and $NS/fbda-shared is ReadWriteMany-only ($pv_modes)" \
         "Kubernetes' default policy (ReadWriteOnceWithFSType) would NOT chown an RWX volume; 'File' overrides that and chowns it anyway, on every pod mount, for every pod. This is the trap. Mitigations, in order: keep the session root off this volume (the manifests in this repo already set Ray's session root to an emptyDir for this reason), set fsGroupChangePolicy: OnRootMismatch, and keep the file count low (--probe-file-count). Note fsGroupPolicy itself is re-applied by the storage operator and cannot be durably edited."
  fi
else
  ok "CSIDriver fsGroupPolicy=$fsgp (an RWX volume is exempt from the recursive chown)"
fi
[[ -n "$ns_fsg" ]] && ok "namespace injects fsGroup from range $ns_fsg (expected on OpenShift; not a fault)"

# This script cannot check the array-side half of this trap from here.
note "NOT CHECKED: whether the array exposes read-only snapshot copies inside the export" \
     "On FlashBlade a visible .snapshot directory puts a full read-only copy of the volume INSIDE the volume, so the chown above walks it too, on a volume large enough to make that walk expensive. It is a per-filesystem array attribute (snapshot_directory_enabled), and it is read from the array's own management API, not from anything visible to a pod running in the cluster, so this script has no way to check it from here. Check it from your array: it should be false for any volume a pod mounts. Provision new volumes with the StorageClass parameter pure_fb_snapshot_directory_enabled: \"false\"."

# --- 4c. file count on the checkpoint volume (opt-in; creates a pod) --------
#
# No tier gives a file-count signal. The array reports space, performance, and data reduction per
# filesystem, but not file count. `kubelet_volume_stats_inodes_*` on this storage class are
# 512-byte BLOCKS, not files (blocks x 512 = capacity_bytes, exactly). An alert based on inodes only
# restates free space; it cannot fire on file growth. This is a known limitation. The only way to
# get a real count is to count the files directly.
#
# The probe mounts the volume as readOnly. This skips the kubelet's fsGroup logic completely, so
# the probe pod does not pay the cost it measures, and it cannot get stuck the way a real pod can.
if (( PROBE_FILES )); then
  hdr "file count on $NS/fbda-shared (probe pod — this one is not read-only)"
  if ! "$KUBE" -n "$NS" get pvc fbda-shared >/dev/null 2>&1; then
    note "PVC $NS/fbda-shared does not exist — nothing to count" "Expected before phase 30 is applied."
  else
    pname="preflight-filecount-$$"
    # find's stderr (e.g. permission-denied on a subdirectory) is redirected to a file
    # instead of /dev/null, and its line count is reported alongside FILECOUNT below. A
    # walk that hits read errors can still print a low or zero count on stdout; without
    # this, that misread as a confirmed low/zero count instead of an incomplete one.
    apply_out=$(cat <<PROBE | "$KUBE" apply -f - 2>&1
apiVersion: v1
kind: Pod
metadata: {name: $pname, namespace: $NS}
spec:
  restartPolicy: Never
  activeDeadlineSeconds: 600
  volumes:
    - name: fbda
      persistentVolumeClaim: {claimName: fbda-shared, readOnly: true}
  containers:
    - name: probe
      image: registry.access.redhat.com/ubi9/ubi-minimal
      command: ["/bin/sh","-c","n=\$(find /mnt/fbda -xdev -type f 2>/tmp/find.err | wc -l); e=\$(wc -l < /tmp/find.err); echo FILECOUNT=\$n ERRLINES=\$e"]
      volumeMounts:
        - {name: fbda, mountPath: /mnt/fbda, readOnly: true}
PROBE
)
    apply_rc=$?
    if (( apply_rc != 0 )); then
      bad "probe pod apply was rejected (exit $apply_rc)" \
          "$apply_out"
    else
      for _ in $(seq 1 60); do
        ph=$("$KUBE" -n "$NS" get pod "$pname" -o jsonpath='{.status.phase}' 2>/dev/null)
        [[ "$ph" == Succeeded || "$ph" == Failed ]] && break
        sleep 5
      done
      log_out=$("$KUBE" -n "$NS" logs "$pname" 2>/dev/null)
      n=$(grep -oE 'FILECOUNT=[0-9]+' <<<"$log_out" | head -1 | cut -d= -f2)
      errlines=$(grep -oE 'ERRLINES=[0-9]+' <<<"$log_out" | head -1 | cut -d= -f2)
      "$KUBE" -n "$NS" delete pod "$pname" --wait=false >/dev/null 2>&1
      if [[ -z "$n" ]]; then
        note "probe pod produced no count" "It may still have been starting, or timed out before finishing. Re-run, or count by hand from a pod that mounts the volume."
      elif (( n > FILE_COUNT_MAX )); then
        bad "$n files on fbda-shared — above the ${FILE_COUNT_MAX} threshold" \
            "This is the variable that actually predicts eviction, and it is invisible to every dashboard. At two NFS SETATTRs per file per pod mount, a volume this size does not finish its chown inside a typical PodsReady deadline. Find what is writing them — for example, a Ray runtime_env pip tree can produce ~63,600 files per pod — and get it off this volume."
      elif [[ -n "$errlines" ]] && (( errlines > 0 )); then
        note "probe pod counted $n file(s) but hit $errlines read error(s) while walking $NS/fbda-shared" \
             "The count above is NOT confirmed — find could not read every entry (permission denied or similar), so this may be an undercount, not a verified low/zero value. Investigate the read errors (re-run this probe interactively to see them) before trusting this number."
      else
        ok "$n files on fbda-shared (threshold ${FILE_COUNT_MAX})"
      fi
    fi
  fi
fi

# --- 5. secrets: names and KEYS, never values -------------------------------
hdr "secrets (names and keys only — no values are read or printed)"
# check_secret [sev] <name> <ns> <key>...
#
# sev defaults to `bad`, so every existing call below still works unchanged. Add `note` as the
# first argument to make a new check advisory: it does not fail preflight's exit code. This avoids
# a second copy of this function. Use `note` only for a secret the contract genuinely treats as
# optional under some real condition — every secret checked below is unconditionally required, so
# none currently passes `note`; that severity exists for a future check, not a live example here.
check_secret() {
  local sev=bad
  if [[ "$1" == note || "$1" == bad ]]; then sev="$1"; shift; fi
  local name="$1" ns="$2"; shift 2
  if ! "$KUBE" -n "$ns" get secret "$name" >/dev/null 2>&1; then
    "$sev" "Secret $ns/$name is missing" "How you create it is your choice — sealed secrets, an external secrets operator, oc create secret. The manifests reference it by name and key only. Required keys: $*"
    return
  fi
  local keys missing=()
  keys=$("$KUBE" -n "$ns" get secret "$name" -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null)
  for k in "$@"; do grep -qx "$k" <<<"$keys" || missing+=("$k"); done
  if (( ${#missing[@]} == 0 )); then ok "$ns/$name has all required keys ($*)"
  else "$sev" "$ns/$name is missing key(s): ${missing[*]}" "A Secret that exists with the wrong keys fails at pod start with CreateContainerConfigError, which reads like a manifest bug."
  fi
}
check_secret flashblade-s3 "$NS" AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY S3_ENDPOINT

# px-pure-secret fails as `bad` right away; it is not a note. Contract §5 requires it with no
# condition. The Portworx operator auto-detects this exact Secret and key name. Without it,
# nothing provisions. If your Portworx credential uses a different name, read the message below —
# this check assumes the operator's default name.
check_secret px-pure-secret portworx pure.json

# hf-token fails as `bad` right away, same as px-pure-secret above. Contract §5 requires this
# secret unconditionally: model-staging-job.yaml reads HF_TOKEN as a required env var with no
# default, so staging fails without it even against a non-gated base model or dataset.
check_secret bad hf-token "$NS" HF_TOKEN

# This check for the Red Hat pull secret stays a note. Reading openshift-config/pull-secret needs
# high privilege, and a non-admin account correctly cannot read it. A `bad` result would fire on
# correct RBAC, not on a real problem.
hdr "Red Hat pull secret"
if ps=$("$KUBE" -n openshift-config get secret pull-secret -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null) && [[ -n "$ps" ]]; then
  if base64 -d <<<"$ps" 2>/dev/null | grep -q 'registry\.redhat\.io'; then
    ok "openshift-config/pull-secret carries a registry.redhat.io entry"
  else
    note "openshift-config/pull-secret has no registry.redhat.io entry" \
         "Every Ray image comes from registry.redhat.io. A missing entry surfaces much later as ImagePullBackOff on driver pods, which reads as a scheduling problem. Add it from console.redhat.com → Downloads → Pull Secret."
  fi
else
  note "could not read openshift-config/pull-secret" \
       "That is a privileged read and your account may correctly lack it. Check by hand — see docs/getting-started.md section 2."
fi

# --- 5b. bucket names: the most expensive mistake to get wrong -------------
#
# base/30-pipeline/pipeline-config.yaml ships `S3_DATA_BUCKET: my-models` (and `my-inbox` /
# `my-registry` for the other two bucket keys) as placeholder values. overlays/example does not
# override them by default. With these values, a run can fail 15 minutes in, after the
# runtime environment installs on nine pods and Kueue admits all 8 GPUs, with this error:
#
#     botocore.errorfactory.NoSuchBucket: An error occurred (NoSuchBucket) when calling the
#     ListObjectsV2 operation: The specified bucket does not exist.
#
# This error does not name the bucket. Everything before this point looks correct.
#
# This check is advisory, not a reachability test. The S3 endpoint is the array's data VIP. It is
# deliberately not reachable from where you run preflight (contract §12 keeps management and data
# paths separate). Only in-cluster workloads can reach it, and this script creates nothing, so it
# cannot test the connection. It can read the bucket names from the ConfigMap and show them next to
# the one command that checks them. A check that cannot verify something must say so.
hdr "S3 buckets (names only — this script cannot reach the data VIP to verify them)"
if "$KUBE" -n "$NS" get cm pipeline-config >/dev/null 2>&1; then
  data_b=$("$KUBE" -n "$NS" get cm pipeline-config -o jsonpath='{.data.S3_DATA_BUCKET}' 2>/dev/null)
  val_b=$("$KUBE" -n "$NS" get cm pipeline-config -o jsonpath='{.data.S3_VALIDATION_BUCKET}' 2>/dev/null)
  reg_b=$("$KUBE" -n "$NS" get cm pipeline-config -o jsonpath='{.data.S3_REGISTRY_BUCKET}' 2>/dev/null)
  # Both reads return "" when the key is absent, not only when it holds "". Compare only when
  # there is a value to compare: without the -n guard, a pipeline-config that is missing both keys
  # makes them trivially equal and reports "both ''" — a finding about a collision that does not
  # exist, on a ConfigMap whose actual problem is that the keys are not set at all.
  if [[ -n "$data_b" && "$data_b" == "$val_b" ]]; then
    bad "S3_DATA_BUCKET and S3_VALIDATION_BUCKET are both '$data_b'" \
        "The poller watches the validation bucket. Point it at the data bucket and EVERY dataset upload fires a training run (contract §4)."
  fi
  # This is the one bucket value preflight can judge with certainty, even without reaching the
  # data VIP. Each key below has its own literal placeholder shipped in
  # base/30-pipeline/pipeline-config.yaml: 'my-models' for S3_DATA_BUCKET, 'my-inbox' for
  # S3_VALIDATION_BUCKET, 'my-registry' for S3_REGISTRY_BUCKET. 'REPLACE-ME*' is this repo's
  # generic placeholder convention (scripts/trigger-validation-object.yaml). None of these values
  # can be a real customer bucket. Failing on them is not a false positive. A different, unknown
  # bucket name gets only a `note`, because this script cannot tell a wrong bucket name from a
  # real one.
  declare -A bucket_placeholder=(
    [S3_DATA_BUCKET]=my-models
    [S3_VALIDATION_BUCKET]=my-inbox
    [S3_REGISTRY_BUCKET]=my-registry
  )
  for pair in "S3_DATA_BUCKET:$data_b" "S3_VALIDATION_BUCKET:$val_b" "S3_REGISTRY_BUCKET:$reg_b"; do
    key="${pair%%:*}"; val="${pair#*:}"
    if [[ "$val" == "${bucket_placeholder[$key]}" || "$val" == REPLACE-ME* ]]; then
      bad "$key is still '$val'" \
          "That is the shipped example/placeholder value (base ships '${bucket_placeholder[$key]}' for $key), not a bucket that exists on your array. It does not fail at apply — it fails ~15 minutes into an 8-GPU run with a NoSuchBucket that does not name the bucket. Override it in your overlay's 30-pipeline kustomization (see overlays/example/30-pipeline/kustomization.yaml for the commented configMapGenerator) before applying phase 30."
    fi
  done
  note "buckets: data='$data_b' validation='$val_b' registry='$reg_b' — NOT verified to exist" \
       "Beyond the placeholder check above, this script cannot reach the data VIP to confirm any of these are real buckets. Settle it from inside the cluster before you trigger anything: oc -n $NS run s3check --rm -it --restart=Never --image=docker.io/amazon/aws-cli:2.15.30 --overrides='{\"spec\":{\"containers\":[{\"name\":\"s3check\",\"image\":\"docker.io/amazon/aws-cli:2.15.30\",\"command\":[\"sh\",\"-c\",\"for b in \$S3_DATA_BUCKET \$S3_VALIDATION_BUCKET \$S3_REGISTRY_BUCKET; do aws --endpoint-url \$S3_ENDPOINT --no-verify-ssl s3 ls s3://\$b/ >/dev/null 2>&1 && echo OK \$b || echo MISSING \$b; done\"],\"envFrom\":[{\"configMapRef\":{\"name\":\"pipeline-config\"}}],\"env\":[{\"name\":\"S3_ENDPOINT\",\"valueFrom\":{\"secretKeyRef\":{\"name\":\"flashblade-s3\",\"key\":\"S3_ENDPOINT\"}}},{\"name\":\"AWS_ACCESS_KEY_ID\",\"valueFrom\":{\"secretKeyRef\":{\"name\":\"flashblade-s3\",\"key\":\"AWS_ACCESS_KEY_ID\"}}},{\"name\":\"AWS_SECRET_ACCESS_KEY\",\"valueFrom\":{\"secretKeyRef\":{\"name\":\"flashblade-s3\",\"key\":\"AWS_SECRET_ACCESS_KEY\"}}}]}]}}'"
else
  note "ConfigMap $NS/pipeline-config not found — bucket names not checked" \
       "It is created by phase 30. Before that phase this is expected; after it, something removed it."
fi

# --- 6. quota ---------------------------------------------------------------
hdr "compute quota"
# Read EVERY ClusterQueue. Do not cap this list. The loop below skips any queue that declares no
# nvidia.com/gpu quota and reports "no ClusterQueue declares an nvidia.com/gpu quota" only when
# none of them do, so a cap does not bound work — it changes the verdict. `oc get` returns queues
# in name order, which has nothing to do with which one serves this pipeline, so any cap fails a
# correctly configured cluster whose own queue happens to sort past it: the check reporting a
# missing quota because it never looked, which is the one answer this check must never give.
# Converts a Kubernetes binary-suffixed quantity (Gi/Mi/Ki) or a bare byte count to whole
# mebibytes, for integer comparison against the ephemeral-storage floor. This pipeline's own
# manifests only ever use Gi for ephemeral-storage/memory quantities; decimal (G/M/K) suffixes
# are not handled, since none of this repo's shipped manifests use them for this resource.
to_mib() {
  local v="$1"
  case "$v" in
    '') echo 0 ;;
    *Gi) echo $(( ${v%Gi} * 1024 )) ;;
    *Mi) echo "${v%Mi}" ;;
    *Ki) echo $(( ${v%Ki} / 1024 )) ;;
    *[0-9]) echo $(( v / 1024 / 1024 )) ;;
    *) echo 0 ;;
  esac
}
EPH_FLOOR_MIB=$(( 720 * 1024 ))

CQ=$("$KUBE" get clusterqueue --no-headers 2>/dev/null | awk '{print $1}')
if [[ -z "$CQ" ]]; then
  bad "no ClusterQueue exists" "Kueue admits this pipeline's work. Without a ClusterQueue nothing is ever admitted — and Kueue does not error, it simply holds the workload forever."
else
  found=0
  for q in $CQ; do
    gpu=$("$KUBE" get clusterqueue "$q" -o jsonpath='{range .spec.resourceGroups[0].flavors[0].resources[?(@.name=="nvidia.com/gpu")]}{.nominalQuota}{end}' 2>/dev/null)
    eph=$("$KUBE" get clusterqueue "$q" -o jsonpath='{range .spec.resourceGroups[0].flavors[0].resources[?(@.name=="ephemeral-storage")]}{.nominalQuota}{end}' 2>/dev/null)
    act=$("$KUBE" get clusterqueue "$q" -o jsonpath='{.status.conditions[?(@.type=="Active")].status}' 2>/dev/null)
    [[ -z "$gpu" ]] && continue
    found=1
    eph_mib=$(to_mib "$eph")
    if [[ "$act" != "True" ]]; then
      bad "ClusterQueue $q exists but is not Active (Active=$act)" "An inactive queue admits nothing. Check that the ResourceFlavor it references exists — a queue naming a missing flavor stays inactive."
    elif (( ${gpu%%.*} < 8 )); then
      bad "ClusterQueue $q has nvidia.com/gpu quota $gpu; a run needs 8" \
          "QUOTA BELOW THE FLOOR DOES NOT FAIL — IT HANGS. Kueue holds the workload as unadmitted with no error on the RayJob and no event on the pod, because there is no pod yet. A run that appears to do nothing is nearly always this."
    elif [[ -z "$eph" ]]; then
      bad "ClusterQueue $q covers nvidia.com/gpu but not ephemeral-storage" \
          "Every GPU-worker pod in this pipeline requests ephemeral-storage (the base-model download). A resource this ClusterQueue's coveredResources omits is never admitted — not rejected, held forever, with no error anywhere except a Kueue Workload condition nothing surfaces by default. Add ephemeral-storage to the queue's covered resources with at least 90Gi per GPU worker (720Gi at this pipeline's default 8-worker floor)."
    elif (( eph_mib < EPH_FLOOR_MIB )); then
      bad "ClusterQueue $q has ephemeral-storage quota $eph; a run needs 720Gi" \
          "QUOTA BELOW THE FLOOR DOES NOT FAIL — IT HANGS, the same as nvidia.com/gpu below floor above."
    else
      ok "ClusterQueue $q: Active, nominalQuota nvidia.com/gpu=$gpu, ephemeral-storage=$eph (floor: 8, 720Gi)"
    fi
  done
  (( found )) || bad "no ClusterQueue declares an nvidia.com/gpu quota" "Add nvidia.com/gpu to the queue's covered resources."
fi

# --- 7. FlashBlade ServiceMonitor endpoint -----------------------------------
#
# base/00-platform/servicemonitor-flashblade-exporter.yaml ships all four scrape jobs pointed at
# the placeholder host `flashblade.example.com`. That is documented as the correct failure mode in
# the file's own header. This check surfaces it as a preflight finding — otherwise a customer who
# never opens the Targets page has no way to learn the metrics have been down since day one.
hdr "FlashBlade ServiceMonitor endpoint"
if "$KUBE" get servicemonitor flashblade-exporter -n flashblade-exporter >/dev/null 2>&1; then
  endpoint_list=$("$KUBE" get servicemonitor flashblade-exporter -n flashblade-exporter \
      -o jsonpath='{range .spec.endpoints[*]}{.params.endpoint[0]}{"\n"}{end}' 2>/dev/null)
  # Count from the actual list, not a hardcoded 4 — an overlay is free to add or remove entries
  # (one more array means one more copy of the four jobs, per the file's own header), and a
  # hardcoded denominator would silently misreport either direction once it drifted from base.
  total_count=$(printf '%s' "$endpoint_list" | grep -c '.')
  placeholder_count=$(printf '%s' "$endpoint_list" | grep -c '^flashblade\.example\.com$')
  if (( total_count == 0 )); then
    note "ServiceMonitor flashblade-exporter has no endpoints with params.endpoint set" \
         "Unexpected shape — this does not match base/00-platform's own manifest. Check the object directly: oc get servicemonitor flashblade-exporter -n flashblade-exporter -o yaml"
  elif (( placeholder_count == 0 )); then
    ok "FlashBlade ServiceMonitor endpoint is set on all $total_count scrape job(s)"
  else
    note "$placeholder_count of $total_count ServiceMonitor scrape job(s) still point at the placeholder host flashblade.example.com" \
         "Every one of those jobs fails with a DNS error, and nothing else surfaces it. Set params.endpoint via a JSON6902 patch in your overlay (see overlays/example/00-platform/kustomization.yaml) — a live 'oc patch' against the cluster instead of an overlay patch is wiped by the next 'oc apply -k .../00-platform'."
  fi
else
  note "ServiceMonitor flashblade-exporter is missing (namespace flashblade-exporter)" \
       "Applied by base/00-platform. If you have not applied that phase yet, this is expected."
fi

# --- 8. Inode-metric alert usage on FlashBlade NFS ---------------------------
#
# WHY THIS CHECK EXISTS. On the px-fb-direct-access-nfsv4-retain storage class, FlashBlade's NFS
# reports `f_files`/`f_ffree` in 512-byte block units, not real file counts — a PVC with a
# handful of files reads as hundreds of millions of "inodes" (a 20Gi PVC holding 2 filesystem
# entries reports kubelet_volume_stats_inodes=41943040, exactly 20Gi/512, and
# kubelet_volume_stats_inodes_used=536, not 2). This is a platform capability gap,
# not something fixable from this pipeline's manifests — either the storage class would need to
# report true inode numbers, or the array would need to expose a real per-filesystem file count.
# pipeline-alerts-prometheusrule.yaml documents this at length and deliberately ships
# no rule on the metric. What is NOT guarded against is someone adding one back later without
# reading that comment. This check scans every shipped PrometheusRule for an alert expression
# that references kubelet_volume_stats_inodes_* or node_filesystem_files_* and warns — it never
# fails preflight, because an existing, working rule that already accounts for the unit mismatch
# is a legitimate reason to reference the metric name; the point is just to make sure nobody is
# misled by a false "94% of inodes used" alert on this storage class.
hdr "Inode-metric alert usage on FlashBlade NFS"
rule_json=$("$KUBE" get prometheusrule -n "$NS" -o json 2>/dev/null)
if [[ -z "$rule_json" ]] || ! command -v python3 >/dev/null 2>&1; then
  note "could not inspect PrometheusRule objects in $NS" \
       "Either no PrometheusRule exists yet (expected before base/30-pipeline is applied) or python3 is missing from this shell. Re-run once both are available."
else
  hits=$(python3 -c '
import json, re, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
pat = re.compile(r"kubelet_volume_stats_inodes_?\w*|node_filesystem_files_?\w*")
for item in d.get("items", []):
    rule_name = item.get("metadata", {}).get("name", "?")
    for group in item.get("spec", {}).get("groups", []):
        for r in group.get("rules", []):
            alert = r.get("alert")
            expr = r.get("expr", "")
            if alert and pat.search(expr):
                print(f"{rule_name}/{alert}")
' <<<"$rule_json")
  if [[ -n "$hits" ]]; then
    note "$(printf '%s' "$hits" | wc -l) alert(s) reference an inode/file-count metric on this storage class: $(printf '%s' "$hits" | tr '\n' ' ')" \
         "kubelet_volume_stats_inodes_* and node_filesystem_files_* report 512-byte block counts, not file counts, on px-fb-direct-access-nfsv4-retain (FlashBlade NFS). Confirm the alert's threshold and description already account for that before trusting it — otherwise it will read like a real inode-exhaustion signal and isn't one. See pipeline-alerts-prometheusrule.yaml's own header comment for the measured numbers."
  else
    ok "no shipped alert expression references kubelet_volume_stats_inodes_* or node_filesystem_files_*"
  fi
fi

# --- verdict ----------------------------------------------------------------
printf '\n%s=======================================%s\n' "$GRN" "$NC"
if (( fail > 0 )); then
  printf '%sPREFLIGHT FAILED: %d requirement(s) unmet%s' "$RED" "$fail" "$NC"
  (( warn > 0 )) && printf ' (%d advisory)' "$warn"
  printf '.\n  Fix these before applying. Every one of them fails LATER in a way that is harder to read.\n'
  exit 1
fi
if (( warn > 0 )); then
  printf '%sPreflight passed with %d advisory note(s) — read them before a long run.%s\n' "$YEL" "$warn" "$NC"
else
  printf '%sPreflight passed: this cluster satisfies the contract.%s\n' "$GRN" "$NC"
fi
exit 0
