# Case 02 — solution

## Root cause

The WPA's `metricSelector.matchLabels` contains `kube_container_name: case02-app`. That tag value does
not exist: the container inside the pod is named `web`, not `case02-app`. The other two labels
(`kube_namespace`, `kube_deployment`) are correct, so the metric *is* being collected — but the query
built from all three labels together matches no series and returns nothing.

## Why the report is misleading

The user checked that `container.memory.usage` exists for the namespace, and it does. Their mistake is
assuming the container is named after the deployment, which is a very common assumption and almost
never enforced.

## How to find it

`kubectl describe wpa case02-app -n wpa-case-02`:

```
Conditions:
  Type          Status  Reason                    Message
  AbleToScale   True    SucceededGetScale         the WPA controller was able to get the target's current scale
  ScalingActive False   FailedGetExternalMetric   the WPA was unable to compute the replica count: ...
Events:
  Warning  FailedGetExternalMetric        unable to get external metric wpa-case-02/container.memory.usage/...
  Warning  FailedComputeMetricsReplicas
```

`AbleToScale=True` with `ScalingActive=False` is the opposite shape from case 01: the target is fine,
the metric is not.

The precise reason is on the Cluster Agent side. Because the metric name is in the WPA spec rather than
in a `DatadogMetric` object, the Cluster Agent generates one for the query it built:

```
kubectl get datadogmetric -n datadog
# dcaautogen-<hash>

kubectl describe datadogmetric -n datadog dcaautogen-<hash>
# Query:   avg:container.memory.usage{kube_container_name:case02-app,kube_deployment:case02-app,kube_namespace:wpa-case-02}.rollup(30)
# Conditions:
#   Valid   False
#   Error   True   Unable to fetch data from Datadog
#          ... reason: missing result from reply ...
```

That `Query:` line is the single most useful thing in this case — it shows exactly what was asked of
Datadog, tags and all. Pasting it into a Datadog notebook returns no points, which localises the fault
to the tags rather than the metric.

Then confirm which tag is wrong by asking Datadog what tag values actually exist, or locally:

```
kubectl get pod -n wpa-case-02 -l app=case02-app \
  -o jsonpath='{.items[0].spec.containers[*].name}'
# web
```

## The fix

Either correct the value:

```yaml
        metricSelector:
          matchLabels:
            kube_namespace: wpa-case-02
            kube_deployment: case02-app
            kube_container_name: web
```

or drop the `kube_container_name` label entirely — `kube_namespace` + `kube_deployment` already scope
the query to this application. Dropping it is arguably the better fix: it is one fewer thing to break
when someone renames a container.

## What should happen next

`ScalingActive` flips to `True` with reason `ValidMetricFound`, `wpa_controller_value` starts reporting
again in Datadog, and the deployment goes to 2 replicas: an idle nginx container sits at about 12.7 MB,
above the 8M high watermark, and `algorithm: average` then compares 12.7/2 = 6.35 MB against the
4M–8M band, which is inside it.

## Notes worth knowing

- A raw `metricName` + `matchLabels` becomes `avg:<name>{k:v,...}.rollup(30)`, with the labels sorted
  alphabetically. The aggregator and rollup are Cluster Agent settings, not something the WPA controls.
- On a metric fetch failure the controller *deletes* the `wpa_controller_value` series for that WPA, so
  in Datadog the symptom is an absent metric rather than a wrong value. Alert on absence, not on value.
- A query returning literal `0` is **not** this failure. With the default `tolerateZero: false` the
  controller keeps the current replica count and `ScalingActive` stays `True` with reason
  `ValidMetricFound`. Only genuinely absent data produces `FailedGetExternalMetric`.
- The generated `dcaautogen-*` objects are garbage collected a few hours after nothing references them.
