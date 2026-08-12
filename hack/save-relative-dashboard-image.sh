#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

: "${SCENARIO:?SCENARIO is required}"
: "${FROM:?FROM epoch milliseconds is required}"
: "${TO:?TO epoch milliseconds is required}"
: "${FROM_ISO:?FROM_ISO is required}"
: "${TO_ISO:?TO_ISO is required}"
: "${OUTPUT_FILE:?OUTPUT_FILE is required}"

[[ "${SCENARIO}" =~ ^[1-8]$ ]]
[[ "${FROM}" =~ ^[0-9]{13}$ ]]
[[ "${TO}" =~ ^[0-9]{13}$ ]]
((FROM < TO))

command -v curl >/dev/null
command -v jq >/dev/null
command -v od >/dev/null

DIR="$(dirname "${BASH_SOURCE[0]}")"
ROOT_DIR="$(realpath "${DIR}/..")"
CROP_IMAGE_BIN="${CROP_IMAGE_BIN:-${ROOT_DIR}/bin/crop-dashboard-image}"
[[ -x "${CROP_IMAGE_BIN}" ]]
GRAFANA_URL="${GRAFANA_URL:-http://127.0.0.1:8080/grafana}"
uid="perf-relative-s${SCENARIO}"
loaded=false

for _ in $(seq 1 60); do
  if response="$(curl -fsS --max-time 5 "${GRAFANA_URL%/}/api/dashboards/uid/${uid}" 2>/dev/null)"; then
    if jq -e \
      --arg uid "${uid}" \
      --arg from "${FROM_ISO}" \
      --arg to "${TO_ISO}" '
      .dashboard.uid == $uid
      and .dashboard.time.from == $from
      and .dashboard.time.to == $to
    ' <<<"${response}" >/dev/null; then
      loaded=true
      break
    fi
  fi
  sleep 1
done

if [[ "${loaded}" != "true" ]]; then
  printf 'Grafana did not load %s with the expected time window\n' "${uid}" >&2
  exit 1
fi

mkdir -p "$(dirname "${OUTPUT_FILE}")"
temporary="$(mktemp "${OUTPUT_FILE}.XXXXXX")"
rendered="$(mktemp "${OUTPUT_FILE}.rendered.XXXXXX")"
trap 'rm -f "${temporary}" "${rendered}"' EXIT

curl -fsS --max-time 180 --get --output "${rendered}" \
  --data-urlencode 'orgId=1' \
  --data-urlencode "from=${FROM}" \
  --data-urlencode "to=${TO}" \
  --data-urlencode 'timezone=Asia/Shanghai' \
  --data-urlencode 'var-scheduler=$__all' \
  --data-urlencode 'theme=light' \
  --data-urlencode 'kiosk=true' \
  --data-urlencode 'width=1600' \
  --data-urlencode 'height=1000' \
  --data-urlencode 'scale=1' \
  "${GRAFANA_URL%/}/render/d/${uid}/scenario-${SCENARIO}-relative-scheduler-comparison"

[[ "$(od -An -tx1 -N8 "${rendered}" | tr -d ' \n')" == "89504e470d0a1a0a" ]]
"${CROP_IMAGE_BIN}" "${rendered}" "${temporary}" 8 62 1584 762
[[ "$(od -An -tx1 -N8 "${temporary}" | tr -d ' \n')" == "89504e470d0a1a0a" ]]
mv "${temporary}" "${OUTPUT_FILE}"
trap - EXIT
