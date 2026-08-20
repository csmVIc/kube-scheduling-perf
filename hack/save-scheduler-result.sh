#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

: "${SCHEDULER:?SCHEDULER is required}"
: "${FROM_MILLIS:?FROM_MILLIS is required}"
: "${TO_MILLIS:?TO_MILLIS is required}"
: "${AUDIT_FROM_INODE:?AUDIT_FROM_INODE is required}"
: "${AUDIT_FROM_BYTES:?AUDIT_FROM_BYTES is required}"
: "${AUDIT_TO_INODE:?AUDIT_TO_INODE is required}"
: "${AUDIT_TO_BYTES:?AUDIT_TO_BYTES is required}"
: "${OUTPUT_DIR:?OUTPUT_DIR is required}"
: "${AUDIT_LOG_PATH:?AUDIT_LOG_PATH is required}"

case "${SCHEDULER}" in
  kueue|volcano|yunikorn) ;;
  *) printf 'unsupported scheduler: %s\n' "${SCHEDULER}" >&2; exit 1 ;;
esac

[[ "${FROM_MILLIS}" =~ ^[0-9]{13}$ ]]
[[ "${TO_MILLIS}" =~ ^[0-9]{13}$ ]]
[[ "${AUDIT_FROM_INODE}" =~ ^[0-9]+$ ]]
[[ "${AUDIT_FROM_BYTES}" =~ ^[0-9]+$ ]]
[[ "${AUDIT_TO_INODE}" =~ ^[0-9]+$ ]]
[[ "${AUDIT_TO_BYTES}" =~ ^[0-9]+$ ]]
((FROM_MILLIS < TO_MILLIS))
[[ -f "${AUDIT_LOG_PATH}" ]]

command -v awk >/dev/null
command -v jq >/dev/null

namespace="bench-${SCHEDULER}"
from_seconds="$(awk -v value="${FROM_MILLIS}" 'BEGIN {printf "%.3f", value / 1000}')"
to_seconds="$(awk -v value="${TO_MILLIS}" 'BEGIN {printf "%.3f", value / 1000}')"

format_cst() {
  local millis="$1"
  local seconds=$((millis / 1000))

  if TZ=Asia/Shanghai date -d "@${seconds}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null; then
    return
  fi
  TZ=Asia/Shanghai date -r "${seconds}" '+%Y-%m-%d %H:%M:%S'
}

file_inode() {
  local path="$1"

  if stat -c %i "${path}" 2>/dev/null; then
    return
  fi
  stat -f %i "${path}"
}

find_audit_file() {
  local expected_inode="$1"
  local candidate

  while IFS= read -r -d '' candidate; do
    if [[ "$(file_inode "${candidate}")" == "${expected_inode}" ]]; then
      printf '%s\n' "${candidate}"
      return
    fi
  done < <(find "$(dirname "${AUDIT_LOG_PATH}")" -maxdepth 1 -type f -print0)

  printf 'audit file with inode %s is unavailable\n' "${expected_inode}" >&2
  return 1
}

audit_from_file="$(find_audit_file "${AUDIT_FROM_INODE}")"
audit_to_file="$(find_audit_file "${AUDIT_TO_INODE}")"
audit_from_file_bytes="$(wc -c <"${audit_from_file}")"
audit_to_file_bytes="$(wc -c <"${audit_to_file}")"

((AUDIT_FROM_BYTES <= audit_from_file_bytes))
((AUDIT_TO_BYTES <= audit_to_file_bytes))
if [[ "${AUDIT_FROM_INODE}" == "${AUDIT_TO_INODE}" ]]; then
  ((AUDIT_FROM_BYTES <= AUDIT_TO_BYTES))
fi

stream_audit_window() {
  if [[ "${AUDIT_FROM_INODE}" == "${AUDIT_TO_INODE}" ]]; then
    tail -c "+$((AUDIT_FROM_BYTES + 1))" "${audit_from_file}" |
      head -c "$((AUDIT_TO_BYTES - AUDIT_FROM_BYTES))"
    return
  fi

  tail -c "+$((AUDIT_FROM_BYTES + 1))" "${audit_from_file}"
  head -c "${AUDIT_TO_BYTES}" "${audit_to_file}"
}

set +o pipefail
audit_stats="$(
  stream_audit_window |
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

    def nearest_rank($sorted; $quantile):
      if ($sorted | length) == 0 then null
      else $sorted[((($sorted | length) * $quantile | ceil) - 1)]
      end;

    (reduce (
      inputs |
      fromjson? |
      select(.stage == "ResponseComplete") |
      select(.verb == "create") |
      select(.objectRef.resource == "pods") |
      select(.objectRef.namespace == $namespace) |
      select((.responseStatus.code // 0) >= 200 and (.responseStatus.code // 0) < 300) |
      select($scheduler != "yunikorn" or ((.objectRef.name // "") | startswith("tg-") | not)) |
      {
        name: .objectRef.name,
        subresource: (.objectRef.subresource // ""),
        timestamp: (.stageTimestamp | ts_epoch)
      } |
      select(.timestamp >= $before and .timestamp <= $after) |
      select(.subresource == "" or .subresource == "binding")
    ) as $event (
      {created: {}, bound: {}};
      if $event.subresource == "binding" then
        .bound[$event.name] = $event.timestamp
      else
        .created[$event.name] = $event.timestamp
      end
    )) as $events |
    ($events.bound | to_entries | map(.value)) as $binding_times |
    ($events.bound | to_entries | map(
      select($events.created[.key] != null) |
      (.value - $events.created[.key]) |
      select(. >= 0)
    ) | sort) as $latencies |
    ($binding_times | length) as $binding_count |
    ($latencies | length) as $paired_count |
    if $binding_count == 0 then
      error("no successful pod binding events found in the result window")
    elif $paired_count != $binding_count then
      error("pod create/binding event count mismatch: bindings=\($binding_count), paired=\($paired_count)")
    elif $binding_count < 2 then
      {
        count: $binding_count,
        p50: nearest_rank($latencies; 0.50),
        p90: nearest_rank($latencies; 0.90),
        p99: nearest_rank($latencies; 0.99),
        window_seconds: null,
        pods_per_second: null
      }
    else
      (($binding_times | max) - ($binding_times | min)) as $window |
      {
        count: $binding_count,
        p50: nearest_rank($latencies; 0.50),
        p90: nearest_rank($latencies; 0.90),
        p99: nearest_rank($latencies; 0.99),
        window_seconds: (($window * 1000 | round) / 1000),
        pods_per_second: (($binding_count / $window * 100 | round) / 100)
      }
    end
  '
)"
set -o pipefail

p50="$(jq -r '.p50' <<<"${audit_stats}")"
p90="$(jq -r '.p90' <<<"${audit_stats}")"
p99="$(jq -r '.p99' <<<"${audit_stats}")"
scheduled="$(jq -r '.count' <<<"${audit_stats}")"
throughput="$(jq -r '.pods_per_second // "N/A"' <<<"${audit_stats}")"
throughput_window="$(jq -r '.window_seconds // "N/A"' <<<"${audit_stats}")"
binding_count="${scheduled}"

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
