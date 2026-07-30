# Workshop plan

This is a working document describing how the workshop will be structured, along with the different investigation test cases.

## Useful documentation links

* WPA controller repository: https://github.com/DataDog/watermarkpodautoscaler
* Datadog external metrics service setup: https://docs.datadoghq.com/containers/guide/cluster_agent_autoscaling_metrics/?tab=datadogoperator
* Agent installation with the Datadog Operator: https://docs.datadoghq.com/getting_started/containers/datadog_operator/

## Workshop requirements

* The workshop must be completable by a user on their own, without an instructor. It should also work as a group session, like a classroom.
* To keep it easy to run, the user should be able to run everything locally with minimal prerequisites. Current thinking:
  - The [kind](https://kind.sigs.k8s.io/) CLI, to create a Kubernetes cluster, and `kubectl`, to interact with it.
  - A Datadog API key and APP key, to configure the Datadog Agent in the workshop cluster. The user also needs access to the Datadog org that owns those keys.
* The workshop should use the Datadog Operator to deploy the Agent and Cluster Agent in the cluster, with the external metrics server feature enabled.
* The focus is on WPAs using Datadog as their external metrics provider. It should cover the case where the user creates and references a `DatadogMetric` CRD to define the autoscaling query, as well as the case where the user sets the Datadog metric name directly in the WPA spec.
* The workshop should ship fake/dummy application manifests that reproduce each issue.
* The workshop should provide as many workloads and WPAs as there are investigation cases, so a user who gets stuck on one can move to another. Cases should still be ordered by complexity, so users naturally start with the simplest.
* Some gamification would be nice. For example, the workshop could create a Datadog dashboard showing how many investigation cases have been resolved, turning it into a friendly competition. An optional setup parameter could be the participant's name, so a single dashboard can show results for several users; the `kube_cluster_name` (set in the Agent deployment configuration) can be the key used to attribute each user's score.
* The workshop should be scripted as much as possible — e.g. a `setup.sh` and a `cleanup.sh`.
* Answers and explanations for each investigation should live in a dedicated file.
* Each investigation case should have:
   - A short description of the reported issue, written from the end user's point of view only — the symptoms they noticed, never the root cause. Finding the root cause from the partial information in the report is the whole point of the exercise. Example reports:
     - "In namespace `foo`, my deployment `bar` isn't scaling up even though I set up a WPA on it. CPU usage is at 90% and my WPA target is 60%, so the WPA controller should have scaled up."
     - "For deployment `baz` in namespace `foo`, every time I redeploy, the WPA scales the replica count back down to 1."
   - A way to verify that the issue has been resolved.
   - A detailed explanation of the issue and its cause, kept in a dedicated folder so users aren't tempted to peek too early.

## Investigation cases

### Case 1:

#### the end user report:

I have create a WPA for my deployment but it doesn't seems to work

#### root cause:

The end user made a typo in the deployment name when configuring the targetRef in the WPA manifest.

### Case 2:

#### the end user report:

I have create a WPA for my deployment but it doesn't seems to work

#### root cause:

The end user use the datadog metric name directly in the external metrics definition in the WPA manifest, The metric exist and data are available for the application, but when defining label selector of the metrics that are use as tag in the metrics query, the user but a tag that is not present on the metric.

#### technical idea to create the issue

we can use a metrics that every application have like: `container.memory.usage`