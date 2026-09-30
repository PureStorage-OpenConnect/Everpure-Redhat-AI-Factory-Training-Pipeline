#!/usr/bin/env bash
# restore-checkpoint-from-s3.sh — Tier 2 recovery: pull a checkpoint back out of S3 and verify
# it downloaded completely.
#
# WHAT THIS SCRIPT DOES. train/train_qwen3_deepspeed.py only ever writes to S3 — it uploads every
# checkpoint file, uploads checkpoint-manifest.json LAST as the "upload is complete" signal, then
# deletes the local copy. This is the download-side mirror of that upload path: it recovers a
# checkpoint from the S3 archive (ENVIRONMENT-CONTRACT.md §3.3, tier 2) if the checkpoint volume
# (fbda-shared) is lost, using the same manifest-driven completeness check the upload path relies on.
#
# WHY THE MANIFEST CHECK IS THE PART THAT MATTERS. A restore that copies most of the files and
# exits 0 is worse than one that fails loudly — it puts a partial ZeRO-3 checkpoint back on disk
# that LOOKS complete (a resume attempt would fail confusingly at load time, possibly minutes into
# an expensive job, instead of failing here in seconds with a named list of what is missing). The
# upload path treats "checkpoint-manifest.json exists in the bucket" as the completion signal
# precisely because Ray Train and DeepSpeed's own save path do not guarantee that (see
# verify_checkpoint() in train_qwen3_deepspeed.py: Ray registers a checkpoint if ANY one worker
# reports one, without counting shards). This script applies the same discipline in reverse:
# download the manifest FIRST, then treat its file list as the one true definition of "every file
# that has to come back", and only claim success if every one of them did, at the recorded size.
#
# THIS SCRIPT IS CONTENT-AGNOSTIC ON PURPOSE. It never looks at what a file IS — not a DeepSpeed
# shard name, not a file extension, nothing. It downloads whatever the manifest's "files" array
# lists, by name and byte count, and nothing else. This is deliberate: it is what lets the same
# script work identically against small synthetic test fixtures and a real 366 GiB (~393 GB)
# checkpoint prefix, unchanged.
#
# WHAT THIS SCRIPT PROVES. A clean download with matching sizes proves the OBJECTS came back
# byte-complete, for every file the manifest lists, at the recorded size.
#
# Usage:
#   ./restore-checkpoint-from-s3.sh -r RUN_ID  -d DEST_DIR [-b BUCKET]
#   ./restore-checkpoint-from-s3.sh -p PREFIX  -d DEST_DIR [-b BUCKET]
#
#   -r RUN_ID    derives the prefix the training code itself uses: checkpoints/RUN_ID
#                (matches CHECKPOINT_PREFIX in train/train_qwen3_deepspeed.py). Use this for a
#                real checkpoint.
#   -p PREFIX    an exact S3 key prefix, no derivation. Use this for anything that is not a
#                checkpoint upload (e.g. a synthetic test prefix) — the script does not care
#                either way, see the content-agnostic note above.
#   -d DEST_DIR  local directory to restore into. Created if it does not exist. Must be empty,
#                or empty enough — see the check below for exactly what that means and why.
#   -b BUCKET    S3 bucket. Default: $S3_DATA_BUCKET, falling back to "my-models" — the same
#                default chain train_qwen3_deepspeed.py uses for BUCKET, so a plain invocation
#                that inherits the pipeline's own env agrees with the uploader by construction
#                instead of by two copies of the same literal staying in sync by luck.
#
# Required env (same three keys the flashblade-s3 Secret carries — source them from it, e.g.
# `oc set env --from=secret/flashblade-s3 ...` or a pod envFrom; do not hardcode credentials):
#   S3_ENDPOINT, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
#
# Exit codes:
#   0 — every file the manifest lists was downloaded, at the recorded size
#   1 — the restore ran, but is incomplete: a file is missing, or its downloaded size does not
#       match the manifest — do not resume training against DEST_DIR
#   2 — environment error: bad arguments, missing tools, missing credentials, bucket unreachable,
#       no manifest found at this prefix at all (so there is nothing to verify against — either
#       this is the wrong prefix, or the upload that wrote it never finished), or the manifest
#       names an unsafe path (escapes DEST_DIR via ".." or an absolute path) — a manifest that
#       names even one such entry cannot be trusted as "every file that has to come back", so
#       nothing is downloaded at all rather than downloading everything except that one entry

set -uo pipefail

BUCKET="${S3_DATA_BUCKET:-my-models}"
RUN_ID=""
PREFIX=""
DEST=""

usage() {
  echo "usage: $0 -r RUN_ID | -p PREFIX  -d DEST_DIR  [-b BUCKET]" >&2
}

while getopts ":r:p:d:b:h" opt; do
  case "$opt" in
    r) RUN_ID="$OPTARG" ;;
    p) PREFIX="$OPTARG" ;;
    d) DEST="$OPTARG" ;;
    b) BUCKET="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

if [[ -n "$RUN_ID" && -n "$PREFIX" ]]; then
  echo "FATAL: pass -r RUN_ID or -p PREFIX, not both — it is ambiguous which prefix you mean." >&2
  exit 2
fi
if [[ -n "$RUN_ID" ]]; then
  PREFIX="checkpoints/$RUN_ID"
fi
if [[ -z "$PREFIX" ]]; then
  echo "FATAL: no prefix given — pass -r RUN_ID or -p PREFIX." >&2
  usage
  exit 2
fi
if [[ -z "$DEST" ]]; then
  echo "FATAL: -d DEST_DIR is required." >&2
  usage
  exit 2
fi
# Trim exactly one trailing slash. "checkpoints/RUN_ID/" and "checkpoints/RUN_ID" must produce the
# same key, or list-objects-v2 below (which appends its own "/") would double it.
PREFIX="${PREFIX%/}"

command -v aws >/dev/null 2>&1 || { echo "FATAL: aws CLI is not on PATH." >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is not on PATH." >&2; exit 2; }
for v in S3_ENDPOINT AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
  [[ -n "${!v:-}" ]] || { echo "FATAL: \$$v is not set — source the flashblade-s3 Secret's keys into this shell first." >&2; exit 2; }
done

# WARNING: TLS verification is disabled here, matching every other S3 caller in this repo
# (s3-poller-cronjob.yaml, pipeline-canary-cronjob.yaml, train_qwen3_deepspeed.py's s3_client()).
# The array this pipeline was validated against uses a self-signed certificate. This is not a
# recommendation — supply a CA bundle instead if you have one.
AWS=(aws --endpoint-url "$S3_ENDPOINT" --no-verify-ssl)

# Temp files for captured stderr, same pattern check-alert-satisfiability.sh already uses for its
# RULE_JSON_FILE: mktemp (not a fixed /tmp/restore-*.err name) so a pre-existing symlink at a
# guessable path cannot be substituted for one of these, and two concurrent invocations of this
# script cannot collide by writing the same file. The trap removes all three on exit regardless of
# how the script terminates (normal exit, FATAL early-return, or a signal).
HEAD_ERR=$(mktemp)
MANIFEST_ERR=$(mktemp)
DL_ERR=$(mktemp)
trap 'rm -f "$HEAD_ERR" "$MANIFEST_ERR" "$DL_ERR"' EXIT

mkdir -p "$DEST" || { echo "FATAL: cannot create $DEST" >&2; exit 2; }
# An existing file that happens to share a name and size with a manifest entry would pass the
# post-download check below without this script ever having downloaded it — a false "complete"
# from stale data left by an earlier, unrelated attempt. This is a warning, not a hard failure:
# a genuinely empty directory that merely already exists (the normal case for a freshly created
# scratch dir) must not be rejected.
if [[ -n "$(ls -A "$DEST" 2>/dev/null)" ]]; then
  echo "WARNING: $DEST is not empty. Pre-existing files there can make this restore report" >&2
  echo "  success without this script actually having downloaded them. Use an empty directory." >&2
fi

echo "Restoring s3://$BUCKET/$PREFIX -> $DEST"
echo

# Bucket reachability first, as its own check — same reasoning as s3-poller-cronjob.yaml's
# head-bucket call: it tells apart "bucket absent" (404) and "credentials rejected" (403) from
# "prefix has no manifest", which the manifest download below cannot do on its own. Without this,
# a typo'd bucket name and a genuinely incomplete checkpoint look identical: both make the next
# step fail.
if ! "${AWS[@]}" s3api head-bucket --bucket "$BUCKET" 2>"$HEAD_ERR"; then
  echo "FATAL: bucket s3://$BUCKET is not reachable: $(tr -d '\n' <"$HEAD_ERR")" >&2
  exit 2
fi

# THE MANIFEST COMES FIRST. This is the download-side half of the upload's own "manifest last =
# complete" contract (see write_checkpoint_manifest() and the upload loop in
# train_qwen3_deepspeed.py). Downloading it before anything else, and refusing to proceed without
# it, means a restore attempt against a prefix that was never finished uploading — or against the
# wrong prefix entirely — fails here, in seconds, instead of after copying most of a 366 GiB (~393 GB)
# checkpoint.
MANIFEST_NAME="checkpoint-manifest.json"
MANIFEST_KEY="$PREFIX/$MANIFEST_NAME"
MANIFEST_LOCAL="$DEST/$MANIFEST_NAME"

echo "[1/3] downloading manifest s3://$BUCKET/$MANIFEST_KEY"
if ! "${AWS[@]}" s3 cp "s3://$BUCKET/$MANIFEST_KEY" "$MANIFEST_LOCAL" 2>"$MANIFEST_ERR"; then
  echo "FATAL: could not download $MANIFEST_NAME from s3://$BUCKET/$PREFIX/" >&2
  echo "  $(tr -d '\n' <"$MANIFEST_ERR")" >&2
  echo "  Its absence means one of two things: this prefix is wrong, or the upload that wrote it" >&2
  echo "  never reached the point where it uploads the manifest (uploaded LAST, on purpose — see" >&2
  echo "  train_qwen3_deepspeed.py). Either way, there is nothing here this script can verify" >&2
  echo "  completeness against, so it refuses to guess and download the rest blind." >&2
  exit 2
fi

# Parsing the manifest is the part that needs a real JSON reader, not shell text-munging — same
# division of labour as check-alert-satisfiability.sh (bash drives S3/network calls; python3 does
# the offline structural parsing). This only reads the file already sitting in $MANIFEST_LOCAL —
# no stdin trick needed, unlike that script, because there is no RULE_JSON variable to route
# around a `python3 -` script's own stdin consumption.
MANIFEST_INFO=$(python3 - "$MANIFEST_LOCAL" <<'PYEOF'
import json, os, sys

def is_unsafe_path(name):
    # The manifest is REMOTE, UNTRUSTED input — it comes from the bucket, not from this script.
    # A corrupted or crafted manifest containing ".." components or a leading "/" must not be
    # allowed to write (download loop) or be inspected (verify pass) outside DEST_DIR:
    # os.path.join("/dest", "/etc/cron.d/x") discards "/dest" entirely and returns "/etc/cron.d/x"
    # unchanged, and "../../x" walks straight out of DEST_DIR either way. Reject both up front
    # rather than trusting the manifest the same way the rest of this script deliberately does
    # not trust it to describe real DeepSpeed shards.
    if name.startswith("/") or "\x00" in name:
        return True
    normalized = os.path.normpath(name)
    return normalized == ".." or normalized.startswith(".." + os.sep)

path = sys.argv[1]
try:
    with open(path) as f:
        manifest = json.load(f)
except Exception as e:
    print(f"FATAL\tmanifest at {path} is not valid JSON: {e}")
    sys.exit(0)

files = manifest.get("files")
if not isinstance(files, list) or not files:
    print(f"FATAL\tmanifest has no non-empty 'files' list — nothing to restore or verify")
    sys.exit(0)

print(f"HEADER\trun_id={manifest.get('run_id', '?')} step={manifest.get('step', '?')} "
      f"world_size={manifest.get('world_size', '?')} tag={manifest.get('tag', '?')} "
      f"object_count={manifest.get('object_count', len(files))}")
for entry in files:
    name = entry.get("name")
    size = entry.get("bytes")
    if not isinstance(name, str) or not isinstance(size, int):
        print(f"FATAL\tmanifest file entry is malformed: {entry!r}")
        sys.exit(0)
    if is_unsafe_path(name):
        print(f"FATAL\tmanifest file entry has an unsafe path, refusing to use it: {name!r}")
        sys.exit(0)
    print(f"FILE\t{name}\t{size}")
PYEOF
)

if [[ -z "$MANIFEST_INFO" ]]; then
  echo "FATAL: manifest parsing produced no output — this should not happen." >&2
  exit 2
fi
# This check uses a line-anchored search (`grep '^FATAL\t'`), not a whole-string prefix match,
# because a FATAL line is not always the first line of $MANIFEST_INFO. The malformed-JSON and
# empty-files-list checks fail before any HEADER/FILE line is printed, so a FATAL from either of
# those is always first — but the unsafe-path check runs INSIDE the per-file loop, after HEADER
# has already been printed, so its FATAL line can land in the middle of the output instead of at
# the start. A whole-string prefix match would miss a FATAL line in that position entirely,
# letting the unsafe entry silently drop out of FILE_LIST instead of stopping the restore. The
# verify pass below independently re-derives the same unsafe-path check from the manifest on
# disk, as a second layer that still refuses an unsafe path even if this line-anchored check were
# ever bypassed.
FATAL_LINE=$(grep '^FATAL'$'\t' <<<"$MANIFEST_INFO" | head -1)
if [[ -n "$FATAL_LINE" ]]; then
  echo "FATAL: ${FATAL_LINE#FATAL$'\t'}" >&2
  exit 2
fi

FILE_LIST=$(grep '^FILE'$'\t' <<<"$MANIFEST_INFO" | cut -f2-)
HEADER_LINE=$(grep '^HEADER' <<<"$MANIFEST_INFO" | cut -f2-)
echo "  manifest: $HEADER_LINE"
TOTAL_FILES=$(wc -l <<<"$FILE_LIST")
echo "  $TOTAL_FILES file(s) listed"
echo

# Download every file the manifest names. Best-effort per file, on purpose: a run that stops at
# the first missing shard reports one problem when there may be several. The verification pass
# below is what actually decides pass/fail — this loop's job is only to try, and to say so when a
# single transfer fails, so the cause (network blip vs. genuinely absent object) is visible
# instead of folded into a generic "missing" a few seconds later.
echo "[2/3] downloading $TOTAL_FILES file(s)"
DOWNLOAD_ERRORS=0
while IFS=$'\t' read -r name size; do
  [[ -z "$name" ]] && continue
  local_path="$DEST/$name"
  mkdir -p "$(dirname "$local_path")"
  if ! "${AWS[@]}" s3 cp "s3://$BUCKET/$PREFIX/$name" "$local_path" >/dev/null 2>"$DL_ERR"; then
    echo "  WARNING download failed for $name: $(tr -d '\n' <"$DL_ERR")"
    DOWNLOAD_ERRORS=$((DOWNLOAD_ERRORS + 1))
  fi
done <<<"$FILE_LIST"
echo "  done ($DOWNLOAD_ERRORS transfer error(s))"
echo

# THE CHECK THAT ACTUALLY MATTERS. Presence and size, for every file the manifest names — nothing
# here inspects file content, because this script has no idea what a "correct" DeepSpeed shard or
# a synthetic dummy file looks like, and it must not need to. A restore that silently drops files
# is the exact failure mode this exists to catch, so this pass is unconditional: it runs and
# reports every mismatch, even if the download loop above reported zero errors — a transfer can
# succeed at the protocol level and still land at the wrong size (see verify_checkpoint()'s own
# reasoning in train_qwen3_deepspeed.py: NFS surfaces ENOSPC at close/fsync, not at write; the
# analogous risk here is a truncated or interrupted S3 GET that the CLI does not surface as a
# nonzero exit).
echo "[3/3] verifying every manifest file downloaded at its recorded size"
VERIFY_RESULT=$(python3 - "$MANIFEST_LOCAL" "$DEST" <<'PYEOF'
import json, os, sys

def is_unsafe_path(name):
    # Same check as the manifest-parsing pass above, deliberately duplicated rather than shared:
    # this pass re-reads the manifest itself from disk rather than trusting the earlier pass's
    # output, so it must not trust an unsafe path either, on its own, independent of whether the
    # first pass already caught it. See that pass's comment for the full reasoning.
    if name.startswith("/") or "\x00" in name:
        return True
    normalized = os.path.normpath(name)
    return normalized == ".." or normalized.startswith(".." + os.sep)

manifest_path, dest = sys.argv[1], sys.argv[2]
with open(manifest_path) as f:
    manifest = json.load(f)

missing, mismatched, ok, unsafe = [], [], [], []
for entry in manifest["files"]:
    name, expected = entry["name"], entry["bytes"]
    if is_unsafe_path(name):
        unsafe.append(name)
        continue
    local_path = os.path.join(dest, name)
    if not os.path.isfile(local_path):
        missing.append(name)
        continue
    actual = os.path.getsize(local_path)
    if actual != expected:
        mismatched.append((name, expected, actual))
    else:
        ok.append(name)

for name in unsafe:
    print(f"UNSAFE\t{name}")
for name in missing:
    print(f"MISSING\t{name}")
for name, expected, actual in mismatched:
    print(f"MISMATCH\t{name}\t{expected}\t{actual}")
for name in ok:
    print(f"OK\t{name}")
print(f"SUMMARY\t{len(ok)}\t{len(missing)}\t{len(mismatched)}")
PYEOF
)

FAIL=0
while IFS=$'\t' read -r kind a b c; do
  case "$kind" in
    UNSAFE)    echo "  ✗ UNSAFE     $a — manifest path escapes $DEST, refusing it (see script header)"; FAIL=1 ;;
    MISSING)   echo "  ✗ MISSING   $a — never landed in $DEST"; FAIL=1 ;;
    MISMATCH)  echo "  ✗ MISMATCH  $a — manifest says $b bytes, downloaded file is $c bytes"; FAIL=1 ;;
    OK)        : ;;  # printed in the summary line below, not per-file — 18+ "✓" lines add nothing
    SUMMARY)   OK_COUNT="$a"; MISSING_COUNT="$b"; MISMATCH_COUNT="$c" ;;
  esac
done <<<"$VERIFY_RESULT"
UNSAFE_COUNT=$(grep -c '^UNSAFE'$'\t' <<<"$VERIFY_RESULT")

echo
echo "RESULT: $OK_COUNT/${TOTAL_FILES} file(s) verified complete, $MISSING_COUNT missing, $MISMATCH_COUNT size-mismatched, $UNSAFE_COUNT unsafe path(s) rejected."
if (( FAIL )); then
  echo "RESTORE INCOMPLETE — do not treat $DEST as a usable checkpoint. Fix the cause above and re-run;"
  echo "this script is safe to re-run (existing correct files are simply re-verified, not re-checked for content)."
  exit 1
fi
echo "RESTORE COMPLETE — every manifest-listed file is present at its recorded size."
exit 0
