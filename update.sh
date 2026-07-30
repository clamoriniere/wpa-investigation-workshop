#!/usr/bin/env bash
#
# Refresh a workshop that setup.sh already created: pick up new component
# versions, a changed DatadogAgent, and new or changed investigation cases,
# without recreating the cluster.
#
# Usage:
#   export DD_API_KEY=... DD_APP_KEY=...
#   ./update.sh [--reset-cases]
#
#   --reset-cases   also re-render every case from its template, discarding the
#                   edits in workspace/. Off by default.
#
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

RESET_CASES=false

usage() {
  sed -n '3,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while (($# > 0)); do
  case "$1" in
    --reset-cases) RESET_CASES=true ;;
    -h | --help) usage 0 ;;
    *) error "unknown argument: $1"; usage 1 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------

header "1/5 Preflight"

require_cmds kind kubectl helm git

# Versions pinned in lib/common.sh are the target; the state file says what is
# currently installed.
TARGET_WPA_VERSION="${WPA_VERSION}"
TARGET_OPERATOR_CHART_VERSION="${OPERATOR_CHART_VERSION}"

load_state

INSTALLED_WPA_VERSION="${WPA_VERSION}"
INSTALLED_OPERATOR_CHART_VERSION="${OPERATOR_CHART_VERSION}"
WPA_VERSION="${TARGET_WPA_VERSION}"
OPERATOR_CHART_VERSION="${TARGET_OPERATOR_CHART_VERSION}"

cluster_exists || die "kind cluster ${CLUSTER_NAME} no longer exists — run ./delete.sh then ./setup.sh"
require_dd_credentials

ok "participant: ${WORKSHOP_NAME}"
ok "cluster:     ${CLUSTER_NAME}"
[[ "${INSTALLED_WPA_VERSION}" == "${WPA_VERSION}" ]] \
  && ok "WPA controller: ${WPA_VERSION} (unchanged)" \
  || info "WPA controller: ${INSTALLED_WPA_VERSION} -> ${WPA_VERSION}"
[[ "${INSTALLED_OPERATOR_CHART_VERSION}" == "${OPERATOR_CHART_VERSION}" ]] \
  && ok "operator chart: ${OPERATOR_CHART_VERSION} (unchanged)" \
  || info "operator chart: ${INSTALLED_OPERATOR_CHART_VERSION} -> ${OPERATOR_CHART_VERSION}"

# ---------------------------------------------------------------------------
# 2. WPA controller
# ---------------------------------------------------------------------------

header "2/5 WatermarkPodAutoscaler controller"

CRD_BEFORE="$(kc get crd watermarkpodautoscalers.datadoghq.com -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null || true)"

WPA_SRC="${CACHE_DIR}/watermarkpodautoscaler-${WPA_VERSION}"
if [[ ! -d "${WPA_SRC}/chart/watermarkpodautoscaler" ]]; then
  mkdir -p "${CACHE_DIR}"
  rm -rf "${WPA_SRC}"
  git clone --depth 1 --branch "${WPA_VERSION}" \
    https://github.com/DataDog/watermarkpodautoscaler.git "${WPA_SRC}" >/dev/null 2>&1 \
    || die "could not clone the WPA controller at tag ${WPA_VERSION}"
  ok "cloned the WPA controller at ${WPA_VERSION}"
fi

helm repo add datadog https://helm.datadoghq.com >/dev/null 2>&1 || true
helm repo update datadog >/dev/null 2>&1 || warn "helm repo update failed, continuing with the local index"
helm dependency update "${WPA_SRC}/chart/watermarkpodautoscaler" >/dev/null 2>&1 || true

helm upgrade --install wpacontroller "${WPA_SRC}/chart/watermarkpodautoscaler" \
  --namespace "${DATADOG_NAMESPACE}" \
  --kube-context "$(kube_context)" \
  --set "image.tag=${WPA_VERSION}" \
  --set "datadogCRDs.crds.datadogMonitors=false" \
  --wait --timeout 5m >/dev/null
ok "WPA controller reconciled"

CRD_AFTER="$(kc get crd watermarkpodautoscalers.datadoghq.com -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null || true)"

# ---------------------------------------------------------------------------
# 3. Operator and Agent
# ---------------------------------------------------------------------------

header "3/5 Datadog Operator and Agent"

helm upgrade --install datadog-operator datadog/datadog-operator \
  --version "${OPERATOR_CHART_VERSION}" \
  --namespace "${DATADOG_NAMESPACE}" \
  --kube-context "$(kube_context)" \
  --set "clusterRole.allowReadAllResources=true" \
  --wait --timeout 5m >/dev/null
ok "operator reconciled"

kc create secret generic "${DATADOG_SECRET_NAME}" \
  --namespace "${DATADOG_NAMESPACE}" \
  --from-literal "api-key=${DD_API_KEY}" \
  --from-literal "app-key=${DD_APP_KEY}" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null

DDA_RENDERED="${CACHE_DIR}/datadogagent.rendered.yaml"
mkdir -p "${CACHE_DIR}"
render_template "${REPO_ROOT}/manifests/datadog/datadogagent.yaml" "${DDA_RENDERED}"
kc apply -f "${DDA_RENDERED}" >/dev/null
ok "DatadogAgent reconciled"

# The Cluster Agent's WPA informer binds at startup. If the CRD changed under
# it, it keeps working against the old schema without ever complaining loudly,
# so force a restart. This is the step that is easy to forget and hard to
# diagnose afterwards.
if [[ -n "${CRD_BEFORE}" && "${CRD_BEFORE}" != "${CRD_AFTER}" ]]; then
  info "the WPA CRD changed — restarting the Cluster Agent so its WPA informer rebinds"
  kc rollout restart deployment/datadog-cluster-agent -n "${DATADOG_NAMESPACE}" >/dev/null
  kc rollout status deployment/datadog-cluster-agent -n "${DATADOG_NAMESPACE}" --timeout 5m >/dev/null \
    || die "the Cluster Agent did not come back after the restart"
  ok "Cluster Agent restarted"
fi

# ---------------------------------------------------------------------------
# 4. Cases
# ---------------------------------------------------------------------------

header "4/5 Investigation cases"

PREVIOUS_CASES="${CASES:-}"
mkdir -p "${WORKSPACE_DIR}"

for id in $(all_case_ids); do
  ws="$(case_workspace "${id}")"
  if [[ ! -d "${ws}" ]]; then
    render_case "${id}"
    apply_case "${id}"
    ok "case ${id} is new — deployed in $(case_namespace "${id}")"
  elif [[ "${RESET_CASES}" == true ]]; then
    render_case "${id}"
    apply_case "${id}"
    ok "case ${id} reset from template"
  else
    # Deliberately not re-applying: the usual reason to run this script is
    # "pull the new cases", and silently reverting someone's half-finished
    # investigation would be the worst possible surprise.
    ok "case ${id} left as-is (use --reset-cases or ./case.sh reset ${id} to restore it)"
  fi
done

# Cases removed from the repo are torn down, so a stale namespace does not sit
# around looking like an unsolved case.
for id in ${PREVIOUS_CASES//,/ }; do
  if ! case_dir "${id}" >/dev/null 2>&1; then
    ns="$(case_namespace "${id}")"
    warn "case ${id} no longer exists in the repo — deleting namespace ${ns}"
    kc delete namespace "${ns}" --ignore-not-found --wait=false >/dev/null
    rm -rf "$(case_workspace "${id}")"
  fi
done

# ---------------------------------------------------------------------------
# 5. Gate and state
# ---------------------------------------------------------------------------

header "5/5 External metrics API"

if ! wait_for 300 "external.metrics.k8s.io to serve" \
  kc get --raw "/apis/external.metrics.k8s.io/v1beta1"; then
  error "the external metrics API is not serving after the update. Useful checks:"
  error "  kubectl get apiservice v1beta1.external.metrics.k8s.io"
  error "  kubectl -n ${DATADOG_NAMESPACE} logs deployment/datadog-cluster-agent"
  die "aborting: the cases would be unsolvable in this state"
fi
ok "external.metrics.k8s.io is serving"

save_state
ok "state updated"

latency_banner
printf '  ./case.sh list to see where every case stands.\n\n'
