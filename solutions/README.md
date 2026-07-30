# Solutions — spoilers ahead

Every file in this directory gives away the root cause of a case. They are in plain text on the
honour system: nothing stops you reading them, but a case you read the answer to is a case you didn't
learn anything from.

If you are stuck, the order that usually unblocks people is:

1. `kubectl describe wpa <name> -n <namespace>` — read the conditions, not just the events. `AbleToScale`
   and `ScalingActive` tell you two different things, and the reason strings are specific.
2. `kubectl -n datadog logs deployment/datadog-cluster-agent` — anything about the external metrics
   provider, queries, or the API.
3. `kubectl get datadogmetric -A` — including the generated `dcaautogen-*` ones, and their conditions.
4. `kubectl -n datadog exec deployment/datadog-cluster-agent -- agent status` — the external metrics
   section distinguishes horizontal from watermark autoscalers.
5. The metric itself, in Datadog: does the exact query the Cluster Agent builds actually return
   points?

- [Case 01](case-01.md)
- [Case 02](case-02.md)
