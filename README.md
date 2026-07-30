# WPA Investigation Workshop

## Goal

This workshop teaches users and maintainers of the WatermarkPodAutoscaler (WPA) controller how to investigate common issues when using a WPA resource to horizontally scale an application.

It focuses on WPA configurations that use Datadog as the metrics provider — either through a `DatadogMetric` CRD or by referencing Datadog metrics directly in the WPA's external metrics configuration.

Most issues covered here also apply to HPA when Datadog is used as the external metrics provider in a Kubernetes cluster.

## What you need

| | |
|---|---|
| CLIs | `kind`, `kubectl`, `helm`, `git`, `docker` |
| Datadog | an API key **and** an APP key, plus access to the org that owns them |
| Docker | around 6 GB of memory available to the daemon |

The APP key is not optional: the external metrics server uses it to query Datadog, and without it every
query is rejected and all the cases fail for the same uninteresting reason.

## Getting started

```bash
export DD_API_KEY=...
export DD_APP_KEY=...
export DD_SITE=datadoghq.com     # datadoghq.eu, us3/us5/ap1.datadoghq.com, ...
export WORKSHOP_NAME=your-name   # optional, defaults to $(whoami)

./setup.sh
```

`setup.sh` creates a single-node kind cluster called `wpa-workshop-$WORKSHOP_NAME`, installs the WPA
controller, the Datadog Operator, and an Agent with the external metrics server enabled, then deploys
every investigation case. It refuses to finish unless `external.metrics.k8s.io` is genuinely serving,
because a broken APIService makes every case look broken for the wrong reason.

Then work through the cases:

```bash
./case.sh list          # every case and where it stands
./case.sh show 01       # the end-user report
./case.sh verify 01     # did you fix it?
./case.sh reset 01      # start over
```

Give any change **about two minutes** before deciding it didn't work. Datadog ingestion, the Cluster
Agent's 30-second external-metrics refresh and the WPA controller's own poll interval all stack up.

## How the cases work

Each case is a namespace containing a deliberately broken WPA and a workload for it to scale. You get
the symptoms the end user reported — never the root cause; working that out from partial information is
the whole exercise.

`cases-tmpl/` holds the templates. `setup.sh` renders them into `workspace/case-NN/`, which is what you
edit (and what is gitignored, so pulling new cases can never clash with a half-finished investigation).
You can also just `kubectl edit` the live objects.

`setup.sh` also writes `workspace/README.md`: the list of cases with their titles and namespaces, and
how to work through them. Start there once the cluster is up.

`solutions/` explains every case. It is plain text on the honour system, and reading it early is the one
way to get nothing out of this.

## Maintaining a workshop

```bash
./update.sh              # pull new cases and component versions, keep the cluster
./update.sh --reset-cases  # ...and restore every case to its original broken state
./delete.sh              # remove the cluster and this participant's Datadog objects
```

`update.sh` leaves cases you have already edited alone by default. `delete.sh` prints exactly what it
will remove and asks before doing it; it is scoped by `workshop_name`, so it will not touch a
colleague's objects in a shared org. Note that metrics already submitted cannot be deleted — and that
`wpa_workshop.app.load` is a custom metric, so a forgotten cluster keeps costing you.

## Running it as a group

Set a different `WORKSHOP_NAME` per participant. It becomes the cluster name and therefore the
`kube_cluster_name` tag on every metric, which is how one dashboard can show everyone's progress side by
side.

## Repository layout

| Path | |
|---|---|
| [setup.sh](setup.sh), [update.sh](update.sh), [delete.sh](delete.sh), [case.sh](case.sh) | the workshop lifecycle |
| [lib/common.sh](lib/common.sh) | shared shell helpers, pinned versions |
| [kind/](kind/), [manifests/](manifests/) | cluster and Datadog Agent configuration |
| [cases-tmpl/](cases-tmpl/) | investigation case templates, rendered into `workspace/` |
| [solutions/](solutions/) | spoilers |
| [workshop-plan.md](workshop-plan.md) | requirements and the case list |
| [IMPLEMENTATION-PLAN.md](IMPLEMENTATION-PLAN.md) | how this repo is built, and the upstream facts it relies on |
