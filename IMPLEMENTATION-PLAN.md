# Implementation plan

Technical plan for building the WPA investigation workshop. See [workshop-plan.md](workshop-plan.md) for
the workshop requirements and the investigation cases themselves.

## Upstream facts this plan depends on

Verified against the sources listed, because several of them are non-obvious and the setup order
depends on them.

| Fact | Consequence for this repo | Source |
|---|---|---|
| The WPA Helm chart is **not** published to `helm.datadoghq.com`; it only exists in the repo at `chart/watermarkpodautoscaler` | `setup.sh` clones the repo at a pinned tag and installs from the local path | `helm.datadoghq.com/index.yaml` has no `watermarkpodautoscaler` entry |
| The chart's `appVersion` / `image.tag` lag the actual release (`main` pins `v0.9.0` while `v0.11.0` is released) | always pass `--set image.tag=$WPA_VERSION` | `chart/watermarkpodautoscaler/Chart.yaml`, `values.yaml` |
| The WPA chart declares its `datadog-crds` dependency with `condition: lifecycleControl.enabled && datadogCRDs.crds.datadogMonitors`. A Helm `condition` is a comma-separated list of value **paths**, not a boolean expression, so that path never resolves and the subchart is enabled whatever `lifecycleControl` says | **verified on a real cluster**: it installs `datadogmonitors.datadoghq.com` owned by release `wpacontroller`, and the operator chart then dies with `invalid ownership metadata`. `setup.sh` / `update.sh` pass `--set datadogCRDs.crds.datadogMonitors=false` | `chart/watermarkpodautoscaler/Chart.yaml`, Helm dependency-condition docs |
| `kind load docker-image` imports with `--all-platforms`, but Docker Desktop's containerd image store holds only the host platform | side-loading fails with `content digest …: not found`. A plain `docker save` archive fails the same way; `setup.sh` falls back to `docker save --platform $(docker version -f '{{.Server.Os}}/{{.Server.Arch}}')`, which imports cleanly | verified on darwin/arm64 |
| WatermarkPodAutoscaler is not one of the CRDs the orchestrator explorer collects automatically, and the Agent's default ClusterRole cannot read arbitrary custom resources | to see WPA objects in Kubernetes Explorer, both halves are needed: `features.orchestratorExplorer.customResources: [datadoghq.com/v1alpha1/watermarkpodautoscalers]` **and** installing the operator with `--set clusterRole.allowReadAllResources=true`. The operator renders the list into the `datadog-orchestrator-explorer-config` ConfigMap as `crd_collectors`, not into an env var | [Datadog Operator configuration](https://docs.datadoghq.com/containers/datadog_operator/configuration/), verified on the cluster |
| The Cluster Agent's WPA informer binds at startup and needs the WPA CRD to already exist | install the WPA controller **before** the `DatadogAgent`; restart the Cluster Agent if the CRD changes later | WPA controller README |
| The WPA chart already ships an Agent autodiscovery annotation scraping `http://%%host%%:8383/metrics` for `wpa_controller*` | controller metrics reach Datadog with no extra config — this is the data path for the phase 5 scoring dashboard | `chart/.../templates/deployment.yaml` |
| The WPA spec field is `scaleTargetRef`, not `targetRef` | case 01's bug and all docs must use the correct name | `apis/datadoghq/v1alpha1/watermarkpodautoscaler_types.go` |
| WPA uses the legacy `external.metricName` + `external.metricSelector.matchLabels` shape, not HPA v2's nested `metric.name` | case manifests | WPA README |
| A missing `scaleTargetRef` target yields `AbleToScale=False`, reason `FailedProcessWPA`, and `wpa_controller_conditions{condition:able_to_scale}=0` | case 01 verification | `controllers/datadoghq/watermarkpodautoscaler_controller.go` |
| An external metric query returning nothing yields `ScalingActive=False`, reason `FailedGetExternalMetric`; the `wpa_controller_value` series is **deleted** | case 02 verification | same controller + `controllers/datadoghq/metrics.go` |
| A raw `metricName` + `matchLabels` becomes `avg:<name>{k:v,...}.rollup(30)` and the Cluster Agent autogenerates a hidden `dcaautogen-<hash>` DatadogMetric | case 02's failure is visible on that autogen object | `pkg/clusteragent/autoscaling/externalmetrics/utils.go` |
| Cluster Agent needs `externalMetricsServer.wpaController: true` (env `DD_EXTERNAL_METRICS_PROVIDER_WPA_CONTROLLER`), default `false` | `DatadogAgent` manifest | datadog-operator `configuration.v2alpha1.md` |
| kind's kubelet serving cert is not signed by the cluster CA | `global.kubelet.tlsVerify: false`, else container metrics fail and case 02 breaks for the wrong reason | kind + Agent behaviour (not in the Datadog docs) |
| External metrics latency: 30s Datadog refresh + 30s poll + ingest | scripts print a "wait ~2 min" banner; verification must not be judged sooner | `pkg/config/setup/common_settings.go` (`refresh_period: 30`, `max_age: 120`) |
| kind does not share the host Docker image cache | pre-pull + `kind load` the Agent images | kind docs |
| Datadog metric names accept only letters, digits, `_` and `.`; anything else is converted to `_` at intake | the workshop's custom metric is `wpa_workshop.app.load`, not `wpa-workshop.app.load` — a dashed name would be submitted, stored underscored, and never match the WPA's query | Datadog metric naming rules |
| `admissionController.enabled` defaults to **`true`**, and `dogstatsd.unixDomainSocketConfig.enabled` also defaults to `true`, from which the operator derives `agentCommunicationMode: socket` | the mode is set to `service` explicitly: in socket mode the pod gets `DD_DOGSTATSD_URL=unix://…` and **no** `DD_AGENT_HOST`, and busybox's `nc -U` speaks stream while DogStatsD's socket is datagram | operator `datadogagent_default.go`, `feature/admissioncontroller/feature.go` |
| The operator's local Agent service (`<dda-name>-agent`, i.e. `datadog-agent.datadog.svc`) exposes **8125/UDP unconditionally** — `dogstatsd.hostPortConfig.enabled` only changes the *host* port number, not whether the service publishes DogStatsD. The service is hardcoded `internalTrafficPolicy: Local` | no host port is needed: `agentCommunicationMode: service` gets `DD_AGENT_HOST=datadog-agent.datadog.svc.cluster.local`, and `Local` traffic policy keeps the packet on the sender's node, which is what lets origin detection resolve the pod UID | operator `dogstatsd/feature.go` (~L154-184), `GetLocalAgentServiceName` |
| A UDP socket held open against a ClusterIP can be blackholed by a stale conntrack entry after the backing pod restarts (kubernetes#48370) | not a problem here: the load generator opens a **new** `nc -u` socket every 10s, so each send gets a fresh conntrack entry. Any long-lived UDP client would need `hostPort` instead | kubernetes/kubernetes#48370 |
| The admission controller injects `DD_ENTITY_ID` (pod UID) and `DD_EXTERNAL_ENV`; a DogStatsD client turns `DD_ENTITY_ID` into the payload tag `dd.internal.entity_id:<uid>`, which the Agent resolves to the pod's Kubernetes tags | origin detection works over **UDP**, not just UDS — the load generator sends that tag by hand because `nc` is not a client library | agent `comp/dogstatsd/server/impl/enrich.go` |
| Injection is opt-in per pod via the label `admission.datadoghq.com/enabled: "true"` (on the **pod template**, not the Deployment) unless `mutateUnlabelled: true`, and only happens on pod `CREATE` | `mutateUnlabelled: true` is set, so no case has to carry the label; the load generator still fails loudly if `DD_AGENT_HOST` is empty, and `setup.sh` waits for the webhook before deploying cases | agent `admission/common/const.go`, `mutate/config/config.go` |
| The admission controller self-signs its webhook certificate and `failurePolicy` defaults to `Ignore` | no cert-manager on kind, and a down Cluster Agent cannot block pod creation | agent `common_settings.go` |

Two upstream bugs worth knowing while working here: the controller registers duplicate misspelled
`wpa_controller_high_watermak` / `low_watermak` gauges alongside the correct ones, and its
`--metrics-addr` flag is dead code (the port is hardcoded to 8383).

## Repository layout

```
setup.sh                     # create the workshop
update.sh                    # refresh an existing workshop
delete.sh                    # destroy everything (cluster + Datadog objects)
case.sh                      # status / verify / reset / show individual cases
lib/common.sh                # shared shell helpers, sourced by all scripts
kind/kind-config.yaml
manifests/datadog/datadogagent.yaml     # template, placeholders substituted at apply time
cases-tmpl/case-01/{README.md,case.env,app.yaml,loadgen.yaml,wpa.yaml}  # numbered only: a
cases-tmpl/case-02/{README.md,case.env,app.yaml,wpa.yaml}              # slug would spoil the case
.solutions/{README.md,case-01.md,case-02.md}   # dotted so a casual ls does not spoil it
workspace/                   # gitignored: rendered, user-editable copies of each case,
                             # plus a generated README.md indexing them
.cache/                      # gitignored: cloned WPA repo
.workshop-state              # gitignored: what setup.sh created
```

### `cases-tmpl/` vs `workspace/`

Each case directory also carries a `case.env` — `CASE_TITLE`, `WPA_NAME`, `DEPLOYMENT`,
`EXPECTED_MIN_REPLICAS`, `DD_QUERY` — so `case.sh` stays data-driven and adding a case means adding a
directory, not editing a script. The load generator lives with the case that needs it rather than in a
shared `manifests/` file, because its namespace, tags and value are all case-specific.

`cases-tmpl/` holds templates containing `__PLACEHOLDER__` tokens (participant name, cluster name,
site) — the `-tmpl` suffix so that editing there reads as "change every future render" rather than
"change my copy". `setup.sh` renders them into `workspace/case-NN/` and applies from there, and also
writes a generated `workspace/README.md` listing every case and how to work through it. Users edit the files in
`workspace/`, which is why it is gitignored — a `git pull` for new cases can never conflict with
someone's half-finished investigation. `./case.sh reset NN` re-renders a case from its template.

### `.workshop-state`

Written by `setup.sh`, read by `update.sh`, `delete.sh` and `case.sh`:

```sh
WORKSHOP_NAME=cedric
CLUSTER_NAME=wpa-workshop-cedric
DD_SITE=datadoghq.com
OPERATOR_CHART_VERSION=2.24.0
WPA_VERSION=v0.11.0
CASES=01,02
DASHBOARD_ID=
SETUP_AT=2026-07-30T10:00:00Z
```

Its main job is scoping. Several participants may share one Datadog org, so every object the
workshop creates in Datadog is tagged `workshop:wpa-investigation` and
`workshop_name:$WORKSHOP_NAME`, and `delete.sh` only ever removes objects matching this
participant's tags. Without the state file, deletion could not be scoped safely.

## Phase 1 — `setup.sh`

Steps, each gated on the previous one succeeding:

1. **Preflight.** Require `kind`, `kubectl`, `helm`, `git`, `docker` on `PATH`; require `DD_API_KEY`
   and `DD_APP_KEY`; default `DD_SITE=datadoghq.com` and `WORKSHOP_NAME=$(whoami)`. Refuse to run if
   `.workshop-state` already exists (point the user at `update.sh` or `delete.sh`).
2. **Cluster.** `kind create cluster --name wpa-workshop-$WORKSHOP_NAME` with `kind/kind-config.yaml`.
   Then pre-pull the Agent, Cluster Agent and WPA images on the host and `kind load` them, so a slow
   or rate-limited registry does not look like a broken workshop.
3. **WPA controller.** Clone the repo shallowly at `$WPA_VERSION` into `.cache/`, then
   `helm install wpacontroller -n datadog ./chart/watermarkpodautoscaler --set image.tag=$WPA_VERSION`.
   This runs before the Cluster Agent so the CRD exists first.
4. **Operator.** `helm repo add datadog https://helm.datadoghq.com`, then
   `helm install datadog-operator datadog/datadog-operator --version $OPERATOR_CHART_VERSION`. The
   `DatadogAgent` and `DatadogMetric` CRDs come with this chart (`installCRDs: true`), so there is no
   separate CRD step.
5. **Keys + `DatadogAgent`.** Create the `datadog-secret` from the env vars, render
   `manifests/datadog/datadogagent.yaml`, apply it.
6. **Gate.** Block until `kubectl get --raw /apis/external.metrics.k8s.io/v1beta1` answers, with a
   timeout and an actionable error. This is the highest-value check in the script: if the APIService
   is not serving, every case looks broken for a reason that has nothing to do with the case.
7. **Cases.** Render and apply all cases plus their loadgens; write `.workshop-state`; print next
   steps and the "wait ~2 minutes before judging any WPA" banner.

## Phase 2 — metric sources

Both paths from the workshop requirements are covered, with no image to build or publish.

**Synthetic gauge** (case 01): a `busybox` Deployment looping
`printf '%s' "wpa_workshop.app.load:$LOAD_VALUE|g|#<tags>" | nc -u -w1 $DD_AGENT_HOST 8125`, with
`LOAD_VALUE` from a ConfigMap so a case can dial the value.

The pod does not configure its own connection to the Agent, and carries no Datadog label: the
DatadogAgent runs with `mutateUnlabelled: true`, so the admission controller mutates every pod and
injects `DD_AGENT_HOST`, `DD_ENTITY_ID` and `DD_EXTERNAL_ENV`. With `agentCommunicationMode: service`
that host is the Agent's local service, `datadog-agent.datadog.svc.cluster.local`, which already
publishes 8125/UDP — no host port anywhere. The service is `internalTrafficPolicy: Local`, so the
packet is delivered to the Agent on the sender's own node, which is what keeps origin detection
working.

Kubernetes tags come from origin detection rather than from the tag list: `DD_ENTITY_ID` is forwarded
as `dd.internal.entity_id:<pod-uid>`, which the Agent resolves to `kube_namespace`, `kube_deployment`
and so on. A real client library does that step itself; `nc` cannot, so the load generator appends the
tag by hand. Only the two workshop-specific tags — `case` and `workshop_name` — are sent explicitly.

Two consequences worth remembering. Mutation happens on pod **creation** only, so a load generator
that starts before the webhook is registered comes up with no `DD_AGENT_HOST` at all; it checks for
that and exits with an explanation rather than silently sending nothing, and `setup.sh` waits for the
webhook before deploying cases. And `pod_name`-level tags need `dogstatsd.tagCardinality:
orchestrator` — the default `low` cardinality gives namespace- and deployment-level tags, which is all
this workshop queries.

**Real container metric** (case 02): `container.memory.usage`, collected by the node Agent with no
extra configuration. This is the realistic path and the reason `kubelet.tlsVerify: false` matters.

## Phase 3 — the two starter cases

Both use the raw `metricName` form (the `DatadogMetric` CRD path comes in a later case).

**Case 01 — `scaleTargetRef` typo.** The metric name *and* the selector labels are entirely valid and
resolving: the gauge sits at 90 against a `highWatermark` of 60, so the WPA visibly should scale up.
The only defect is a typo in `spec.scaleTargetRef.name`. This makes the symptom maximally confusing —
the metric is demonstrably hot — while the root cause is a one-character diff, which is the right
difficulty for the first case. Signal: `AbleToScale=False` / `FailedProcessWPA`.

**Case 02 — bogus tag in the selector.** `metricName: container.memory.usage` with correct
`kube_namespace` / `kube_deployment` labels plus one tag that exists on no series. The query returns
no data. Signal: `ScalingActive=False` / `FailedGetExternalMetric`, no `wpa_controller_value` series,
and the autogenerated `dcaautogen-<hash>` DatadogMetric carrying `Error=True` with
`missing result from reply`.

The two end-user reports must read differently — describing distinct observed symptoms — or users
cannot tell the cases apart.

## Phase 4 — the remaining scripts

### `case.sh`

- `list` — every case, its namespace, and current pass/fail.
- `verify NN` — pass/fail from WPA status conditions and the replica count read over `kubectl`
  (instant, no API keys, no query latency), **and** print the equivalent Datadog query so users learn
  the metric names as they go.
- `reset NN` — re-render from the template and re-apply, for a case broken beyond repair.
- `show NN` — print the end-user report again.

Checks use `kubectl -o jsonpath` rather than `jq`, to keep `jq` off the prerequisite list.

### `update.sh`

Refreshes an existing workshop without recreating the cluster:

1. Require `.workshop-state` and a cluster that still exists in `kind get clusters`; otherwise point
   at `setup.sh`.
2. `helm upgrade` the operator and the WPA controller if their pinned versions changed; re-apply the
   `DatadogAgent`.
3. **If the WPA CRD changed, restart the Cluster Agent.** Its WPA informer binds at startup, so a CRD
   change without a restart leaves it silently stale. This is the step most likely to be forgotten.
4. Apply new or changed cases, remove cases deleted from the repo, and report what is new.
5. Leave already-edited cases in `workspace/` untouched by default; `--reset-cases` forces templates
   back. Reverting someone's in-progress investigation silently is the worst possible surprise, and
   the common use of this script is "pull new cases".
6. Re-run the external-metrics gate and rewrite `.workshop-state`.

### `delete.sh`

Destroys the cluster and the workshop's Datadog objects, so it prints exactly what it will remove and
asks for confirmation unless `--yes` is passed. Scoped to `workshop_name` from `.workshop-state`.

- Cluster: `kind delete cluster --name $CLUSTER_NAME` removes the Agent, operator, WPA controller and
  every case in one call. If the cluster is already gone, say so and continue with the Datadog side.
- Datadog: delete the scoring dashboard by `DASHBOARD_ID` (phase 5), falling back to a tag search;
  delete monitors carrying the workshop tag (none today — this guards later cases that use
  `lifecycleControl` / `DatadogMonitor`).
- Local: `.cache/`, `workspace/`, `.workshop-state`, any rendered secret.
- Flags: `--yes`, `--keep-cluster`, `--datadog-only`. Idempotent.

It also states plainly what it cannot remove: submitted timeseries (`wpa_workshop.app.load`,
`wpa_controller_*`, `kubernetes_state.*`) cannot be deleted and age out per the org's retention, and
`wpa_workshop.app.load` is a custom metric that counts toward custom-metric billing for as long as a
forgotten cluster keeps submitting it. API and APP keys are supplied by the user and never touched.

## Phase 5 — later

Gamification: a Datadog dashboard built from `wpa_controller_conditions`,
`wpa_controller_scaling_active` and `kubernetes_state.deployment.replicas_desired`, split by
`kube_cluster_name`, so a group session can compare progress in one place. `setup.sh` records its id
in `.workshop-state` and `delete.sh` removes it.

Further investigation cases, including the `DatadogMetric` CRD path, HPA equivalents, and cases
exercising `dryRun`, the forbidden windows and the velocity caps.
