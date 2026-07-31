# Case 04

## What the user reported

> `case04-app` in `__CASE_NAMESPACE__` autoscales on a processing-lag metric. It did scale up —
> we're not stuck at one replica like some other teams have reported — but it stopped at 3 and the
> lag is still way above our high watermark. `kubectl describe wpa` shows `AbleToScale: True` and
> `ScalingActive: True`, so the controller isn't complaining about anything. It just... stopped
> going up. We haven't touched this WPA's replica limits since we set them up, back when this
> service handled a lot less traffic.

## What you are given

| | |
|---|---|
| Namespace | `__CASE_NAMESPACE__` |
| Application | `deployment/case04-app` |
| Autoscaler | `watermarkpodautoscaler/case04-app` |
| Metric | `wpa_workshop.orders.processing_lag`, submitted by `deployment/case04-loadgen` |
| Working copy | `workspace/case-__CASE_ID__/` |

## Your goal

Get `case04-app` to actually reach a replica count where the metric settles inside its watermark
band, not just "more replicas than before". Then:

```
./case.sh verify __CASE_ID__
```

## Rules of the game

Edit the manifests in `workspace/case-__CASE_ID__/` and re-apply them, or edit the live object with
`kubectl edit`. Don't change the load generator or the watermarks — the metric is correct and the
thresholds are the ones the user wants.

`AbleToScale` and `ScalingActive` are not the only conditions on this object worth reading.

Remember the pipeline delay: the Cluster Agent refreshes external metrics every 30s and the WPA
controller polls on its own interval, so give any change a couple of minutes before deciding it
didn't work.
