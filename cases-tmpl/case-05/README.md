# Case 05

## What the user reported

> `case05-app` in `__CASE_NAMESPACE__` handles checkout traffic, which has been quiet for a while —
> nights and weekends it's basically idle. We were expecting the WPA to bring it down to one pod
> overnight to save cost, the way it's supposed to. It never does; it just sits at 4 replicas
> around the clock. `kubectl describe wpa` doesn't show any errors — `AbleToScale` and
> `ScalingActive` are both `True`. The metric itself looks fine too, low the way we'd expect at 2am.
> We're not sure what we're even looking for at this point.

## What you are given

| | |
|---|---|
| Namespace | `__CASE_NAMESPACE__` |
| Application | `deployment/case05-app` |
| Autoscaler | `watermarkpodautoscaler/case05-app` |
| Metric | `wpa_workshop.checkout.queue_depth`, submitted by `deployment/case05-loadgen` |
| Working copy | `workspace/case-__CASE_ID__/` |

## Your goal

Get `case05-app` to actually scale down while the metric is idle. Then:

```
./case.sh verify __CASE_ID__
```

## Rules of the game

Edit the manifests in `workspace/case-__CASE_ID__/` and re-apply them, or edit the live object with
`kubectl edit`. Don't change the load generator or the watermarks — the metric is correct and the
thresholds are the ones the user wants.

Not every fault in this workshop shows up as a `False` condition, or as a condition at all. Some of
them are sitting in plain sight in `spec`, doing exactly what they were configured to do.

Remember the pipeline delay: the Cluster Agent refreshes external metrics every 30s and the WPA
controller polls on its own interval, so give any change a couple of minutes before deciding it
didn't work.
