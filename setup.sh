#!/usr/bin/env bash
#
# Create the WPA investigation workshop: a local kind cluster running the
# WatermarkPodAutoscaler controller and a Datadog Agent with the external
# metrics server, plus one broken workload per investigation case.
#
# Usage:
#   export DD_API_KEY=... DD_APP_KEY=...
#   export DD_SITE=datadoghq.com          # optional, defaults to datadoghq.com
#   export WORKSHOP_NAME=your-name        # optional, defaults to $(whoami)
#   ./setup.sh [--no-preload]
#
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

PRELOAD_IMAGES=true

usage() {
  sed -n '3,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while (($# > 0)); do
  case "$1" in
    --no-preload) PRELOAD_IMAGES=false ;;
    -h | --help) usage 0 ;;
    *) error "unknown argument: $1"; usage 1 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------

header "1/7 Preflight"

require_cmds kind kubectl helm git docker
require_dd_credentials
init_state_defaults

if state_exists; then
  die "$(
    printf 'a workshop already exists (%s)\n' "${STATE_FILE##*/}"
    printf '       run ./update.sh to refresh it, or ./delete.sh to remove it first'
  )"
fi

docker info >/dev/null 2>&1 || die "docker does not appear to be running"

ok "prerequisites present"
ok "participant: ${WORKSHOP_NAME}"
ok "cluster:     ${CLUSTER_NAME}"
ok "site:        ${DD_SITE}"

# ---------------------------------------------------------------------------
# 2. kind cluster
# ---------------------------------------------------------------------------

header "2/7 Kubernetes cluster"

if cluster_exists; then
  warn "kind cluster ${CLUSTER_NAME} already exists, reusing it"
else
  kind create cluster --name "${CLUSTER_NAME}" --config "${REPO_ROOT}/kind/kind-config.yaml"
  ok "kind cluster ${CLUSTER_NAME} created"
fi

kc cluster-info >/dev/null || die "cannot reach the cluster with context $(kube_context)"

if [[ "${PRELOAD_IMAGES}" == true ]]; then
  # kind does not share the host's Docker image cache, so every image is pulled
  # inside the node. Doing it here, best-effort, keeps a slow or rate-limited
  # registry from looking like a broken workshop later on.
  info "pre-loading container images (best effort)"
  # Empty if the daemon does not report it; the fallback below is then skipped.
  HOST_PLATFORM="$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}' 2>/dev/null || true)"
  for image in \
    "gcr.io/datadoghq/watermarkpodautoscaler:${WPA_VERSION}" \
    "gcr.io/datadoghq/agent:7" \
    "gcr.io/datadoghq/cluster-agent:latest" \
    "nginx:1.27-alpine" \
    "busybox:1.36"; do
    if docker pull --quiet "${image}" >/dev/null 2>&1; then
      # Two ways in, because the first one fails on Docker Desktop's containerd
      # image store: kind always imports with --all-platforms, but that store
      # keeps only the host platform, so ctr aborts with "content digest ...:
      # not found". Exporting a single-platform archive gives ctr an image whose
      # every referenced digest is present, and the import succeeds.
      if kind load docker-image "${image}" --name "${CLUSTER_NAME}" >/dev/null 2>&1; then
        ok "loaded ${image}"
      elif [[ -n "${HOST_PLATFORM}" ]] \
        && docker save --platform "${HOST_PLATFORM}" "${image}" 2>/dev/null \
          | kind load image-archive /dev/stdin --name "${CLUSTER_NAME}" >/dev/null 2>&1; then
        ok "loaded ${image} (single-platform archive)"
      else
        warn "could not side-load ${image}, the node will pull it itself"
      fi
    else
      warn "could not pull ${image}, the node will pull it itself"
    fi
  done
fi

# ---------------------------------------------------------------------------
# 3. WPA controller
#
# Installed BEFORE the Cluster Agent on purpose: the Cluster Agent's WPA
# informer binds at startup and needs the CRD to already exist, otherwise it
# logs informer errors and never serves WPA metrics.
# ---------------------------------------------------------------------------

header "3/7 WatermarkPodAutoscaler controller (${WPA_VERSION})"

kc create namespace "${DATADOG_NAMESPACE}" --dry-run=client -o yaml | kc apply -f - >/dev/null

# The chart is not published to any Helm repository — it only exists inside the
# controller's git repository — so it has to be cloned.
WPA_SRC="${CACHE_DIR}/watermarkpodautoscaler-${WPA_VERSION}"
if [[ -d "${WPA_SRC}/chart/watermarkpodautoscaler" ]]; then
  ok "using cached chart at ${WPA_SRC#"${REPO_ROOT}/"}"
else
  mkdir -p "${CACHE_DIR}"
  rm -rf "${WPA_SRC}"
  git clone --depth 1 --branch "${WPA_VERSION}" \
    https://github.com/DataDog/watermarkpodautoscaler.git "${WPA_SRC}" >/dev/null 2>&1 \
    || die "could not clone the WPA controller at tag ${WPA_VERSION}"
  ok "cloned the WPA controller at ${WPA_VERSION}"
fi

helm repo add datadog https://helm.datadoghq.com >/dev/null 2>&1 || true
helm repo update datadog >/dev/null 2>&1 || warn "helm repo update failed, continuing with the local index"

# The chart declares a conditional dependency (datadog-crds, used only for
# lifecycleControl). Helm refuses to install with unmet dependencies even when
# the condition is false, so build them first.
helm dependency update "${WPA_SRC}/chart/watermarkpodautoscaler" >/dev/null 2>&1 \
  || warn "helm dependency update failed for the WPA chart, attempting the install anyway"

if helm status wpacontroller -n "${DATADOG_NAMESPACE}" --kube-context "$(kube_context)" >/dev/null 2>&1; then
  warn "the wpacontroller release already exists, upgrading it"
fi

# image.tag is always set explicitly: the chart's appVersion and default tag lag
# behind the actual controller releases.
#
# datadogCRDs.crds.datadogMonitors=false works around a bug in the chart: its
# datadog-crds dependency is declared with
#   condition: lifecycleControl.enabled && datadogCRDs.crds.datadogMonitors
# but a Helm condition is a comma-separated list of value paths, not a boolean
# expression. That path never resolves, so the subchart is enabled regardless of
# lifecycleControl and installs datadogmonitors.datadoghq.com owned by this
# release — after which the operator chart cannot adopt it and step 4 dies with
# "invalid ownership metadata".
helm upgrade --install wpacontroller "${WPA_SRC}/chart/watermarkpodautoscaler" \
  --namespace "${DATADOG_NAMESPACE}" \
  --kube-context "$(kube_context)" \
  --set "image.tag=${WPA_VERSION}" \
  --set "datadogCRDs.crds.datadogMonitors=false" \
  --wait --timeout 5m >/dev/null

kc get crd watermarkpodautoscalers.datadoghq.com >/dev/null \
  || die "the WatermarkPodAutoscaler CRD was not installed"
ok "WPA controller running, CRD registered"

# ---------------------------------------------------------------------------
# 4. Datadog Operator
# ---------------------------------------------------------------------------

header "4/7 Datadog Operator (chart ${OPERATOR_CHART_VERSION})"

# The DatadogAgent and DatadogMetric CRDs ship with this chart
# (installCRDs: true), so there is no separate CRD step.
#
# allowReadAllResources widens the ClusterRole the operator grants the Agent to
# cover arbitrary resource types. Without it the orchestratorExplorer
# customResources entry for watermarkpodautoscalers is accepted but collects
# nothing, because the Cluster Agent cannot list or watch WPA objects.
helm upgrade --install datadog-operator datadog/datadog-operator \
  --version "${OPERATOR_CHART_VERSION}" \
  --namespace "${DATADOG_NAMESPACE}" \
  --kube-context "$(kube_context)" \
  --set "clusterRole.allowReadAllResources=true" \
  --wait --timeout 5m >/dev/null

ok "operator running"

# ---------------------------------------------------------------------------
# 5. Datadog Agent
# ---------------------------------------------------------------------------

header "5/7 Datadog Agent and external metrics server"

# Piped through apply so the keys never touch the filesystem.
kc create secret generic "${DATADOG_SECRET_NAME}" \
  --namespace "${DATADOG_NAMESPACE}" \
  --from-literal "api-key=${DD_API_KEY}" \
  --from-literal "app-key=${DD_APP_KEY}" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "credentials stored in secret/${DATADOG_SECRET_NAME}"

DDA_RENDERED="${CACHE_DIR}/datadogagent.rendered.yaml"
mkdir -p "${CACHE_DIR}"
render_template "${REPO_ROOT}/manifests/datadog/datadogagent.yaml" "${DDA_RENDERED}"
kc apply -f "${DDA_RENDERED}" >/dev/null
ok "DatadogAgent applied"

wait_for 300 "the node Agent" \
  kc rollout status daemonset/datadog-agent -n "${DATADOG_NAMESPACE}" --timeout 10s \
  || warn "the node Agent is not ready yet; container metrics (case 02) will lag until it is"

wait_for 300 "the Cluster Agent" \
  kc rollout status deployment/datadog-cluster-agent -n "${DATADOG_NAMESPACE}" --timeout 10s \
  || die "the Cluster Agent never became ready — check: kubectl -n ${DATADOG_NAMESPACE} logs deployment/datadog-cluster-agent"

# ---------------------------------------------------------------------------
# 6. Gate: is the external metrics API actually serving?
#
# The single highest-value check in this script. If the APIService is not
# serving, every investigation case looks broken for a reason that has nothing
# to do with the case, and the workshop teaches the wrong lesson.
# ---------------------------------------------------------------------------

header "6/7 External metrics API"

if ! wait_for 300 "external.metrics.k8s.io to serve" \
  kc get --raw "/apis/external.metrics.k8s.io/v1beta1"; then
  error "the external metrics API is not serving. Useful checks:"
  error "  kubectl get apiservice v1beta1.external.metrics.k8s.io"
  error "  kubectl -n ${DATADOG_NAMESPACE} logs deployment/datadog-cluster-agent"
  error "  kubectl -n ${DATADOG_NAMESPACE} exec deployment/datadog-cluster-agent -- agent status"
  die "aborting: the cases would be unsolvable in this state"
fi
ok "external.metrics.k8s.io is serving"

# ---------------------------------------------------------------------------
# 7. Investigation cases
# ---------------------------------------------------------------------------

header "7/7 Investigation cases"

# The admission controller mutates pods only as they are created, and silently
# skips anything created before its webhook is registered. Waiting here means
# the load generator comes up with DD_AGENT_HOST already injected instead of
# crash-looping until someone restarts it.
if ! wait_for 180 "the admission controller webhook" \
  kc get mutatingwebhookconfiguration datadog-webhook; then
  warn "the admission controller webhook is not registered yet"
  warn "if case 01's load generator crash-loops, recreate it once the webhook exists:"
  warn "  kubectl -n $(case_namespace 01) rollout restart deployment/case01-loadgen"
fi

mkdir -p "${WORKSPACE_DIR}"
for id in $(all_case_ids); do
  render_case "${id}"
  apply_case "${id}"
  ok "case ${id} deployed in namespace $(case_namespace "${id}")"
done

write_workspace_readme
ok "wrote workspace/README.md"

SETUP_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
save_state
ok "state written to ${STATE_FILE##*/}"

latency_banner

cat <<EOF
Workshop ready.

  ./case.sh list          what to investigate, and where each case stands
  ./case.sh show 01       the end-user report for a case
  ./case.sh verify 01     check whether you have fixed it
  ./case.sh reset 01      start a case over

Start with workspace/README.md: it lists every case and how to work through it.
Your working copies live in workspace/ — edit those, not cases-tmpl/.
Solutions are in .solutions/, on the honour system.
EOF
