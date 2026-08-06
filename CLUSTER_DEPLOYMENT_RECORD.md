# Kubernetes 调度基准集群部署记录

## 1. 记录范围

本文记录远端调度基准集群的实际部署状态、安装来源、版本、关键配置、镜像摘要、重建顺序和已知风险，供故障恢复、版本更新和实验环境审计使用。

- 初始记录时间：`2026-08-03T12:35:49Z`（北京时间 `2026-08-03 20:35:49`）
- 最近变更时间：`2026-08-06`，完成场景 5 高基数 Kueue 异步清理与 Grafana 结果链路定向验证
- 服务器：`104.105.137.213`
- 当前唯一 Kind 集群：`volcano-benchmark-1348`
- Kubernetes：`v1.34.8`
- 当前状态：`1001/1001` Node Ready，其中 `1000` 个 KWOK Node、`1` 个控制面 Node
- 旧集群 `volcano-benchmark` 已删除，不再具备旧环境回滚能力
- 本仓库源码已改为复用该常驻集群；普通 `make` 会按 Kueue、Volcano、YuniKorn 顺序直接运行实验，不再创建或删除 Kind 集群
- `manage-benchmark-experiment` 和 `volcano-benchmark-server` Skill 已删除；本地 SSH 转发改由 `forward-grafana-local` 提供，日常查看 Dashboard 现优先使用持久 Ingress

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

`/root/benchmark-1348-deploy` 是基础集群和调度/监控组件的可执行权威部署包。Grafana Ingress 的版本化部署源位于服务器仓库 `/root/github/kube-scheduling-perf/deploy/grafana-ingress/`；chart 缓存和运行镜像摘要仍保存在远端部署包中。

### 过时本地参考副本（只读）

- 路径：`/Users/csmvic/Documents/Codex/2026-08-03/k8s-1-35/deploy`
- 方案文档：`/Users/csmvic/Documents/Codex/2026-08-03/k8s-1-35/benchmark-cluster-deployment-plan.md`

该目录只是早期部署过程留下的过时参考副本，不再随当前集群更新，不能保证与远端部署包相同，也不能作为恢复源。后续不要再修改该目录；如需追溯，只进行只读比较。

## 3. 宿主机与工具链

| 项目 | 当前值 |
|---|---|
| 宿主机系统 | Ubuntu `24.04`，`x86_64` |
| CPU | `32` 逻辑 CPU |
| 内存 | `62 GiB` |
| 根磁盘 | `645 GiB`，记录时已用约 `168 GiB` |
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
| Grafana Ingress | 无，Traefik Service 为 ClusterIP | `31005` |

Prometheus Service 还自动分配了第二个 NodePort `30104` 给 Service 的 `8080` 端口，但 Kind 没有把它映射到宿主机；日常访问只使用 `31003`。

为兼容源码现有结果采集地址，宿主机运行 systemd 服务 `benchmark-grafana-port-forward.service`，将 `127.0.0.1:8080` 持久转发到 `monitoring/monitoring-grafana:80`。外部 Dashboard 入口由 `benchmark-grafana-ingress-port-forward.service` 将 `0.0.0.0:31005` 持久转发到 Traefik ClusterIP Service。两个入口都不是 Kind 端口映射。

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
- `--concurrent-job-syncs=100`
- `--node-monitor-grace-period=7200s`
- `--node-monitor-period=3600s`
- `--cluster-cidr=10.244.0.0/16`

长 Node 监控周期用于降低大量虚拟节点带来的状态检查开销。它也会让真实节点故障感知明显变慢，因此本集群不应作为通用 Kubernetes 集群使用。

Controller Manager 静态 Pod 的 CPU request/limit 为 `1/8`，不设置内存 request/limit。

### 默认 Scheduler 自定义参数

- `--kube-api-qps=1000`
- `--kube-api-burst=1000`

默认 Scheduler 静态 Pod 的 CPU request/limit 为 `1/8`，不设置内存 request/limit。Kueue 非 Gang 场景未指定 `schedulerName`，会经过该 Scheduler；Gang 场景使用 Coscheduling，Volcano 和 YuniKorn 使用各自 Scheduler。

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
| Traefik | chart `40.2.0` / app `v3.7.1` | `benchmark-grafana-ingress` | chart 先下载并校验，再从本地 tgz 安装；镜像固定 digest |
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
| Traefik chart | `https://traefik.github.io/charts` | `downloads/traefik-40.2.0.tgz` | `b73d0159fc1222cc9bdaefde80000a9bad2dfe81de4caed14b9509b3bf6c1df9` |

Kueue、Scheduler Plugins 和 kube-prometheus-stack 的期望 SHA-256 已写入 `versions.env`，部署脚本会验证。Volcano 和 YuniKorn 脚本当前只打印实际 SHA-256，没有把期望值写入 `versions.env`；上表是当前已部署缓存的基线，升级或重建时应先比较，不要无条件覆盖。

### 具体安装路径

- Volcano：`helm upgrade --install` 使用本地 `volcano-1.15.1.tgz` 和 `values/volcano.yaml`；安装脚本随后为 Admission 补齐 chart 未暴露的 API client QPS/Burst 参数，并核对三个 Deployment 的统一资源基线。
- Kueue：本地 `kueue-v0.19.0.yaml` 使用带字段接管的 `kubectl apply --server-side --force-conflicts`；随后应用本地 `kueue-manager-config.yaml`，以 JSON Patch 覆盖官方 manifest 的资源配置，重启 Controller，并运行 Webhook 作用域修正脚本。字段接管用于保证资源覆盖后的重复安装不会因 field manager 冲突而中止。
- Coscheduling：本地 source tarball 解压后，先 server-side apply `manifests/coscheduling/crd.yaml` 和 `config/crd/bases/scheduling.x-k8s.io_elasticquotas.yaml`，再从 `manifests/install/charts/as-a-second-scheduler` 进行 Helm 安装；最后用本地 ConfigMap 覆盖 scheduler 配置，为 Controller 补齐 QPS/Burst/Workers 参数并重启。
- YuniKorn：`helm upgrade --install` 使用本地 `yunikorn-1.9.0.tgz` 和 `values/yunikorn.yaml`；由于 1.9.0 chart 强制渲染内存字段和 Go 内存环境变量，安装脚本随后以 JSON Patch 精确恢复 CPU-only 资源基线并移除 `GOMEMLIMIT`、`GOGC`，再把 Mutating Webhook 限定到 `bench-yunikorn` 标签、Validating Webhook 限定到 `yunikorn` 命名空间。
- 监控：`helm upgrade --install` 使用本地且已校验的 kube-prometheus-stack tgz；Prometheus 不设置 CPU/内存 request 或 limit；Image Renderer 由 chart 部署；Audit Exporter、审计 Dashboard 和 `perf` Dashboard 均由部署目录中的本地文件 apply；安装脚本同时安装并启用 Grafana 8080 systemd 转发服务。
- Grafana Ingress：仓库 `deploy/grafana-ingress/install.sh` 校验并使用远端缓存的 Traefik tgz，以非默认 IngressClass 安装 controller，apply 本地 Ingress，并安装启用 31005 systemd 持久入口。

## 8. 调度器实际配置

### Volcano

- Scheduler 名称：`volcano`
- Helm release：`volcano`，chart `volcano-1.15.1`
- 常驻 Deployment：`volcano-scheduler`、`volcano-controllers`、`volcano-admission`，各 `1` 副本
- Agent Scheduler：关闭
- Sharding Controller：关闭
- Webhook 目标命名空间标签：`benchmark.scheduling/base=volcano`
- 安装后空闲配置：actions 为 `enqueue, allocate, backfill`；第一层为 `priority/gang/conformance`，第二层为 `overcommit/drf/predicates/proportion/nodeorder/binpack`
- 测试期间配置：`TestInit` 临时切换为 `enqueue, allocate, backfill, reclaim`；第一层为 `priority/gang`，第二层为 `predicates/capacity`，以支持 `benchmark-root` 层级队列；`make down` 恢复测试前空闲配置
- Volcano Job CRD：`jobs.batch.volcano.sh/v1alpha1`，served/storage 均为 true
- Scheduler、Controller、Admission API client QPS/Burst 均为 `1000/1000`
- Controller 的 Job、GC、PodGroup worker 均为 `100`

资源配置：

| Deployment | Requests | Limits |
|---|---|---|
| volcano-scheduler | `500m CPU` | `8 CPU` |
| volcano-controllers | `500m CPU` | `8 CPU` |
| volcano-admission | `500m CPU` | `8 CPU` |

### Kueue

- Controller 镜像：`registry.k8s.io/kueue/kueue:v0.19.0`
- Deployment：`kueue-controller-manager`，`1` 副本
- 配置 API：`config.kueue.x-k8s.io/v1beta2`
- `manageJobsWithoutQueueName=false`
- 只集成 `batch/job`
- 只管理带 `benchmark.scheduling/base=kueue` 标签的命名空间
- `leaderElect=false`
- API client：`qps=1000`、`burst=1000`
- 当前启用且名称兼容的 Controller 并发：Job、Workload、LocalQueue、Cohort、ClusterQueue、ResourceFlavor 均为 `100`
- `DisableWaitForPodsReady=true`，显式保持 v0.10.3 省略该项时的关闭语义
- Workload CRD 同时 served `v1beta1` 与 `v1beta2`，storage 版本为 `v1beta2`
- 资源：Requests `500m CPU`，Limits `8 CPU`，不设置内存 request/limit

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
- `permitWaitingTimeSeconds=60`
- Scheduler Plugins Controller 配置参数：`qps=1000`、`burst=1000`、`workers=100`
- v0.32.7 与 v0.34.7 的同一上游实现都会丢弃前两个参数所修改的 REST config，因此有效 QPS/Burst 都是 controller-runtime 默认值；保留参数是为了配置一致，未构建自定义镜像改变旧基线行为；`workers=100` 正常生效

资源配置：

| Deployment | Requests | Limits |
|---|---|---|
| coscheduling | `500m CPU` | `8 CPU` |
| scheduler-plugins-controller | `500m CPU` | `8 CPU` |

### YuniKorn

- Scheduler 名称：`yunikorn`
- Helm release：`yunikorn`，chart `yunikorn-1.9.0`
- 标准 Scheduler 模式，不是已移除的 Scheduler Plugin 模式
- Scheduler Deployment：`yunikorn-scheduler`，`1` 副本
- Admission Deployment：`yunikorn-admission-controller`，`1` 副本
- 内嵌 Admission Controller：开启
- Web Service/UI：关闭
- Mutating Webhook 的 Kubernetes `namespaceSelector` 只匹配 `benchmark.scheduling/base=yunikorn`，进程内部再以 `^bench-yunikorn$` 二次过滤
- Validating Webhook 只匹配 `kubernetes.io/metadata.name=yunikorn`，用于配置 ConfigMap
- Admission 绕过 `^(kube-system|yunikorn)$`
- 空闲时没有 `yunikorn-configs`，使用内置 placement 规则，`bench-yunikorn` 的动态队列为 `root.bench-yunikorn`
- 测试期间 `TestInit` 临时创建专用 `queues.yaml`，同时设置 `kubernetes.qps=1000`、`kubernetes.burst=1000`；`make down` 恢复测试前空闲状态
- Scheduler 和 Admission 均未设置 `GOMEMLIMIT`、`GOGC`，使用与旧基线一致的 Go runtime 默认行为

资源配置：

| Deployment | Requests | Limits |
|---|---|---|
| yunikorn-scheduler | `500m CPU` | `8 CPU` |
| yunikorn-admission-controller | `500m CPU` | `8 CPU` |

## 9. 命名空间与多调度器隔离

| 命名空间 | 标签 | 目标组件 |
|---|---|---|
| `bench-volcano` | `benchmark.scheduling/base=volcano` | Volcano |
| `bench-kueue` | `benchmark.scheduling/base=kueue` | Kueue + Coscheduling |
| `bench-yunikorn` | `benchmark.scheduling/base=yunikorn` | YuniKorn |

空闲基线下三套 Scheduler Deployment 都是 `1` 副本并同时运行。仓库常驻集群流程会在每轮实验前记录所有调度组件的实际副本数，仅保留目标调度组件为 `1` 副本、将其他调度组件缩容为 `0`，等待非目标 Pod 完全退出后再开始测试；Kueue 命名空间资源使用异步删除并在最多 600 秒内确认归零，再删除集群级测试资源；随后使用精确替换恢复可变 ConfigMap，并恢复测试前实际副本数。YuniKorn 清理不主动扩容 Scheduler 或 Admission；测试前 Scheduler 为 `0` 时，配置恢复也不会额外启动或重启它。

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
- Prometheus resources：未设置 CPU/内存 request 或 limit
- Alertmanager：关闭
- Node Exporter：关闭
- Kubelet、CoreDNS、kube-proxy ServiceMonitor：关闭
- Default rules：关闭

第二轮完整测试期间 Prometheus 进程 RSS 峰值约为 `19.44GiB`，主容器未重启也未 OOM。当前不设置内存上限与旧源码基线一致，但完整测试前仍需确认宿主机有充足可用内存。

访问地址（从服务器本机）：

- Prometheus：`http://127.0.0.1:31003`
- Grafana：`http://127.0.0.1:31004`
- 源码结果采集入口：`http://127.0.0.1:8080/grafana`
- Grafana Ingress：`http://104.105.137.213:31005/grafana/d/perf/?theme=light`

安全说明：宿主机入口使用 `0.0.0.0:31003/31004/31005`，是否能被公网访问取决于服务器防火墙和云安全组。Grafana Ingress 已从外部验证可访问，且 Grafana 启用了匿名 Viewer，因此 `31005` 会公开基准指标；不需要公网访问时应在防火墙或云安全组限制来源。Grafana 密码保存在 Kubernetes Secret 中，不写入本文。

Grafana 启用了匿名 Viewer 和 `/grafana/` 子路径。`perf` Dashboard 由 `manifests/perf-dashboard.json` 创建为 `scheduling-perf-dashboard` ConfigMap，固定 UID 为 `perf`；当前 20 条可见查询均使用 `exported_namespace`。Image Renderer 负责 `/render/d-solo/perf` 图片接口；场景 5 已验证 `panel-1` 至 `panel-8` 均能渲染实际曲线。`verify-monitoring.sh` 的基础 PNG 检查仍只属于连通性验收，完整实验还需检查图片内容。

### Grafana Ingress

仓库中的 `deploy/grafana-ingress/` 是当前持久入口的部署和验收源：

- Controller：Traefik Helm chart `40.2.0`，应用版本 `v3.7.1`
- Helm release 和命名空间：`benchmark-grafana-ingress`
- 非默认 IngressClass：`benchmark-grafana`
- 监听范围：只处理 `monitoring` 命名空间的 Kubernetes Ingress；不启用 Traefik CRD 和 Gateway provider
- 路由：`/grafana` 转发到 `monitoring/monitoring-grafana:80`
- 宿主机入口：`0.0.0.0:31005`
- 持久暴露方式：systemd 服务将宿主机 `31005` 转发到 Traefik ClusterIP Service 的 `80` 端口
- Kind 端口映射：不新增 `extraPortMappings`；现有 Kind 集群不重建，因此 `31005` 不是 Docker/Kind 端口映射

官方 chart 制品来源为 `https://traefik.github.io/charts/traefik/traefik-40.2.0.tgz`，固定 SHA-256 为 `b73d0159fc1222cc9bdaefde80000a9bad2dfe81de4caed14b9509b3bf6c1df9`。当前浅色入口为 `http://104.105.137.213:31005/grafana/d/perf/?theme=light`；服务器内的 `31004` 和回环 `8080` 入口继续保留。

### Audit Exporter

- 镜像：`ghcr.io/wzshiming/kube-apiserver-audit-exporter/kube-apiserver-audit-exporter:v0.0.25`
- Deployment：`kube-apiserver-audit-exporter`，`1` 副本
- 从控制面宿主路径只读读取 `/var/log/kubernetes/kube-apiserver-audit.log`
- ServiceMonitor 抓取间隔和超时均为 `1s`
- 已验证指标包括 `pod_scheduling_latency_seconds` 和 `api_requests_total`
- Grafana Dashboard：`Scheduling Audit Overview`，UID `scheduling-audit-overview`

源码运行性能实验时，会在截断审计日志前停止 Audit Exporter，并为 Kueue、Volcano、YuniKorn 分别以独立 `cluster` 标签启动全新进程。测试结束后先等待 Exporter 指标稳定，再确认 Prometheus 已抓取到晚于稳定时刻的样本，最后以毫秒时间窗采集结果并恢复 Exporter 测试前参数和副本数。这样常驻部署不依赖 overview 集群，也不会把进程内指标或文件 offset 混入下一轮。

### 审计日志稀疏文件风险（已观察）

当前实验通过截断正在由 API Server 写入的同一个审计文件来重置日志，但不会让 API Server 重新打开文件。第二轮完整测试已经观察到：API Server 保留旧文件 offset 后继续写入会形成带大段 NUL 空洞的稀疏文件，随后复制到结果目录的审计日志继承该问题。Gang 场景中的日志表观大小逐轮增长到数 GiB，但实际分配块明显更小；例如最后一个结果中的 Kueue 审计日志表观大小约 `5.80 GB`，而分配空间约 `313 MiB`。

因此，非空或表观大小很大的审计日志不等于完整有效的 JSON Lines 文件。后续分析必须先检查 NUL、首条有效 JSON 的偏移和记录连续性；不能只根据文件大小验收。Prometheus 抓取屏障通过只能证明 Exporter 指标已被抓取，不能替代原始审计文件完整性验证。该风险尚未修复。

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
| Traefik | `docker.io/traefik:v3.7.1` | `sha256:6b9cbca6fac42ab0075f5437d8dc1685cfd188626d8d515839ea94f8b6271c42` |
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

cd /root/github/kube-scheduling-perf
./deploy/grafana-ingress/install.sh
./deploy/grafana-ingress/verify.sh

cd /root/benchmark-1348-deploy

./scripts/scale-kwok-nodes.sh 1000
./scripts/verify-base.sh 1000
./scripts/verify-schedulers.sh
./scripts/verify-monitoring.sh
```

执行前还要确认：

- `/usr/local/bin/kind` 是 `v0.32.0`
- `versions.env` 和全部下载制品 SHA-256 与本文一致
- audit policy 源文件仍存在
- `31003`、`31004`、`31005` 和回环地址 `127.0.0.1:8080` 未被其他进程占用
- 至少有足够的 Docker 磁盘空间
- 已备份需要保留的审计日志、Prometheus 数据导出和实验结果

## 13. 日常验收

服务器上的只读/低风险验收入口：

```bash
cd /root/benchmark-1348-deploy
./scripts/verify-base.sh 1000
./scripts/verify-schedulers.sh
./scripts/verify-monitoring.sh
cd /root/github/kube-scheduling-perf
./deploy/grafana-ingress/verify.sh
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
- Grafana Ingress `verify.sh` 确认 Helm 版本、Deployment、IngressClass、路由、镜像、systemd unit 和服务器回环 31005 链路
- 从本地电脑单独执行外部 URL 的 `curl`，确认健康接口和 Dashboard 返回 HTTP 200
- Audit Exporter 暴露调度指标

`run-scheduler-smoke-tests.sh` 会创建并删除真实测试资源，不属于纯只读检查；只在允许变更集群状态时运行。

PNG 签名和 HTTP 200 都不能排除面板显示 `No data`。完整实验验收必须再检查图片内容，并使用对应实验时间窗查询关键 Prometheus 序列。

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
- 远端部署包损坏：不要使用过时的 `k8s-1-35` 本地副本覆盖；应从当前版本化备份或已确认来源重建远端权威部署包，并逐项核对本文指纹和实时集群状态。

## 16. 部署包文件指纹

以下为当前远端权威部署包的关键文件 SHA-256。过时本地参考副本不在一致性承诺范围内：

| 文件 | SHA-256 |
|---|---|
| `versions.env` | `9802258aa7437b303934ab306442f5f48d4ba7466802ff93ed0371a8932c7305` |
| `kind-config.yaml` | `bb5e52c0339cd90862baaea9f404b7994afa224e17a3f505b2e888cf4c848286` |
| `values/volcano.yaml` | `e2bbd980356f744873887498bcc50da99d5a7ee6d2abbbfade6c135078271316` |
| `values/coscheduling.yaml` | `3bc034780c3681265dd399556abf80ff8b09817c301c3a116b183e2fb3443920` |
| `values/yunikorn.yaml` | `a2955429e78d203c17a9b4c21de03ab1aa04a055a57989d16fcba9d7eacb1856` |
| `values/monitoring.yaml` | `9e1851bb5538b05bb7380be878857b22c13d3acc0f688af3bad49f5320c48bf6` |
| `manifests/kueue-manager-config.yaml` | `4ef6994a2568fc4ad9b5aac90b27107cc3c985405810d274d99d70425497057a` |
| `manifests/coscheduling-configmap.yaml` | `734c327e14ca405679e5bb57e875386aa11981e17dfbe7e22a3749b2efc4ebbe` |
| `manifests/benchmark-namespaces.yaml` | `e766ab1fc5c3de100f727a5ac46fcaee8ae3e9d0eb9eb682c4769b715fbba74f` |
| `manifests/audit-exporter.yaml` | `e784ca7241ffb9b1b3055505643d3a34b92b55e47395bd6670562e393d1039a8` |
| `manifests/audit-dashboard.yaml` | `558dfb641b07815b1dba8467a7939516be88ce3b07016f448d08e775c81d82fb` |
| `manifests/perf-dashboard.json` | `4f86fba9eb59e5496b80c3c09fb1491e88554662b8b5acecf4f54e22b025f4f3` |
| `manifests/scheduler-smoke-tests.yaml` | `8574169b65bd048ed085c344bdbf6650cae18773c44001a7bef1bfc0acd8aa45` |
| `scripts/create-canary-cluster.sh` | `796c7aee3595252d492d937a6ebb76c7f6fd609806a419aae746c7b42c14ce03` |
| `scripts/configure-control-plane-baseline.sh` | `8e533ca29ef7b45751fa5c178f04cf088ae55f74d878b17907e6d1c2831d7a47` |
| `scripts/install-kwok-canary.sh` | `24ec70a2d257b5615ee67c5fd6e0e743542aed552d209683eed33f8ff19cbcb5` |
| `scripts/prepare-scheduler-artifacts.sh` | `ef0fc3f6d828d9e98c0cc8dcbe4ff1dfbb6a603ba62ec93a3c2feee7c1f574c1` |
| `scripts/install-schedulers.sh` | `d974402272616e26f95f3396525a9e35197df59e4f60fe224f47cd812bc08438` |
| `scripts/scope-kueue-webhooks.sh` | `f3be442a47f5992e78b37b0b4c2f4dac672cc79fc683f44cb206c9e44a96acdc` |
| `scripts/scope-yunikorn-webhooks.sh` | `251569cb2fbcd8072141e04e3b1592e6702e85429fd95e179da4e6f282ab1c22` |
| `scripts/prepare-monitoring-artifacts.sh` | `04bdaafab302f228bc7c1d843531db0059dbadca3b7effda3a9e576704caf020` |
| `scripts/install-monitoring.sh` | `c05b6909f00556bd2f26810f899fe69236a9edeec9b20e19ba78ed11ff495994` |
| `scripts/scale-kwok-nodes.sh` | `6d4bfdf53b644f04d661c55698caad4b9303824752a2859ae5c235fc54e8960c` |
| `scripts/run-scheduler-smoke-tests.sh` | `e1258ff299dc28162c59ba507365d234308e6344e42449d9582c16e89959d6cb` |
| `scripts/verify-base.sh` | `af35c07b047896d6d0109324080bf5132f6b1a96b57429ca9dac7fdb037f7fcd` |
| `scripts/verify-schedulers.sh` | `01d2beb821119b578c71fe1776b3aa8e654b4a8f3f8be1a8a6f45569415a3fb2` |
| `scripts/verify-monitoring.sh` | `a13c5acea6793d15de610420e4ed14f43c06771c8824029d3b62e63adbbc2e1d` |
| `systemd/benchmark-grafana-port-forward.service` | `23952b1b52fd95bdaab07f91abf1b695a97a52ef99a95dce5a0a27ba84a94ec1` |
| `deployed-image-lock.md` | `11c3337ca068b1eb1ec3b3482e09d7c926960a2cd8372d59be7e6e40333492cc` |

Grafana Ingress 的版本化部署源位于仓库，当前文件指纹如下：

| 文件 | SHA-256 |
|---|---|
| `deploy/grafana-ingress/versions.env` | `2161ee1332a66dbb5e4e4b0187723d6ad56ca154c08398a85dd82a4feb554f6f` |
| `deploy/grafana-ingress/values.yaml` | `6c87c4507b1a3528bfdcf6734b0d5d9f9145de6569f03eed2212d9e66be51b32` |
| `deploy/grafana-ingress/grafana-ingress.yaml` | `d406ea5aa302429fd59176067df684024af9202ab2700867b0866b96fdcaaefe` |
| `deploy/grafana-ingress/systemd/benchmark-grafana-ingress-port-forward.service` | `9b96570c6594db170aa5d616ef302c5b6b5d793b4ea03dea4f1f3951d5ab51a0` |
| `deploy/grafana-ingress/install.sh` | `af24426f9a5dd3edd5bc452502e53ca639cc0bc05441f0a53b2b2b5cde6190d6` |
| `deploy/grafana-ingress/verify.sh` | `2f888cee794a933e4fa79ed30252a7864a82c4213cab8eeff83669efbbfff206` |

这些指纹用于识别部署包漂移，不等于对文件来源的签名认证。

## 17. 2026-08-04 变更与验收记录

- 精确删除 `kwok-node-1000` 至 `kwok-node-4999`，基线缩减为 `1000` 个 KWOK Node。
- 安装 Grafana Image Renderer `v5.11.1`、`perf` Dashboard 和 `127.0.0.1:8080/grafana` systemd 转发服务。
- 补装 Scheduler Plugins `ElasticQuota` CRD，修复 `scheduler-plugins-controller` 因 informer 找不到资源而持续重启的问题；部署和验收脚本已同步固化。
- 当时曾对本地参考副本与远端 `/root/benchmark-1348-deploy` 的本轮变更文件逐项核对；远端此后继续修订，该历史结论不代表当前仍一致。
- 常驻集群源码在服务器隔离目录 `/root/benchmark-resident-source` 完成 Kueue、Volcano、YuniKorn 单项冒烟和完整串行实验；原目录 `/root/github/kube-scheduling-perf` 的跟踪文件未改动。
- 完整串行验收结果位于 `/root/benchmark-resident-source/results/1785850713`，包含 8 张有效 PNG 和三份非空 API Server 审计日志。
- 在 Volcano 完成 `prepare`、尚未执行 `start/end` 时直接执行 `make down`，确认实验资源和状态文件零残留、Volcano 配置恢复、全部调度 Deployment 为 `1/1`、`1001/1001` Node Ready。

## 18. 2026-08-05 性能基线纠正记录

- 比较常驻集群改造前提交 `6ce46e0cd2464a5c03331f8ee756980719ca4d69`、当前部署包和实时 Deployment，确认 8 个调度组件的资源配置在常驻部署时发生了未经批准的变化。
- 将 Kueue、Coscheduling、Volcano、YuniKorn 的 8 个调度组件统一恢复为 CPU request `500m`、limit `8`，不设置内存 request/limit。
- Kueue 恢复 API client `1000/1000`、兼容且启用的六类 Controller 并发 `100` 和关闭 Leader Election；未机械添加未启用的 Pod Controller。
- Coscheduling 保留当前版本默认 parallelism `16`，恢复 Controller 参数 `qps/burst/workers=1000/1000/100` 和旧基线等价的 Permit 等待 `60s`；v0.32.7 和 v0.34.7 的相同上游缺陷会让 Controller 的 QPS/Burst 实际保持默认值，因此未额外改变有效行为。
- Volcano 恢复 Scheduler、Controller、Admission API client `1000/1000` 和 Controller 三类 worker `100`；保留已批准的新版 Admission 集合、命名空间隔离以及 `benchmark-root` 所需的 Scheduler actions/plugins。
- YuniKorn 测试态继续使用旧基线已有的 `kubernetes.qps/burst=1000/1000`；恢复统一 CPU-only 资源，并移除 chart 因内存限制生成的 `GOMEMLIMIT`、`GOGC`。
- 当时曾对 6 个变更文件逐项核对；远端部署包此后继续修订，当前只以远端为权威。执行 `install-schedulers.sh` 后，基础集群、调度器和监控验证全部通过，Node 为 `1001/1001 Ready`。
- 独立评审后补齐 Controller Manager `concurrent-job-syncs=100`、Controller Manager 与默认 Scheduler CPU `1/8`、默认 Scheduler QPS/Burst `1000/1000`，显式禁用 Kueue WaitForPodsReady，并在 Kubernetes Webhook 层隔离 YuniKorn。
- `configure-control-plane-baseline.sh` 与完整 `install-schedulers.sh` 均完成重复执行验证；首次复跑发现并修复 Kueue server-side apply 字段冲突，修复后从头复跑成功。

## 19. 2026-08-05 基线纠正后复测记录

- 被测源码 Commit 为 `3fedf92c82fce58ca12f1e1551443a55b4e79e97`。
- 场景 1 最小测试首轮通过：Kueue `118.25s`、Volcano `122.84s`、YuniKorn `118.04s`；结果位于 `/root/github/kube-scheduling-perf/results/1785924215`，包含完整控制台日志、3 份审计日志和 8 张 Grafana PNG。
- 随后唯一一轮完整 `make` 在首场景 Kueue 通过后因 SSH 连接中断而终止；Volcano、YuniKorn 和后续场景未执行。该轮属于基础设施中断，未修复、未重跑；现场保存在 `/root/github/kube-scheduling-perf/results/failed-full-20260805T100557Z`。
- 中断后 `make down` 返回 0；`.resident-state` 和实验资源均无残留。
- 最终 `verify-base.sh 1000`、`verify-schedulers.sh`、`verify-monitoring.sh` 全部通过，`1001/1001` Node Ready，8 个调度组件均 Running/Ready 且重启次数为 0，YuniKorn Webhook 最近 15 分钟失败数为 0。

## 20. 2026-08-05 两轮独立完整测试与最终边界

### 20.1 第一轮失败与 Prometheus 基线纠正

- 第一轮独立完整测试使用提交 `73ae14df7f29e6f4e81e34f91e286e1ff7f278cd`，运行时间为 `2026-08-05T13:20:37Z` 至 `13:44:51Z`，总耗时 `24m13.961s`，在场景 3 失败。
- 直接根因是 Prometheus 在 `4Gi` 内存 limit 下发生 OOMKilled；常驻改造前源码中的 Prometheus CR 没有 resources，该限制也没有获得基线变更批准。
- 已从远端 `values/monitoring.yaml` 删除整个 Prometheus resources 配置并重新应用，恢复为不设置 CPU/内存 request 或 limit；同时保留原监控版本和抓取配置。修复后的 values 指纹见第 16 节。
- 第一轮失败现场位于服务器 `/root/github/kube-scheduling-perf/results/failed-full-20260805T132037Z`。修复后 Prometheus 健康，第二轮没有再次 OOM。

### 20.2 第二轮完整测试最终失败

| 项目 | 结果 |
|---|---|
| 被测提交 | `c3805c84e68fa233f76041ec720b7ccbbb20cbe8` |
| 运行时间 | `2026-08-05T14:00:57Z` 至 `14:59:26Z` |
| 总耗时 | `3508.883s`（`58m28.883s`） |
| 结果目录 | `1785938917`、`1785939214`、`1785939507`、`1785939808`、`1785940558`、`1785941020`、`1785941406`、`1785941910` |
| 进程退出码 | `0`，但不满足完整测试验收条件 |
| 最终结论 | 失败；按执行计划不再修复，也不执行第三轮完整测试 |

场景 1 至 4 的三套 `TestBatchJob` 均通过。场景 5（Gang `10000 job × 1 pod`）中，Kueue 测试和指标屏障通过后，`kubectl delete podgroups --all --timeout=5m` 已将对象删为 0，但客户端按对象等待时因限流耗尽 5 分钟并返回错误。Kueue 恢复状态未清除，Volcano 准备阶段被安全检查拒绝；既有分号串行流程仍继续启动 Volcano 测试，最终因 Volcano Admission 仍为 0 副本而发生 Webhook connection refused。该 Volcano 数据没有性能意义。场景 6 至 8 后续执行完成，但单个子测试失败已经使整轮不能验收通过；顶层退出码 `0` 也不能覆盖内部失败。

第二轮创建了 8 个结果目录和 `64` 张具有合法 PNG 文件签名的图片，但现场检查确认图片面板均为 `No data`，同一 panel 在 8 个场景中的文件摘要完全相同。这些图片不能作为有效指标结果，说明仅检查 PNG 签名的既有验收不足。

第二轮复制出的部分审计日志还包含第 10 节记录的稀疏 NUL 空洞，不能仅凭非空和表观大小判定有效。原始运行与失败现场保存在服务器 `/root/benchmark-full-runs/20260805T140031Z-second` 和 `/root/github/kube-scheduling-perf/results/failed-full-20260805T140057Z`。

测试后基础集群、8 个调度组件和监控组件均恢复健康，`1001/1001` Node Ready。最终失败属于常驻资源清理的高基数适配缺陷及结果制品验收缺陷，不是 Prometheus `4Gi` OOM 的复发；本轮停止修复，留待后续单独设计。

## 21. 2026-08-05 Grafana Ingress 部署记录

- 首次部署时间：`2026-08-05T15:20:14Z`；收紧重复部署与验收逻辑后于 `15:33:41Z` 完成幂等 reconcile。Helm release `benchmark-grafana-ingress` 当前 revision `2`，chart `40.2.0`，应用 `v3.7.1`。
- 初始记录的 GitHub release tgz URL 返回 `404`，下载阶段即停止，未创建集群资源；随后改用 Traefik 官方 Helm 仓库 URL，并以官方 index 中相同的 SHA-256 校验后部署。
- Controller Deployment 为 `1/1`，Pod restart `0`；Service 是 ClusterIP `10.96.157.253:80`，IngressClass `benchmark-grafana` 为非默认类，controller 为 `traefik.io/ingress-controller`。
- Ingress `monitoring/benchmark-grafana` 将 `/grafana` 转发到 `monitoring-grafana:80`。Traefik 只监听 `monitoring` 命名空间的 Kubernetes Ingress，不启用 CRD、Gateway provider、管理 Dashboard 或额外 metrics。
- `benchmark-grafana-ingress-port-forward.service` 已设为 enabled/active，并在主动重启后自动恢复；宿主机 `0.0.0.0:31005` 由该服务持久监听。
- 从服务器回环和本地电脑访问健康接口均返回 `database=ok`，浅色 Dashboard URL 均返回 HTTP `200`，不再依赖手工 SSH 转发。
- 部署前后的 Prometheus Pod UID `85919f37-5777-40cb-b438-b3025c602ae1`、Grafana Pod UID `7a40229a-384e-47dc-a467-64b5f6405108` 保持不变，容器 restart 均为 `0`；Ingress 部署没有重启 Prometheus 或 Grafana。
- 部署后 `verify-base.sh 1000`、`verify-schedulers.sh`、`verify-monitoring.sh`、Ingress `verify.sh` 和三套实验资源零残留断言全部通过。

## 22. 2026-08-06 场景 5 定向修复验证

- 服务器仓库与远程 `master` 同步到 `708f8fafb2ba9b86641d2f3a8201b168561905b0`。
- Kueue 的 Job、PodGroup、Workload、LocalQueue 和 Pod 改为异步删除，等待最多 600 秒确认命名空间资源归零后，再删除 ClusterQueue、ResourceFlavor 和 WorkloadPriorityClass。
- 场景 5（Gang，`10000 job × 1 pod`）于 `2026-08-06T12:52:59Z` 至 `13:02:45Z` 执行，退出码为 `0`；Kueue、Volcano、YuniKorn 分别用时 `158.79s`、`118.21s`、`118.04s`。
- Kueue 的 10000 个 PodGroup 清理成功，Volcano 与 YuniKorn 随后正常执行；结果目录为 `/root/github/kube-scheduling-perf/results/1786021307`。
- Grafana 渲染使用原生 `$__all` 变量；8 张 PNG 均包含实际曲线，不再是 `No data`。实时 Dashboard 的 20 条可见查询全部使用 `exported_namespace`，远端权威部署文件指纹已更新到第 16 节。
- 本轮不处理历史审计日志稀疏 NUL 空洞，也没有重跑全部 8 个场景；因此只将场景 5 原失败链路判定为修复，不改变上一轮完整测试的历史结论。
- 测试后 `.resident-state` 和三套实验资源均无残留；`1001/1001` Node、8 个调度组件、Audit Exporter、Prometheus、Grafana 和 Ingress 验收通过。
