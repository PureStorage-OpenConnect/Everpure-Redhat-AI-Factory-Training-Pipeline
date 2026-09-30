# Troubleshooting

**The failure mode this pipeline produces most often is not a crash.** It is a deployment that
applies cleanly, reports success, and does nothing. Entries are ordered by how long each takes to
notice.

Run `./preflight.sh` first. Most of what follows it catches before you apply anything.

---

## A run appears to do absolutely nothing

**No pod, no event, no error on the RayJob.**

Almost always Kueue quota. The workload is held as *unadmitted*, and because no pod has been created
there is nothing to carry an event.

```bash
oc get clusterqueue ml-training-cq -o jsonpath='{.status.conditions[*].type}={.status.conditions[*].status}{"\n"}'
oc get workloads -n ml-training
```

- `Active=False` → the ClusterQueue references a `ResourceFlavor` that does not exist. A queue
  naming a missing flavor stays inactive and admits nothing.
- Active but nothing admitted → nominal quota is below what a run requests (8 GPU / 56 CPU /
  1600 Gi / 720 Gi ephemeral-storage by default), or the ClusterQueue's `coveredResources` omits
  `ephemeral-storage` entirely — the same silent-wait outcome either way. **Quota below the floor
  does not fail; it waits.**

## Pods are Pending forever, with no explanatory event

An unsatisfiable `nodeSelector` is not an error in Kubernetes — it is a node set of size zero.

```bash
oc -n ml-training get pod -o wide
oc get nodes -l nvidia.com/gpu.present=true
oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.labels.nvidia\.com/gpu\.product}{"\n"}{end}'
```

The base selects `nvidia.com/gpu.present` only. If you pinned `nvidia.com/gpu.product` in your
overlay, confirm the value matches a label a node actually carries — exactly, including case. And
if you pinned it in the Kueue `ResourceFlavor` but not in the pod specs (or the reverse), the
intersection can be empty.

## The poller reports `new-objects-fired=0` forever

The poller dedupes by key + ETag against a state object in the same bucket. Objects already in the
seen-set never fire again — which is correct, and also means a re-uploaded identical file does
nothing.

```bash
oc -n ml-training create job trigger-poll --from=cronjob/s3-poller
oc -n ml-training logs job/trigger-poll
```

If it reports `0` for a genuinely new object, check the bucket the poller is actually watching:

```bash
oc -n ml-training get cm pipeline-config -o jsonpath='{.data.S3_VALIDATION_BUCKET}{"\n"}'
```

A poller pointed at a bucket that does not exist exits non-zero rather than reporting
`new-objects-fired=0`, which would be indistinguishable from a healthy idle poll.

## A run started but the pipeline never triggered it

The Sensor carries a **whole RayJob inside it** as a literal template. Kustomize's namespace
transformer does not reach into it, patches on `kind: RayJob` do not match it, and the image
transformer does not rewrite it. If you changed the namespace, the GPU selector, the image or the
worker count in your overlay, there is a second copy inside the Sensor that also needs changing.

```bash
oc -n argo-events get sensor s3-new-object -o yaml | grep -A5 'namespace\|nodeSelector'
```

`overlays/example/20-events/kustomization.yaml` shows the patches, with the full JSON pointer paths.

## Containers stuck in `CreateContainerConfigError`

A Secret exists with the wrong keys, or does not exist in the namespace the pod runs in.

```bash
oc -n ml-training get secret flashblade-s3 \
  -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'
```

That prints key **names** only. Required: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
`S3_ENDPOINT`. `preflight.sh` checks this.

## `aws s3 ls` returns AccessDenied on a credential that works

A bucket-scoped key cannot enumerate the account. Always scope the command:

```bash
aws --endpoint-url "$S3_ENDPOINT" s3 ls s3://your-bucket/     # correct
aws --endpoint-url "$S3_ENDPOINT" s3 ls                       # AccessDenied, even when the key is fine
```

## Storage: `create volume: : not found`

That message means **authentication**, not a missing object. The most common cause is logging in
against a *versioned* API path: it accepts the token, and every subsequent call returns 403 "Access
Denied", which looks exactly like an under-privileged token.

The login endpoint is **unversioned**. See
[contract §12.1](../ENVIRONMENT-CONTRACT.md#121-create-volume--not-found-means-authentication-not-a-missing-object)
for the full sequence, and contract §12.2 for the `pure.json` schema — the block-storage form of that file
will not work for the file backend.

## The checkpoint volume fills up

Peak volume occupancy for a single checkpoint plus accrued logs is ~444.8 GiB of an 800 GiB
volume — the checkpoint itself is 366 GiB (~393 GB); the rest is the base model, datasets and
per-run residue that share the volume. Ray's log-shipper sidecar persists only the logs
subdirectory of its session directory to the shared volume — it does not touch
`runtime_resources/` (the materialized pip environment), which lives solely on each pod's
ephemeral container filesystem and is destroyed with the pod. Real per-run residue on the shared
volume is ~15 MB/pod (session logs), not a meaningful factor next to a 366 GiB checkpoint — see
[contract §3](../ENVIRONMENT-CONTRACT.md#3-storage) for the measurement.

```bash
oc -n ml-training exec deploy/mlflow -- df -h /mnt/fbda 2>/dev/null || \
  oc -n ml-training get pvc fbda-shared
```

**The `mlflow` deployment does not mount `fbda-shared`** — only `mlflow-store` at `/mlflow` — so
the `exec` above always fails and the command falls through to the PVC-level fallback by design,
not as an occasional degraded path. `oc get pvc` gives capacity and phase only; to actually list
what's on the volume, run a short-lived pod that mounts it directly, matching the volume definition
in any RayJob under `base/40-workloads/`:

```bash
oc -n ml-training run fbda-debug --rm -it --restart=Never --image=registry.access.redhat.com/ubi9/ubi-minimal \
  --overrides='{"spec":{"containers":[{"name":"fbda-debug","image":"registry.access.redhat.com/ubi9/ubi-minimal","command":["sh","-c","ls -la /mnt/fbda"],"volumeMounts":[{"name":"fbda-shared","mountPath":"/mnt/fbda"}]}],"volumes":[{"name":"fbda-shared","persistentVolumeClaim":{"claimName":"fbda-shared"}}]}}'
```

**Put the command inside `--overrides`, not after `--`.** `oc run`'s generated container spec is
replaced wholesale by `--overrides`, not merged with it — trailing args after `--` are silently
discarded once `--overrides` supplies its own container spec, and the pod runs whatever `command`
(or the image's default entrypoint) that spec names instead. Bake the actual command into the
override's `command` array, as above, or it never runs.

**Size against one checkpoint, not a percentage.** A 3%-free alert fires at 24 GB on an 800 GiB
volume — an order of magnitude below one checkpoint, i.e. after the write it was meant to warn about
has already failed. The threshold to set is one checkpoint plus margin, in absolute bytes;
`overlays/example/30-pipeline/kustomization.yaml` has the patch.

Note that NFS surfaces `ENOSPC` at `close()`/`fsync()`, not at `write()`, and DeepSpeed's checkpoint
`commit()` returns `True` unconditionally — so a checkpoint save onto a full volume can report
success and lose the run's output.

## Confirming a run landed in MLflow, without a browser

The `mlflow` image ships no `curl` and no shell tool for hitting its own REST API, so `oc exec` in
is not enough on its own. Query it with the tracking server's own client library, from a debug pod
or any pod already in `ml-training` with network access to the `mlflow` Service:

```bash
oc -n ml-training run mlflow-check --rm -it --restart=Never --image=registry.access.redhat.com/ubi9/python-311 \
  -- python3 -c "
import json, urllib.request
base = 'http://mlflow.ml-training.svc:5000/api/2.0/mlflow'
exp = json.load(urllib.request.urlopen(f'{base}/experiments/search'))
exp_id = exp['experiments'][0]['experiment_id']
req = urllib.request.Request(f'{base}/runs/search',
    data=json.dumps({'experiment_ids': [exp_id], 'max_results': 5}).encode(),
    headers={'Content-Type': 'application/json'})
runs = json.load(urllib.request.urlopen(req))
for r in runs.get('runs', []):
    print(r['info']['run_id'], r['info']['status'], r['data'].get('metrics'))
"
```

`experiments/search` is a **GET**; `runs/search` is a **POST** with a JSON body — a GET on the
latter returns `400`, which is the shape that costs the most time to find by trial and error. Any
image with a Python 3 interpreter works; this uses only `urllib` from the standard library, no
`requests` or `mlflow` package required.

## The volume-usage graph stops mid-chart

`kubelet_volume_stats_*` is reported only while a pod actually mounts the volume. Once the
RayCluster is reclaimed at its TTL, the series goes absent — that is the metric ending, not the
volume emptying. The shipped `FbdaVolumeStatsAbsentWhileMounted` rule exists for exactly this
distinction.

## The FlashBlade exporter's targets are all DOWN

Expected on a fresh install. `base/00-platform/servicemonitor-flashblade-exporter.yaml` ships four
scrape jobs pointing at `flashblade.example.com`, which does not exist. Patch in your array's
**management** address (not a data VIP) and create the token Secret — both are in
`overlays/example/00-platform/kustomization.yaml`, with the JSON6902 patch written out.

## Alerts exist but nothing ever notifies

Two separate things, and both must be true:

1. **User-workload monitoring must be on**, or rules in your namespace are never evaluated.
2. **Alertmanager needs a receiver that actually delivers.** The shipped receiver is a placeholder
   whose only job is to take `alertmanager_integrations` off zero. Wiring a real destination is
   yours.

```bash
oc -n openshift-user-workload-monitoring get pod
oc -n ml-training get prometheusrule
```

## `ray_training_*` metrics are missing

This is a workaround for an upstream Ray defect, not something this repo controls — confirm it on
your own cluster before trusting it. If your platform enables TLS for Ray's internal gRPC (`RAY_USE_TLS`) and you're on
Ray 2.52+, the OpenTelemetry metrics backend that version made the default does not pick up those
TLS credentials when reaching the dashboard agent — see
[github.com/ray-project/ray/issues/59968](https://github.com/ray-project/ray/issues/59968). Every
RayJob manifest in this tree sets `RAY_enable_open_telemetry: "false"` to revert to the older
metrics backend, which has no such dependency. If your cluster doesn't enable Ray-internal TLS, or
runs a Ray version outside the affected range, this workaround is a no-op — harmless either way.

Confirm on your own cluster:

```bash
oc -n ml-training exec <a-gpu-worker-pod> -- curl -s localhost:8080/metrics | grep -c ray_training
```

If that still returns `0`, check the worker pod's own dashboard-agent log for TLS handshake
errors (`SSL_ERROR_SSL`, `WRONG_VERSION_NUMBER`) before assuming this is the same defect — a
different cause needs a different fix.

## Re-running the registration Job creates v2, v3, …

Expected. MLflow's `RESOURCE_ALREADY_EXISTS` is handled by incrementing the model version. For a
clean re-validation, delete the prior version first.

## See also

- [docs/getting-started.md](getting-started.md) — if the symptom you hit is not one step above,
  confirm you followed every step in order first.
- [docs/rollback-runbook.md](rollback-runbook.md) — for reverting the checkpoint volume from a
  snapshot, which is a deliberate procedure, not a failure mode.
- [docs/results.md](results.md) — what a healthy run's numbers look like, for comparison.
