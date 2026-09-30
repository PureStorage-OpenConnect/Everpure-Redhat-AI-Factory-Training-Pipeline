# FlashBlade array-side preparation

Everything else in this repository runs inside OpenShift. This directory is the one part that runs
against the **array**, and it exists to close a gap: the environment contract told you what the
FlashBlade must provide and what it looks like when it does not, but gave you nothing to run.

- [`flashblade-prepare.yml`](flashblade-prepare.yml) — the playbook
- [`vars/flashblade-example.yml`](vars/flashblade-example.yml) — example variables, no credentials
- [`requirements.yml`](requirements.yml) — the collection this needs, and the namespace rename

Read [`../ENVIRONMENT-CONTRACT.md`](../ENVIRONMENT-CONTRACT.md) first. This playbook implements a
slice of it; the contract is what you are actually adopting.

---

## What it does, and what it deliberately does not

| Step | Automated here | Why |
|---|---|---|
| Verify the management endpoint and API token | **yes** | read-only |
| Verify the NFS data VIP is a data-service interface **on the same array** | **yes** | read-only, and the single check that catches the most expensive misconfiguration |
| Create a throwaway NFS probe filesystem with the pipeline's export rules and snapshot-directory setting | **yes** | proves the settings before Portworx is installed |
| Create the object-store account, the three buckets, and the pipeline user | **yes** | this is the array-side half of the object storage the contract requires |
| Create the array API token for `px-pure-secret` | **no** | see below |
| Mint the S3 access key | **no** | see below |
| Attach an object-store access policy to the user | **no** | see below |
| Create the pipeline's data volumes | **no — and it would be wrong to** | Portworx creates one filesystem per PVC at PVC-create time |
| Configure array networking (VIPs, subnets, VLANs) | **no** | physical facts about your installation; the playbook verifies them |

**The most important line in that table is the last-but-one.** It is a reasonable assumption that an
array-preparation playbook pre-creates the volumes the workload will use. It must not. The shipped
StorageClasses provision a FlashBlade filesystem per PersistentVolumeClaim, named after the claim's
UUID, and a hand-made filesystem sitting beside them is an orphan from the moment it is created.

### The three manual steps, and why each one stays manual

**The Storage Admin API token.** No module in the FlashBlade collection mints an array admin API
token, and the array returns a token's value exactly once at creation — it can never be read back,
only rotated. Create it yourself, on a dedicated Storage Admin user rather than the built-in array
admin, and put it wherever your platform keeps secrets. The token is what `px-pure-secret` carries;
its exact JSON schema is given in contract §12.2, and the login-endpoint trap that makes a
perfectly good token look permission-scoped is contract §12.1.

**The S3 access key.** Same shape of reason, with a sharper edge. FlashBlade returns an access key's
secret exactly once, at creation, and an object-store user has a maximum of **two concurrent keys**.
A creation whose secret was not captured leaves an orphaned, unrecoverable key occupying a slot;
two of those and the next attempt fails on a maximum-key-count error — and can return an empty
result rather than an obvious failure. Automating that step means the only copy of a live credential
exists in Ansible's output: a terminal scrollback, a log file, or a job record. This repository ships
no secret values anywhere, and that property is easier to keep than to recover. So the playbook
**counts the slots and reports them**, and leaves the minting to a person who is watching.

**The object-store access policy.** A freshly created FlashBlade object-store user with a valid
access key still gets `AccessDenied` until an access policy is attached. The collection has a module
for this and **it does not work on a standalone array**: the call that attaches the policy is issued
only when a fleet context is set, and on an array that is not a fleet member the context is empty, so
the module reports `changed: true`, returns no error, and attaches nothing. Attaching a policy in a
task that silently succeeds is worse than not attaching it, because the failure surfaces later as an
application permissions bug. Attach the policy from the array UI or CLI and confirm it is listed
before you rely on the credential.

---

## Prerequisites

**On the array**, before you run anything:

- A **Storage Admin** user with a **non-expiring API token** (`T-…`). Do not reuse the built-in
  array admin account for this.
- An **NFS data VIP** already configured and L2-reachable from every node that will mount a volume,
  with port 2049 open. The playbook checks that the address you name is a data-service interface on
  the array your token authenticates against; it cannot create one.
- A Purity//FB release your Portworx version supports. Check the Portworx support matrix, not this
  file — the floor moves.

**On the machine you run from:**

- `ansible-core` **≥ 2.16**. The collection declares that floor and older cores emit
  `Collection everpure.flashblade does not support Ansible version …` and then run anyway. Treat
  the warning as a real version requirement rather than noise.
- The `everpure.flashblade` collection and the `py-pure-client` Python SDK:

  ```bash
  ansible-galaxy collection install -r requirements.yml
  pip install py-pure-client==1.93.0
  ```

- Network reach to the **management** endpoint. That is frequently a different network from the
  data VIP, and it is often the workstation rather than the cluster nodes that can reach it.

---

## Running it

Credentials come from the environment, so the token never has to be written to a file:

```bash
export PUREFB_URL='<your FlashBlade management VIP or hostname>'
export PUREFB_API='<the T-... token for your Storage Admin user>'

# Copy vars/flashblade-example.yml to a name of your own first, and edit the copy.

# 1. Always start here. Nothing is written.
ansible-playbook flashblade-prepare.yml -e @vars/flashblade-example.yml --check --diff

# 2. Only after you have read the diff.
ansible-playbook flashblade-prepare.yml -e @vars/flashblade-example.yml -e fbda_confirm_apply=true
```

**`--check` is not a suggestion.** Without `-e fbda_confirm_apply=true` the play refuses in its
first task whenever it would actually write — the one exception is `--check` mode itself, which
the assert deliberately lets through so the dry run always works even before you set the confirm
flag. Every module used here supports check mode, so the dry run is a real dry run rather than a
partial one.

Tags let you run a slice: `--tags verify` for the read-only checks alone, `--tags nfs` for the probe
filesystem, `--tags s3` for the object store.

**The three preflight tasks are tagged `always`, and that is what makes the sentence above safe.**
Ansible skips an untagged task whenever `--tags` is passed at all. `always` is the only tag that
survives a `--tags` selection, which is why they carry it — without it, `--tags s3` would go
straight to the first array write with the write gate never evaluated.

### After the probe filesystem exists

Mount it from a node that will later mount pipeline volumes, and confirm two things by hand:

- a write as **root** succeeds — that is what `*(rw,no_root_squash)` buys, and it is load-bearing
  rather than a permissive default worth tightening;
- **`.snapshot` is absent** from the export root.

Then delete the probe. It is not part of the running pipeline.

Both settings, and the measurements behind them, are documented at length in the header of
[`../base/10-storage/storageclass-snapclass-px-csi.yaml`](../base/10-storage/storageclass-snapclass-px-csi.yaml).
The short version: under `root_squash` the kubelet's `fsGroup` walk still visits every file and each
ownership call merely fails, so nothing is saved and the volume root is never stamped; and the array
default for the snapshot directory is *off*, but the CSI driver turns it *on* at create time, which
is what the StorageClass parameter puts back.

---

## Two collection behaviours worth knowing before you extend this

Both will bite anyone who writes their own tasks against this collection.

**The namespace was renamed.** `purestorage.flashblade` became `everpure.flashblade` at 1.27.0. The
old namespace still installs and still resolves, but it now contains redirects only, every call
emits a deprecation warning, and the redirects are scheduled for removal at 2.0.0. Playbooks written
from memory will use the old name.

**`purefb_fs` can only turn the snapshot directory ON.** Its modify path acts only when the module
is asked to enable a setting that is currently disabled. Passing `snapshot: false` to an existing
filesystem that has the snapshot directory enabled is a **silent no-op** — no change, no warning.
This is precisely the state a Portworx-provisioned volume is in, which is why the fix for existing
volumes is an array-side API call and the fix for new ones is the StorageClass parameter. It is also
why this playbook creates a probe filesystem rather than offering to repair one.
