#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

if [[ "$#" -ne 2 ]]; then
  printf 'usage: %s REPOSITORY RUN_ARCHIVE\n' "$0" >&2
  exit 2
fi

repository="$1"
run_archive="$2"

if [[ ! -d "${repository}/.git" ]]; then
  printf 'repository is not a Git checkout: %s\n' "${repository}" >&2
  exit 2
fi

mkdir -p "${run_archive}"
if [[ -e "${run_archive}/started-cst.txt" ]]; then
  printf 'run archive already initialized: %s\n' "${run_archive}" >&2
  exit 2
fi

cd "${repository}"

for command in date git make python3 sha256sum tee; do
  command -v "${command}" >/dev/null || {
    printf 'required command is unavailable: %s\n' "${command}" >&2
    exit 2
  }
done

timestamp_stream() {
  TZ=Asia/Shanghai python3 -u -c 'import sys, time
for line in sys.stdin:
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{stamp}] {line}", end="", flush=True)'
}

epoch_millis() {
  python3 -c 'import time; print(time.time_ns() // 1_000_000)'
}

write_result_manifest() {
  local destination="$1"
  local scenario directory file digest

  : >"${destination}"
  for scenario in $(seq 1 8); do
    directory="results/scenario-${scenario}"
    file="${directory}/result-window.txt"
    if [[ -f "${file}" ]]; then
      digest="$(sha256sum "${file}" | awk '{print $1}')"
      printf '%s\t%s\t%s\n' "${scenario}" "${digest}" "${file}" >>"${destination}"
    else
      printf '%s\tMISSING\t%s\n' "${scenario}" "${file}" >>"${destination}"
    fi
  done
}

started_epoch_millis="$(epoch_millis)"
TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S' >"${run_archive}/started-cst.txt"
printf '%s\n' "${started_epoch_millis}" >"${run_archive}/started-epoch-millis.txt"
git rev-parse HEAD >"${run_archive}/tested-commit.txt"
write_result_manifest "${run_archive}/results-before.tsv"

set +o errexit
make 2>&1 | timestamp_stream | tee "${run_archive}/make.log"
make_status="${PIPESTATUS[0]}"
printf '%s\n' "${make_status}" >"${run_archive}/make-exit-code.txt"

make down 2>&1 | timestamp_stream | tee "${run_archive}/make-down.log"
down_status="${PIPESTATUS[0]}"
printf '%s\n' "${down_status}" >"${run_archive}/make-down-exit-code.txt"
set -o errexit

write_result_manifest "${run_archive}/results-after.tsv"
ended_epoch_millis="$(epoch_millis)"
TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S' >"${run_archive}/ended-cst.txt"
printf '%s\n' "${ended_epoch_millis}" >"${run_archive}/ended-epoch-millis.txt"
printf '%s\n' "$((ended_epoch_millis - started_epoch_millis))" >"${run_archive}/duration-millis.txt"
printf 'make=%s\nmake_down=%s\n' "${make_status}" "${down_status}" >"${run_archive}/status.txt"
touch "${run_archive}/complete"

if [[ "${make_status}" -ne 0 ]]; then
  exit "${make_status}"
fi
exit "${down_status}"
