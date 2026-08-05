#!/usr/bin/env bash

set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "${SOURCE_DIR}/versions.env"

DEPLOY_ROOT=/root/benchmark-1348-deploy
KUBECTL="${DEPLOY_ROOT}/bin/kubectl"
KUBECONFIG_PATH="${DEPLOY_ROOT}/kubeconfig"
CHART_CACHE="${DEPLOY_ROOT}/downloads/traefik-${TRAEFIK_CHART_VERSION}.tgz"
CHART_TMP="${CHART_CACHE}.tmp"
PORT_FORWARD_UNIT=benchmark-grafana-ingress-port-forward.service
PORT_FORWARD_UNIT_SOURCE="${SOURCE_DIR}/systemd/${PORT_FORWARD_UNIT}"
PORT_FORWARD_UNIT_TARGET="/etc/systemd/system/${PORT_FORWARD_UNIT}"

for command in curl helm install sha256sum systemctl; do
  command -v "${command}" >/dev/null
done
test -x "${KUBECTL}"
test -f "${KUBECONFIG_PATH}"
test -f "${PORT_FORWARD_UNIT_SOURCE}"
expected_exec="ExecStart=${KUBECTL} --kubeconfig=${KUBECONFIG_PATH} --namespace=${TRAEFIK_NAMESPACE} port-forward --address=0.0.0.0 service/${TRAEFIK_RESOURCE_NAME} ${GRAFANA_HOST_PORT}:80"
grep -Fqx "${expected_exec}" "${PORT_FORWARD_UNIT_SOURCE}"

mkdir -p "$(dirname "${CHART_CACHE}")"
if ! test -f "${CHART_CACHE}" || ! printf '%s  %s\n' "${TRAEFIK_CHART_SHA256}" "${CHART_CACHE}" | sha256sum --check --status; then
  curl --fail --location --retry 5 --retry-all-errors \
    --output "${CHART_TMP}" "${TRAEFIK_CHART_URL}"
  printf '%s  %s\n' "${TRAEFIK_CHART_SHA256}" "${CHART_TMP}" | sha256sum --check --status
  mv "${CHART_TMP}" "${CHART_CACHE}"
fi

helm upgrade --install "${TRAEFIK_RELEASE}" "${CHART_CACHE}" \
  --kubeconfig "${KUBECONFIG_PATH}" \
  --namespace "${TRAEFIK_NAMESPACE}" \
  --create-namespace \
  --skip-crds \
  --values "${SOURCE_DIR}/values.yaml" \
  --set-string "image.digest=${TRAEFIK_IMAGE_DIGEST}" \
  --set-string "versionOverride=${TRAEFIK_APP_VERSION}" \
  --wait --timeout 10m

"${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}" apply -f "${SOURCE_DIR}/grafana-ingress.yaml"
"${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}" --namespace "${TRAEFIK_NAMESPACE}" \
  rollout status "deployment/${TRAEFIK_RESOURCE_NAME}" --timeout=5m

install -m 0644 "${PORT_FORWARD_UNIT_SOURCE}" "${PORT_FORWARD_UNIT_TARGET}"
systemctl daemon-reload
systemctl enable "${PORT_FORWARD_UNIT}"
systemctl restart "${PORT_FORWARD_UNIT}"

"${SOURCE_DIR}/verify.sh"
