#!/usr/bin/env bash
#
# Remove everything the workshop created: the kind cluster and the objects this
# participant created in the Datadog org.
#
# Usage:
#   ./delete.sh [--yes] [--keep-cluster | --datadog-only]
#
#   --yes            skip the confirmation prompt
#   --keep-cluster   leave the kind cluster alone, clean up Datadog only
#   --datadog-only   same as --keep-cluster, and keep the local files too
#
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

ASSUME_YES=false
DELETE_CLUSTER=true
DELETE_LOCAL=true

usage() {
  sed -n '3,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while (($# > 0)); do
  case "$1" in
    --yes | -y) ASSUME_YES=true ;;
    --keep-cluster) DELETE_CLUSTER=false ;;
    --datadog-only) DELETE_CLUSTER=false; DELETE_LOCAL=false ;;
    -h | --help) usage 0 ;;
    *) error "unknown argument: $1"; usage 1 ;;
  esac
  shift
done

require_cmds kind kubectl
load_state

# ---------------------------------------------------------------------------
# Say exactly what will happen before doing any of it.
# ---------------------------------------------------------------------------

header "This will remove the following"

if [[ "${DELETE_CLUSTER}" == true ]]; then
  if cluster_exists; then
    printf '  kind cluster       %s\n' "${CLUSTER_NAME}"
    printf '                     (with it: the Agent, the operator, the WPA controller and every case)\n'
  else
    printf '  kind cluster       %s — already gone\n' "${CLUSTER_NAME}"
  fi
else
  printf '  kind cluster       kept (--keep-cluster)\n'
fi

printf '  Datadog objects    tagged %s and workshop_name:%s\n' "${WORKSHOP_TAG}" "${WORKSHOP_NAME}"
if [[ -n "${DASHBOARD_ID:-}" ]]; then
  printf '                     dashboard %s\n' "${DASHBOARD_ID}"
else
  printf '                     no dashboard recorded in the state file\n'
fi

if [[ "${DELETE_LOCAL}" == true ]]; then
  printf '  Local files        .cache/ workspace/ .workshop-state\n'
  printf '                     (workspace/ holds your edits — they are not recoverable)\n'
fi

cat <<EOF

  What cannot be removed, for honesty's sake:
    - Metrics already submitted (wpa_workshop.app.load, wpa_controller_*,
      kubernetes_state.*) cannot be deleted. They age out with your org's
      retention.
    - wpa_workshop.app.load is a custom metric and counts toward custom-metric
      billing for as long as something keeps submitting it, which is a good
      reason not to leave a forgotten cluster running.
    - The kind host and its containers simply stop reporting and go stale.
    - Your API and APP keys are never touched by the workshop.

EOF

if [[ "${ASSUME_YES}" != true ]]; then
  confirm "Proceed?" || { info "nothing was removed"; exit 0; }
fi

# ---------------------------------------------------------------------------
# Datadog objects — done first, while the state file is still around.
#
# Scoped by workshop_name on purpose: several participants may share one org,
# and a broad tag-only match would delete a colleague's dashboard.
# ---------------------------------------------------------------------------

header "Datadog org"

if [[ -z "${DD_API_KEY:-}" || -z "${DD_APP_KEY:-}" ]]; then
  warn "DD_API_KEY / DD_APP_KEY are not set, skipping the Datadog cleanup"
  if [[ -n "${DASHBOARD_ID:-}" ]]; then
    warn "dashboard ${DASHBOARD_ID} is still there; export the keys and re-run, or delete it in the UI"
  fi
elif ! command -v curl >/dev/null 2>&1; then
  warn "curl is not available, skipping the Datadog cleanup"
else
  if [[ -n "${DASHBOARD_ID:-}" ]]; then
    response="$(dd_api DELETE "/api/v1/dashboard/${DASHBOARD_ID}" || true)"
    if printf '%s' "${response}" | grep -q '"errors"'; then
      warn "could not delete dashboard ${DASHBOARD_ID}: ${response}"
    else
      ok "deleted dashboard ${DASHBOARD_ID}"
    fi
  else
    ok "no dashboard to delete"
  fi

  # No monitors are created today. This guards the later cases that use
  # lifecycleControl / DatadogMonitor, so they cannot leave objects behind.
  if command -v jq >/dev/null 2>&1; then
    query="tag:\"${WORKSHOP_TAG}\" tag:\"workshop_name:${WORKSHOP_NAME}\""
    monitors="$(dd_api GET "/api/v1/monitor/search?query=$(printf '%s' "${query}" | sed 's/ /%20/g; s/"/%22/g')" || true)"
    ids="$(printf '%s' "${monitors}" | jq -r '.monitors[]?.id // empty' 2>/dev/null || true)"
    if [[ -n "${ids}" ]]; then
      for monitor_id in ${ids}; do
        dd_api DELETE "/api/v1/monitor/${monitor_id}" >/dev/null || warn "could not delete monitor ${monitor_id}"
        ok "deleted monitor ${monitor_id}"
      done
    else
      ok "no workshop monitors found"
    fi
  else
    ok "jq not installed, skipping the monitor search (no monitors are created yet)"
  fi
fi

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------

header "Cluster"

if [[ "${DELETE_CLUSTER}" == true ]]; then
  if cluster_exists; then
    # One call removes the Agent, the operator, the WPA controller and every
    # case namespace, so there is no per-resource teardown to get wrong.
    kind delete cluster --name "${CLUSTER_NAME}" >/dev/null
    ok "deleted kind cluster ${CLUSTER_NAME}"
  else
    ok "kind cluster ${CLUSTER_NAME} was already gone"
  fi
else
  ok "kept kind cluster ${CLUSTER_NAME}"
fi

# ---------------------------------------------------------------------------
# Local files
# ---------------------------------------------------------------------------

header "Local files"

if [[ "${DELETE_LOCAL}" == true ]]; then
  rm -rf "${CACHE_DIR}" "${WORKSPACE_DIR}"
  rm -f "${STATE_FILE}"
  ok "removed .cache/, workspace/ and ${STATE_FILE##*/}"
else
  ok "kept the local files"
fi

printf '\nDone. ./setup.sh starts a fresh workshop whenever you want one.\n\n'
