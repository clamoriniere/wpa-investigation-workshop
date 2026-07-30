# Case 01 — solution

## Root cause

`spec.scaleTargetRef.name` on the WPA is `case01-ap`. The deployment is called `case01-app`. The WPA
is pointing at an object that does not exist, so it never gets a scale subresource to act on, and the
metric — which is genuinely fine — is irrelevant.

## Why the report is misleading

The user's reasoning is sound and their evidence is real: the metric is at 90, the high watermark is
60, and the metric is visible in Datadog. All of that is true and none of it matters. It is worth
noticing how much of the reported evidence is about the *metric* while the failure is entirely on the
*target* side.

## How to find it

`kubectl describe wpa case01-app -n wpa-case-01` shows:

```
Conditions:
  Type          Status  Reason              Message
  AbleToScale   False   FailedProcessWPA    Error happened while processing the WPA
  ScalingActive False   FailedProcessWPA
Events:
  Warning  FailedProcessWPA  ... could not get scale for the GV apps/v1 ... scale not found
```

`AbleToScale=False` is the tell. It means the controller could not resolve or update the target at
all, which is a different failure from `ScalingActive=False` (that one is about the metric). Reason
`FailedProcessWPA` plus a "scale not found" event points at `scaleTargetRef`.

Corroborating signals:

- `kubectl get deploy -n wpa-case-01` — no `case01-ap` exists, only `case01-app` and the load generator.
- In Datadog, `wpa_controller_conditions{condition:able_to_scale,wpa_name:case01-app}` is `0`.
- The controller requeues every 10s in this state (`scaleNotFoundRequeueDelay`) rather than the usual
  1s, so the events repeat on a slow, regular beat.

## The fix

```
kubectl -n wpa-case-01 patch wpa case01-app --type merge \
  -p '{"spec":{"scaleTargetRef":{"name":"case01-app"}}}'
```

Or fix the name in `workspace/case-01/wpa.yaml` and re-apply.

## What should happen next

Within a poll interval or two, `AbleToScale` flips to `True` with reason `SucceededGetScale`, then the
metric at 90 against a high watermark of 60 gives a proposal of `ceil(1 * 90 / 60) = 2` replicas, and
the deployment scales up. It then stays there: the WPA uses `algorithm: average`, so the next
reconcile compares 90/2 = 45 against the 30–60 band and finds it already inside.
`./case.sh verify 01` checks exactly that.

## The lesson

`AbleToScale` and `ScalingActive` are two independent questions: "can I touch the target?" and "can I
read the metric?". Always read both before deciding whether an autoscaling problem is a metrics
problem. Also note that a WPA is namespaced and must live in the same namespace as its target — a
missing target and a target in the wrong namespace look identical in the conditions.
