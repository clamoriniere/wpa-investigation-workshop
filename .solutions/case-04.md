# Case 04 — solution

## Root cause

`spec.maxReplicas` on the WPA is `3`. It was sized for traffic the service has since outgrown, and
nobody revisited it. The metric genuinely needs more replicas than that to come down into the
watermark band, and the controller is capping the replica count at the ceiling it was given.

## Why the report is misleading

The user checked exactly what cases 01-03 taught them to check — `AbleToScale` and `ScalingActive`
— and both are `True`, correctly. That rules out a target problem, a metric-read problem, and (case
03's lesson) a dry-run problem. None of those is the fault here. The controller is doing precisely
what it was configured to do; the configuration is just wrong for the traffic level.

## How to find it

`kubectl describe wpa case04-app -n wpa-case-04`:

```
Conditions:
  Type            Status  Reason           Message
  AbleToScale     True    ReadyForScale    the last scaling time was sufficiently old as to warrant a new scale
  ScalingActive   True    ValidMetricFound
  ScalingLimited  True    TooManyReplicas  the desired replica count is above the maximum replica count
Status:
  Current Replicas:  3
  Desired Replicas:  3
```

`ScalingLimited=True` is the tell, and it is a third condition beyond the two everybody checks
first — same shape of mistake as case 03, different condition. Note that `Desired Replicas` here is
already clamped to 3; the WPA does not expose "what it would have asked for before capping" in
status, so this condition's presence is the signal, not a number to diff against.

Corroborating signals:

- `spec.maxReplicas: 3` on the object itself — the fix is visible right next to the fault.
- The metric, unaffected by any of this: `avg:wpa_workshop.orders.processing_lag{case:04,...}` sits
  at 180 the entire time, far above the high watermark of 40, and never becomes the story.
- In Datadog, `wpa_controller_restricted_scaling_reason{wpa_name:case04-app}` is set with a
  capping-related reason while this holds.
- `kubectl -n wpa-case-04 get deploy case04-app` shows 3/3 ready — nothing is failing to schedule
  or crash-looping, which rules out a resource-pressure explanation for the plateau.

## The fix

```
kubectl -n wpa-case-04 patch wpa case04-app --type merge -p '{"spec":{"maxReplicas":8}}'
```

Or raise `maxReplicas` in `workspace/case-04/wpa.yaml` and re-apply. Anything at or above 5 is
enough for this metric; 8 leaves headroom rather than trading one tight ceiling for another.

## What should happen next

On the next reconcile the controller computes a proposal above 3, finds it now fits under the new
ceiling, and jumps straight there — `ScaleUpLimitFactor` is unset (0, meaning unlimited) on this
WPA, same as every other case, so there is no per-reconcile step limit slowing this down.
180 metric / 5 replicas = 36, inside the 20-40 band, so it settles at 5 and `ScalingLimited` flips
back to `False` with reason `DesiredWithinRange`. `./case.sh verify 04` requires `currentReplicas
>= 5` for exactly this reason — a fix that still caps below the converged value does not pass.

## The lesson

`maxReplicas` (and `minReplicas`) are capacity assumptions baked in at setup time, and they don't
self-correct as traffic changes — unlike the metric and the watermarks, which the team already
trusts. A capped WPA looks identical to a healthy one on `AbleToScale`/`ScalingActive`; the only
place the ceiling shows up is `ScalingLimited` and the `spec` field sitting right next to it. Read
every condition on the object, not just the two that cover target-reachability and metric-health.
