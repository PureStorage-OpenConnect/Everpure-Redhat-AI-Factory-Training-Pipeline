# Rollback runbook — reverting the checkpoint volume from a snapshot

This is the one operation in this pipeline that destroys data, and it has no button. It is a
manifest you apply by hand, deliberately, after you have decided you want it — never something
`apply -k` can trigger as a side effect.

**Read this in full before you apply anything.** If you only read one line: **a restore on this
driver does not clone your data — it reverts the live volume in place, and it discards everything
written since the snapshot.**

## What actually happens

On this CSI driver, creating a PersistentVolumeClaim from a VolumeSnapshot does not produce a
second, independent copy of the data. It reverts the **source** filesystem to the state the
snapshot captured, and hands you back a new PersistentVolume that is an alias for that same
filesystem — not a clone sitting beside it. There is no point at which two copies of the data
exist.

Concretely, for this pipeline's checkpoint volume (`fbda-shared`):

- **Anything written to `fbda-shared` after the snapshot was taken is gone once you restore** —
  the whole filesystem reverts, not just the checkpoint directory.
- **There is no experiment branching.** You cannot hold the live state and a restored state side
  by side. Reverting *is* the recovery; it is not a way to inspect an old state while keeping the
  new one.
- **A pod must never mount both the live PVC and a restored PVC at once.** They are the same
  filesystem under two names, mounted read-write twice, and the mount hangs.

The full measurement behind this — three independent restores, three shared `volumeHandle`s, and
what the array actually reported — is in
[contract §3.3](../ENVIRONMENT-CONTRACT.md#33-snapshot-behaviour-you-must-design-around), along
with the three-tier recovery table this pipeline's recovery story rests on. This runbook does not
restate that table; read it there.

## The procedure — the snapshot has to exist first

Rolling back needs **three objects applied deliberately, in order**, never fused into one job
that reverts a volume as a side effect of starting:

0. **The VolumeSnapshot itself.** `rollback-revert-from-snapshot.yaml` restores *from* a
   VolumeSnapshot named `fbda-ckpt-v9` — it does not create one. That snapshot is created by
   `base/30-pipeline/volumesnapshot-ckpt.yaml`, which is **opt-in**: it is not in any phase's
   `resources:` list, so a normal `apply -k` never creates it, and this runbook's step 1 will fail
   to find a source to restore from unless you have applied it yourself, after a run has actually
   written a checkpoint to `fbda-shared`:

   ```bash
   oc -n ml-training apply -f base/30-pipeline/volumesnapshot-ckpt.yaml
   oc -n ml-training get volumesnapshot fbda-ckpt-v9 -o jsonpath='{.status.readyToUse}'   # expect: true
   ```

   See that file's own header for why timing matters — snapshotting an empty, just-provisioned
   volume binds just as cleanly and is just as wrong.

1. **A human, or a runbook, creates the PVC that reverts the volume.**
   `base/30-pipeline/rollback-revert-from-snapshot.yaml` is that PVC. It is **not** in any phase's
   `resources:` list — `apply -k` cannot apply it by accident — so you apply it explicitly:

   ```bash
   oc -n ml-training apply -f base/30-pipeline/rollback-revert-from-snapshot.yaml
   oc -n ml-training get pvc fbda-shared-rollback   # expect: Bound
   ```

   The `-n` is not optional — see the file's own header for what a bare `apply -f` does here.

2. **Confirm the revert did what you intended before you go any further.** Check a file, a
   directory listing, or an mtime you know should be gone if the revert happened. Do not assume;
   the file binding `Bound` only means the volume attached, not that its contents are what you
   expected.

3. **Only then** apply the job that resumes training against the reverted volume. That job is a
   separate manifest, applied separately, and it is out of scope for this runbook — it should
   never itself contain a step that reverts a volume.

## Before you do this on a cluster that matters

- Verify the mechanism on your own array first, with two throwaway volumes, a snapshot, and a
  marker file — not on `fbda-shared`.
- Confirm you actually want tier 1 recovery (snapshot rollback) and not tier 2 (the S3 archive) or
  tier 3 (replication to a second array, which this pipeline does not implement). See the
  three-tier table in [contract §3.3](../ENVIRONMENT-CONTRACT.md#33-snapshot-behaviour-you-must-design-around)
  — a rollback cannot help you if the array itself is gone.
- Delete the rollback PVC when you are done with it. That delete issues no array call, because the
  source StorageClass is `Retain` — see `base/10-storage/storageclass-snapclass-px-csi.yaml`.

## If you actually need tier 2, not tier 1

Everything above is tier 1: the checkpoint volume still exists, and you are rewinding it in place.
If the volume or the array itself is gone, there is nothing here to rewind — recover from the S3
archive instead, with `scripts/restore-checkpoint-from-s3.sh`. It downloads a checkpoint's
`checkpoint-manifest.json` first (the same file the upload path uploads LAST as its own
completion signal) and only reports success once every file that manifest lists has come back at
its recorded size, so a restore that silently drops a shard fails loudly instead of producing a
checkpoint that looks complete:

```bash
scripts/restore-checkpoint-from-s3.sh -r <RUN_ID> -d <empty local directory>
```

This is a different kind of procedure than the one above — an S3 download into an ordinary
directory, not a PVC/snapshot operation — and it needs the `flashblade-s3` Secret's three keys in
the environment it runs in. It restores a checkpoint byte-for-byte and rejects an incomplete one —
see the script's own header for exactly what it checks.

## See also

- [docs/results.md](results.md#what-did-not-work) — the measured proof behind this procedure: three
  independent restores, and a resumed run that reproduced all eight per-step losses bit-identically.
- [docs/troubleshooting.md](troubleshooting.md) — for failure modes that are not this deliberate
  procedure.
