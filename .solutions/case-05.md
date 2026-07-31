# Case 05 — solution

## Root cause

`spec.minReplicas` on the WPA is `4`, left over from sizing a load test that has long since ended.
It is not a bug in the controller — the WPA is enforcing exactly the floor it was told to enforce.
The metric wants far fewer replicas than that, and `minReplicas` wins every time.

## Why the report is misleading

There is no error to find, and the user is right that there isn't one. `AbleToScale` and
`ScalingActive` are `True` because the controller isn't failing at anything — it computed a low
desired replica count from the (correctly low) metric, then clamped it up to the floor it was
given, exactly as designed. The report's confusion ("we're not sure what we're even looking for")
is the honest state of someone who has, correctly, ruled out every condition-based fault the
workshop has taught so far.

## How to find it

`kubectl describe wpa case05-app -n wpa-case-05`:

```
Conditions:
  Type          Status  Reason           Message
  AbleToScale   True    ReadyForScale    the last scaling time was sufficiently old as to warrant a new scale
  ScalingActive True    ValidMetricFound
Status:
  Current Replicas:  4
  Desired Replicas:  4
Spec:
  Min Replicas:  4
  Max Replicas:  6
```

Nothing here is `False`. The fault is in `spec.minReplicas` sitting right next to a `status` that
matches it exactly — `currentReplicas == desiredReplicas == minReplicas` is the pattern to notice:
the controller isn't being prevented from reaching a lower number, it never proposes one in the
first place, because anything below the floor gets normalized up before it is ever acted on.

Corroborating signals:

- The metric is genuinely low: `avg:wpa_workshop.checkout.queue_depth{case:05,...}` sits at 5,
  under the low watermark of 20, the entire time — the user is right that it looks fine.
- `kubectl -n wpa-case-05 describe wpa case05-app` shows no `Scaling` events at all after the
  initial startup — a WPA sitting exactly at its floor has nothing left to decide.
- In Datadog, `wpa_controller_min_replicas{wpa_name:case05-app}` reads `4`, next to
  `wpa_controller_value` reading `5` — two flat lines that explain each other once plotted
  together.

## The fix

```
kubectl -n wpa-case-05 patch wpa case05-app --type merge -p '{"spec":{"minReplicas":1}}'
```

Or lower `minReplicas` in `workspace/case-05/wpa.yaml` and re-apply.

## What should happen next

On the next reconcile the floor no longer clamps the proposal, and the deployment scales down.
5/1 = 5 is still below the low watermark of 20, so a single replica is exactly where this metric
settles — there is nothing pulling it back up. `./case.sh verify 05` uses this case's own
`check.sh` rather than the shared one: success here is `currentReplicas <= 1`, the opposite
direction from every other case, because the broken state (4) already satisfies any floor-style
check trivially.

## The lesson

`minReplicas` and `maxReplicas` are not safety rails that only matter at the edges — they are hard
floors and ceilings the controller enforces every single reconcile, silently, with no condition
dedicated to announcing it. A WPA parked exactly at one of them, with matching `current` and
`desired` in `status`, is doing its job perfectly; the question to ask is whether that job
description is still the right one for today's traffic. Compare `spec.minReplicas`/`maxReplicas`
against what the metric would actually ask for before trusting `AbleToScale`/`ScalingActive` to
have told the whole story.
