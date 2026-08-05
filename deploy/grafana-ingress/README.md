# Grafana Ingress

This directory installs the persistent Grafana Ingress used by the resident benchmark cluster.

- Controller: Traefik `v3.7.1`, Helm chart `40.2.0`; both the chart checksum and the multi-architecture image digest are pinned.
- IngressClass: `benchmark-grafana` (not the cluster default).
- Scope: only the `monitoring` namespace; Kubernetes CRD and Gateway providers are disabled.
- Route: `/grafana` to `monitoring/monitoring-grafana:80`.
- External endpoint: `http://104.105.137.213:31005/grafana/d/perf/?theme=light`.
- Exposure: systemd keeps a host-side port-forward from TCP `31005` to the controller Service. This is necessary because the existing Kind cluster cannot gain another Docker port mapping without being rebuilt.

The chart is downloaded from Traefik's official Helm repository into `/root/benchmark-1348-deploy/downloads/` when the cache is missing or its checksum is invalid, and is accepted only after its pinned SHA-256 matches. `--skip-crds` is used because this deployment consumes only the built-in Kubernetes Ingress API.

Install or reconcile:

```bash
./deploy/grafana-ingress/install.sh
```

Verify without changing state:

```bash
./deploy/grafana-ingress/verify.sh
```

That script verifies the Helm release, Kubernetes objects, pinned image, systemd unit, and server-side loopback route. From the client machine, verify public reachability separately:

```bash
curl --fail http://104.105.137.213:31005/grafana/api/health
curl --fail --output /dev/null 'http://104.105.137.213:31005/grafana/d/perf/?theme=light'
```

Grafana anonymous Viewer access is enabled by the monitoring baseline, so TCP `31005` exposes benchmark data without authentication. Restrict this port at the server firewall or cloud security group if public access is not intended.
