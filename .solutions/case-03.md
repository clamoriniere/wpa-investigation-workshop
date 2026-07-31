# Case 03 — solution

## Root cause

`spec.dryRun` on the WPA is `true`. In dry-run mode the controller still computes everything —
resolves the target, reads the metric, works out `desiredReplicas` — but deliberately skips the
call that updates the target's scale subresource. `currentReplicas` never changes no matter how
correct everything else is.

## Why the report is misleading

The user did the right first check from cases 01 and 02 — read `AbleToScale` and `ScalingActive` —
and both are genuinely `True`. That is real evidence, and it rules out a target problem and a metric
problem. It just doesn't rule out the actual fault, because dry-run mode is a third, independent
switch that sits downstream of both those conditions.

## How to find it

`kubectl describe wpa case03-app -n wpa-case-03`:

```
Conditions:
  Type          Status  Reason                     Message
  AbleToScale   True    ReadyForScale              the last scaling time was sufficiently old as to warrant a new scale
  ScalingActive True     ValidMetricFound
  DryRun        True    DryRun mode enabled        Scaling changes won't be applied
Status:
  Current Replicas:  1
  Desired Replicas:  2
```

The `DryRun` condition is easy to miss because it isn't one of the two everybody checks first, and
`kubectl describe` prints it below them. `kubectl get wpa case03-app -n wpa-case-03` surfaces it
directly, in its own `DRY-RUN` column, without needing `describe` at all.

Corroborating signals:

- `Desired Replicas: 2` and `Current Replicas: 1` disagreeing in `status` — the controller computed
  a scaling decision and did not act on it.
- No `Scaling` event in `kubectl describe wpa` history, even though the metric has been above the
  high watermark the whole time. A working WPA emits one the moment it rescales; this one never
  will, however long you wait.
- The Cluster Agent / controller log line is informational only, not a warning: `"DryRun mode:
  scaling change was inhibited"`, easy to scroll past.
- In Datadog, `wpa_controller_dry_run{wpa_name:case03-app}` is `1`.

## The fix

```
kubectl -n wpa-case-03 patch wpa case03-app --type merge -p '{"spec":{"dryRun":false}}'
```

Or remove `dryRun: true` from `workspace/case-03/wpa.yaml` and re-apply.

## What should happen next

On the next reconcile, `AbleToScale` and `ScalingActive` stay `True`, but this time the controller
actually calls the scale subresource: `currentReplicas` catches up to `desiredReplicas` and moves
to 2. From there it stays: 50/2 = 25 sits inside the 20-40 band, so the next reconcile finds nothing
to do. `./case.sh verify 03` checks exactly that — the shared check already covers this case, since
`currentReplicas` failing to reach `EXPECTED_MIN_REPLICAS` is precisely what dry-run mode produces.

## The lesson

`AbleToScale=True` and `ScalingActive=True` mean the controller *would* scale, not that it *will*.
A WPA can agree with you about everything — target, metric, math — and still be configured not to
act. `dryRun` is meant for validating a new WPA's math against real traffic before trusting it, and
it is easy to leave flipped on after that trial run ends. When `status.desiredReplicas` and
`status.currentReplicas` disagree and neither `AbleToScale` nor `ScalingActive` explains why, check
every condition on the object, not just the two that usually matter.
