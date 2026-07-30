#!/usr/bin/env bash
#
# Work with the individual investigation cases.
#
# Usage:
#   ./case.sh list             every case and where it currently stands
#   ./case.sh show <id>        the end-user report for a case
#   ./case.sh verify <id>      check whether the case is solved
#   ./case.sh reset <id>       re-render a case from its template and re-apply it
#
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() {
  sed -n '3,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# Load a case's metadata (CASE_TITLE, WPA_NAME, DEPLOYMENT,
# EXPECTED_MIN_REPLICAS, DD_QUERY) with the workshop's values substituted in.
load_case_env() {
  local id="$1" dir rendered
  dir="$(case_dir "${id}")" || die "unknown case '${id}' (known: $(all_case_ids | paste -sd' ' -))"
  [[ -f "${dir}/case.env" ]] || die "case ${id} has no case.env"
  rendered="$(mktemp)"
  render_template "${dir}/case.env" "${rendered}" "${id}"
  # shellcheck disable=SC1090
  source "${rendered}"
  rm -f "${rendered}"
  CASE_NS="$(case_namespace "${id}")"
}

# Read one condition's status off a WPA, e.g. AbleToScale -> "True".
wpa_condition_status() {
  local ns="$1" name="$2" type="$3"
  kc get wpa "${name}" -n "${ns}" \
    -o jsonpath="{range .status.conditions[?(@.type==\"${type}\")]}{.status}{end}" 2>/dev/null
}

wpa_condition_reason() {
  local ns="$1" name="$2" type="$3"
  kc get wpa "${name}" -n "${ns}" \
    -o jsonpath="{range .status.conditions[?(@.type==\"${type}\")]}{.reason}{end}" 2>/dev/null
}

wpa_field() {
  local ns="$1" name="$2" path="$3"
  kc get wpa "${name}" -n "${ns}" -o jsonpath="{${path}}" 2>/dev/null
}

# Returns 0 when the case is solved. Quiet unless verbose=true.
check_case() {
  local id="$1" verbose="${2:-false}"
  local able active reason_able reason_active current desired result=0

  load_case_env "${id}"

  if ! kc get wpa "${WPA_NAME}" -n "${CASE_NS}" >/dev/null 2>&1; then
    [[ "${verbose}" == true ]] && fail "no WatermarkPodAutoscaler ${WPA_NAME} in ${CASE_NS} — try ./case.sh reset ${id}"
    return 1
  fi

  able="$(wpa_condition_status "${CASE_NS}" "${WPA_NAME}" AbleToScale)"
  active="$(wpa_condition_status "${CASE_NS}" "${WPA_NAME}" ScalingActive)"
  reason_able="$(wpa_condition_reason "${CASE_NS}" "${WPA_NAME}" AbleToScale)"
  reason_active="$(wpa_condition_reason "${CASE_NS}" "${WPA_NAME}" ScalingActive)"
  current="$(wpa_field "${CASE_NS}" "${WPA_NAME}" .status.currentReplicas)"
  desired="$(wpa_field "${CASE_NS}" "${WPA_NAME}" .status.desiredReplicas)"
  current="${current:-0}"
  desired="${desired:-0}"

  # Three independent questions: can the controller reach the target, can it
  # read the metric, and did the replica count actually move.
  [[ "${able}" == "True" ]] || result=1
  [[ "${active}" == "True" ]] || result=1
  ((current >= EXPECTED_MIN_REPLICAS)) || result=1

  if [[ "${verbose}" == true ]]; then
    printf '  %-16s %-6s %s\n' "AbleToScale" "${able:-<unset>}" "${reason_able:-}"
    printf '  %-16s %-6s %s\n' "ScalingActive" "${active:-<unset>}" "${reason_active:-}"
    printf '  %-16s %s (want >= %s), desired %s\n' "replicas" "${current}" "${EXPECTED_MIN_REPLICAS}" "${desired}"
  fi

  return "${result}"
}

cmd_list() {
  load_state
  header "Investigation cases — ${WORKSHOP_NAME} (${CLUSTER_NAME})"
  local id status
  for id in $(all_case_ids); do
    load_case_env "${id}"
    if check_case "${id}"; then
      status="${_c_green}solved${_c_reset}"
    else
      status="${_c_yellow}open  ${_c_reset}"
    fi
    printf '  %s  case %s  %-24s %s\n' "${status}" "${id}" "${CASE_NS}" "${CASE_TITLE}"
  done
  printf '\n  ./case.sh show <id> for the report, ./case.sh verify <id> for the details.\n\n'
}

cmd_show() {
  local id="${1:-}"
  [[ -n "${id}" ]] || usage 1
  load_state
  local rendered="$(case_workspace "${id}")/README.md"
  if [[ -f "${rendered}" ]]; then
    cat "${rendered}"
  else
    local dir
    dir="$(case_dir "${id}")" || die "unknown case '${id}'"
    render_template "${dir}/README.md" /dev/stdout "${id}"
  fi
}

cmd_verify() {
  local id="${1:-}"
  [[ -n "${id}" ]] || usage 1
  load_state
  load_case_env "${id}"

  header "Case ${id} — ${CASE_TITLE}"

  local solved=false
  if check_case "${id}" true; then
    solved=true
    printf '\n%s  solved.%s The WPA can reach its target, is reading its metric, and has scaled.\n' \
      "${_c_green}" "${_c_reset}"
    printf '  The explanation is in solutions/case-%s.md if you want to compare notes.\n\n' "${id}"
  else
    printf '\n%s  not solved yet.%s\n\n' "${_c_yellow}" "${_c_reset}"
    cat <<EOF
  Worth checking, in this order:
    kubectl -n ${CASE_NS} describe wpa ${WPA_NAME}
    kubectl -n ${CASE_NS} get deploy
    kubectl -n ${DATADOG_NAMESPACE} logs deployment/datadog-cluster-agent | grep -i external
    kubectl get datadogmetric -A

EOF
  fi

  # DD_QUERY is the *correct* query, so it is only ever printed once the case is
  # solved — for case 02 it is the answer verbatim. The wpa_controller_* series
  # below give away nothing and are half of what this workshop teaches, so they
  # are printed either way.
  if [[ "${solved}" == true ]]; then
    cat <<EOF
  The Datadog query behind this case, now that it is configured correctly:
    ${DD_QUERY}

EOF
  fi

  cat <<EOF
  The controller's own view of this WPA, in Datadog:
    wpa_controller_value{wpa_name:${WPA_NAME},kube_cluster_name:${CLUSTER_NAME}}
    wpa_controller_conditions{wpa_name:${WPA_NAME},kube_cluster_name:${CLUSTER_NAME}}
    kubernetes_state.deployment.replicas_desired{kube_deployment:${DEPLOYMENT},kube_cluster_name:${CLUSTER_NAME}}

EOF

  check_case "${id}"
}

cmd_reset() {
  local id="${1:-}"
  [[ -n "${id}" ]] || usage 1
  load_state
  load_case_env "${id}"

  info "resetting case ${id} — your edits in $(case_workspace "${id}")/ will be overwritten"
  # Delete the WPA first so the controller does not act on a half-applied state.
  kc delete wpa "${WPA_NAME}" -n "${CASE_NS}" --ignore-not-found >/dev/null
  render_case "${id}"
  apply_case "${id}"
  # app.yaml deliberately carries no replicas field — that is the autoscaler's
  # business — which also means re-applying it cannot bring the deployment back
  # down. Without this, a case that was solved and then reset starts again at
  # whatever the WPA had scaled it to, and its report ("stuck at one replica")
  # no longer matches what the participant sees.
  kc scale deployment "${DEPLOYMENT}" -n "${CASE_NS}" --replicas=1 >/dev/null
  ok "case ${id} is back to its original state"
  latency_banner
}

case "${1:-}" in
  list) shift; cmd_list "$@" ;;
  show) shift; cmd_show "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  reset) shift; cmd_reset "$@" ;;
  -h | --help | "") usage 0 ;;
  *) error "unknown command: $1"; usage 1 ;;
esac
