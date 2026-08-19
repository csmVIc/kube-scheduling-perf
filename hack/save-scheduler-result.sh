#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

: "${SCHEDULER:?SCHEDULER is required}"
: "${FROM_MILLIS:?FROM_MILLIS is required}"
: "${TO_MILLIS:?TO_MILLIS is required}"
: "${AUDIT_FROM_BYTES:?AUDIT_FROM_BYTES is required}"
: "${AUDIT_TO_BYTES:?AUDIT_TO_BYTES is required}"
: "${OUTPUT_DIR:?OUTPUT_DIR is required}"
: "${PROMETHEUS_URL:?PROMETHEUS_URL is required}"
: "${AUDIT_LOG_PATH:?AUDIT_LOG_PATH is required}"

case "${SCHEDULER}" in
  kueue|volcano|yunikorn) ;;
  *) printf 'unsupported scheduler: %s\n' "${SCHEDULER}" >&2; exit 1 ;;
esac

[[ "${FROM_MILLIS}" =~ ^[0-9]{13}$ ]]
[[ "${TO_MILLIS}" =~ ^[0-9]{13}$ ]]
[[ "${AUDIT_FROM_BYTES}" =~ ^[0-9]+$ ]]
[[ "${AUDIT_TO_BYTES}" =~ ^[0-9]+$ ]]
((FROM_MILLIS < TO_MILLIS))
((AUDIT_FROM_BYTES <= AUDIT_TO_BYTES))
[[ -f "${AUDIT_LOG_PATH}" ]]

command -v awk >/dev/null
command -v curl >/dev/null
command -v jq >/dev/null

namespace="bench-${SCHEDULER}"
from_seconds="$(awk -v value="${FROM_MILLIS}" 'BEGIN {printf "%.3f", value / 1000}')"
to_seconds="$(awk -v value="${TO_MILLIS}" 'BEGIN {printf "%.3f", value / 1000}')"
selector="cluster=\"${SCHEDULER}\", exported_namespace=\"${namespace}\""

format_cst() {
  local millis="$1"
  local seconds=$((millis / 1000))

  if TZ=Asia/Shanghai date -d "@${seconds}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null; then
    return
  fi
  TZ=Asia/Shanghai date -r "${seconds}" '+%Y-%m-%d %H:%M:%S'
}

prometheus_query() {
  local query="$1"

  curl -fsS --get \
    --data-urlencode "query=${query}" \
    --data-urlencode "time=${to_seconds}" \
    "${PROMETHEUS_URL%/}/api/v1/query" |
    jq -ce 'if .status == "success" then .data.result else error("Prometheus query failed") end'
}

histogram_metric="pod_scheduling_latency_seconds_bucket{${selector}}"
bucket_query="sum by (le) (${histogram_metric} and (timestamp(${histogram_metric}) >= ${from_seconds}))"
buckets="$(prometheus_query "${bucket_query}" | jq -c '[.[] | {le: .metric.le, val: (.value[1] | tonumber)}]')"

histogram_quantile() {
  local quantile="$1"

  jq -r --argjson quantile "${quantile}" '
    sort_by(if .le == "+Inf" then 1e308 else (.le | tonumber) end) as $sorted |
    ($sorted | last.val // 0) as $total |
    if $total == 0 then "N/A"
    else
      ($quantile * $total) as $target |
      $sorted | reduce .[] as $bucket (
        {prev_le: 0, prev_count: 0, result: null};
        if .result == null then
          ($bucket.le | if . == "+Inf" then 1e308 else tonumber end) as $upper |
          if $bucket.val >= $target then
            if ($bucket.val - .prev_count) == 0 then
              .result = $upper
            else
              .result = (.prev_le + ($upper - .prev_le) * ($target - .prev_count) / ($bucket.val - .prev_count))
            end
          else
            .prev_le = $upper |
            .prev_count = $bucket.val
          end
        else . end
      ) | .result // "N/A"
    end
  ' <<<"${buckets}"
}

p50="$(histogram_quantile 0.5)"
p90="$(histogram_quantile 0.9)"
p99="$(histogram_quantile 0.99)"

if [[ "${SCHEDULER}" == "yunikorn" ]]; then
  scheduled_metric="yunikorn_workload_pods_scheduled_total{${selector}}"
  scheduled_query="sum(${scheduled_metric} and (timestamp(${scheduled_metric}) >= ${from_seconds}))"
  scheduled="$(prometheus_query "${scheduled_query}" | jq -r 'if length == 0 then 0 else (.[0].value[1] | tonumber | round) end')"
else
  scheduled="$(jq -r 'map(select(.le == "+Inf"))[0].val // 0 | round' <<<"${buckets}")"
fi

audit_bytes=$((AUDIT_TO_BYTES - AUDIT_FROM_BYTES))
set +o pipefail
throughput_stats="$(
  tail -c "+$((AUDIT_FROM_BYTES + 1))" "${AUDIT_LOG_PATH}" |
  head -c "${audit_bytes}" |
  jq -Rnc \
    --arg scheduler "${SCHEDULER}" \
    --arg namespace "${namespace}" \
    --argjson before "${from_seconds}" \
    --argjson after "${to_seconds}" '
    def ts_epoch:
      capture("(?<Y>[0-9]{4})-(?<m>[0-9]{2})-(?<d>[0-9]{2})T(?<H>[0-9]{2}):(?<M>[0-9]{2}):(?<S>[0-9]{2})(?<frac>\\.[0-9]+)?Z") as $t |
      ([
        ($t.Y | tonumber),
        (($t.m | tonumber) - 1),
        ($t.d | tonumber),
        ($t.H | tonumber),
        ($t.M | tonumber),
        ($t.S | tonumber),
        0,
        0
      ] | mktime) + (($t.frac // "0") | tonumber);

    reduce (
      inputs |
      fromjson? |
      select(.stage == "ResponseComplete") |
      select(.verb == "create") |
      select(.objectRef.resource == "pods") |
      select(.objectRef.subresource == "binding") |
      select(.objectRef.namespace == $namespace) |
      select((.responseStatus.code // 0) >= 200 and (.responseStatus.code // 0) < 300) |
      select($scheduler != "yunikorn" or ((.objectRef.name // "") | startswith("tg-") | not)) |
      (.stageTimestamp | ts_epoch) |
      select(. >= $before and . <= $after)
    ) as $timestamp (
      {count: 0, first: null, last: null};
      .count += 1 |
      .first = if .first == null or $timestamp < .first then $timestamp else .first end |
      .last = if .last == null or $timestamp > .last then $timestamp else .last end
    ) |
    if .count < 2 then
      {count: .count, window_seconds: null, pods_per_second: null}
    else
      (.last - .first) as $window |
      {
        count: .count,
        window_seconds: (($window * 1000 | round) / 1000),
        pods_per_second: ((.count / $window * 100 | round) / 100)
      }
    end
  '
)"
set -o pipefail

throughput="$(jq -r '.pods_per_second // "N/A"' <<<"${throughput_stats}")"
throughput_window="$(jq -r '.window_seconds // "N/A"' <<<"${throughput_stats}")"
binding_count="$(jq -r '.count' <<<"${throughput_stats}")"

fmt_ms() {
  local value="$1"

  awk -v value="${value}" 'BEGIN {if (value == "N/A") print "N/A"; else printf "%.2f", value * 1000}'
}

fmt_number() {
  local value="$1"
  local precision="$2"

  awk -v value="${value}" -v precision="${precision}" 'BEGIN {
    if (value == "N/A") print "N/A";
    else printf "%.*f", precision, value
  }'
}

mkdir -p "${OUTPUT_DIR}"
printf '%s 至 %s\n' "$(format_cst "${FROM_MILLIS}")" "$(format_cst "${TO_MILLIS}")" >"${OUTPUT_DIR}/window.txt"

report_time="$(TZ=Asia/Shanghai date '+%H:%M:%S')"
{
  printf '[INFO]  %s === Pod Scheduling Latency (created -> scheduled) ===\n' "${report_time}"
  printf '[INFO]  %s   P50:  %s ms\n' "${report_time}" "$(fmt_ms "${p50}")"
  printf '[INFO]  %s   P90:  %s ms\n' "${report_time}" "$(fmt_ms "${p90}")"
  printf '[INFO]  %s   P99:  %s ms\n' "${report_time}" "$(fmt_ms "${p99}")"
  printf '[INFO]  %s   Total scheduled: %s pods\n' "${report_time}" "${scheduled}"
  printf '[INFO]  %s   Pod scheduling throughput: %s pods/sec\n' "${report_time}" "$(fmt_number "${throughput}" 2)"
  printf '[INFO]  %s   Throughput window: %s sec (%s binding events)\n' "${report_time}" "$(fmt_number "${throughput_window}" 3)" "${binding_count}"
} >"${OUTPUT_DIR}/report.txt"
