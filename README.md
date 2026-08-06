# Kubernetes Scheduling Performance Benchmark

A comparative benchmark framework for Kueue, Volcano, and Apache YuniKorn. It runs the same batch workloads serially on a resident Kind + KWOK cluster, isolates scheduler components between runs, and collects API Server audit metrics and Grafana panels into timestamped result directories.

## Resident Kind Cluster

This is the supported execution mode. The framework reuses an already provisioned cluster; it does not create or delete a Kind cluster.

### Prerequisites

- A healthy resident cluster matching [CLUSTER_DEPLOYMENT_RECORD.md](CLUSTER_DEPLOYMENT_RECORD.md)
- Docker, Make, curl, and jq
- Cluster-admin access through `KUBECONFIG`
- The configured `kubectl` binary and resident deployment bundle
- Enough capacity for 1000 KWOK nodes and the monitoring stack; the validated baseline uses at least 16 CPU cores and should have at least 32 GiB memory

The validated defaults are:

| Setting | Default |
| --- | --- |
| Kind cluster | `volcano-benchmark-1348` |
| Kubernetes | `v1.34.8` |
| Nodes | 1 control-plane + 1000 KWOK nodes |
| Kubeconfig | `/root/benchmark-1348-deploy/kubeconfig` |
| kubectl | `/root/benchmark-1348-deploy/bin/kubectl` |
| Deployment bundle | `/root/benchmark-1348-deploy` |

Validated component versions:

| Component | Version |
| --- | --- |
| Kind | `v0.32.0` |
| Kubernetes / kubectl | `v1.34.8` |
| KWOK | `v0.7.0` |
| Volcano | `v1.15.1` |
| Kueue | `v0.19.0` |
| Scheduler Plugins / Coscheduling | `v0.34.7` |
| Apache YuniKorn | `v1.9.0` |
| kube-prometheus-stack | `88.1.3` |

Override `KIND_CLUSTER_NAME`, `KUBECONFIG`, `KUBECTL`, or `RESIDENT_DEPLOY_DIR` when using an equivalent resident deployment at different paths.

### Quick Start

```bash
# Validate the resident cluster and build the three test binaries.
make up

# Run all eight benchmark scenarios against all three scheduler stacks.
make

# Recover from an interrupted run and restore the pre-test scheduler state.
make down
```

`make up` only validates the existing cluster, schedulers, and monitoring stack. `make down` removes benchmark resources and restores saved configuration and Deployment replica counts; it does not delete the cluster or archived results.

### Step-by-Step

#### 1. Validate the Baseline

```bash
make up
```

The command verifies the resident Kubernetes cluster, all scheduler components, and monitoring, then compiles the Kueue, Volcano, and YuniKorn test binaries in a Go container.

#### 2. Run One Scenario

```bash
make serial-test \
  NODES_SIZE=1000 \
  QUEUES_SIZE=1 \
  JOBS_SIZE_PER_QUEUE=500 \
  PODS_SIZE_PER_JOB=20 \
  GANG=false \
  TEST_TIMEOUT_SECONDS=200
```

Each `serial-test` run executes Kueue, Volcano, and YuniKorn in that order. Before every scheduler test, the framework snapshots all eight scheduler Deployment replica counts, runs only the target stack, resets the Audit Exporter, and restores the original cluster state after the test.

For Kueue, `GANG=false` uses the default Kubernetes scheduler and `GANG=true` uses Coscheduling. Volcano and YuniKorn use their native schedulers in both modes.

#### 3. Run the Full Matrix

```bash
make
```

The default target runs these eight scenarios:

| Scenario | Mode | Jobs | Pods per job | Total pods |
| ---: | --- | ---: | ---: | ---: |
| 1 | Non-Gang | 10000 | 1 | 10000 |
| 2 | Non-Gang | 500 | 20 | 10000 |
| 3 | Non-Gang | 20 | 500 | 10000 |
| 4 | Non-Gang | 1 | 10000 | 10000 |
| 5 | Gang | 10000 | 1 | 10000 |
| 6 | Gang | 500 | 20 | 10000 |
| 7 | Gang | 20 | 500 | 10000 |
| 8 | Gang | 1 | 10000 | 10000 |

The complete matrix contains 24 `TestBatchJob` cases.

The latest validated run completed all 24 cases successfully in `54m59s` (`2026-08-06T13:39:34Z` to `2026-08-06T14:34:33Z`). It produced eight result directories and 64 Grafana panels with data. Exact scenario and scheduler timestamps are recorded in [RESIDENT_CLUSTER_FULL_TEST_REPORT.md](RESIDENT_CLUSTER_FULL_TEST_REPORT.md#19-异步清理修复后的完整测试通过).

#### 4. View Results

Every scenario creates `results/<unix-timestamp>/`:

```text
results/<timestamp>/
├── envs.txt
├── result-window.txt
├── logs/
│   ├── kube-apiserver-audit.kueue.log
│   ├── kube-apiserver-audit.volcano.log
│   └── kube-apiserver-audit.yunikorn.log
└── output/
    ├── panel-1.png
    ├── ...
    └── panel-8.png
```

The persistent Grafana endpoint is:

```text
http://<benchmark-server>:31005/grafana/d/perf/?theme=light
```

For a local-only view, use the `forward-grafana-local` Codex Skill. It forwards Grafana to `http://127.0.0.1:8080` and returns a light-theme Dashboard URL, optionally preserving a historical `FROM`/`TO` window.

#### 5. Recover an Interrupted Run

```bash
make down
```

Use this when a scheduler run is interrupted after resident state has been saved. The target cleans benchmark resources, restores the Audit Exporter, restores scheduler configuration and replica counts, verifies the base cluster, and removes `.resident-state/`.

## Benchmark Parameters

| Variable | Default | Description |
| --- | ---: | --- |
| `NODES_SIZE` | `1000` | KWOK worker-node count recorded in the experiment |
| `QUEUES_SIZE` | `1` | Number of benchmark queues |
| `JOBS_SIZE_PER_QUEUE` | `1` | Jobs created in each queue |
| `PODS_SIZE_PER_JOB` | `1` | Pods created by each job |
| `CPU_REQUEST_PER_POD` | `1` | CPU request per pod |
| `MEMORY_REQUEST_PER_POD` | `1Gi` | Memory request per pod |
| `CPU_PER_QUEUE` | `10000` | Queue CPU capacity |
| `MEMORY_PER_QUEUE` | `10000Gi` | Queue memory capacity |
| `GANG` | `false` | Enable gang scheduling semantics |
| `PREEMPTION` | `false` | Enable preemption scenarios |
| `TEST_TIMEOUT_SECONDS` | `3600` | Go test timeout for one scheduler case |
| `CLEANUP_TIMEOUT_SECONDS` | `600` | Maximum confirmation wait for Kueue namespaced cleanup |

Additional impacting and critical workload variables are defined at the top of the [Makefile](Makefile).

## Existing Cluster

Generic existing-cluster support is not implemented. The current Makefile assumes the resident cluster has the namespaces, CRDs, scheduler Deployments, Audit Exporter, Prometheus, Grafana, and verification scripts documented in [CLUSTER_DEPLOYMENT_RECORD.md](CLUSTER_DEPLOYMENT_RECORD.md). Another cluster can be used only after providing an equivalent deployment and overriding the resident paths; this is not a portable bootstrap workflow yet.

## Reference

### Scheduler Stacks

| Stack | Components |
| --- | --- |
| Kueue | Kueue Controller, default kube-scheduler for non-Gang tests, Coscheduling Scheduler and Controller for Gang tests |
| Volcano | Volcano Scheduler, Controllers, and Admission |
| YuniKorn | YuniKorn Scheduler and Admission Controller |

### Metrics

The customized `kube-apiserver-audit-exporter` reads API Server audit events and exports scheduler-labelled Prometheus metrics. The Grafana `perf` Dashboard compares scheduling latency, API call totals and rates, pods scheduled, and batch jobs completed across the three scheduler stacks.

Raw audit files can contain sparse NUL regions after repeated truncation on the resident cluster. Prometheus metrics and Grafana panels are the primary benchmark outputs; do not assume every archived audit file is directly parseable as clean JSONL.

### Repository Layout

```text
base/                       # Resident cluster support manifests
clusters/                   # Legacy per-component cluster definitions
deploy/grafana-ingress/     # Persistent Grafana ingress
hack/                       # Result collection and helper scripts
schedulers/                 # Scheduler-specific configuration
test/                       # Kueue, Volcano, YuniKorn tests and shared utilities
results/                    # Generated benchmark artifacts
```

Detailed deployment history and the latest complete validation are recorded in [CLUSTER_DEPLOYMENT_RECORD.md](CLUSTER_DEPLOYMENT_RECORD.md) and [RESIDENT_CLUSTER_FULL_TEST_REPORT.md](RESIDENT_CLUSTER_FULL_TEST_REPORT.md).

## Troubleshooting

### Too Many Open Files

On Linux, increase inotify limits when the host reports `Too many open files`:

```bash
echo fs.inotify.max_user_watches=655360 | sudo tee -a /etc/sysctl.conf
echo fs.inotify.max_user_instances=1280 | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

### Resident State Already Exists

If a new run stops with `Resident state exists`, do not delete `.resident-state/` manually. Run `make down` so the saved scheduler state is restored safely.
