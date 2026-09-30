#!/usr/bin/env bash
# check-alert-satisfiability.sh — for every alert in a shipped PrometheusRule, confirms every
# metric name its expression references is actually registered on this cluster's Prometheus.
#
# WHY THIS EXISTS. Valid PromQL syntax is not the same as a query that can ever return data. A
# rule built against a metric name that is not emitted on this platform (a typo, a renamed
# metric, a metric this storage class or runtime does not expose) is syntactically fine and
# semantically dead — it will never fire, and it looks identical to a healthy, quiet alert. This
# script checks every shipped alert expression against the cluster's Prometheus for exactly that.
#
# THIS IS NOT AN "IS THE ALERT FIRING CORRECTLY" CHECK. An alert whose condition is simply not
# true right now (no failed jobs, no low headroom) is healthy, and a state-conditional metric
# (one that only emits a series while something is actually in that state, like
# kube_pod_container_status_waiting_reason) can legitimately have zero current series on an idle
# cluster. Neither is a finding. This script checks a narrower, structural thing instead: does
# Prometheus know about this metric name AT ALL, via its declared HELP/TYPE metadata rather than
# an instant count of current series — a metric with a real collector registered for it reports
# metadata regardless of whether any series exists right now; a typo'd or genuinely unemitted
# metric name reports none.
#
# Usage: ./check-alert-satisfiability.sh [-n NAMESPACE] [-r RULE_NAME]
#   -n  namespace the PrometheusRule is applied in (default: ml-training)
#   -r  PrometheusRule object name (default: fbda-pipeline-alerts)
#
# Exit codes: 0 every referenced metric exists · 1 at least one alert references a metric
# CONFIRMED not to exist on this cluster · 2 cannot check (no cluster connection, rule not
# found, no platform Prometheus pod, python3 missing, the alert-expression extractor itself
# crashed, OR at least one metric query could not run at all — e.g. curl missing inside the
# Prometheus pod — with no metric confirmed dead; that is inconclusive, not a failure, and is
# reported as such rather than folded into exit 1)

set -uo pipefail
NS="ml-training"
RULE="fbda-pipeline-alerts"
while getopts ":n:r:h" opt; do
  case "$opt" in
    n) NS="$OPTARG" ;;
    r) RULE="$OPTARG" ;;
    h) echo "usage: $0 [-n NAMESPACE] [-r RULE_NAME]"; exit 0 ;;
    *) echo "usage: $0 [-n NAMESPACE] [-r RULE_NAME]" >&2; exit 2 ;;
  esac
done

command -v oc >/dev/null 2>&1 && KUBE=oc || KUBE=kubectl
command -v "$KUBE" >/dev/null 2>&1 || { echo "FATAL: neither oc nor kubectl is on PATH." >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is not on PATH." >&2; exit 2; }

RULE_JSON=$("$KUBE" get prometheusrule "$RULE" -n "$NS" -o json 2>/dev/null) || {
  echo "FATAL: PrometheusRule $RULE not found in namespace $NS." >&2; exit 2; }

# kube_* and kubelet_* — every metric this file's rules reference — are collected by the
# PLATFORM Prometheus, not the user-workload stack (see pipeline-alerts-prometheusrule.yaml's own
# header). Querying prometheus-k8s's own local API (inside its pod, port 9090, no external OAuth
# proxy in the way) is sufficient; it does not require reaching Thanos Querier or any route.
PROM_POD=$("$KUBE" get pod -n openshift-monitoring -l app.kubernetes.io/name=prometheus \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[[ -n "$PROM_POD" ]] || { echo "FATAL: no platform Prometheus pod found in openshift-monitoring." >&2; exit 2; }

query_metric_exists() {
  # $1 = metric name. Echoes "1" if this metric is known to Prometheus, "0" if it genuinely is
  # not, "2" if the query itself could not be run (network/exec failure).
  #
  # THIS QUERIES /api/v1/metadata, NOT an instant count(<metric>). kube_pod_container_status_waiting_reason
  # is a real kube-state-metrics gauge that only emits a series while some container actually IS
  # waiting — count() on an idle cluster returns an empty vector for it, indistinguishable from a
  # metric that has never existed. The metadata endpoint reports its HELP/TYPE declaration (which
  # kube-state-metrics registers unconditionally) regardless of whether any series currently
  # exists, which is what "satisfiable in principle" actually means for a state-conditional
  # metric. A genuinely nonexistent metric name returns {"data":{}} here.
  local metric="$1" resp
  resp=$("$KUBE" exec -n openshift-monitoring "$PROM_POD" -c prometheus -- \
      curl -sG --data-urlencode "metric=$metric" http://localhost:9090/api/v1/metadata 2>/dev/null)
  [[ -n "$resp" ]] || { echo 2; return; }
  python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(1 if d.get("data") else 0)
except Exception:
    print(2)
' <<<"$resp"
}

echo "Alert satisfiability for PrometheusRule $RULE (namespace $NS), against $PROM_POD"
echo

# The extraction step (parsing every rule's PromQL expression into candidate metric names) is
# the part that genuinely needs a real parser, not regex-in-bash. It runs once, offline, and
# just prints "alert_name<TAB>metric_name" pairs — the shell loop above only queries Prometheus.
#
# The rule JSON goes through a temp file, not stdin: `python3 -` already consumes stdin to read
# the program text itself, so a `<<<"$RULE_JSON"` here would collide with that and starve
# json.load() of any input — which is exactly the failure mode this comment is warning off.
RULE_JSON_FILE=$(mktemp)
trap 'rm -f "$RULE_JSON_FILE"' EXIT
printf '%s' "$RULE_JSON" > "$RULE_JSON_FILE"
PAIRS=$(python3 - "$RULE_JSON_FILE" <<'PYEOF'
import json, re, sys

with open(sys.argv[1]) as f:
    rule_json = json.load(f)
groups = rule_json.get("spec", {}).get("groups", [])

# PromQL keywords, aggregation operators and built-in functions — never a metric name, wherever
# they appear. This list is deliberately generous: an over-broad denylist can only cause a false
# negative (a real dead metric slips through because its name coincides with a keyword, which
# cannot happen since these are all reserved words), never a false positive.
KEYWORDS = {
    "by", "without", "on", "ignoring", "group_left", "group_right", "and", "or", "unless",
    "offset", "bool",
    "sum", "min", "max", "avg", "group", "stddev", "stdvar", "count", "count_values",
    "bottomk", "topk", "quantile",
    "abs", "absent", "absent_over_time", "ceil", "changes", "clamp", "clamp_max", "clamp_min",
    "day_of_month", "day_of_week", "days_in_month", "delta", "deriv", "exp", "floor",
    "histogram_quantile", "holt_winters", "hour", "idelta", "increase", "irate", "label_join",
    "label_replace", "ln", "log2", "log10", "minute", "month", "predict_linear", "rate",
    "resets", "round", "scalar", "sort", "sort_desc", "sqrt", "time", "timestamp", "vector",
    "year", "avg_over_time", "min_over_time", "max_over_time", "sum_over_time",
    "count_over_time", "quantile_over_time", "stddev_over_time", "stdvar_over_time",
    "last_over_time", "present_over_time",
}
# by/on/without/ignoring/group_left/group_right open a label-name list in parens that follows
# them directly — those identifiers are grouping labels, not metric names, even though they are
# not otherwise reserved words (e.g. `by (namespace, pod)`).
GROUPING_KEYWORDS = {"by", "without", "on", "ignoring", "group_left", "group_right"}

TOKEN_RE = re.compile(r'''
    (?P<string>"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')
  | (?P<bracket>\[[^\]]*\])
  | (?P<duration>(?:\d+(?:ms|s|m|h|d|w|y))+\b)
  | (?P<matchop>=~|!~|==|!=|=)
  | (?P<ident>[a-zA-Z_:][a-zA-Z0-9_:]*)
  | (?P<lbrace>\{) | (?P<rbrace>\})
  | (?P<lparen>\() | (?P<rparen>\))
''', re.VERBOSE)


def candidate_metrics(expr):
    """Return the set of identifiers in a PromQL expression that are plausibly metric names —
    i.e. not a keyword/function, not a label-matcher key inside {}, and not a grouping-label
    inside by(...)/on(...)/etc."""
    tokens = [m for m in TOKEN_RE.finditer(expr)]
    metrics = set()
    brace_depth = 0
    # Stack of bools: True if this paren opened right after a grouping keyword (its contents
    # are label names, not metric names).
    grouping_stack = []
    prev_kind, prev_text = None, None
    for i, m in enumerate(tokens):
        kind = m.lastgroup
        text = m.group()
        if kind == "lbrace":
            brace_depth += 1
        elif kind == "rbrace":
            brace_depth = max(0, brace_depth - 1)
        elif kind == "lparen":
            opened_by_grouping_kw = (prev_kind == "ident" and prev_text in GROUPING_KEYWORDS)
            grouping_stack.append(opened_by_grouping_kw)
        elif kind == "rparen":
            if grouping_stack:
                grouping_stack.pop()
        elif kind == "ident":
            next_kind = tokens[i + 1].lastgroup if i + 1 < len(tokens) else None
            in_grouping_list = bool(grouping_stack) and grouping_stack[-1]
            if brace_depth > 0 and next_kind == "matchop":
                pass  # label-matcher key, e.g. reason=~"..."
            elif in_grouping_list:
                pass  # grouping label, e.g. `by (namespace, pod)`
            elif text in KEYWORDS:
                pass
            else:
                metrics.add(text)
        prev_kind, prev_text = kind, text
    return metrics


pairs = []
for g in groups:
    for r in g.get("rules", []):
        alert = r.get("alert")
        expr = r.get("expr")
        if not alert or not expr:
            continue
        cands = sorted(candidate_metrics(expr))
        if cands:
            for metric in cands:
                pairs.append((alert, metric))
        else:
            # An alert whose expression names zero candidate metrics (e.g. `vector(1) > 0`, or a
            # pure `{__name__=~"..."}` selector) must still surface in the report with an empty
            # metric field. Without this, it never appears in the bash consumer's grouping loop
            # at all — no PASS, no FAIL, just silently absent, which reads as full coverage when
            # it is actually zero coverage for that alert.
            pairs.append((alert, ""))

for alert, metric in pairs:
    print(f"{alert}\t{metric}")
PYEOF
)
PAIRS_STATUS=$?

# The extractor's own exit status matters, separately from whether it produced any output. A
# crash (bad JSON, an unhandled exception) prints nothing to stdout, and empty $PAIRS is exactly
# what a healthy rule with zero alerts would also produce — the two are indistinguishable by
# output alone. $PAIRS_STATUS is checked so that a crash is reported as a crash — with a distinct
# exit code — rather than falling into the "nothing to check" branch below and exiting 0, which
# this script's own header defines as "every referenced metric exists".
if (( PAIRS_STATUS != 0 )); then
  echo "FATAL: the alert-expression extractor (python3) exited $PAIRS_STATUS instead of completing normally." >&2
  echo "  This is a crash, not \"nothing to check\" — no alerts were actually verified. Fix the crash" >&2
  echo "  (rerun with the RULE_JSON_FILE contents to see the traceback) before trusting any result" >&2
  echo "  from this script." >&2
  exit 2
fi

if [[ -z "$PAIRS" ]]; then
  echo "No alert/metric pairs extracted — nothing to check."
  exit 0
fi

declare -A METRIC_EXISTS
FAIL=0
INCONCLUSIVE=0
CURRENT_ALERT=""
ALERT_HAD_MISSING=0
ALERT_HAD_INCONCLUSIVE=0
ALERT_HAD_ANY_METRIC=0

print_alert_verdict() {
  # $1=alert name, $2=had-missing(dead) flag, $3=had-inconclusive flag, $4=had-any-metric flag.
  #
  # A THIRD OUTCOME, NOT JUST PASS/FAIL: an alert whose expression names zero candidate metrics
  # (`vector(1) > 0`, or a pure `{__name__=~"..."}` selector) has nothing to disprove — printing
  # a plain ✓ for it would claim a verification that never actually happened. Use ⊘, a distinct
  # "not applicable" symbol, matching how a structurally-skipped gate is reported elsewhere in
  # this pipeline's own tooling, rather than a plain ✓. The same ⊘ symbol, with different text,
  # also covers an alert that could not be checked at all (case 2 below): that is inconclusive,
  # not a finding, and must never be reported with the ✗ this function reserves for a
  # confirmed-dead metric (case 0).
  if (( $2 )); then
    echo "  ✗ $1 — references at least one metric this Prometheus has never registered"
  elif (( $3 )); then
    echo "  ⊘ $1 — at least one metric could not be queried (exec/network failure); inconclusive, not verified"
  elif (( ! $4 )); then
    echo "  ⊘ $1 — no metric name found in its expression; nothing was checked"
  else
    echo "  ✓ $1"
  fi
}

while IFS=$'\t' read -r alert metric; do
  [[ -z "$alert" ]] && continue
  if [[ "$alert" != "$CURRENT_ALERT" ]]; then
    [[ -n "$CURRENT_ALERT" ]] && print_alert_verdict "$CURRENT_ALERT" "$ALERT_HAD_MISSING" "$ALERT_HAD_INCONCLUSIVE" "$ALERT_HAD_ANY_METRIC"
    CURRENT_ALERT="$alert"
    ALERT_HAD_MISSING=0
    ALERT_HAD_INCONCLUSIVE=0
    ALERT_HAD_ANY_METRIC=0
  fi
  [[ -z "$metric" ]] && continue
  ALERT_HAD_ANY_METRIC=1
  if [[ -z "${METRIC_EXISTS[$metric]+x}" ]]; then
    exists=$(query_metric_exists "$metric")
    METRIC_EXISTS[$metric]="$exists"
  fi
  case "${METRIC_EXISTS[$metric]}" in
    1) : ;;
    0) echo "      metric '$metric' is not registered on this Prometheus (no HELP/TYPE metadata)"; ALERT_HAD_MISSING=1; FAIL=1 ;;
    2) echo "      ⊘ could not query metric '$metric' (exec/network failure) — inconclusive, NOT evidence the metric is dead"; ALERT_HAD_INCONCLUSIVE=1; INCONCLUSIVE=1 ;;
  esac
done <<<"$PAIRS"
[[ -n "$CURRENT_ALERT" ]] && print_alert_verdict "$CURRENT_ALERT" "$ALERT_HAD_MISSING" "$ALERT_HAD_INCONCLUSIVE" "$ALERT_HAD_ANY_METRIC"

echo
if (( FAIL )); then
  echo "RESULT: at least one alert references a metric this Prometheus has never registered. Fix the expression or the metric before shipping it."
  if (( INCONCLUSIVE )); then
    echo "  Separately, at least one other metric could not be checked at all (exec/network failure) —"
    echo "  that one is inconclusive, not a confirmed dead metric; see the ⊘ line(s) above."
  fi
  exit 1
fi
if (( INCONCLUSIVE )); then
  echo "RESULT: inconclusive — at least one metric could not be queried (exec/network failure inside the"
  echo "  Prometheus pod, e.g. curl missing on PATH). No metric was confirmed dead; this means the check"
  echo "  itself could not run to completion, not that shipping is unsafe. Fix the tooling and re-run."
  exit 2
fi
echo "RESULT: every alert's referenced metrics are registered on this Prometheus."
exit 0
