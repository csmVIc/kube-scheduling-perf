#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

DIR="$(dirname "${BASH_SOURCE[0]}")"
ROOT_DIR="$(realpath "${DIR}/..")"

RECENT_DURATION=${RECENT_DURATION:-5min}

FROM=$(date -u -Iseconds -d "- ${RECENT_DURATION}" | sed 's/+00:00/.000Z/')
TO=$(date -u -Iseconds | sed 's/+00:00/.000Z/')

OUTPUT="${ROOT_DIR}/output"
mkdir -p "${OUTPUT}"

for i in {1..8}; do
  wget -O "${OUTPUT}/panel-${i}.png" "http://127.0.0.1:8080/grafana/render/d-solo/perf?var-rate_interval=5s&orgId=1&from=${FROM}&to=${TO}&timezone=browser&var-datasource=prometheus&var-resource=\$__all&var-user=\$__all&var-verb=create&var-verb=delete&var-verb=patch&var-verb=update&var-namespace=\$__all&var-cluster=\$__all&refresh=5s&theme=dark&panelId=panel-${i}&__feature.dashboardSceneSolo&width=900&height=500&scale=10"
done
