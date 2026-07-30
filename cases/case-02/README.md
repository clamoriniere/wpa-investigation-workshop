# Case 02

## What the user reported

> Different team, different problem. Our service `case02-app` in `__CASE_NAMESPACE__` autoscales on
> memory usage. We didn't want to bother with a DatadogMetric object, so we put the Datadog metric
> name straight into the WPA spec with the tags that match our pods. The WPA has been sitting at one
> replica since we deployed it and `kubectl describe` says something about not being able to compute
> a replica count. We checked in Datadog and `container.memory.usage` is definitely being collected
> for this namespace — I can graph it. So why can't the autoscaler read it?

## What you are given

| | |
|---|---|
| Namespace | `__CASE_NAMESPACE__` |
| Application | `deployment/case02-app` |
| Autoscaler | `watermarkpodautoscaler/case02-app` |
| Metric | `container.memory.usage`, collected by the node Agent |
| Working copy | `workspace/case-__CASE_ID__/` |

## Your goal

Get the WPA reading the metric so it scales `case02-app`. Then:

```
./case.sh verify __CASE_ID__
```

## Hints on where to look

This case has no `DatadogMetric` object of its own — the metric name is in the WPA spec directly. It
is worth knowing what the Cluster Agent does with that: it builds a Datadog query out of the metric
name and the selector labels, and tracks it in a generated `DatadogMetric` in its own namespace whose
name starts with `dcaautogen-`. Those objects have a status, and the status has conditions.

Give any change a couple of minutes: 30s for the Cluster Agent's refresh, plus the controller's own
poll interval.
