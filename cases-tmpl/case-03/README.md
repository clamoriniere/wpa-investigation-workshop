# Case 03

## What the user reported

> We put a WatermarkPodAutoscaler on `case03-app` in `__CASE_NAMESPACE__` a couple of weeks ago,
> scaling on a queue-depth metric. It's been sitting at one replica the whole time even though the
> metric is well above our high watermark. I don't think this is a metric problem or a target
> problem though — I ran `kubectl describe wpa case03-app` and both `AbleToScale` and
> `ScalingActive` say `True`, no errors anywhere. The controller clearly agrees it should be
> scaling. So why is the pod count stuck?

## What you are given

| | |
|---|---|
| Namespace | `__CASE_NAMESPACE__` |
| Application | `deployment/case03-app` |
| Autoscaler | `watermarkpodautoscaler/case03-app` |
| Metric | `wpa_workshop.queue.depth`, submitted by `deployment/case03-loadgen` |
| Working copy | `workspace/case-__CASE_ID__/` |

## Your goal

Get the WPA to actually scale `case03-app` up. Then:

```
./case.sh verify __CASE_ID__
```

## Rules of the game

Edit the manifests in `workspace/case-__CASE_ID__/` and re-apply them, or edit the live object with
`kubectl edit`. Don't change the load generator or the watermarks — the metric is correct and the
thresholds are the ones the user wants.

`kubectl describe wpa` shows more than two conditions — read all of them, not just the two you
already checked last time. `kubectl get wpa` also has a column that answers this in about one
second.

Remember the pipeline delay: the Cluster Agent refreshes external metrics every 30s and the WPA
controller polls on its own interval, so give any change a couple of minutes before deciding it
didn't work.
