# Custom verify for case 05: success here is a DOWNSCALE happening, the
# opposite shape from every other case, so the shared "currentReplicas >=
# EXPECTED_MIN_REPLICAS" check would already pass on the broken state (4 is
# comfortably above any floor). See EXPECTED_MAX_REPLICAS in case.env.
#
# Sourced by check_case() in case.sh, which already has CASE_NS, WPA_NAME,
# EXPECTED_MAX_REPLICAS and verbose in scope, and wpa_condition_status /
# wpa_condition_reason / wpa_field available from lib/common.sh.

able="$(wpa_condition_status "${CASE_NS}" "${WPA_NAME}" AbleToScale)"
active="$(wpa_condition_status "${CASE_NS}" "${WPA_NAME}" ScalingActive)"
reason_able="$(wpa_condition_reason "${CASE_NS}" "${WPA_NAME}" AbleToScale)"
reason_active="$(wpa_condition_reason "${CASE_NS}" "${WPA_NAME}" ScalingActive)"
current="$(wpa_field "${CASE_NS}" "${WPA_NAME}" .status.currentReplicas)"
desired="$(wpa_field "${CASE_NS}" "${WPA_NAME}" .status.desiredReplicas)"
current="${current:-0}"
desired="${desired:-0}"

result=0
[[ "${able}" == "True" ]] || result=1
[[ "${active}" == "True" ]] || result=1
((current <= EXPECTED_MAX_REPLICAS)) || result=1

if [[ "${verbose}" == true ]]; then
  printf '  %-16s %-6s %s\n' "AbleToScale" "${able:-<unset>}" "${reason_able:-}"
  printf '  %-16s %-6s %s\n' "ScalingActive" "${active:-<unset>}" "${reason_active:-}"
  printf '  %-16s %s (want <= %s), desired %s\n' "replicas" "${current}" "${EXPECTED_MAX_REPLICAS}" "${desired}"
fi
