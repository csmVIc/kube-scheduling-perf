#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

repository="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace="$(mktemp -d)"
trap 'rm -rf -- "${workspace}"' EXIT

file_inode() {
  local path="$1"

  if stat -c %i "${path}" 2>/dev/null; then
    return
  fi
  stat -f %i "${path}"
}

write_events_before_rotation() {
  local path="$1"

  printf '%s\n' \
    '{"stage":"ResponseComplete","verb":"create","objectRef":{"resource":"pods","namespace":"bench-kueue","name":"pod-1"},"responseStatus":{"code":201},"stageTimestamp":"2026-08-20T00:00:01.000Z"}' \
    '{"stage":"ResponseComplete","verb":"create","objectRef":{"resource":"pods","namespace":"bench-kueue","name":"pod-2"},"responseStatus":{"code":201},"stageTimestamp":"2026-08-20T00:00:01.500Z"}' \
    '{"stage":"ResponseComplete","verb":"create","objectRef":{"resource":"pods","namespace":"bench-kueue","name":"pod-1","subresource":"binding"},"responseStatus":{"code":201},"stageTimestamp":"2026-08-20T00:00:02.000Z"}' >>"${path}"
}

write_event_after_rotation() {
  local path="$1"

  printf '%s\n' \
    '{"stage":"ResponseComplete","verb":"create","objectRef":{"resource":"pods","namespace":"bench-kueue","name":"pod-2","subresource":"binding"},"responseStatus":{"code":201},"stageTimestamp":"2026-08-20T00:00:03.500Z"}' >>"${path}"
}

assert_report() {
  local output="$1"

  grep -F 'P50:  1000.00 ms' "${output}/report.txt" >/dev/null
  grep -F 'P90:  2000.00 ms' "${output}/report.txt" >/dev/null
  grep -F 'P99:  2000.00 ms' "${output}/report.txt" >/dev/null
  grep -F 'Total scheduled: 2 pods' "${output}/report.txt" >/dev/null
  grep -F 'Pod scheduling throughput: 1.33 pods/sec' "${output}/report.txt" >/dev/null
  grep -F 'Throughput window: 1.500 sec (2 binding events)' "${output}/report.txt" >/dev/null
}

run_report() {
  local audit_log="$1"
  local from_inode="$2"
  local from_bytes="$3"
  local to_inode="$4"
  local to_bytes="$5"
  local output="$6"

  SCHEDULER=kueue \
    FROM_MILLIS=1787184000000 \
    TO_MILLIS=1787184010000 \
    AUDIT_FROM_INODE="${from_inode}" \
    AUDIT_FROM_BYTES="${from_bytes}" \
    AUDIT_TO_INODE="${to_inode}" \
    AUDIT_TO_BYTES="${to_bytes}" \
    OUTPUT_DIR="${output}" \
    AUDIT_LOG_PATH="${audit_log}" \
    "${repository}/hack/save-scheduler-result.sh"
}

same_dir="${workspace}/same"
mkdir -p "${same_dir}"
same_log="${same_dir}/kube-apiserver-audit.log"
printf '%s\n' '{"ignored":"before-window"}' >"${same_log}"
same_from_inode="$(file_inode "${same_log}")"
same_from_bytes="$(wc -c <"${same_log}")"
write_events_before_rotation "${same_log}"
write_event_after_rotation "${same_log}"
same_to_inode="$(file_inode "${same_log}")"
same_to_bytes="$(wc -c <"${same_log}")"
run_report "${same_log}" "${same_from_inode}" "${same_from_bytes}" "${same_to_inode}" "${same_to_bytes}" "${same_dir}/output"
assert_report "${same_dir}/output"

rotation_dir="${workspace}/rotation"
mkdir -p "${rotation_dir}"
rotation_log="${rotation_dir}/kube-apiserver-audit.log"
printf '%s\n' '{"ignored":"before-window"}' >"${rotation_log}"
rotation_from_inode="$(file_inode "${rotation_log}")"
rotation_from_bytes="$(wc -c <"${rotation_log}")"
write_events_before_rotation "${rotation_log}"
mv "${rotation_log}" "${rotation_dir}/kube-apiserver-audit-2026-08-20T00-00-02.500.log"
write_event_after_rotation "${rotation_log}"
rotation_to_inode="$(file_inode "${rotation_log}")"
rotation_to_bytes="$(wc -c <"${rotation_log}")"
run_report "${rotation_log}" "${rotation_from_inode}" "${rotation_from_bytes}" "${rotation_to_inode}" "${rotation_to_bytes}" "${rotation_dir}/output"
assert_report "${rotation_dir}/output"

printf 'save-scheduler-result tests passed\n'
