#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

DIR="$(dirname "${BASH_SOURCE[0]}")"
ROOT_DIR="$(realpath "${DIR}/..")"
TEMPLATE="${ROOT_DIR}/hack/relative-scheduler-dashboard-template.json"
RESULT_WINDOW_DIR="${RESULT_WINDOW_DIR:-${ROOT_DIR}/tmp}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://127.0.0.1:31003}"
GRAFANA_NAMESPACE="${GRAFANA_NAMESPACE:-monitoring}"
KUBECTL="${KUBECTL:-kubectl}"

: "${SCENARIO:?SCENARIO is required}"
: "${GANG:?GANG is required}"
: "${JOBS_SIZE_PER_QUEUE:?JOBS_SIZE_PER_QUEUE is required}"
: "${PODS_SIZE_PER_JOB:?PODS_SIZE_PER_JOB is required}"
: "${KUBECONFIG:?KUBECONFIG is required}"

[[ "${SCENARIO}" =~ ^[1-8]$ ]]
[[ "${JOBS_SIZE_PER_QUEUE}" =~ ^[1-9][0-9]*$ ]]
[[ "${PODS_SIZE_PER_JOB}" =~ ^[1-9][0-9]*$ ]]
[[ "${GANG}" == "true" || "${GANG}" == "false" ]]
[[ -f "${TEMPLATE}" ]]
[[ -x "${KUBECTL}" ]]
[[ -f "${KUBECONFIG}" ]]

command -v curl >/dev/null
command -v jq >/dev/null

read_window_millis() {
  local scheduler="$1"
  local boundary="$2"
  local file="${RESULT_WINDOW_DIR}/result-${scheduler}-${boundary}-millis"
  local value

  [[ -s "${file}" ]]
  value="$(<"${file}")"
  [[ "${value}" =~ ^[0-9]{13}$ ]]
  printf '%s\n' "${value}"
}

first_pod_millis() {
  local scheduler="$1"
  local namespace="$2"
  local from_millis="$3"
  local to_millis="$4"
  local from_seconds=$((from_millis / 1000))
  local to_seconds=$((to_millis / 1000 + 1))
  local user_matcher=""
  local query response first_seconds

  if [[ "${scheduler}" == "yunikorn" ]]; then
    user_matcher=', user="kube-controller-manager"'
  fi

  query="max(timestamp(api_requests_total{cluster=\"${scheduler}\", exported_namespace=\"${namespace}\", resource=\"pods\", verb=\"create\"${user_matcher}} > 0))"
  response="$(curl -fsS --get \
    --data-urlencode "query=${query}" \
    --data-urlencode "start=${from_seconds}" \
    --data-urlencode "end=${to_seconds}" \
    --data-urlencode 'step=500ms' \
    "${PROMETHEUS_URL%/}/api/v1/query_range")"

  first_seconds="$(printf '%s' "${response}" | jq -er --argjson lower "${from_seconds}" '
    if .status != "success" then error("Prometheus query failed") else . end
    | [.data.result[].values[][1] | tonumber | select(. >= $lower)]
    | min // error("no Pod creation sample in scheduler window")
  ')"

  awk -v value="${first_seconds}" 'BEGIN {printf "%.0f\n", value * 1000}'
}

scheduled_target_millis() {
  local scheduler="$1"
  local namespace="$2"
  local from_millis="$3"
  local to_millis="$4"
  local from_seconds=$((from_millis / 1000))
  local to_seconds=$((to_millis / 1000 + 1))
  local scheduled_metric placeholder_metric
  local query response target_seconds

  scheduled_metric="pod_scheduling_latency_seconds_count{cluster=\"${scheduler}\", exported_namespace=\"${namespace}\"}"

  if [[ "${scheduler}" == "yunikorn" ]]; then
    placeholder_metric="api_requests_total{cluster=\"${scheduler}\", exported_namespace=\"${namespace}\", resource=\"pods\", verb=\"create\", user=\"yunikorn-scheduler\"}"
    query="clamp_min(sum(${scheduled_metric} and (timestamp(${scheduled_metric}) >= ${from_seconds})) - (sum(${placeholder_metric} and (timestamp(${placeholder_metric}) >= ${from_seconds})) or vector(0)), 0)"
  else
    query="sum(${scheduled_metric} and (timestamp(${scheduled_metric}) >= ${from_seconds}))"
  fi

  response="$(curl -fsS --get \
    --data-urlencode "query=${query}" \
    --data-urlencode "start=${from_seconds}" \
    --data-urlencode "end=${to_seconds}" \
    --data-urlencode 'step=500ms' \
    "${PROMETHEUS_URL%/}/api/v1/query_range")"

  target_seconds="$(printf '%s' "${response}" | jq -er '
    if .status != "success" then error("Prometheus query failed") else . end
    | [.data.result[].values[] | select((.[1] | tonumber) >= 10000) | .[0]]
    | min // error("actual Scheduled Pods never reached 10000")
  ')"

  awk -v value="${target_seconds}" 'BEGIN {printf "%.0f\n", value * 1000}'
}

second_millis() {
  printf '%s\n' "$@" | sort -n | sed -n '2p'
}

format_iso_millis() {
  local value="$1"
  local seconds=$((value / 1000))
  local millis=$((value % 1000))
  local base

  base="$(jq -nr --argjson seconds "${seconds}" '$seconds | todateiso8601 | sub("Z$"; "")')"
  printf '%s.%03dZ\n' "${base}" "${millis}"
}

kueue_from="$(read_window_millis kueue from)"
kueue_to="$(read_window_millis kueue to)"
volcano_from="$(read_window_millis volcano from)"
volcano_to="$(read_window_millis volcano to)"
yunikorn_from="$(read_window_millis yunikorn from)"
yunikorn_to="$(read_window_millis yunikorn to)"

((kueue_from < kueue_to))
((volcano_from < volcano_to))
((yunikorn_from < yunikorn_to))

kueue_first="$(first_pod_millis kueue bench-kueue "${kueue_from}" "${kueue_to}")"
volcano_first="$(first_pod_millis volcano bench-volcano "${volcano_from}" "${volcano_to}")"
yunikorn_first="$(first_pod_millis yunikorn bench-yunikorn "${yunikorn_from}" "${yunikorn_to}")"
kueue_scheduled_target="$(scheduled_target_millis kueue bench-kueue "${kueue_from}" "${kueue_to}")"
volcano_scheduled_target="$(scheduled_target_millis volcano bench-volcano "${volcano_from}" "${volcano_to}")"
yunikorn_scheduled_target="$(scheduled_target_millis yunikorn bench-yunikorn "${yunikorn_from}" "${yunikorn_to}")"

((kueue_first <= volcano_first))
((volcano_first <= yunikorn_first))

volcano_offset_millis=$((volcano_first - kueue_first))
yunikorn_offset_millis=$((yunikorn_first - kueue_first))
volcano_offset_seconds="$(awk -v value="${volcano_offset_millis}" 'BEGIN {printf "%.3f", value / 1000}')"
yunikorn_offset_seconds="$(awk -v value="${yunikorn_offset_millis}" 'BEGIN {printf "%.3f", value / 1000}')"
volcano_offset_duration="${volcano_offset_millis}ms"
yunikorn_offset_duration="${yunikorn_offset_millis}ms"

aligned_kueue_scheduled_target="${kueue_scheduled_target}"
aligned_volcano_scheduled_target=$((volcano_scheduled_target - volcano_offset_millis))
aligned_yunikorn_scheduled_target=$((yunikorn_scheduled_target - yunikorn_offset_millis))
dashboard_to_millis="$(second_millis \
  "${aligned_kueue_scheduled_target}" \
  "${aligned_volcano_scheduled_target}" \
  "${aligned_yunikorn_scheduled_target}")"
dashboard_to_millis=$((dashboard_to_millis + 5000))
if ((dashboard_to_millis <= kueue_first)); then
  printf 'invalid dashboard end: second scheduler target is not after T+0\n' >&2
  exit 1
fi

from_iso="$(format_iso_millis "${kueue_first}")"
to_iso="$(format_iso_millis "${dashboard_to_millis}")"
if t0_cst_base="$(TZ=Asia/Shanghai date -d "@$((kueue_first / 1000))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"; then
  :
else
  t0_cst_base="$(TZ=Asia/Shanghai date -r "$((kueue_first / 1000))" '+%Y-%m-%d %H:%M:%S')"
fi
printf -v t0_cst '%s.%03d' "${t0_cst_base}" "$((kueue_first % 1000))"

if [[ "${GANG}" == "true" ]]; then
  mode="Gang"
else
  mode="Non-Gang"
fi

if [[ "${JOBS_SIZE_PER_QUEUE}" == "1" ]]; then
  job_word="Job"
else
  job_word="Jobs"
fi
if [[ "${PODS_SIZE_PER_JOB}" == "1" ]]; then
  pod_word="Pod"
else
  pod_word="Pods"
fi
shape="${JOBS_SIZE_PER_QUEUE} ${job_word} × ${PODS_SIZE_PER_JOB} ${pod_word}"

mkdir -p "${ROOT_DIR}/tmp"
dashboard="$(mktemp "${ROOT_DIR}/tmp/relative-dashboard-${SCENARIO}.XXXXXX.json")"
manifest="$(mktemp "${ROOT_DIR}/tmp/relative-dashboard-${SCENARIO}.XXXXXX.yaml")"
trap 'rm -f "${dashboard}" "${manifest}"' EXIT

jq \
  --arg scenario "${SCENARIO}" \
  --arg mode "${mode}" \
  --arg shape "${shape}" \
  --arg from_iso "${from_iso}" \
  --arg to_iso "${to_iso}" \
  --arg t0_cst "${t0_cst}" \
  --arg volcano_offset_seconds "${volcano_offset_seconds}" \
  --arg yunikorn_offset_seconds "${yunikorn_offset_seconds}" \
  --arg volcano_offset_duration "${volcano_offset_duration}" \
  --arg yunikorn_offset_duration "${yunikorn_offset_duration}" '
  walk(
    if type == "string" then
      gsub("__SCENARIO__"; $scenario)
      | gsub("__MODE__"; $mode)
      | gsub("__SHAPE__"; $shape)
      | gsub("__FROM_ISO__"; $from_iso)
      | gsub("__TO_ISO__"; $to_iso)
      | gsub("__T0_CST__"; $t0_cst)
      | gsub("__VOLCANO_OFFSET_SECONDS__"; $volcano_offset_seconds)
      | gsub("__YUNIKORN_OFFSET_SECONDS__"; $yunikorn_offset_seconds)
      | gsub("__VOLCANO_OFFSET_DURATION__"; $volcano_offset_duration)
      | gsub("__YUNIKORN_OFFSET_DURATION__"; $yunikorn_offset_duration)
    else . end
  )
' "${TEMPLATE}" >"${dashboard}"

! grep -Eq '__[A-Z0-9_]+__' "${dashboard}"
jq -e --arg uid "perf-relative-s${SCENARIO}" --arg scenario "${SCENARIO}" '
  .uid == $uid
  and .id == null
  and (.panels | length) == 5
  and .tags == ["benchmark", "relative-time", ("scenario-" + $scenario)]
  and (.templating.list[] | select(.name == "scheduler") | .allValue) == "kueue|volcano|yunikorn"
' "${dashboard}" >/dev/null

configmap="scheduling-perf-relative-s1-s7"
dashboard_key="relative-s${SCENARIO}.json"
kubectl_cmd=("${KUBECTL}" --kubeconfig "${KUBECONFIG}")

if "${kubectl_cmd[@]}" -n "${GRAFANA_NAMESPACE}" get configmap "${configmap}" >/dev/null 2>&1; then
  patch="$(jq -cn --arg key "${dashboard_key}" --rawfile dashboard "${dashboard}" '{data:{($key):$dashboard}}')"
  "${kubectl_cmd[@]}" -n "${GRAFANA_NAMESPACE}" patch configmap "${configmap}" --type merge -p "${patch}" >/dev/null
else
  jq -n \
    --arg name "${configmap}" \
    --arg namespace "${GRAFANA_NAMESPACE}" \
    --arg key "${dashboard_key}" \
    --rawfile dashboard "${dashboard}" '
    {
      apiVersion: "v1",
      kind: "ConfigMap",
      metadata: {
        name: $name,
        namespace: $namespace,
        labels: {grafana_dashboard: "1"}
      },
      data: {($key): $dashboard}
    }
  ' >"${manifest}"
  "${kubectl_cmd[@]}" apply -f "${manifest}" >/dev/null
fi

if ((SCENARIO == 8)); then
  "${kubectl_cmd[@]}" -n "${GRAFANA_NAMESPACE}" delete configmap scheduling-perf-relative-s8 \
    --ignore-not-found --wait=false >/dev/null
fi

printf 'relative_dashboard_updated scenario=%s t0=%s volcano_offset=%s yunikorn_offset=%s configmap=%s\n' \
  "${SCENARIO}" "${t0_cst}" "${volcano_offset_duration}" "${yunikorn_offset_duration}" "${configmap}"
