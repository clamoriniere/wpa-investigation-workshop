---
name: new-case
description: Author a new WPA investigation case for this workshop — creates cases-tmpl/case-NN/ (case.env, app.yaml, wpa.yaml, README.md, optional loadgen.yaml) plus .solutions/case-NN.md, following the conventions the existing cases and case.sh rely on. Use when asked to add, write, or design a workshop case.
---

# Adding an investigation case

A case is a directory of manifests that deploys a *plausibly broken* WPA setup, plus the
metadata `case.sh` needs to tell whether someone has fixed it. Nothing registers a case
anywhere: `all_case_ids()` globs `cases-tmpl/case-*/`, so creating the directory is what
adds it.

## Before writing anything

Settle these three, in this order. Getting the fault wrong makes everything downstream
busywork.

1. **The fault.** One root cause, reachable from `kubectl describe wpa` plus Cluster Agent
   logs. It must be a *realistic misconfiguration* — something a person would actually
   write — not a typo nobody makes twice. Check the existing cases so the new one teaches
   something they don't: case 01 is target-side (`AbleToScale=False`), case 02 is
   metric-side (`ScalingActive=False` / `FailedGetExternalMetric`).
2. **The observable signature.** Which condition goes False, with which reason, and what
   the participant sees that misleads them. If you cannot name the condition, the case is
   not diagnosable and needs rethinking.
3. **The arithmetic.** What the metric will really be, and what replica count a *fixed*
   WPA converges to. Do this on paper before writing the watermarks — see Watermarks below.

## Files

`cases-tmpl/case-NN/`, where NN is zero-padded and one past the current highest. The
directory name carries the number and nothing else: a descriptive slug in the path would
spoil the case before it's opened.

| File | Required | Notes |
|---|---|---|
| `case.env` | yes | metadata sourced by `case.sh` |
| `app.yaml` | yes | the namespace **and** the target deployment |
| `wpa.yaml` | yes | the WatermarkPodAutoscaler, carrying the fault |
| `README.md` | yes | the end-user report; the participant's only briefing |
| `loadgen.yaml` | only if the case needs a custom metric | DogStatsD sender, see case 01 |
| `.solutions/case-NN.md` | yes | write it at the same time, not later |

`render_case()` renders every `*.yaml` in the directory plus `README.md`, then `apply_case()`
runs `kubectl apply -f` on the whole rendered directory. So any `.yaml` you drop in is
deployed, and files are applied together — put the `Namespace` first in `app.yaml`.

## Templating

Templates are rendered by `sed` over a fixed token set. Only these exist; anything else
stays literal and ships broken:

`__WORKSHOP_NAME__` `__CLUSTER_NAME__` `__DD_SITE__` `__CASE_ID__` `__CASE_NAMESPACE__`

Rules that follow from `sed`-based rendering:

- Templates must be valid YAML *unrendered* too — quote tokens used as values where a bare
  `__TOKEN__` would be ambiguous (`workshop-case: "__CASE_ID__"`).
- Never hardcode the namespace; it is always `__CASE_NAMESPACE__` (`wpa-case-NN`).
- Any metric tagged per-participant must carry `workshop_name:__WORKSHOP_NAME__`, otherwise
  two people running the workshop against the same Datadog org read each other's data.

## `case.env`

```bash
CASE_TITLE="One line, states the symptom, gives away nothing"
WPA_NAME="caseNN-app"
DEPLOYMENT="caseNN-app"
EXPECTED_MIN_REPLICAS=2
DD_QUERY='avg:metric.name{tag:__CASE_ID__}.rollup(30)'
```

- `CASE_TITLE` is the symptom as the *user* would phrase it. It appears in `./case.sh list`,
  so "A WPA that never scales, on a metric that is clearly hot" — not "wrong scaleTargetRef".
- `EXPECTED_MIN_REPLICAS` is the shared success criterion. Justify it in a comment with the
  actual arithmetic.
- `DD_QUERY` is the query the Cluster Agent builds **once the case is correct**: labels
  sorted alphabetically, `avg` aggregator, `.rollup(30)`. It is printed only after the case
  is solved, because for a metric-side case it is the answer verbatim. Keep it accurate —
  that is the reason it is withheld.

## `wpa.yaml`

Start from `cases-tmpl/case-01/wpa.yaml` and keep these unless the case is specifically
about one of them:

- **`algorithm: average`.** Non-negotiable for a fixed-value metric. With the default
  `absolute` the WPA compares the raw metric to the watermark on every reconcile, the value
  never falls as replicas are added, and it walks straight to `maxReplicas` instead of
  converging — which makes the case look broken after it has been fixed.
- `tolerance: "0.01"`, `readinessDelaySeconds: 10`, and 30s forbidden windows. The short
  windows exist so a fix visibly takes effect inside a workshop session.
- `labels.workshop-case: "__CASE_ID__"`.

### Watermarks

Pick them from the measured metric value, then verify the converged state lands *inside* the
band. With `average`, one replica sees `V`, two see `V/2`:

- case 01: V=90, band 30–60. `ceil(1 × 90/60) = 2`; 90/2 = 45, inside → settles at 2.
- case 02: idle nginx ≈ 12.7 MB, band 4M–8M. 12.7/2 = 6.35M, inside → settles at 2.

If `V/2` falls below the low watermark the WPA scales back down and the case oscillates. If
the band is far too low it runs to `maxReplicas`. Write the numbers into a comment.

## `README.md` — the user report

The hardest file. Structure, mirroring case 01:

- `## What the user reported` — a blockquote in the voice of a competent colleague. Their
  evidence must be **true and irrelevant**: the misdirection comes from what they chose to
  look at, never from them lying.
- `## What you are given` — table: namespace, application, autoscaler, metric, working copy.
- `## Your goal` — plain sentence plus `./case.sh verify __CASE_ID__`.
- `## Rules of the game` — what is off-limits (usually the load generator and watermarks:
  the metric and thresholds are what the user wants), and the reminder that the Cluster Agent
  refreshes external metrics every 30s so changes take a couple of minutes to show.

Do not name the broken field, the condition that is False, or the resource holding the fault.

## `.solutions/case-NN.md`

Sections, following case 01: Root cause / Why the report is misleading / How to find it (real
`describe` output and corroborating signals, including the Datadog `wpa_controller_*` series)
/ The fix (a copy-pasteable `kubectl patch`, plus the edit-and-reapply route) / What should
happen next / The lesson. Add the case to the list at the bottom of `.solutions/README.md`.

## Verify criterion

`check_case()` in `case.sh` ANDs three things: `AbleToScale=True`, `ScalingActive=True`, and
`currentReplicas >= EXPECTED_MIN_REPLICAS`. If the new case's success has a different shape —
scaling *down*, a `DatadogMetric` that must become `Valid`, a condition this ignores — do not
weaken the shared check. Add a `check.sh` in the case directory and have `check_case()` prefer
it; `wpa_condition_status`, `wpa_condition_reason` and `wpa_field` live in `lib/common.sh`
precisely so such a check can read the object without copying anything.

## Checklist before calling it done

```bash
# 1. every template is valid YAML unrendered and rendered
for f in cases-tmpl/case-NN/*.yaml; do python3 -c 'import sys,yaml;list(yaml.safe_load_all(open(sys.argv[1])))' "$f"; done
bash -c 'source lib/common.sh; load_state; render_case NN'
for f in workspace/case-NN/*.yaml; do python3 -c 'import sys,yaml;list(yaml.safe_load_all(open(sys.argv[1])))' "$f"; done

# 2. no unrendered tokens survived
grep -rn '__[A-Z_]*__' workspace/case-NN/ && echo 'UNRENDERED TOKEN'

# 3. deploy it into the running cluster and confirm it fails the intended way
./update.sh            # new case, so it is deployed without touching the others
sleep 120              # external metrics latency; anything sooner is not evidence
./case.sh verify NN    # must report NOT solved, on the intended condition

# 4. confirm it is solvable: apply the fix from .solutions/case-NN.md, wait, re-verify
./case.sh verify NN    # must report solved
./case.sh reset NN     # and must go back to broken
```

A case that has not been through steps 3 and 4 against a live cluster is not finished. The
one failure mode that ruins a workshop is a case that is broken for a reason other than the
one it teaches.

## Housekeeping

- `workspace/README.md` regenerates itself; do not edit it.
- `./case.sh list`, `show`, `verify`, `reset` need no changes — all data-driven.
- Adding a case to the repo is enough; `update.sh` deploys any case with no workspace
  directory and tears down namespaces for cases that disappear.
