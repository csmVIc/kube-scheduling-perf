#!/usr/bin/env bash

set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "${SOURCE_DIR}/versions.env"

DEPLOY_ROOT=/root/benchmark-1348-deploy
KUBECTL="${DEPLOY_ROOT}/bin/kubectl"
KUBECONFIG_PATH="${DEPLOY_ROOT}/kubeconfig"
PORT_FORWARD_UNIT=benchmark-grafana-ingress-port-forward.service

for command in curl helm jq systemctl; do
  command -v "${command}" >/dev/null
done
test -x "${KUBECTL}"
test -f "${KUBECONFIG_PATH}"

release_json="$(helm --kubeconfig "${KUBECONFIG_PATH}" list \
  --namespace "${TRAEFIK_NAMESPACE}" --filter "^${TRAEFIK_RELEASE}$" --output json)"
printf '%s\n' "${release_json}" | jq --exit-status \
  --arg release "${TRAEFIK_RELEASE}" \
  --arg chart "traefik-${TRAEFIK_CHART_VERSION}" \
  --arg app_version "${TRAEFIK_APP_VERSION}" \
  'length == 1 and .[0].name == $release and .[0].status == "deployed" and .[0].chart == $chart and .[0].app_version == $app_version' \
  >/dev/null

"${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}" --namespace "${TRAEFIK_NAMESPACE}" \
  rollout status "deployment/${TRAEFIK_RESOURCE_NAME}" --timeout=5m
test "$("${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}" --namespace "${TRAEFIK_NAMESPACE}" get deployment "${TRAEFIK_RESOURCE_NAME}" -o jsonpath='{.spec.template.spec.containers[0].image}')" = "docker.io/traefik@${TRAEFIK_IMAGE_DIGEST}"
test "$("${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}" --namespace "${TRAEFIK_NAMESPACE}" get service "${TRAEFIK_RESOURCE_NAME}" -o jsonpath='{.spec.type}')" = "ClusterIP"
test "$("${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}" get ingressclass "${TRAEFIK_INGRESS_CLASS}" -o jsonpath='{.spec.controller}')" = "traefik.io/ingress-controller"
test "$("${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}" --namespace "${GRAFANA_NAMESPACE}" get ingress "${GRAFANA_INGRESS_NAME}" -o jsonpath='{.spec.ingressClassName}')" = "${TRAEFIK_INGRESS_CLASS}"
test "$("${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}" --namespace "${GRAFANA_NAMESPACE}" get ingress "${GRAFANA_INGRESS_NAME}" -o jsonpath='{.spec.rules[0].http.paths[0].path}')" = "/grafana"
test "$("${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}" --namespace "${GRAFANA_NAMESPACE}" get ingress "${GRAFANA_INGRESS_NAME}" -o jsonpath='{.spec.rules[0].http.paths[0].backend.service.name}')" = "monitoring-grafana"
test "$("${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}" --namespace "${GRAFANA_NAMESPACE}" get ingress "${GRAFANA_INGRESS_NAME}" -o jsonpath='{.spec.rules[0].http.paths[0].backend.service.port.number}')" = "80"
cmp --silent "${SOURCE_DIR}/systemd/${PORT_FORWARD_UNIT}" "/etc/systemd/system/${PORT_FORWARD_UNIT}"
systemctl is-enabled --quiet "${PORT_FORWARD_UNIT}"
systemctl is-active --quiet "${PORT_FORWARD_UNIT}"

health=
for _ in {1..20}; do
  if health="$(curl --fail --silent --max-time 5 "http://127.0.0.1:${GRAFANA_HOST_PORT}/grafana/api/health" 2>/dev/null)" && \
    printf '%s\n' "${health}" | grep -q '"database"[[:space:]]*:[[:space:]]*"ok"'; then
    break
  fi
  sleep 1
done
printf '%s\n' "${health}" | grep -q '"database"[[:space:]]*:[[:space:]]*"ok"'
curl --fail --silent --show-error --max-time 10 --output /dev/null \
  "http://127.0.0.1:${GRAFANA_HOST_PORT}/grafana/d/perf/?theme=light"

printf 'server_loopback_verified=true\n'
printf 'grafana_ingress_url=http://104.105.137.213:%s/grafana/d/perf/?theme=light\n' "${GRAFANA_HOST_PORT}"
