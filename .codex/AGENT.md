# 当前调度基准集群基线

详细记录见仓库根目录 `CLUSTER_DEPLOYMENT_RECORD.md`。处理集群故障、更新、测试隔离或重建前必须先阅读该文件。

## 当前集群

- 服务器：`104.105.137.213`
- 唯一 Kind 集群：`volcano-benchmark-1348`
- Kubernetes：`v1.34.8`
- 拓扑：1 个控制面 + 1000 个 KWOK Node，正常状态为 `1001/1001 Ready`
- 远端部署目录：`/root/benchmark-1348-deploy`
- `/root/benchmark-1348-deploy` 是基础集群、调度和监控配置的权威副本；Grafana Ingress 的版本化部署源是仓库 `deploy/grafana-ingress/`
- `/Users/csmvic/Documents/Codex/2026-08-03/k8s-1-35/` 是过时参考目录，只读且禁止修改或用于重新部署
- kubeconfig：`/root/benchmark-1348-deploy/kubeconfig`
- 必须使用的 kubectl：`/root/benchmark-1348-deploy/bin/kubectl v1.34.8`
- 创建集群使用的 Kind：`/usr/local/bin/kind v0.32.0`
- 仓库 `/root/github/kube-scheduling-perf/bin/kind` 是 `v0.27.0`，不要把它当作本集群基线工具
- 旧集群 `volcano-benchmark` 已删除

## 组件版本

| 组件 | 版本 | 主要对象/命名空间 |
|---|---|---|
| Kind | `v0.32.0` | 宿主机 `/usr/local/bin/kind` |
| Kubernetes / kubectl | `v1.34.8` | `volcano-benchmark-1348` |
| KWOK | `v0.7.0` | `kube-system/kwok-controller` |
| Volcano | `v1.15.1` | `volcano-system`，schedulerName `volcano` |
| Kueue | `v0.19.0` | `kueue-system` |
| Scheduler Plugins / Coscheduling | `v0.34.7` | `coscheduling`，schedulerName `coscheduling` |
| YuniKorn | `v1.9.0` | `yunikorn`，schedulerName `yunikorn` |
| kube-prometheus-stack | `88.1.3` | `monitoring` |
| Prometheus | `v3.13.2-distroless` | host `31003` |
| Prometheus Operator | `v0.93.0` | `monitoring` |
| Grafana | `13.1.1` | host `31004` |
| Grafana Image Renderer | `v5.11.1` | `monitoring`，结果采集入口 `127.0.0.1:8080/grafana` |
| Traefik | Helm chart `40.2.0` / app `v3.7.1` | `benchmark-grafana-ingress`，外部入口 `31005` |
| kube-state-metrics | `v2.19.1` | `monitoring` |
| Audit Exporter | `v0.0.27` | `kube-system` |

## 安装来源

- KWOK 的 `kwok.yaml` 和 `stage-fast.yaml` 是 GitHub release URL 直接 apply，没有缓存在 downloads。
- Volcano、YuniKorn、kube-prometheus-stack 都先 pull 为远端部署目录中的本地 tgz，再通过 Helm 安装。
- Kueue release manifest 先下载并校验 SHA-256，再从本地文件 server-side apply。
- Scheduler Plugins source tarball 先下载并校验，PodGroup、ElasticQuota CRD 和 Coscheduling Helm chart 从本地解压目录安装。
- Audit Exporter、Dashboard、命名空间和自定义 ConfigMap 使用部署目录中的本地文件 apply。
- Grafana Image Renderer 由本地 kube-prometheus-stack chart 安装；`perf` Dashboard 来自本地 JSON；8080 入口由 systemd 持久转发。
- Traefik chart 从官方 Helm 仓库下载并校验 SHA-256，再由仓库 `deploy/grafana-ingress/` 安装；镜像固定 digest，31005 入口由 systemd 持久维持。
- 固定制品 SHA-256、运行镜像 digest 和完整重建顺序见 `CLUSTER_DEPLOYMENT_RECORD.md`。

## 关键配置

- API Server inflight：mutating `20000`，总请求 `20000`。
- Controller Manager：QPS `5000`、burst `10000`、Job 并发 `100`、Node monitor grace `7200s`、period `3600s`；CPU request/limit `1/8`。
- 默认 Scheduler：QPS/burst `1000/1000`，CPU request/limit `1/8`；Kueue 非 Gang 场景使用它。
- etcd：8 GiB quota，revision compaction retention `1000`。
- 每个 KWOK Node：`16 CPU / 64Gi / 110 Pods`，标签 `type=kwok`，带 `kwok.x-k8s.io/node=fake:NoSchedule`。
- `kindnet` 和 `kube-proxy` 通过 NodeAffinity 排除 KWOK Node。
- Volcano Webhook 目标 namespace 标签为 `benchmark.scheduling/base=volcano`。
- Kueue Controller 和全部 Kueue Webhook 目标 namespace 标签为 `benchmark.scheduling/base=kueue`。
- YuniKorn Mutating Webhook 在 Kubernetes 层只匹配 `bench-yunikorn` 标签，Validating Webhook 只匹配 `yunikorn` 命名空间。
- 8 个调度组件统一资源基线：CPU request `500m`、limit `8`，不设置内存 request/limit。
- Kueue：leader election 关闭，client QPS/burst `1000/1000`，当前启用且兼容的六类 Controller 并发均为 `100`，`DisableWaitForPodsReady=true`。
- Coscheduling：parallelism `16`，client QPS/burst `1000/1000`，permit wait `60s`；Controller 参数 `qps/burst/workers=1000/1000/100`，但 0.32.7 与 0.34.7 相同上游缺陷使前两项有效值均为默认值，workers `100` 生效。
- Volcano：Scheduler、Controller、Admission client QPS/burst 均为 `1000/1000`；Controller 的 Job/GC/PodGroup worker 均为 `100`。
- YuniKorn：Scheduler 和 Admission 均不设置 `GOMEMLIMIT`、`GOGC`；`TestInit` 在 `yunikorn-configs` 不存在或内容变化时创建或原地更新，仅在变化后重启 Scheduler；内容一致时不操作。配置设置 `kubernetes.qps/burst=1000/1000`。
- Prometheus：retention `7d`，全局 scrape `5s`，evaluation `30s`；Audit Exporter 的 ServiceMonitor 单独覆盖为 interval/timeout `100ms`，`honorLabels=false`；不设置 CPU/内存 request 或 limit；第二轮完整测试 RSS 峰值约 `19.44GiB`。
- Coscheduling Controller 依赖 `elasticquotas.scheduling.x-k8s.io` CRD，不得只安装 PodGroup CRD。

## 测试命名空间

- `bench-volcano`：`benchmark.scheduling/base=volcano`
- `bench-kueue`：`benchmark.scheduling/base=kueue`
- `bench-yunikorn`：`benchmark.scheduling/base=yunikorn`

## 操作边界

- 本仓库已切换为常驻集群模式。普通 `make` 会直接在 `volcano-benchmark-1348` 上依次运行 Kueue、Volcano、YuniKorn 实验，不再创建或删除 Kind 集群。
- `make up` 只检查常驻集群、监控和调度组件并编译测试二进制，不创建实验资源。
- 每轮 `up-<scheduler>` 不保存运行前状态，只保留目标组件运行并等待非目标 Pod 归零；`TestInit` 仅在内容变化时对 Volcano 和 YuniKorn ConfigMap 原地更新并重启对应 Scheduler；`end-<scheduler>` 等待指标抓取、清理资源并将 8 个调度组件统一设置为 `1` 副本，不再保存每调度器审计日志。
- Kueue 的 Job、PodGroup、Workload、LocalQueue 和 Pod 使用异步删除，默认等待最多 600 秒确认命名空间资源归零后再删除集群级测试资源。
- 每轮 Audit Exporter 都在停止状态下清空日志，再以 `cluster=kueue|volcano|yunikorn` 的全新进程采集；Exporter 指标稳定且 Prometheus 抓取到更新样本后，结果图片使用显式毫秒级 `FROM/TO`；结束后保持当前标签和 `1` 副本，下一轮直接切换标签。
- `perf` Dashboard 查询使用 `exported_namespace`；ServiceMonitor 必须保持 `honorLabels=false`。主 Dashboard 的 8 个面板及 8 个相对时间 Dashboard 的 4 个指标面板最小查询步长均为 `100ms`。结果图片包含相对 Dashboard 的场景说明和 `Job Submission — Created vs Scheduled` 面板，直接保存为 `results/scenario-N/job-submission.png`。
- `make down` 不依赖 `.resident-state`，而是启用全部调度组件和 Audit Exporter、清理三套测试资源并收敛到统一的 `1` 副本基线；不恢复或删除 ConfigMap，也不修改 Exporter 当前标签。
- `make down` 不删除集群，也不归档结果；`save-result` 不再隐式调用 `make down`。
- 服务器连接统一使用 `.codex/skills/volcano-benchmark-server`，完整测试使用 `.codex/skills/run-full-integrity-test`；Grafana 日常查看使用持久 Ingress，不再保留本地 SSH 转发 Skill。
- Grafana Ingress 使用 Traefik chart `40.2.0`（app `v3.7.1`），入口为 `http://104.105.137.213:31005/grafana/d/perf/?theme=light`；IngressClass 为非默认的 `benchmark-grafana`，systemd 服务已验证重启后自动恢复。
- Grafana 启用了匿名 Viewer，31005 当前可从外部访问；不需要公开时应在服务器防火墙或云安全组限制来源。
- 不得因为重跑部署脚本而删除健康集群。删除或重建必须获得用户明确授权，并先备份结果和审计日志。
- 不要输出 kubeconfig、SSH 凭据、Grafana 密码或 Kubernetes Secret。
- Prometheus 和 Grafana 使用 emptyDir，没有 PVC；Pod 重建会丢失历史指标或本地状态。
- 1000 个 KWOK Node 中只有 255 个拥有 PodCIDR；该集群仅适合不依赖真实 kubelet和 Pod 网络的调度基准。
- 最新完整验证记录位于服务器 `/root/benchmark-full-runs/full-100ms-single-panel-20260811T040535Z`，8 个结果目录为 `results/scenario-1` 至 `results/scenario-8`；同场景的新结果直接覆盖上一轮目录。完整历史见仓库根目录 `RESIDENT_CLUSTER_FULL_TEST_REPORT.md` 第 21 节。

## 验收入口

```bash
cd /root/benchmark-1348-deploy
./scripts/verify-base.sh 1000
./scripts/verify-schedulers.sh
./scripts/verify-monitoring.sh
cd /root/github/kube-scheduling-perf
./deploy/grafana-ingress/verify.sh
```

`run-scheduler-smoke-tests.sh` 会创建和删除集群资源，不是只读验收命令。

`verify-monitoring.sh` 的 PNG 检查和 Ingress `verify.sh` 的回环检查只证明链路可用；完整实验仍需从客户端验证外部 URL，并检查图片不是 `No data`、关键 Prometheus 序列有数据。

## 最新复测状态

- 完整测试主体使用源码 Commit `4fa30be14eff9b522ea1ab027d057f8b971ce281`；ServiceMonitor 标签语义修复提交为 `69142a954a17bef64133662ce041a1c291651586`。
- `2026-08-11 12:05:35` 至 `2026-08-11 12:50:26` CST 完成全部 8 个场景，24/24 组 `TestBatchJob` 与 24/24 个 Prometheus 抓取屏障通过，总耗时 `2691.248s`（`44m51.248s`）。
- Audit Exporter 的有效抓取间隔/超时均为 `100ms`；主 Dashboard 与 8 个相对 Dashboard 的指标面板也使用 `100ms` 最小查询步长。完整窗口抓取耗时平均约 `1.14ms`、P99 约 `1.72ms`、最大约 `2.13ms`。
- 本轮保存 8 个元数据结果目录；场景 3 至 8 各保存一张 `3200×1800` 相对面板 PNG。场景 1 至 2 因测试前 ServiceMonitor 的 `honorLabels` 与部署基线不一致而只保存元数据；图片失败按既定规则不影响完整测试判定。源码不再归档每调度器审计日志。
- 测试后没有 `.resident-state`、活动测试进程或三套实验资源；`1001/1001` Node Ready，8 个调度组件、Audit Exporter、Prometheus、Grafana 和 Ingress 全部通过验收。
- 详细场景时间、24 个 Case 结果和标签修复见 `RESIDENT_CLUSTER_FULL_TEST_REPORT.md` 第 21 节。
