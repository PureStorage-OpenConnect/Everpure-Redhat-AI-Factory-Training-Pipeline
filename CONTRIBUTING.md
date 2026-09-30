# Contributing

Thank you for looking. Please read the next section before spending time on a pull request — it
describes a real constraint on this repository, and it is better to know first.

## How this repository is published

**This is a one-way mirror.** The manifests are developed in an internal Everpure repository and
published here by an automated extraction that squashes history into a single commit per release.
The extraction is one-directional: it copies an allowlisted subset of files outward and has no path
back.

Two consequences, stated plainly:

- **A pull request cannot be merged here.** A merge would be overwritten by the next publish, and
  the change would never reach the source the publish is generated from.
- **Commit history is intentionally absent.** Each release arrives as one squashed commit. That is
  not neglect; internal commit messages are not published, by design.

This is a limitation of how the repository is produced, not a judgement about outside
contributions. We would rather say so up front than let you discover it after writing a patch.

## What to do instead

**Open an issue.** It is the channel that works, and it is read.

Especially useful:

- **"I ran this on an environment that isn't the one you tested."** The single most valuable report
  we can receive. The manifests were validated on a specific configuration — 2 GPU nodes with
  NVIDIA L40S, OpenShift 4.18, a flash array behind Portworx CSI. Anything that had to change for
  your GPU model, node count, storage backend or OpenShift version is a gap in the environment
  contract, and the contract is the actual deliverable.
- **A step in `ENVIRONMENT-CONTRACT.md` that is wrong, incomplete, or assumes something it should
  not.** Include what you expected and what happened.
- **A manifest that applies cleanly and then does not work.** These are the expensive ones and the
  ones we most want to hear about — the failure mode this whole tree is organised to prevent.
  Check [docs/troubleshooting.md](docs/troubleshooting.md) first — it may already cover the
  symptom you are seeing.

If you have a concrete patch, attach it to the issue as a diff or a description of the change. It
will be applied to the internal source and appear in a subsequent publish. It cannot be merged as a
PR, but it is not wasted.

## Reporting a security vulnerability

**Do not open a public issue for a security vulnerability.**

Report it to Everpure's Product Security and Incident Response Team:

- **Email: psirt@everpuredata.com**
- Public policy: <https://support.everpuredata.com/r/product-security-policy/everpure-vulnerability-reporting-and-disclosure-policy>

PSIRT acknowledges receipt within 2–4 business days; say so in the subject line if the issue is
critical. Please give us the opportunity to investigate before disclosing publicly. There is no bug
bounty — Everpure does not offer compensation for vulnerability reports, though a valid report that
warrants a CVE record credits the reporter in it. That is stated so nobody spends effort under a
false expectation.

**Scope.** This repository is configuration and example code for a reference architecture. It is not
an Everpure product, ships no binaries, and is not covered by any product support agreement.
Vulnerabilities in the container images, Python packages and operators it *references* belong to
their upstreams. A vulnerability reachable *because of how this repository configures* something is
in scope here.

Two things this tree does deliberately, so neither is mistaken for an oversight:

- **It ships no secrets.** Every credential is referenced by Kubernetes Secret name and key only.
- **It disables TLS verification in several places**, against the storage array's API and S3
  endpoint, because the array validated against presented a self-signed certificate. Each site is
  marked in-line. **Supply a CA bundle instead of copying that pattern into production.**

## Validating a change locally

**There is no CI on this repository** — nothing runs these checks automatically, so run them
yourself:

```bash
make preflight        # does your cluster satisfy the contract? fails fast if not
make validate         # every overlay renders and passes schema validation
```

`make validate` is the tested path — it is the only one that ships and the only one that has run
in a fresh clone. This repository carries no vendored schema bundle, so a hand-rolled `kubeconform`
invocation that points `-schema-location` at a local directory fails on every resource; use the
Makefile target above instead of reconstructing its command.

**`make validate` needs network egress.** It fetches core Kubernetes schemas from
`raw.githubusercontent.com` on every run; without egress, or with a vendored schema bundle of your
own, it reports a schema DOWNLOAD failure distinctly from a manifest defect — read the message
before assuming a rendered resource is actually invalid.

Two things worth knowing before you change a manifest:

- **The training source and its ConfigMap must move together.**
  `base/30-pipeline/train-code-configmap.yaml` is generated from
  `train/train_qwen3_deepspeed.py`. Run `make validate-train-configmap` after touching either; a
  drifted pair deploys cleanly and runs the wrong code.
- **The comments in these manifests are load-bearing.** They explain the design rationale and the
  operational constraint behind a value, not just what the value is. If you change a value that has
  a comment explaining it, address the comment in the same change rather than leaving it
  contradicting the code beneath it.

## Licence

By contributing, you agree that your contributions are licensed under the
[Apache License 2.0](LICENSE), the licence covering this repository.
