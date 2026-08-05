#!/usr/bin/env bash

set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "${SOURCE_DIR}/versions.env"

DEPLOY_ROOT="${DEPLOY_ROOT:-/root/benchmark-1348-deploy}"
KUBECTL="${DEPLOY_ROOT}/bin/kubectl"
KUBECONFIG_PATH="${DEPLOY_ROOT}/kubeconfig"
CHART_CACHE="${DEPLOY_ROOT}/downloads/traefik-${TRAEFIK_CHART_VERSION}.tgz"
CHART_TMP="${CHART_CACHE}.tmp"
PORT_FORWARD_UNIT=benchmark-grafana-ingress-port-forward.service

for command in curl helm install sha256sum systemctl; do
  command -v "${command}" >/dev/null
done
test -x "${KUBECTL}"
test -f "${KUBECONFIG_PATH}"

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
  rollout status deployment/benchmark-grafana-ingress-traefik --timeout=5m

install -m 0644 "${SOURCE_DIR}/systemd/${PORT_FORWARD_UNIT}" "/etc/systemd/system/${PORT_FORWARD_UNIT}"
systemctl daemon-reload
systemctl enable --now "${PORT_FORWARD_UNIT}"

"${SOURCE_DIR}/verify.sh"
