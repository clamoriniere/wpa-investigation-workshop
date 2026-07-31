# Case 06

## What the user reported

> `case06-app` in `__CASE_NAMESPACE__` scales on queue depth. This WPA has actually worked before —
> it scaled up fine for months. It's been stuck at one replica for the last couple of weeks though,
> and nothing about our deploy process changed in that window. We do know we renamed a queue
> recently as part of some cleanup work, but that was purely a naming thing on our side and
> shouldn't have touched anything in Kubernetes or Datadog.

## What you are given

| | |
|---|---|
| Namespace | `__CASE_NAMESPACE__` |
| Application | `deployment/case06-app` |
| Autoscaler | `watermarkpodautoscaler/case06-app` |
| Metric | queue depth, submitted by `deployment/case06-loadgen` |
| Working copy | `workspace/case-__CASE_ID__/` |

## Your goal

Get the WPA reading the metric so it scales `case06-app`. Then:

```
./case.sh verify __CASE_ID__
```

## Rules of the game

Edit the manifests in `workspace/case-__CASE_ID__/` and re-apply them, or edit the live objects with
`kubectl edit`. Don't change the load generator or the watermarks — the metric is correct and the
thresholds are the ones the user wants.

This case's WPA does not carry a metric name and label selector directly the way some others do —
it points at another object. Find that object and look at what it's asking Datadog for.

Remember the pipeline delay: the Cluster Agent refreshes external metrics every 30s and the WPA
controller polls on its own interval, so give any change a couple of minutes before deciding it
didn't work.
