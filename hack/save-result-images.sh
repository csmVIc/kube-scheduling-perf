#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

DIR="$(dirname "${BASH_SOURCE[0]}")"
ROOT_DIR="$(realpath "${DIR}/..")"

: "${FROM:?FROM epoch milliseconds is required}"
: "${TO:?TO epoch milliseconds is required}"

[[ "${FROM}" =~ ^[0-9]{13}$ ]]
[[ "${TO}" =~ ^[0-9]{13}$ ]]
(( FROM < TO ))

OUTPUT="${ROOT_DIR}/output"
mkdir -p "${OUTPUT}"

for i in {1..8}; do
  file="${OUTPUT}/panel-${i}.png"
  curl -fsS --get --output "${file}" \
    --data-urlencode 'var-rate_interval=5s' \
    --data-urlencode 'orgId=1' \
    --data-urlencode "from=${FROM}" \
    --data-urlencode "to=${TO}" \
    --data-urlencode 'timezone=browser' \
    --data-urlencode 'var-datasource=prometheus' \
    --data-urlencode 'var-resource=$__all' \
    --data-urlencode 'var-user=$__all' \
    --data-urlencode 'var-verb=$__all' \
    --data-urlencode 'var-namespace=$__all' \
    --data-urlencode 'var-cluster=kueue' \
    --data-urlencode 'var-cluster=volcano' \
    --data-urlencode 'var-cluster=yunikorn' \
    --data-urlencode 'refresh=5s' \
    --data-urlencode 'theme=dark' \
    --data-urlencode "panelId=panel-${i}" \
    --data-urlencode '__feature.dashboardSceneSolo=' \
    --data-urlencode 'width=900' \
    --data-urlencode 'height=500' \
    --data-urlencode 'scale=10' \
    'http://127.0.0.1:8080/grafana/render/d-solo/perf'
  [[ "$(od -An -tx1 -N8 "${file}" | tr -d ' \n')" == "89504e470d0a1a0a" ]]
done
