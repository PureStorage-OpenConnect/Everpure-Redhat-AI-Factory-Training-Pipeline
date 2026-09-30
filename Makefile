# Makefile — the checks and the apply path, in the order you actually need them.
#
#   make preflight                 does this cluster satisfy the contract? read-only, fails fast
#   make validate                  every overlay renders and passes schema validation
#   make render PHASE=30-pipeline  print one rendered phase (pipe to less, or to a file)
#   make apply-phase PHASE=30-pipeline
#                                  apply one phase — the ONLY target that writes to a cluster
#   make validate-train-configmap  the training source and its ConfigMap have not drifted
#   make check-alerts              every shipped alert's metric names are real, against a live cluster
#
# OVERLAY selects which overlay is used; it defaults to the example one you are meant to copy.
#   make validate OVERLAY=overlays/mine
#
# There is NO CI on this repository. Nothing runs these for you.

OVERLAY  ?= overlays/example
NAMESPACE ?= ml-training
PHASE    ?=
TRAIN_SRC := train/train_qwen3_deepspeed.py
TRAIN_CM  := base/30-pipeline/train-code-configmap.yaml

KUBECTL := $(shell command -v oc 2>/dev/null || command -v kubectl 2>/dev/null)

.PHONY: help preflight validate render apply-phase validate-train-configmap check-alerts

help:
	@echo "preflight                     — read-only contract check against the current cluster"
	@echo "validate                      — render + schema-validate every phase of $(OVERLAY)"
	@echo "render PHASE=30-pipeline      — print one rendered phase"
	@echo "apply-phase PHASE=30-pipeline — apply one phase (WRITES to the cluster)"
	@echo "validate-train-configmap      — training source vs its ConfigMap"
	@echo "check-alerts                  — every fbda-pipeline-alerts metric name is real, against a live cluster"

preflight:
	@./preflight.sh -n $(NAMESPACE)

# Renders every phase, then schema-validates the BUILT-IN kinds.
#
# WHAT THIS DOES NOT CHECK, said plainly rather than implied: CRD kinds — RayJob, ClusterQueue,
# Sensor, StorageCluster, PrometheusRule and the rest — are SKIPPED. kubeconform has no schema for
# a CRD unless you give it one, and this repository deliberately ships none: validating a CRD
# against a schema that does not match your installed CRD version is worse than not validating it,
# because it reports Valid. To cover them, extract the schemas from YOUR cluster's CRDs and pass
# -schema-location. The count below tells you how many kinds went unchecked, so the gap is visible
# rather than silent.
validate:
	@fail=0; tmp=$$(mktemp -d); \
	for d in $(OVERLAY)/*/; do \
	  p=$$(basename $$d); \
	  if ! $(KUBECTL) kustomize $$d >$$tmp/out.yaml 2>$$tmp/err.txt; then \
	    echo "FAIL  $$p — does not render"; head -3 $$tmp/err.txt; fail=1; continue; \
	  fi; \
	  if command -v kubeconform >/dev/null 2>&1; then \
	    kubeconform -strict -ignore-missing-schemas -summary <$$tmp/out.yaml >$$tmp/res.txt 2>&1; kc_rc=$$?; \
	    inv=$$(sed -n 's/.*Invalid: \([0-9]*\).*/\1/p' $$tmp/res.txt); \
	    errs=$$(sed -n 's/.*Errors: \([0-9]*\).*/\1/p' $$tmp/res.txt); \
	    skip=$$(sed -n 's/.*Skipped: \([0-9]*\).*/\1/p' $$tmp/res.txt); \
	    if grep -q 'failed downloading schema' $$tmp/res.txt; then \
	      echo "FAIL  $$p — schema DOWNLOAD failed (no egress?), not a manifest defect"; \
	      grep 'failed downloading schema' $$tmp/res.txt | head -3; fail=1; continue; \
	    fi; \
	    if [ -n "$$inv" -o -n "$$errs" ] && [ "$${inv:-0}" != "0" -o "$${errs:-0}" != "0" ]; then \
	      echo "FAIL  $$p — schema validation (Invalid: $$inv, Errors: $$errs)"; \
	      grep -v '^Summary:' $$tmp/res.txt | head -3; fail=1; continue; \
	    elif [ $$kc_rc -ne 0 ]; then \
	      echo "FAIL  $$p — kubeconform exited $$kc_rc before producing a usable Summary line"; \
	      tail -5 $$tmp/res.txt; fail=1; continue; \
	    fi; \
	    echo "ok    $$p — renders, built-in kinds valid ($${skip:-0} CRD kind(s) skipped)"; \
	  else \
	    echo "ok    $$p — renders (kubeconform not installed; NO schema checking happened)"; \
	  fi; \
	done; rm -rf $$tmp; \
	if [ $$fail -ne 0 ]; then echo; echo "validate FAILED"; exit 1; fi; \
	echo; echo "validate passed for $(OVERLAY) — note the skipped counts: those are CRD kinds, unchecked."

render:
	@test -n "$(PHASE)" || { echo "usage: make render PHASE=30-pipeline"; exit 2; }
	@$(KUBECTL) kustomize $(OVERLAY)/$(PHASE)

# The only target that writes. Phases are applied in order — 00, 10, 20, 30 — and 40/50 are opt-in;
# see the README. Applying 00-platform REBOOTS NODES via the MachineConfigPool rollout WHEN THE
# px-storage POOL HAS MEMBERS TO RECONFIGURE. On a fresh install the pool has zero members, so
# nothing reboots; see base/00-platform/machineconfigpool-px-storage.yaml.
apply-phase:
	@test -n "$(PHASE)" || { echo "usage: make apply-phase PHASE=30-pipeline"; exit 2; }
	@echo "Applying $(OVERLAY)/$(PHASE) — this WRITES to the current cluster context:"
	@$(KUBECTL) config current-context
	@$(KUBECTL) apply -k $(OVERLAY)/$(PHASE)

validate-train-configmap:
	@echo "Checking that $(TRAIN_CM) matches $(TRAIN_SRC)..."
	@tmp=$$(mktemp); \
	 RAW=$$($(KUBECTL) create configmap train-code \
	    --from-file=train_qwen3_deepspeed.py=$(TRAIN_SRC) \
	    --dry-run=client -o yaml 2>$$tmp); rc=$$?; \
	 if [ $$rc -ne 0 ]; then \
	   echo "FAIL: kubectl/oc not found or errored — this is a tooling problem, not a ConfigMap"; \
	   echo "diff. Nothing was compared. Underlying error:"; \
	   cat $$tmp; \
	   rm -f $$tmp; \
	   exit 1; \
	 fi; \
	 rm -f $$tmp; \
	 EXPECTED=$$(printf '%s\n' "$$RAW" | grep -A999999 "^data:" | tail -n +2); \
	 ACTUAL=$$(grep -A999999 "^data:" $(TRAIN_CM) | tail -n +2); \
	 if [ "$$EXPECTED" = "$$ACTUAL" ]; then \
	   echo "OK: ConfigMap is in sync with source file."; \
	 else \
	   echo "FAIL: ConfigMap is OUT OF SYNC with $(TRAIN_SRC)"; \
	   echo "Run: $(KUBECTL) create configmap train-code --from-file=train_qwen3_deepspeed.py=$(TRAIN_SRC) --dry-run=client -o yaml > $(TRAIN_CM)"; \
	   echo "Then manually restore the file header comment lines at the top."; \
	   exit 1; \
	 fi

check-alerts:
	@./scripts/check-alert-satisfiability.sh -n $(NAMESPACE)
