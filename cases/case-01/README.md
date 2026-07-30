# Case 01

## What the user reported

> We run a small web app, `case01-app`, in the `__CASE_NAMESPACE__` namespace, and we put a
> WatermarkPodAutoscaler on it last week. The load metric we autoscale on has been sitting around 90
> for a while now and our high watermark is 60, so I would expect the WPA to add replicas. It hasn't
> moved — we're still on a single pod. I can see the metric fine in Datadog, so the data is
> definitely there. The WPA object exists, `kubectl get wpa` shows it. What are we missing?

## What you are given

| | |
|---|---|
| Namespace | `__CASE_NAMESPACE__` |
| Application | `deployment/case01-app` |
| Autoscaler | `watermarkpodautoscaler/case01-app` |
| Metric | `wpa_workshop.app.load`, submitted by `deployment/case01-loadgen` |
| Working copy | `workspace/case-__CASE_ID__/` |

## Your goal

Get the WPA to scale `case01-app` up. Then:

```
./case.sh verify __CASE_ID__
```

## Rules of the game

Edit the manifests in `workspace/case-__CASE_ID__/` and re-apply them, or edit the live objects with
`kubectl edit`. Don't change the load generator or the watermarks — the metric is correct and the
thresholds are the ones the user wants.

Remember the pipeline delay: the Cluster Agent refreshes external metrics every 30s and the WPA
controller polls on its own interval, so give any change a couple of minutes before deciding it
didn't work.
