#!/usr/bin/env bash

set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "${SOURCE_DIR}/versions.env"

DEPLOY_ROOT="${DEPLOY_ROOT:-/root/benchmark-1348-deploy}"
KUBECTL="${DEPLOY_ROOT}/bin/kubectl"
KUBECONFIG_PATH="${DEPLOY_ROOT}/kubeconfig"
PORT_FORWARD_UNIT=benchmark-grafana-ingress-port-forward.service

"${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}" --namespace "${TRAEFIK_NAMESPACE}" \
  rollout status deployment/benchmark-grafana-ingress-traefik --timeout=5m
test "$("${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}" --namespace "${TRAEFIK_NAMESPACE}" get deployment benchmark-grafana-ingress-traefik -o jsonpath='{.spec.template.spec.containers[0].image}')" = "docker.io/traefik@${TRAEFIK_IMAGE_DIGEST}"
test "$("${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}" get ingressclass "${TRAEFIK_INGRESS_CLASS}" -o jsonpath='{.spec.controller}')" = "traefik.io/ingress-controller"
test "$("${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}" --namespace "${GRAFANA_NAMESPACE}" get ingress "${GRAFANA_INGRESS_NAME}" -o jsonpath='{.spec.ingressClassName}')" = "${TRAEFIK_INGRESS_CLASS}"
systemctl is-active --quiet "${PORT_FORWARD_UNIT}"

health="$(curl --fail --silent --show-error --max-time 10 "http://127.0.0.1:${GRAFANA_HOST_PORT}/grafana/api/health")"
printf '%s\n' "${health}" | grep -q '"database"[[:space:]]*:[[:space:]]*"ok"'
curl --fail --silent --show-error --max-time 10 --output /dev/null \
  "http://127.0.0.1:${GRAFANA_HOST_PORT}/grafana/d/perf/?theme=light"

printf 'grafana_ingress_url=http://104.105.137.213:%s/grafana/d/perf/?theme=light\n' "${GRAFANA_HOST_PORT}"
