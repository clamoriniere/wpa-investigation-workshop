#!/usr/bin/env bash
# Shared helpers for setup.sh, update.sh, delete.sh and case.sh.
# Sourced, never executed directly.

# ---------------------------------------------------------------------------
# Pinned versions and shared constants
# ---------------------------------------------------------------------------

# WPA controller release to install. The chart's own appVersion/image.tag lag
# behind the releases, so image.tag is always overridden explicitly.
WPA_VERSION="${WPA_VERSION:-v0.11.0}"

# datadog-operator Helm chart version. Pinned so a new upstream release cannot
# silently change the workshop's behaviour.
OPERATOR_CHART_VERSION="${OPERATOR_CHART_VERSION:-2.24.0}"

DATADOG_NAMESPACE="datadog"
DATADOG_SECRET_NAME="datadog-secret"
DATADOG_AGENT_NAME="datadog"

# Every object the workshop creates in Datadog carries these tags, so that
# delete.sh can scope removal to one participant even when a whole group shares
# a single Datadog org.
WORKSHOP_TAG="workshop:wpa-investigation"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="${REPO_ROOT}/.workshop-state"
CACHE_DIR="${REPO_ROOT}/.cache"
WORKSPACE_DIR="${REPO_ROOT}/workspace"
# Templates, not the cases you work on: the name is meant to make it obvious
# that editing here changes what every future render produces, while
# workspace/ holds the rendered copies a participant actually edits.
CASES_DIR="${REPO_ROOT}/cases-tmpl"

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
  _c_reset=$'\033[0m'; _c_red=$'\033[31m'; _c_green=$'\033[32m'
  _c_yellow=$'\033[33m'; _c_blue=$'\033[34m'; _c_bold=$'\033[1m'
else
  _c_reset=""; _c_red=""; _c_green=""; _c_yellow=""; _c_blue=""; _c_bold=""
fi

info()  { printf '%s==>%s %s\n' "${_c_blue}" "${_c_reset}" "$*"; }
ok()    { printf '%s  ok%s %s\n' "${_c_green}" "${_c_reset}" "$*"; }
warn()  { printf '%swarn%s %s\n' "${_c_yellow}" "${_c_reset}" "$*" >&2; }
error() { printf '%s err%s %s\n' "${_c_red}" "${_c_reset}" "$*" >&2; }
fail()  { printf '%sfail%s %s\n' "${_c_red}" "${_c_reset}" "$*"; }
die()   { error "$*"; exit 1; }

header() {
  printf '\n%s%s%s\n' "${_c_bold}" "$*" "${_c_reset}"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

require_cmds() {
  local missing=()
  local cmd
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
  done
  if ((${#missing[@]} > 0)); then
    die "missing required command(s): ${missing[*]}"
  fi
}

require_dd_credentials() {
  [[ -n "${DD_API_KEY:-}" ]] || die "DD_API_KEY is not set (export it before running)"
  [[ -n "${DD_APP_KEY:-}" ]] || die "DD_APP_KEY is not set; the external metrics server needs an APP key to query Datadog"
}

# ---------------------------------------------------------------------------
# State file
# ---------------------------------------------------------------------------

# Populate the workshop variables from defaults / environment, for setup.sh.
init_state_defaults() {
  WORKSHOP_NAME="${WORKSHOP_NAME:-$(whoami)}"
  # Cluster names end up as the kube_cluster_name tag, which is the key used to
  # attribute results to a participant, so keep it DNS-label safe.
  WORKSHOP_NAME="$(printf '%s' "${WORKSHOP_NAME}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/-\{1,\}/-/g; s/^-//; s/-$//')"
  [[ -n "${WORKSHOP_NAME}" ]] || die "WORKSHOP_NAME is empty after normalisation; set it explicitly"
  CLUSTER_NAME="${CLUSTER_NAME:-wpa-workshop-${WORKSHOP_NAME}}"
  DD_SITE="${DD_SITE:-datadoghq.com}"
  DASHBOARD_ID="${DASHBOARD_ID:-}"
}

state_exists() { [[ -f "${STATE_FILE}" ]]; }

load_state() {
  state_exists || die "no ${STATE_FILE##*/} found — run ./setup.sh first"
  # shellcheck disable=SC1090
  source "${STATE_FILE}"
  [[ -n "${CLUSTER_NAME:-}" ]] || die "${STATE_FILE##*/} is missing CLUSTER_NAME; it looks corrupted"
}

save_state() {
  local cases
  cases="$(all_case_ids | paste -sd, -)"
  cat >"${STATE_FILE}" <<EOF
# Written by the workshop scripts. Do not edit by hand.
WORKSHOP_NAME=${WORKSHOP_NAME}
CLUSTER_NAME=${CLUSTER_NAME}
DD_SITE=${DD_SITE}
OPERATOR_CHART_VERSION=${OPERATOR_CHART_VERSION}
WPA_VERSION=${WPA_VERSION}
CASES=${cases}
DASHBOARD_ID=${DASHBOARD_ID:-}
SETUP_AT=${SETUP_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
EOF
}

# ---------------------------------------------------------------------------
# Cluster access
#
# Always pin the context. Without this, a stray kubectl config change could
# point the workshop's manifests at a real cluster.
# ---------------------------------------------------------------------------

kube_context() { printf 'kind-%s' "${CLUSTER_NAME}"; }

kc() { kubectl --context "$(kube_context)" "$@"; }

cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"
}

# ---------------------------------------------------------------------------
# Reading a WatermarkPodAutoscaler
#
# Generic accessors rather than case.sh internals, so that a case which needs a
# success criterion the shared check cannot express can ship its own check and
# still read the object the same way.
# ---------------------------------------------------------------------------

# One condition's status, e.g. AbleToScale -> "True". Empty if the condition is
# not set yet, which is what a freshly created WPA looks like.
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

# Any other field, given a jsonpath body such as .status.currentReplicas.
wpa_field() {
  local ns="$1" name="$2" path="$3"
  kc get wpa "${name}" -n "${ns}" -o jsonpath="{${path}}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

# "01", "02", ... in directory order. Directories are named case-NN and nothing
# more: a descriptive suffix would give away what the participant is meant to
# find.
all_case_ids() {
  local dir
  for dir in "${CASES_DIR}"/case-*/; do
    [[ -d "${dir}" ]] || continue
    basename "${dir}" | sed -n 's/^case-\([0-9]\{1,\}\)$/\1/p'
  done
}

case_dir() {
  local dir="${CASES_DIR}/case-$1"
  [[ -d "${dir}" ]] || return 1
  printf '%s' "${dir}"
}

case_namespace() { printf 'wpa-case-%s' "$1"; }

case_workspace() { printf '%s/case-%s' "${WORKSPACE_DIR}" "$1"; }

# Substitute the workshop's values into a case template. Kept to a fixed set of
# __TOKEN__ placeholders so a template stays valid YAML and can be read on its
# own.
render_template() {
  local src="$1" dst="$2" case_id="${3:-}"
  sed \
    -e "s|__WORKSHOP_NAME__|${WORKSHOP_NAME}|g" \
    -e "s|__CLUSTER_NAME__|${CLUSTER_NAME}|g" \
    -e "s|__DD_SITE__|${DD_SITE}|g" \
    -e "s|__CASE_ID__|${case_id}|g" \
    -e "s|__CASE_NAMESPACE__|$(case_namespace "${case_id}")|g" \
    "${src}" >"${dst}"
}

# Render every template of a case into workspace/case-NN/. Users edit the
# rendered copies, which is why workspace/ is gitignored: pulling new cases can
# never conflict with a half-finished investigation.
render_case() {
  local id="$1" src dst base f
  src="$(case_dir "${id}")" || die "unknown case '${id}'"
  dst="$(case_workspace "${id}")"
  mkdir -p "${dst}"
  for f in "${src}"/*.yaml; do
    [[ -f "${f}" ]] || continue
    base="$(basename "${f}")"
    render_template "${f}" "${dst}/${base}" "${id}"
  done
  # The end-user report travels with the rendered case so users can read it
  # without digging through the repo.
  [[ -f "${src}/README.md" ]] && render_template "${src}/README.md" "${dst}/README.md" "${id}"
  return 0
}

apply_case() {
  local id="$1" dst
  dst="$(case_workspace "${id}")"
  [[ -d "${dst}" ]] || die "case ${id} has not been rendered yet"
  kc apply -f "${dst}" >/dev/null
}

# The one-line description of a case, read from its case.env. Run in a subshell
# so the sourced variables do not leak into the caller.
case_title() {
  local id="$1"
  (
    local dir rendered
    dir="$(case_dir "${id}")" || exit 0
    [[ -f "${dir}/case.env" ]] || exit 0
    rendered="$(mktemp)"
    render_template "${dir}/case.env" "${rendered}" "${id}"
    # shellcheck disable=SC1090
    source "${rendered}"
    rm -f "${rendered}"
    printf '%s' "${CASE_TITLE:-}"
  )
}

# A table of contents for workspace/, written at setup and refreshed on update.
# Someone who opens the directory a week later should be able to start from here
# without going back to the repository README.
write_workspace_readme() {
  local dst="${WORKSPACE_DIR}/README.md" id
  mkdir -p "${WORKSPACE_DIR}"

  {
    cat <<EOF
# Your workshop — ${WORKSHOP_NAME}

Generated by the workshop scripts. Everything here is yours to edit; it is
gitignored, so pulling new cases can never clash with an investigation you have
half finished.

  Cluster: ${CLUSTER_NAME}   (kubectl context: kind-${CLUSTER_NAME})
  Site:    ${DD_SITE}

## The cases

EOF

    for id in $(all_case_ids); do
      printf '### Case %s — %s\n\n' "${id}" "$(case_title "${id}")"
      printf -- '- Report:    `workspace/case-%s/README.md` (or `./case.sh show %s`)\n' "${id}" "${id}"
      printf -- '- Namespace: `%s`\n' "$(case_namespace "${id}")"
      printf -- '- Manifests: `workspace/case-%s/`\n\n' "${id}"
    done

    cat <<'EOF'
## How to proceed

Take one case at a time. For each one:

1. Read the report — `./case.sh show <id>` — it is written as a user would
   report the problem, not as a description of the bug.
2. Investigate with kubectl and Datadog. The WPA's own status is the fastest
   way in:

   ```
   kubectl -n <namespace> describe wpa <name>
   ```

   `AbleToScale` and `ScalingActive` answer two different questions — "can the
   controller reach the target?" and "can it read the metric?" — and it is worth
   knowing which one is false before touching anything.

3. Fix it. Edit the manifests in `workspace/case-<id>/` and re-apply them:

   ```
   kubectl apply -f workspace/case-<id>/
   ```

   or edit the live object with `kubectl edit`. Either is fine.
4. Check your work: `./case.sh verify <id>`.

Wrong turns are part of it. `./case.sh reset <id>` puts a case back to its
original broken state, discarding your edits to that case.

## Before you judge a change

Give it about two minutes. A metric has to reach Datadog, the Cluster Agent
refreshes external metrics every 30s, and the WPA controller polls on its own
interval on top of that. A WPA that looks broken in the first minute is usually
just early.

## Commands

Run these from the repository root, one directory up from here — they are part
of the workshop, not of your working copy, so they are not duplicated in this
folder where they could drift out of step with it.

```
./case.sh list          every case and where it stands
./case.sh show <id>     the report for one case
./case.sh verify <id>   check whether you have fixed it
./case.sh reset <id>    start a case over
./update.sh             pull new cases and versions, keep your work
./delete.sh             tear the whole thing down
```

## Solutions

`solutions/` in the repository has a full write-up per case. Nothing stops you
from reading them — but the diagnostic path is the point of the exercise, so
they are worth more once you have your own answer to compare against.
EOF
  } >"${dst}"
}

# ---------------------------------------------------------------------------
# Waiting
# ---------------------------------------------------------------------------

# wait_for <timeout-seconds> <description> <command...>
wait_for() {
  local timeout="$1" description="$2"
  shift 2
  local deadline=$((SECONDS + timeout))
  printf '     waiting for %s' "${description}"
  while ((SECONDS < deadline)); do
    if "$@" >/dev/null 2>&1; then
      printf ' — ready\n'
      return 0
    fi
    printf '.'
    sleep 5
  done
  printf ' — timed out after %ss\n' "${timeout}"
  return 1
}

# ---------------------------------------------------------------------------
# Datadog API
# ---------------------------------------------------------------------------

dd_api_base() { printf 'https://api.%s' "${DD_SITE}"; }

# dd_api <method> <path> [body]
# Returns non-zero on transport failure; callers inspect the body for API errors.
dd_api() {
  local method="$1" path="$2" body="${3:-}"
  local -a args=(-sS -X "${method}"
    -H "Content-Type: application/json"
    -H "DD-API-KEY: ${DD_API_KEY}"
    -H "DD-APPLICATION-KEY: ${DD_APP_KEY}")
  [[ -n "${body}" ]] && args+=(-d "${body}")
  curl "${args[@]}" "$(dd_api_base)${path}"
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------

confirm() {
  local prompt="$1" reply
  read -r -p "${prompt} [y/N] " reply
  [[ "${reply}" == "y" || "${reply}" == "Y" ]]
}

latency_banner() {
  cat <<'EOF'

  Before judging any WPA, give the pipeline about two minutes.
  A metric has to reach Datadog, the Cluster Agent refreshes external metrics
  every 30s, and the WPA controller polls on its own interval on top of that.
  A WPA that looks broken in the first minute is usually just early.

EOF
}
