#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

if [[ "$#" -ne 4 ]]; then
  printf 'usage: %s REPOSITORY SCENARIO SCHEDULER RUN_WORKSPACE\n' "$0" >&2
  exit 2
fi

repository="$1"
scenario="$2"
scheduler="$3"
run_workspace="$4"

case "${scenario}" in
  1|2|3|4|5|6|7|8) ;;
  *) printf 'scenario must be an integer from 1 to 8\n' >&2; exit 2 ;;
esac

case "${scheduler}" in
  kueue|volcano|yunikorn) ;;
  *) printf 'scheduler must be kueue, volcano, or yunikorn\n' >&2; exit 2 ;;
esac

if [[ ! -d "${repository}/.git" ]]; then
  printf 'repository is not a Git checkout: %s\n' "${repository}" >&2
  exit 2
fi

mkdir -p "${run_workspace}"
if [[ -e "${run_workspace}/started-cst.txt" ]]; then
  printf 'run workspace already initialized: %s\n' "${run_workspace}" >&2
  exit 2
fi

for command in date git make python3 tee; do
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

cd "${repository}"

if [[ "$(git branch --show-current)" != "master" ]]; then
  printf 'server repository must be on master\n' >&2
  exit 2
fi

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  printf 'server repository has tracked changes\n' >&2
  exit 2
fi

git pull --ff-only origin master

TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S' >"${run_workspace}/started-cst.txt"
git rev-parse HEAD >"${run_workspace}/tested-commit.txt"

set +o errexit
make "scenario-${scenario}" SCHEDULERS="${scheduler}" 2>&1 | timestamp_stream | tee "${run_workspace}/make.log"
make_status="${PIPESTATUS[0]}"
printf '%s\n' "${make_status}" >"${run_workspace}/make-exit-code.txt"

make down 2>&1 | timestamp_stream | tee "${run_workspace}/make-down.log"
down_status="${PIPESTATUS[0]}"
printf '%s\n' "${down_status}" >"${run_workspace}/make-down-exit-code.txt"
set -o errexit

publish_status=0
if [[ "${make_status}" -eq 0 && "${down_status}" -eq 0 ]]; then
  result_path="results/scenario-${scenario}/${scheduler}"
  set +o errexit
  git add -- "${result_path}"
  publish_status="$?"
  if [[ "${publish_status}" -eq 0 ]]; then
    run_stamp="$(TZ=Asia/Shanghai date '+%m%d%H%M%S')"
    git commit -m "results: scenario ${scenario} ${scheduler} single test ${run_stamp}"
    publish_status="$?"
  fi
  if [[ "${publish_status}" -eq 0 ]]; then
    git push origin master
    publish_status="$?"
  fi
  if [[ "${publish_status}" -eq 0 ]]; then
    git rev-parse HEAD >"${run_workspace}/published-commit.txt"
  fi
  set -o errexit
else
  publish_status=1
fi

TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S' >"${run_workspace}/ended-cst.txt"
printf 'make=%s\nmake_down=%s\npublish=%s\n' "${make_status}" "${down_status}" "${publish_status}" >"${run_workspace}/status.txt"
touch "${run_workspace}/complete"

if [[ "${make_status}" -ne 0 ]]; then
  exit "${make_status}"
fi
if [[ "${down_status}" -ne 0 ]]; then
  exit "${down_status}"
fi
exit "${publish_status}"
