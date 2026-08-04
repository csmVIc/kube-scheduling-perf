# Kubernetes 调度基准集群部署记录

## 1. 记录范围

本文记录远端调度基准集群的实际部署状态、安装来源、版本、关键配置、镜像摘要、重建顺序和已知风险，供故障恢复、版本更新和实验环境审计使用。

- 初始记录时间：`2026-08-03T12:35:49Z`（北京时间 `2026-08-03 20:35:49`）
- 最近变更时间：`2026-08-04`，将 KWOK Node 从 `5000` 缩减为 `1000`，补齐常驻实验所需的 Grafana 渲染和 Coscheduling CRD，并完成源码常驻集群改造验收
- 服务器：`104.105.137.213`
- 当前唯一 Kind 集群：`volcano-benchmark-1348`
- Kubernetes：`v1.34.8`
- 当前状态：`1001/1001` Node Ready，其中 `1000` 个 KWOK Node、`1` 个控制面 Node
- 旧集群 `volcano-benchmark` 已删除，不再具备旧环境回滚能力
- 本仓库源码已改为复用该常驻集群；普通 `make` 会按 Kueue、Volcano、YuniKorn 顺序直接运行实验，不再创建或删除 Kind 集群
- `manage-benchmark-experiment` Skill 本轮未修改，仍等待后续单独调整

本文不保存 kubeconfig 内容、SSH 密码、TLS 私钥、Grafana 密码或 Kubernetes Secret 数据。

## 2. 配置源位置

### 远端可执行部署包

- 路径：`/root/benchmark-1348-deploy`
- kubeconfig：`/root/benchmark-1348-deploy/kubeconfig`
- 集群专用 kubectl：`/root/benchmark-1348-deploy/bin/kubectl`
- 下载缓存：`/root/benchmark-1348-deploy/downloads`
- 审计日志：`/root/benchmark-1348-deploy/logs/kube-apiserver-audit.log`
- 版本锁定：`/root/benchmark-1348-deploy/versions.env`
- Kind 配置：`/root/benchmark-1348-deploy/kind-config.yaml`
- Helm values：`/root/benchmark-1348-deploy/values`
- 自维护 YAML：`/root/benchmark-1348-deploy/manifests`
- 部署与验收脚本：`/root/benchmark-1348-deploy/scripts`
- 运行镜像摘要：`/root/benchmark-1348-deploy/deployed-image-lock.md`

### 本地部署包副本

- 路径：`/Users/csmvic/Documents/Codex/2026-08-03/k8s-1-35/deploy`
- 方案文档：`/Users/csmvic/Documents/Codex/2026-08-03/k8s-1-35/benchmark-cluster-deployment-plan.md`

远端与本地部署包的脚本、values、manifest 和版本文件在本次记录时 SHA-256 一致。实际恢复时以远端部署包为执行入口，并在执行前与本地副本比较。

## 3. 宿主机与工具链

| 项目 | 当前值 |
|---|---|
| 宿主机系统 | Ubuntu `24.04`，`x86_64` |
| CPU | `32` 逻辑 CPU |
| 内存 | `62 GiB` |
| 根磁盘 | `645 GiB`，记录时已用约 `144 GiB` |
| Docker Server | `29.1.3` |
| Helm | `v3.21.1` |
| Kind | `/usr/local/bin/kind`，`v0.32.0` |
| 集群专用 kubectl | `v1.34.8` |
| 控制面容器运行时 | `containerd 2.3.1` |
| 控制面容器 OS | Debian GNU/Linux 13 (trixie) |
| 控制面内核 | `6.8.0-134-generic` |

重要差异：仓库内 `/root/github/kube-scheduling-perf/bin/kind` 当前仍是 `v0.27.0`，不是本集群的创建工具。创建、重建或删除本基线集群时应明确使用 `/usr/local/bin/kind v0.32.0`。

`install-tooling.sh` 只安装和校验 `kubectl v1.34.8`，不会安装 Kind、Helm、jq、curl、tar 或 sha256sum；重建前必须先确认这些宿主机工具存在。

## 4. 集群基础配置

### Kind 拓扑

- 单控制面节点：`volcano-benchmark-1348-control-plane`
- 无真实 worker 节点
- Kind Node 镜像：`kindest/node:v1.34.8@sha256:02722c2dedddcfc00febf5d27fbeb9b7b2c14294c82109ff4a85d89ac9ba3256`
- 控制面容器未设置 Docker CPU 或内存上限，使用宿主机可用资源
- Kubernetes Service CIDR：`10.96.0.0/16`
- Kubernetes Pod CIDR：`10.244.0.0/16`
- Docker `kind` 网络：IPv4 `172.18.0.0/16`，IPv6 `fc00:f853:ccd:e793::/64`
- API Server 当前宿主机回环端口：`127.0.0.1:42063`；这是 Kind 动态端口，重建后可能变化，应以 kubeconfig 为准

### 宿主机端口映射

| 用途 | Kubernetes NodePort | 宿主机端口 |
|---|---:|---:|
| Prometheus | `30003` | `31003` |
| Grafana | `30004` | `31004` |

Prometheus Service 还自动分配了第二个 NodePort `30104` 给 Service 的 `8080` 端口，但 Kind 没有把它映射到宿主机；日常访问只使用 `31003`。

为兼容源码现有结果采集地址，宿主机额外运行 systemd 服务 `benchmark-grafana-port-forward.service`，将 `127.0.0.1:8080` 持久转发到 `monitoring/monitoring-grafana:80`。该端口只监听服务器回环地址，不是 Kind 端口映射。

### API Server 自定义参数

- `--max-mutating-requests-inflight=20000`
- `--max-requests-inflight=20000`
- `--audit-policy-file=/etc/kubernetes/policies/audit-policy.yaml`
- `--audit-log-path=/var/log/kubernetes/kube-apiserver-audit.log`
- `--audit-log-maxsize=10240`（单位 MiB，单文件上限约 10 GiB）
- `--audit-log-maxage=7`
- `--audit-log-maxbackup=3`

### Controller Manager 自定义参数

- `--kube-api-qps=5000`
- `--kube-api-burst=10000`
- `--node-monitor-grace-period=7200s`
- `--node-monitor-period=3600s`
- `--cluster-cidr=10.244.0.0/16`

长 Node 监控周期用于降低大量虚拟节点带来的状态检查开销。它也会让真实节点故障感知明显变慢，因此本集群不应作为通用 Kubernetes 集群使用。

### etcd 自定义参数

- `--quota-backend-bytes=8589934592`（8 GiB）
- `--auto-compaction-mode=revision`
- `--auto-compaction-retention=1000`
- `--snapshot-count=10000`

etcd 数据位于 Kind 控制面容器对应的 Docker volume。执行 `kind delete cluster` 会删除集群状态，不应把该 volume 当成长期备份。

### 审计文件挂载

| 宿主机路径 | 控制面容器路径 | 权限 |
|---|---|---|
| `/root/github/volcano/third_party/kube-apiserver-audit-exporter/audit-policy.yaml` | `/etc/kubernetes/policies/audit-policy.yaml` | 只读 |
| `/root/benchmark-1348-deploy/logs` | `/var/log/kubernetes` | 读写 |

审计策略只以 `RequestResponse` 级别记录 Pod、Pod binding/status、Kubernetes Job 和 Volcano Job 的 create/patch/update/delete；其他请求为 `None`。该设计用于调度延迟和 API 调用指标，不是完整安全审计策略。

## 5. KWOK 虚拟节点

| 项目 | 配置 |
|---|---|
| KWOK | `v0.7.0` |
| Controller 镜像 | `registry.k8s.io/kwok/kwok:v0.7.0` |
| 虚拟节点数 | `1000` |
| 节点名 | `kwok-node-0` 至 `kwok-node-999` |
| 单节点容量 | `16 CPU / 64 GiB / 110 Pods` |
| 标签 | `type=kwok`、`node-role.kubernetes.io/agent=""` |
| 注解 | `kwok.x-k8s.io/node=fake` |
| Taint | `kwok.x-k8s.io/node=fake:NoSchedule` |

安装方式：KWOK 的 `kwok.yaml` 和 `stage-fast.yaml` 是直接从下面的远程 URL 执行 `kubectl apply -f URL`，没有先保存到 `downloads`：

- `https://github.com/kubernetes-sigs/kwok/releases/download/v0.7.0/kwok.yaml`
- `https://github.com/kubernetes-sigs/kwok/releases/download/v0.7.0/stage-fast.yaml`

先建立 100 个金丝雀 KWOK Node，再由 `scale-kwok-nodes.sh 1000` 生成缺少的 Node YAML 并通过标准输入执行 `kubectl create -f -`。

`kindnet` 和 `kube-proxy` DaemonSet 均增加 `type NotIn [kwok]` 的 NodeAffinity，所以各自只在控制面运行 1 个 Pod，不会在 1000 个虚拟节点上扩散。

已知网络限制：Pod CIDR 是 `/16`，只能给 `255` 个 KWOK Node 分配唯一 `/24`；当前 1000 个 KWOK Node 中只有 255 个有 PodCIDR。KWOK 压测 Pod 不由真实 kubelet 启动，也不依赖 Pod 网络，因此当前调度测试可用；若未来需要真实网络、真实容器或跨 Pod 通信，本集群设计不适用。

## 6. 组件版本与安装方式

| 组件 | 版本 | 命名空间 | 安装方式 |
|---|---|---|---|
| Volcano | `v1.15.1` | `volcano-system` | Helm chart 先下载到服务器，再从本地 tgz 安装 |
| Kueue | `v0.19.0` | `kueue-system` | release manifest 先下载并校验，再从本地文件 server-side apply |
| Scheduler Plugins / Coscheduling | `v0.34.7` | `coscheduling` | GitHub source tarball 先下载并校验；从解压后的本地 CRD 和 Helm chart 安装 |
| YuniKorn | `v1.9.0` | `yunikorn` | Helm chart 先下载到服务器，再从本地 tgz 安装 |
| kube-prometheus-stack | `88.1.3` | `monitoring` | chart 先下载、固定 SHA-256 校验，再从本地 tgz 安装 |
| Prometheus | `v3.13.2-distroless` | `monitoring` | kube-prometheus-stack 子组件 |
| Prometheus Operator | `v0.93.0` | `monitoring` | kube-prometheus-stack 子组件 |
| Grafana | `13.1.1` | `monitoring` | kube-prometheus-stack 子组件 |
| Grafana Image Renderer | `v5.11.1` | `monitoring` | kube-prometheus-stack 的远程渲染子组件，版本由 values/Helm 参数固定 |
| kube-state-metrics | `v2.19.1` | `monitoring` | kube-prometheus-stack 子组件 |
| Audit Exporter | `v0.0.25` | `kube-system` | 本地维护 YAML apply，镜像运行时拉取 |
| KWOK | `v0.7.0` | `kube-system` | 远程 URL 直接 apply |

集群自带组件还包括 CoreDNS `v1.12.1`、kube-proxy `v1.34.8`、kindnet `v20260528-9350166c` 和 local-path-provisioner `v20260521-9fb22683`。

## 7. 下载来源与制品校验

### 本地化后安装的制品

| 制品 | 来源 | 当前缓存文件 | SHA-256 |
|---|---|---|---|
| Kueue manifest | GitHub release `v0.19.0/manifests.yaml` | `downloads/kueue-v0.19.0.yaml` | `e76d9f386e1d0d346f31e7e7000f55f0d66dc292bb9715738f56a071f053122c` |
| Scheduler Plugins source | GitHub tag `v0.34.7` tarball | `downloads/scheduler-plugins-v0.34.7.tar.gz` | `ece3d79357d07aba19e5ef179bf44e9f66e47b4110da30e7dbd3723a1f938e01` |
| Volcano chart | `https://volcano-sh.github.io/helm-charts` | `downloads/volcano-1.15.1.tgz` | `a8135a7430fd48a57d791faac3bbea210106611a826b22ed089ae2dbaad1e7c3` |
| YuniKorn chart | `https://apache.github.io/yunikorn-release` | `downloads/yunikorn-1.9.0.tgz` | `1d751f5cfb6d545ba21a36ba993669bf08158c1c1abdd89a6c298627d6ed433e` |
| kube-prometheus-stack chart | `https://prometheus-community.github.io/helm-charts` | `downloads/kube-prometheus-stack-88.1.3.tgz` | `8b51a20164aeb3177b1ce20f1d4cb89f103c02c201aa048afc07f73da50c9d73` |

Kueue、Scheduler Plugins 和 kube-prometheus-stack 的期望 SHA-256 已写入 `versions.env`，部署脚本会验证。Volcano 和 YuniKorn 脚本当前只打印实际 SHA-256，没有把期望值写入 `versions.env`；上表是当前已部署缓存的基线，升级或重建时应先比较，不要无条件覆盖。

### 具体安装路径

- Volcano：`helm upgrade --install` 使用本地 `volcano-1.15.1.tgz` 和 `values/volcano.yaml`。
- Kueue：本地 `kueue-v0.19.0.yaml` 使用 `kubectl apply --server-side`；随后应用本地 `kueue-manager-config.yaml`、重启 Controller，并运行 Webhook 作用域修正脚本。
- Coscheduling：本地 source tarball 解压后，先 server-side apply `manifests/coscheduling/crd.yaml` 和 `config/crd/bases/scheduling.x-k8s.io_elasticquotas.yaml`，再从 `manifests/install/charts/as-a-second-scheduler` 进行 Helm 安装；最后用本地 ConfigMap 覆盖 scheduler 配置并重启。
- YuniKorn：`helm upgrade --install` 使用本地 `yunikorn-1.9.0.tgz` 和 `values/yunikorn.yaml`。
- 监控：`helm upgrade --install` 使用本地且已校验的 kube-prometheus-stack tgz；Image Renderer 由 chart 部署；Audit Exporter、审计 Dashboard 和 `perf` Dashboard 均由部署目录中的本地文件 apply；安装脚本同时安装并启用 Grafana 8080 systemd 转发服务。

## 8. 调度器实际配置

### Volcano

- Scheduler 名称：`volcano`
- Helm release：`volcano`，chart `volcano-1.15.1`
- 常驻 Deployment：`volcano-scheduler`、`volcano-controllers`、`volcano-admission`，各 `1` 副本
- Agent Scheduler：关闭
- Sharding Controller：关闭
- Webhook 目标命名空间标签：`benchmark.scheduling/base=volcano`
- Scheduler actions：`enqueue, allocate, backfill, reclaim`
- 第一层插件：`priority`、`gang`，其中 gang `enablePreemptable=false`
- 第二层插件：`predicates`、`capacity`，其中 capacity `enableHierarchy=false`
- Volcano Job CRD：`jobs.batch.volcano.sh/v1alpha1`，served/storage 均为 true

资源配置：

| Deployment | Requests | Limits |
|---|---|---|
| volcano-scheduler | `500m / 512Mi` | `8 CPU / 4Gi` |
| volcano-controllers | `500m / 512Mi` | `4 CPU / 4Gi` |
| volcano-admission | `100m / 128Mi` | `1 CPU / 1Gi` |

### Kueue

- Controller 镜像：`registry.k8s.io/kueue/kueue:v0.19.0`
- Deployment：`kueue-controller-manager`，`1` 副本
- 配置 API：`config.kueue.x-k8s.io/v1beta2`
- `manageJobsWithoutQueueName=false`
- 只集成 `batch/job`
- 只管理带 `benchmark.scheduling/base=kueue` 标签的命名空间
- API client：`qps=300`、`burst=500`
- 主要并发：Job 5、Workload 10、LocalQueue 5、Cohort 1、ClusterQueue 5、ResourceFlavor 1
- Workload CRD 同时 served `v1beta1` 与 `v1beta2`，storage 版本为 `v1beta2`
- 资源：Requests `500m / 512Mi`，Limits `2 CPU / 512Mi`

官方 manifest 默认包含较多可选 workload Webhook。部署后额外执行 `scope-kueue-webhooks.sh`，为全部 `21` 个 Mutating Webhook 和全部 `22` 个 Validating Webhook 增加 `benchmark.scheduling/base In [kueue]` 的 namespaceSelector，避免影响 Volcano 和 YuniKorn 测试命名空间。

### Coscheduling

- 来源：`kubernetes-sigs/scheduler-plugins`，不是独立 Coscheduling 项目
- Scheduler 名称：`coscheduling`
- Scheduler Deployment：`coscheduling`，`1` 副本
- Controller Deployment：`scheduler-plugins-controller`，`1` 副本
- PodGroup CRD：`podgroups.scheduling.x-k8s.io/v1alpha1`
- ElasticQuota CRD：`elasticquotas.scheduling.x-k8s.io/v1alpha1`，供 `scheduler-plugins-controller` informer 使用
- kube-scheduler 配置 API：`kubescheduler.config.k8s.io/v1`
- `parallelism=16`
- `clientConnection.qps=1000`、`burst=1000`
- `leaderElect=false`
- 启用 `Coscheduling` MultiPoint 和 QueueSort；QueueSort 中禁用其他插件
- `permitWaitingTimeSeconds=10`

资源配置：

| Deployment | Requests | Limits |
|---|---|---|
| coscheduling | `500m / 512Mi` | `8 CPU / 4Gi` |
| scheduler-plugins-controller | `100m / 128Mi` | `1 CPU / 1Gi` |

### YuniKorn

- Scheduler 名称：`yunikorn`
- Helm release：`yunikorn`，chart `yunikorn-1.9.0`
- 标准 Scheduler 模式，不是已移除的 Scheduler Plugin 模式
- Scheduler Deployment：`yunikorn-scheduler`，`1` 副本
- Admission Deployment：`yunikorn-admission-controller`，`1` 副本
- 内嵌 Admission Controller：开启
- Web Service/UI：关闭
- Admission 只处理 `^bench-yunikorn$`
- Admission 绕过 `^(kube-system|yunikorn)$`
- 没有挂载自定义队列 ConfigMap；当前使用 YuniKorn 内置默认队列结构，测试队列为 `root.default`

资源配置：

| Deployment | Requests | Limits |
|---|---|---|
| yunikorn-scheduler | `500m / 1Gi` | `8 CPU / 4Gi` |
| yunikorn-admission-controller | `100m / 256Mi` | `1 CPU / 1Gi` |

## 9. 命名空间与多调度器隔离

| 命名空间 | 标签 | 目标组件 |
|---|---|---|
| `bench-volcano` | `benchmark.scheduling/base=volcano` | Volcano |
| `bench-kueue` | `benchmark.scheduling/base=kueue` | Kueue + Coscheduling |
| `bench-yunikorn` | `benchmark.scheduling/base=yunikorn` | YuniKorn |

空闲基线下三套 Scheduler Deployment 都是 `1` 副本并同时运行。仓库常驻集群流程会在每轮实验前记录所有调度组件的实际副本数，仅保留目标调度组件为 `1` 副本、将其他调度组件缩容为 `0`，等待非目标 Pod 完全退出后再开始测试；本轮结束后阻塞清理测试资源，使用精确替换恢复可变 ConfigMap，并恢复测试前实际副本数。YuniKorn 清理不主动扩容 Scheduler 或 Admission；测试前 Scheduler 为 `0` 时，配置恢复也不会额外启动或重启它。

## 10. 监控与审计

### kube-prometheus-stack

- Helm release：`monitoring`
- Chart：`kube-prometheus-stack-88.1.3`
- Prometheus Operator：`v0.93.0`
- Prometheus：`v3.13.2-distroless`
- Grafana：`13.1.1`
- Grafana Image Renderer：`v5.11.1`
- Grafana Sidecar：`2.10.0`
- kube-state-metrics：`v2.19.1`
- Prometheus retention：`7d`
- Scrape interval：`5s`
- Evaluation interval：`30s`
- Alertmanager：关闭
- Node Exporter：关闭
- Kubelet、CoreDNS、kube-proxy ServiceMonitor：关闭
- Default rules：关闭

访问地址（从服务器本机）：

- Prometheus：`http://127.0.0.1:31003`
- Grafana：`http://127.0.0.1:31004`
- 源码结果采集入口：`http://127.0.0.1:8080/grafana`

安全说明：宿主机映射使用 `0.0.0.0:31003/31004`，是否能被公网访问取决于服务器防火墙和云安全组。Grafana 密码保存在 Kubernetes Secret 中，不写入本文。

Grafana 启用了匿名 Viewer 和 `/grafana/` 子路径。`perf` Dashboard 由 `manifests/perf-dashboard.json` 创建为 `scheduling-perf-dashboard` ConfigMap，固定 UID 为 `perf`；Image Renderer 负责 `/render/d-solo/perf` 图片接口。`verify-monitoring.sh` 会同时验证 31004、8080、Dashboard UID 和 PNG 文件签名。

### Audit Exporter

- 镜像：`ghcr.io/wzshiming/kube-apiserver-audit-exporter/kube-apiserver-audit-exporter:v0.0.25`
- Deployment：`kube-apiserver-audit-exporter`，`1` 副本
- 从控制面宿主路径只读读取 `/var/log/kubernetes/kube-apiserver-audit.log`
- ServiceMonitor 抓取间隔和超时均为 `1s`
- 已验证指标包括 `pod_scheduling_latency_seconds` 和 `api_requests_total`
- Grafana Dashboard：`Scheduling Audit Overview`，UID `scheduling-audit-overview`

源码运行性能实验时，会在截断审计日志前停止 Audit Exporter，并为 Kueue、Volcano、YuniKorn 分别以独立 `cluster` 标签启动全新进程。测试结束后先等待 Exporter 指标稳定，再确认 Prometheus 已抓取到晚于稳定时刻的样本，最后以毫秒时间窗采集结果并恢复 Exporter 测试前参数和副本数。这样常驻部署不依赖 overview 集群，也不会把进程内指标或文件 offset 混入下一轮。

### 持久化风险

当前集群没有任何 PVC：

- Prometheus TSDB 使用 `emptyDir`
- Grafana storage 使用 `emptyDir`
- Prometheus retention 虽配置为 7 天，但 Pod 被删除或重建后历史指标会丢失
- Grafana Dashboard 由 ConfigMap Sidecar 重新加载，可重建；Grafana 本地状态和手工修改不持久
- API Server 审计日志位于服务器 `/root/benchmark-1348-deploy/logs`，独立于 Prometheus Pod，集群删除前仍可单独备份

正式实验结果不能只保存在 Prometheus/Grafana 内，必须另行导出或保存到仓库的 results 目录。

## 11. 实际运行镜像摘要

以下为记录时实际运行的 `amd64` 镜像摘要：

| 组件 | 镜像 | 摘要 |
|---|---|---|
| Kind Node | `kindest/node:v1.34.8` | `sha256:02722c2dedddcfc00febf5d27fbeb9b7b2c14294c82109ff4a85d89ac9ba3256` |
| KWOK | `registry.k8s.io/kwok/kwok:v0.7.0` | `sha256:2bb52d4cdd8b3e22e53ec86643a02ee84abdd8cec825269acdf7706d54c0ad6e` |
| Volcano Scheduler | `volcanosh/vc-scheduler:v1.15.1` | `sha256:e79dc85279b5fd2c5e431571b4683f819ff0dfeacdf230fca49e6ce1f4509ae1` |
| Volcano Controller | `volcanosh/vc-controller-manager:v1.15.1` | `sha256:555245dd5c73524dee627ad0c2e308c9dd95af234df791d11e6bcdfa2f33a4ef` |
| Volcano Webhook | `volcanosh/vc-webhook-manager:v1.15.1` | `sha256:569e3671b6d9619c175062e6d3e82bfe3bb4bc3628b36347406ccc07f10fe12c` |
| Kueue | `registry.k8s.io/kueue/kueue:v0.19.0` | `sha256:6fe2cbe4c7799eed1a8d49898c38b8bd73f1572df1825d7cf266ec9e2af70bec` |
| Coscheduling Scheduler | `registry.k8s.io/scheduler-plugins/kube-scheduler:v0.34.7` | `sha256:ae94c1224ef5677ae54bc25b4161a602b4365f479610d550f972e829f7c5b1b6` |
| Coscheduling Controller | `registry.k8s.io/scheduler-plugins/controller:v0.34.7` | `sha256:2b9b6c185b84d003b700506674ed09a37c08b7a62c42efd02f16c2ea3f102e30` |
| YuniKorn Scheduler | `apache/yunikorn:scheduler-1.9.0` | `sha256:96832082e9cfb97cb4d85349ada6243e7c2e3176f167cdde94ad37879f3c815f` |
| YuniKorn Admission | `apache/yunikorn:admission-1.9.0` | `sha256:fe8f5ec91f6c73be4af36afbc41f349ff7bee532593107a80ad90ab3d680a911` |
| Prometheus | `quay.io/prometheus/prometheus:v3.13.2-distroless` | `sha256:64f71bb84e03c855948418b0fc5dea53e9543d8e3fc9931598f583805507f05e` |
| Prometheus Operator | `quay.io/prometheus-operator/prometheus-operator:v0.93.0` | `sha256:a001ed10a3823bbf2410ea347796d0e35ff8decd24fb98acbe7ab9e98d431c39` |
| Prometheus Config Reloader | `quay.io/prometheus-operator/prometheus-config-reloader:v0.93.0` | `sha256:0ccb22ca9f3f6fd9f76ce95585d18bd2e363d421c534dde710be4bd13caa551d` |
| Grafana | `grafana/grafana:13.1.1` | `sha256:7cb8c64c4d57a57e734073f3cc94620adb24a0acb929bd80ba9f14017e3a975b` |
| Grafana Image Renderer | `grafana/grafana-image-renderer:v5.11.1` | `sha256:37e6ed8d55426f80d8d00a839df2cc02568b5877ffa2964f3ec09fa9a295c0a9` |
| Grafana Sidecar | `quay.io/kiwigrid/k8s-sidecar:2.10.0` | `sha256:21b9fe7bb29d65caf2445ccbf96ff6eda5e589a92bd8f5188f957fe75b551d72` |
| kube-state-metrics | `registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.19.1` | `sha256:85108987d044b18a098126732f98602df408888c0f7d456241f5abefb9744bc1` |
| Audit Exporter | `ghcr.io/wzshiming/kube-apiserver-audit-exporter/kube-apiserver-audit-exporter:v0.0.25` | `sha256:26ba85a489ba6c25053b84d27f8048db9cc28eec490cadb62f37593da688857b` |

## 12. 重建顺序

以下命令在服务器执行。创建集群是破坏性恢复流程，已有同名集群时 `create-canary-cluster.sh` 会拒绝覆盖；不要为了重跑脚本而直接删除健康集群。

```bash
cd /root/benchmark-1348-deploy

/usr/local/bin/kind version
helm version
jq --version

./scripts/install-tooling.sh
./scripts/create-canary-cluster.sh
./scripts/install-kwok-canary.sh
./scripts/verify-base.sh 100

./scripts/install-schedulers.sh
./scripts/run-scheduler-smoke-tests.sh

./scripts/install-monitoring.sh
./scripts/verify-monitoring.sh

./scripts/scale-kwok-nodes.sh 1000
./scripts/verify-base.sh 1000
./scripts/verify-schedulers.sh
./scripts/verify-monitoring.sh
```

执行前还要确认：

- `/usr/local/bin/kind` 是 `v0.32.0`
- `versions.env` 和全部下载制品 SHA-256 与本文一致
- audit policy 源文件仍存在
- `31003`、`31004` 和回环地址 `127.0.0.1:8080` 未被其他进程占用
- 至少有足够的 Docker 磁盘空间
- 已备份需要保留的审计日志、Prometheus 数据导出和实验结果

## 13. 日常验收

服务器上的只读/低风险验收入口：

```bash
cd /root/benchmark-1348-deploy
./scripts/verify-base.sh 1000
./scripts/verify-schedulers.sh
./scripts/verify-monitoring.sh
```

最低验收标准：

- Kubernetes client/server 都是 `v1.34.8`
- `1001/1001` Node Ready
- KWOK Controller 镜像是 `v0.7.0`
- API Server 审计日志持续写入
- 三套调度组件 Deployment rollout 成功
- Volcano、Kueue、PodGroup 和 ElasticQuota 关键 CRD Established
- Prometheus、Grafana 和 Grafana Image Renderer 健康检查成功
- `perf` Dashboard 可从 `127.0.0.1:8080/grafana` 渲染为 PNG
- Audit Exporter 暴露调度指标

`run-scheduler-smoke-tests.sh` 会创建并删除真实测试资源，不属于纯只读检查；只在允许变更集群状态时运行。

## 14. 更新流程建议

当前只保留一套集群，直接原地升级会失去快速回滚能力。更新 Kubernetes、CRD 或调度器时推荐：

1. 复制 `/root/benchmark-1348-deploy` 为新的版本化目录。
2. 使用新的集群名、Prometheus/Grafana 宿主端口和 kubeconfig，创建旁路候选集群。
3. 更新 `versions.env`、Kind Node digest、Helm values、下载制品固定 SHA-256 和镜像摘要。
4. 重新下载到候选部署目录并校验，不直接对运行集群 apply 远程浮动内容。
5. 对新版本 CRD 检查 served/storage 版本和 conversion 行为。
6. 重新应用 namespace/Webhook 隔离策略。
7. 完成三套 Scheduler 冒烟和小规模性能对比。
8. 导出旧集群实验数据后再决定是否切换和删除旧集群。
9. 更新本文和 `.codex/AGENT.md`，记录日期、版本、制品 SHA 和运行镜像 digest。

尤其注意：Kueue manifest 和 API 版本、Scheduler Plugins 与 Kubernetes 小版本、YuniKorn Admission 行为都可能发生变化，不能只替换镜像 tag。

## 15. 故障恢复边界

- 控制面容器停止但仍存在：先检查原因，可使用 `docker start volcano-benchmark-1348-control-plane` 恢复容器，再运行验收脚本。
- 单个调度组件异常：优先使用 `kubectl rollout restart` 或重新执行对应 Helm upgrade/apply；不要重建整个集群。
- Webhook 阻断其他测试：检查 namespace 标签和 Kueue/Volcano/YuniKorn selector，不要直接删除全部 Webhook。
- Prometheus/Grafana Pod 重建：历史数据不可恢复，因为当前使用 emptyDir；Dashboard ConfigMap 可恢复。
- Kind 集群被删除：etcd 和集群状态不可恢复，只能按本文顺序重建；宿主机审计日志目录可能仍在。
- 远端部署包损坏：使用本地副本恢复，并先比较本文记录的 SHA-256。

## 16. 部署包文件指纹

以下为远端和本地副本在记录时一致的关键文件 SHA-256：

| 文件 | SHA-256 |
|---|---|
| `versions.env` | `9802258aa7437b303934ab306442f5f48d4ba7466802ff93ed0371a8932c7305` |
| `kind-config.yaml` | `bd10f1e3c27816f08be50741ce6ad58924bfde478249ac249ee4d3f52597e8a8` |
| `values/volcano.yaml` | `12dfb67605f6331981a4d18aebca307bf290bdec0a0b45252a20c92d3d062fc3` |
| `values/coscheduling.yaml` | `61a620d3ffd4ba04c2877b3147aa421c1337b3a99b00e62d7fdf3d943f899148` |
| `values/yunikorn.yaml` | `80b28b179c7cc27ab9b0f723898b0978d9cc9b09e16d511082a3d18ea47ccad7` |
| `values/monitoring.yaml` | `10ade921cffcb719201bbaa01d3f924d17eff4f01904a4a70d0ba19d1e51f566` |
| `manifests/kueue-manager-config.yaml` | `c83ae412d2717ffee1deb9f7deb540cfd4f14dcbf2317810828da809bc672157` |
| `manifests/coscheduling-configmap.yaml` | `5962e58f741802567db2cd4022a1ac19949e18a62b956c1ff3545ea11181ce44` |
| `manifests/benchmark-namespaces.yaml` | `e766ab1fc5c3de100f727a5ac46fcaee8ae3e9d0eb9eb682c4769b715fbba74f` |
| `manifests/audit-exporter.yaml` | `e784ca7241ffb9b1b3055505643d3a34b92b55e47395bd6670562e393d1039a8` |
| `manifests/audit-dashboard.yaml` | `558dfb641b07815b1dba8467a7939516be88ce3b07016f448d08e775c81d82fb` |
| `manifests/perf-dashboard.json` | `a3ea7661ba0023b84f07a46d1fd9afefac5899c725387c37e4649e6e5d5acec2` |
| `manifests/scheduler-smoke-tests.yaml` | `8574169b65bd048ed085c344bdbf6650cae18773c44001a7bef1bfc0acd8aa45` |
| `scripts/create-canary-cluster.sh` | `c8d81b51990e97bcef387cc6a8f47f8cd253d17c2684cb910b1e9ca3899c03ec` |
| `scripts/install-kwok-canary.sh` | `24ec70a2d257b5615ee67c5fd6e0e743542aed552d209683eed33f8ff19cbcb5` |
| `scripts/prepare-scheduler-artifacts.sh` | `ef0fc3f6d828d9e98c0cc8dcbe4ff1dfbb6a603ba62ec93a3c2feee7c1f574c1` |
| `scripts/install-schedulers.sh` | `3fa302d6af5aeebab964a8f6b43f01ee2d7e88d1c85fdf2059e31c98e73f077b` |
| `scripts/scope-kueue-webhooks.sh` | `f3be442a47f5992e78b37b0b4c2f4dac672cc79fc683f44cb206c9e44a96acdc` |
| `scripts/prepare-monitoring-artifacts.sh` | `04bdaafab302f228bc7c1d843531db0059dbadca3b7effda3a9e576704caf020` |
| `scripts/install-monitoring.sh` | `c05b6909f00556bd2f26810f899fe69236a9edeec9b20e19ba78ed11ff495994` |
| `scripts/scale-kwok-nodes.sh` | `6d4bfdf53b644f04d661c55698caad4b9303824752a2859ae5c235fc54e8960c` |
| `scripts/run-scheduler-smoke-tests.sh` | `e1258ff299dc28162c59ba507365d234308e6344e42449d9582c16e89959d6cb` |
| `scripts/verify-base.sh` | `37bbd00b6aede1f567ff8eb1c45ba6fb40cebe1bd4df0fa8bd7c23a0cbf0b339` |
| `scripts/verify-schedulers.sh` | `fc2ad281b5e6569b642ea28f379e659f0fbbbf612c8f3b7faa45001e3c79daa6` |
| `scripts/verify-monitoring.sh` | `a13c5acea6793d15de610420e4ed14f43c06771c8824029d3b62e63adbbc2e1d` |
| `systemd/benchmark-grafana-port-forward.service` | `23952b1b52fd95bdaab07f91abf1b695a97a52ef99a95dce5a0a27ba84a94ec1` |
| `deployed-image-lock.md` | `34a0895152408a68a78533b78dce0a632a6d8e6971e56ac88f9004ffe7583957` |

这些指纹用于识别部署包漂移，不等于对文件来源的签名认证。

## 17. 2026-08-04 变更与验收记录

- 精确删除 `kwok-node-1000` 至 `kwok-node-4999`，基线缩减为 `1000` 个 KWOK Node。
- 安装 Grafana Image Renderer `v5.11.1`、`perf` Dashboard 和 `127.0.0.1:8080/grafana` systemd 转发服务。
- 补装 Scheduler Plugins `ElasticQuota` CRD，修复 `scheduler-plugins-controller` 因 informer 找不到资源而持续重启的问题；部署和验收脚本已同步固化。
- 本地部署包与远端 `/root/benchmark-1348-deploy` 的本轮变更文件 SHA-256 已逐项核对一致。
- 常驻集群源码在服务器隔离目录 `/root/benchmark-resident-source` 完成 Kueue、Volcano、YuniKorn 单项冒烟和完整串行实验；原目录 `/root/github/kube-scheduling-perf` 的跟踪文件未改动。
- 完整串行验收结果位于 `/root/benchmark-resident-source/results/1785850713`，包含 8 张有效 PNG 和三份非空 API Server 审计日志。
- 在 Volcano 完成 `prepare`、尚未执行 `start/end` 时直接执行 `make down`，确认实验资源和状态文件零残留、Volcano 配置恢复、全部调度 Deployment 为 `1/1`、`1001/1001` Node Ready。
