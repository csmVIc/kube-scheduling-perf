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
  local query response first_seconds

  query="max(timestamp(api_requests_total{cluster=\"${scheduler}\", exported_namespace=\"${namespace}\", resource=\"pods\", verb=\"create\"} > 0))"
  response="$(curl -fsS --get \
    --data-urlencode "query=${query}" \
    --data-urlencode "start=${from_seconds}" \
    --data-urlencode "end=${to_seconds}" \
    --data-urlencode 'step=1s' \
    "${PROMETHEUS_URL%/}/api/v1/query_range")"

  first_seconds="$(printf '%s' "${response}" | jq -er --argjson lower "${from_seconds}" '
    if .status != "success" then error("Prometheus query failed") else . end
    | [.data.result[].values[][1] | tonumber | select(. >= $lower)]
    | min // error("no Pod creation sample in scheduler window")
  ')"

  awk -v value="${first_seconds}" 'BEGIN {printf "%.0f\n", value * 1000}'
}

max_millis() {
  local maximum="$1"
  shift
  local value
  for value in "$@"; do
    if ((value > maximum)); then
      maximum="${value}"
    fi
  done
  printf '%s\n' "${maximum}"
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

((kueue_first <= volcano_first))
((volcano_first <= yunikorn_first))

volcano_offset=$(((volcano_first - kueue_first + 500) / 1000))
yunikorn_offset=$(((yunikorn_first - kueue_first + 500) / 1000))

aligned_kueue_to="${kueue_to}"
aligned_volcano_to=$((volcano_to - volcano_offset * 1000))
aligned_yunikorn_to=$((yunikorn_to - yunikorn_offset * 1000))
dashboard_to_millis="$(max_millis "${aligned_kueue_to}" "${aligned_volcano_to}" "${aligned_yunikorn_to}")"
dashboard_to_millis=$((dashboard_to_millis + 15000))
if ((dashboard_to_millis <= kueue_first)); then
  dashboard_to_millis=$((kueue_first + 60000))
fi

from_iso="$(jq -nr --argjson millis "${kueue_first}" '$millis / 1000 | todateiso8601')"
to_iso="$(jq -nr --argjson millis "${dashboard_to_millis}" '$millis / 1000 | todateiso8601')"
if t0_cst="$(TZ=Asia/Shanghai date -d "@$((kueue_first / 1000))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"; then
  :
else
  t0_cst="$(TZ=Asia/Shanghai date -r "$((kueue_first / 1000))" '+%Y-%m-%d %H:%M:%S')"
fi

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
  --arg volcano_offset "${volcano_offset}" \
  --arg yunikorn_offset "${yunikorn_offset}" '
  walk(
    if type == "string" then
      gsub("__SCENARIO__"; $scenario)
      | gsub("__MODE__"; $mode)
      | gsub("__SHAPE__"; $shape)
      | gsub("__FROM_ISO__"; $from_iso)
      | gsub("__TO_ISO__"; $to_iso)
      | gsub("__T0_CST__"; $t0_cst)
      | gsub("__VOLCANO_OFFSET__"; $volcano_offset)
      | gsub("__YUNIKORN_OFFSET__"; $yunikorn_offset)
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

printf 'relative_dashboard_updated scenario=%s t0=%s volcano_offset=%ss yunikorn_offset=%ss configmap=%s\n' \
  "${SCENARIO}" "${t0_cst}" "${volcano_offset}" "${yunikorn_offset}" "${configmap}"
