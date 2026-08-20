# 常驻集群方案细节

如非必要出现源码，则尽量以口头的方式来描述。

## 1. 目标

将 kube-scheduling-perf 的被测环境改为固定复用远端常驻集群 `volcano-benchmark-1348`，三套调度方案继续串行运行，不再为 Kueue、Volcano 和 YuniKorn 分别创建临时 Kind 集群。

最终执行模型：

```text
Kueue + Coscheduling
  -> 清理并恢复
Volcano
  -> 清理并恢复
YuniKorn
  -> 清理并恢复
保存汇总结果
```

## 2. 常驻集群基础配置

### 2.1 将 KWOK Node 缩减为 1000 个

删除 `kwok-node-1000` 至 `kwok-node-4999`，最终保留：

- `1000` 个 KWOK Node
- `1` 个控制面 Node
- 合计 `1001/1001` Node Ready

同步更新远端部署包：

```text
FORMAL_KWOK_NODES=1000
```

并将基础验收标准改为：

```text
1001/1001 Node Ready
1000 个 type=kwok Node
```

缩容完成后更新集群部署记录和 `.codex/AGENT.md`。

### 2.2 将现有结果展示能力放入常驻集群

不再创建 overview 集群。常驻集群需要提供现有结果采集所依赖的能力：

- Grafana 继续通过 `127.0.0.1:8080/grafana` 访问
- 保留现有 `perf` Dashboard UID 和 Panel ID
- 部署 Grafana Image Renderer，使现有图片渲染接口可用
- Grafana 使用常驻集群 Prometheus 作为数据源
- Audit Exporter 继续实时读取常驻集群的 API Server 审计日志

完成后，源码中的 `save-result-images.sh` 不需要切换到其他端口。

## 3. 运行使用方式

### 3.1 完整运行

运行八个场景和三个调度器：

```bash
make
```

`make` 依次调用 `scenario-1` 至 `scenario-8`。每个场景依次运行 Kueue、Volcano 和 YuniKorn，三个调度器均完成后生成相对 Dashboard、场景图片与元数据，并保存各调度器的 `window.txt` 和 `report.txt`。

### 3.2 单场景运行

运行一个场景和全部调度器：

```bash
make scenario-2
```

该命令载入场景 2 的固定参数，再调用 `serial-test` 依次运行三个调度器。测试完成后更新场景 2 的相对 Dashboard 和完整场景结果，并分别保存：

```text
results/scenario-2/kueue/
results/scenario-2/volcano/
results/scenario-2/yunikorn/
```

### 3.3 单场景、单调度器运行

例如只使用 Volcano 运行场景 2：

```bash
make scenario-2 SCHEDULERS=volcano
```

执行顺序为：

```text
scenario-2
└── serial-test
    ├── prepare-volcano
    │   ├── up-volcano
    │   │   └── activate-volcano
    │   ├── wait-volcano
    │   │   └── wait-resident-volcano
    │   └── test-init-volcano
    ├── start-volcano
    │   ├── reset-auditlog-volcano
    │   ├── 记录 Volcano 指标起点
    │   └── test-batch-job-volcano
    ├── end-volcano
    │   ├── wait-audit-metrics-scraped
    │   ├── 记录 Volcano 指标终点
    │   └── down-volcano
    │       └── deactivate-volcano
    │           ├── cleanup-volcano-resources
    │           ├── enable-all-schedulers
    │           └── wait-all-schedulers
    └── save-scheduler-result
```

`up-volcano` 停用 Kueue、Coscheduling 和 YuniKorn，将 Volcano Deployment 设置为 1 副本后统一重启并等待新 Pod Ready；测试资源限定在 `bench-volcano`。Audit Exporter 使用 `cluster=volcano` 从当前审计日志末尾重新采集。`end-volcano` 确认最终指标已进入 Prometheus 后清理本轮资源并恢复全部调度组件。

最后只更新：

```text
results/scenario-2/volcano/
├── window.txt
└── report.txt
```

不会更新三调度器相对 Dashboard，也不会覆盖 `results/scenario-2` 中已有的完整对比结果。将 `SCHEDULERS` 改为 `kueue` 或 `yunikorn` 时执行相同流程，并写入对应调度器目录。

`scenario-1` 至 `scenario-8` 分别对应八个固定场景。运行异常中断后执行 `make down` 恢复常驻集群基线。

## 4. Makefile 方案细节

### 4.1 常驻集群参数

在顶层 Makefile 中固定常驻集群操作入口：

```makefile
KIND_CLUSTER_NAME = volcano-benchmark-1348
KUBECONFIG = /root/benchmark-1348-deploy/kubeconfig
KUBECTL = /root/benchmark-1348-deploy/bin/kubectl

NODES_SIZE = 1000
CPU_PER_NODE = 16
MEMORY_PER_NODE = 64Gi
```

`NODES_SIZE` 只用于记录实验环境规模，不再用于创建 Node。

### 4.2 `make up`

将顶层 `up` 改为常驻集群初始化检查：

- 检查当前 kubeconfig 指向 `volcano-benchmark-1348`
- 检查 Kubernetes client/server 都是 `v1.34.8`
- 检查 `1001/1001` Node Ready
- 检查 `1000` 个 KWOK Node
- 检查三套调度器、Webhook、Controller 和关键 CRD 存在
- 检查常驻监控、Grafana 和 Audit Exporter 可用
- 创建本地结果、日志和临时状态目录
- 编译三套测试二进制

`up` 不再创建集群、节点、调度器或监控组件。

### 4.3 `up-<scheduler>`

每轮不再保存调度组件副本数、当前调度器或 ConfigMap。`up-<scheduler>` 将本轮目标组件设置为 `1` 副本后对其全部 Deployment 执行 `rollout restart`，将其他调度组件设置为 `0` 副本，等待新 Pod Ready、旧 Pod 和非目标 Pod 全部退出，再清理对应测试资源；不重复应用任何调度器配置。实验配置统一由后续 `test-init-<scheduler>` 原地更新。

#### `up-kueue`

- 将 Volcano 和 YuniKorn 相关 Deployment 缩容到 0
- 将 Kueue Controller、Coscheduling Scheduler 和 Controller 恢复到 1
- 重启 Kueue Controller、Coscheduling Scheduler 和 Controller
- 等待非目标 Deployment 和 Pod 全部归零、目标新 Pod Ready 且旧 Pod 完全退出
- 清理上次遗留的 Kueue、Coscheduling 测试资源并确认零残留

#### `up-volcano`

- 将 Kueue、Coscheduling 和 YuniKorn 相关 Deployment 缩容到 0
- 将 Volcano Scheduler、Controller 和 Admission 恢复到 1
- 重启 Volcano Scheduler、Controller 和 Admission
- 等待非目标 Deployment 和 Pod 全部归零、目标新 Pod Ready 且旧 Pod 完全退出
- 清理上次遗留的 Volcano 测试资源并确认零残留

#### `up-yunikorn`

- 将 Volcano、Kueue 和 Coscheduling 相关 Deployment 缩容到 0
- 将 YuniKorn Scheduler 和 Admission 设置为 1，并保留 ConfigMap
- 重启 YuniKorn Scheduler 和 Admission
- 等待非目标 Deployment 和 Pod 全部归零、目标新 Pod Ready 且旧 Pod 完全退出
- 清理上次遗留的 YuniKorn 测试资源并确认零残留

### 4.4 `wait-<scheduler>`

删除原来等待临时集群所有 Pod Ready 的逻辑，改为只等待本轮必要组件。

#### Kueue

- `kueue-controller-manager`
- `coscheduling`
- `scheduler-plugins-controller`

#### Volcano

- `volcano-scheduler`
- `volcano-controllers`
- `volcano-admission`

#### YuniKorn

- `yunikorn-scheduler`
- `yunikorn-admission-controller`

除等待目标组件外，还必须确认全部非目标 Deployment 状态副本和对应 Pod 已归零；完成后再次确认 `1001/1001` Node Ready。

### 4.5 `test-init-<scheduler>`

继续执行现有 `TestInit`，但统一使用常驻集群 kubeconfig。

`TestInit` 只负责创建或更新本轮实验配置。Volcano 和 YuniKorn ConfigMap 不存在时创建、内容变化时原地更新并重启对应 Scheduler；内容一致时跳过更新和重启：

- Kueue：ResourceFlavor、WorkloadPriorityClass、ClusterQueue、LocalQueue
- Volcano：Scheduler ConfigMap、`benchmark-root`、子 Queue、PriorityClass
- YuniKorn：`yunikorn-configs`

`TestInit` 不再创建 Node。

### 4.6 `start-<scheduler>`

保留现有执行结构：

1. `reset-auditlog-<scheduler>`
2. `test-batch-job-<scheduler>`

两者统一使用常驻集群和常驻控制面容器。

### 4.7 `reset-auditlog-<scheduler>`

沿用当前源码的处理时机，不在 `make up` 中统一清理日志。每个目标在对应调度器任务开始前：

1. 将 Exporter 缩容到 0 并等待 Pod 完全退出。
2. 不删除或截断 API Server 审计文件，也不重启 API Server。
3. 使用本轮调度器名称作为 `--cluster-label`，并通过 `--start-at-end` 从当前审计文件末尾启动全新 Exporter 进程。
4. 等待 Exporter Deployment Ready 后再创建本轮 Job。

审计文件为：

```text
/var/log/kubernetes/kube-apiserver-audit.log
```

每轮使用全新的 Exporter 进程，使 Counter、Histogram 和对象关联状态从空状态开始；`--start-at-end` 跳过测试前已有的审计事件，因此无需清空日志或重启 API Server。运行期间发生 kube-apiserver 日志轮转时，Exporter 先读完旧文件尾部，再切换到新的主日志文件。Kueue、Volcano、YuniKorn 分别生成独立 `cluster` 标签。源码不创建 `./logs/kube-apiserver-audit.<scheduler>.log`。Exporter 本轮结束后保持当前参数和 `1` 副本运行，下一轮开始时直接切换标签。

### 4.8 `test-batch-job-<scheduler>`

统一使用：

```text
/root/benchmark-1348-deploy/kubeconfig
```

测试参数继续由 Makefile 传入，Job 只创建在对应测试命名空间。

### 4.9 `end-<scheduler>`

调整为：

1. 等待 Exporter 指标稳定，并确认 Prometheus 中存在晚于稳定时刻的最终抓取样本
2. 以 epoch 毫秒记录本轮结果时间窗结束时间
3. 保持本轮 Exporter 以 `1` 副本运行
4. 调用 `down-<scheduler>`

本步骤不再复制或归档 API Server 审计日志。

### 4.10 `down-<scheduler>`

#### `down-kueue`

- 使用 `kubectl delete --wait=false` 异步提交 `bench-kueue` 中 Job、Pod、Workload、LocalQueue 和 PodGroup 的删除请求
- 默认等待最多 `600` 秒，确认上述命名空间资源全部归零
- 删除测试创建的 ClusterQueue、ResourceFlavor、WorkloadPriorityClass
- 对命名空间和集群级测试资源执行最终零残留断言
- 将全部调度相关 Deployment 设置为 `1` 副本并等待 Ready

#### `down-volcano`

- 删除 `bench-volcano` 中的 Volcano Job 和 Pod
- 删除测试创建的子 Queue、`benchmark-root` 和 PriorityClass
- 保留 `TestInit` 原地更新后的 Volcano Scheduler ConfigMap
- 将全部调度相关 Deployment 设置为 `1` 副本并等待 Ready

#### `down-yunikorn`

- 删除 `bench-yunikorn` 中的 Kubernetes Job 和 Pod
- 保留 `TestInit` 原地更新后的 `yunikorn-configs`
- 将全部调度相关 Deployment 设置为 `1` 副本并等待 Ready

### 4.11 顶层 `make down`

将顶层 `down` 改为固定副本基线收敛入口：

- 将全部调度组件和 Audit Exporter 设置为 `1` 副本
- 依次执行三套调度器资源清理
- 不恢复或删除调度器 ConfigMap，不修改 Audit Exporter 当前标签
- 等待全部组件 Ready
- 阻塞清理并确认三套测试资源全部为零
- 验证 `1001/1001` Node Ready

`down` 不再移动结果目录，也不执行任何 Kind 集群删除操作。

### 4.12 `serial-test`

保留当前从 `prepare-<scheduler>` 开始的串行结构，不增加顶层 `make up` 调用。由于不再创建临时 Kind 集群，删除 `bin/kind` 前置依赖：

```makefile
serial-test: ensure-directories
```

执行顺序调整为：

```text
prepare-kueue
start-kueue
end-kueue

prepare-volcano
start-volcano
end-volcano

prepare-yunikorn
start-yunikorn
end-yunikorn

update-relative-dashboard（仅本轮运行三个调度器时）
save-result（仅本轮运行三个调度器时，保存 Dashboard 图片和元数据）
save-scheduler-result（为本轮每个调度器保存时间窗口和统计报告）
```

本轮不增加自动退出恢复机制。异常中断后由人工执行：

```bash
make down
```

### 4.13 `save-result`

删除其中的：

```makefile
make down
```

`save-result` 只负责：

- 完整运行三个调度器时，等待 Grafana Sidecar 加载本轮相对 Dashboard，并尝试保存其中的 `Job Submission — Created vs Scheduled` 面板；截图失败只告警，不改变测试结果
- 保存 `envs.txt` 和完整串行实验的 `result-window.txt`
- 将单张图片和结果元数据写入独立 staging 目录后原子归档，不移动整个 `./tmp`

单调度器运行不调用 `save-result`，因此不会替换已有的完整场景目录。

### 4.14 `save-scheduler-result`

每个被选中的调度器完成后，根据 `result-<scheduler>-from-millis` 和 `result-<scheduler>-to-millis` 保存：

- `window.txt`：使用 CST 的 `YYYY-MM-DD HH:MM:SS 至 YYYY-MM-DD HH:MM:SS` 格式记录本轮时间窗口
- `report.txt`：保存 Pod 调度延迟 P50、P90、P99、实际调度 Pod 数、调度吞吐和吞吐时间窗

延迟分位数、调度数量和吞吐均直接来自本轮原始审计事件，不使用 Prometheus Histogram 估算。脚本按 Pod 名称配对成功的 `pods` create 与 `pods/binding` 事件，以精确时间戳计算每个 Pod 的创建到绑定延迟，排序后使用 nearest-rank 计算 P50、P90、P99；吞吐按成功 binding 数除以第一和最后 binding 的时间差计算。YuniKorn 排除 `tg-` 开头的 placeholder Pod。Audit Exporter 的 Prometheus 指标继续用于抓取屏障和 Dashboard 展示。

`start-<scheduler>` 和 `end-<scheduler>` 同时记录审计文件 inode 与字节位置。inode 相同时，报告脚本读取同一文件的起止字节区间；测试期间发生一次 kube-apiserver 审计日志轮转时，脚本按起始 inode 找到已轮转文件，拼接旧文件尾部与新文件头部后统一解析。因此正常的单次轮转不会再导致报告保存失败。

结果写入 `results/scenario-<n>/<scheduler>`。完整场景运行保存三个调度器目录；单调度器运行只原子替换本轮调度器目录，不修改同场景的其他结果。

## 5. Go 测试方案细节

### 5.1 限定测试命名空间

固定使用：

| 调度方案 | 命名空间 |
|---|---|
| Kueue + Coscheduling | `bench-kueue` |
| Volcano | `bench-volcano` |
| YuniKorn | `bench-yunikorn` |

所有 Job、LocalQueue、PodGroup 和其他 namespaced 测试资源都改到对应命名空间。

### 5.2 调整完成等待逻辑

`WaitDeployment` 增加目标 namespace 参数，只检查对应测试命名空间中带 `test-instance=1` 的 Pod，避免被其他调度器或历史资源干扰。

`RestartDeployment` 使用 Pod template annotation 触发真实 rollout，并等待 generation 和 updated/ready/available replicas 全部收敛；原副本数为 0 时直接保持停用状态。

## 6. Kueue 测试资源方案细节

- 测试资源使用 `kueue.x-k8s.io/v1beta2` API。
- ClusterQueue 使用 `cohortName`，其 `namespaceSelector` 只匹配 `bench-kueue`。
- Gang 场景继续通过 Coscheduling PodGroup 表达整组调度约束。

## 7. Volcano 测试资源方案细节

### 7.1 专用父队列

不修改内置 `root` Queue。测试统一创建 `benchmark-root` 作为 `root` 的可回收子队列，将全部测试队列共享的 CPU 和内存总上限设置在该队列，并让所有 `test-queue-*` 以 `benchmark-root` 为父队列。

### 7.2 Scheduler 配置

- 固定 Actions：`enqueue`、`allocate`、`backfill`、`reclaim`
- 固定 Plugins：第一层使用 `priority`，第二层使用 `predicates` 和 `capacity`；`capacity.enableHierarchy` 固定为 `true`
- Gang 场景在第一层增加 `gang`，并设置 `enablePreemptable: false`
- Preemption 场景在 Actions 中增加 `preempt`
- 仅在内容变化时原地更新 `volcano-scheduler-configmap` 并重启 Scheduler；内容一致时不操作

## 8. YuniKorn 测试资源方案细节

- 调度配置保存在 `yunikorn` namespace 的 `yunikorn-configs` ConfigMap 中。
- Job 保留 application ID、queue 和 gang scheduling annotations。

## 9. 结果采集方案细节

### 9.1 结果图片与元数据归档

每个场景的三套调度方案测试完成并生成相对 Dashboard 后，等待 Grafana API 返回与本轮一致的时间窗，再通过 `127.0.0.1:8080/grafana` 渲染相对 Dashboard。结果图片统一截取顶部场景说明和 `Job Submission — Created vs Scheduled` 两个面板，并保留固定的上下留白。原 `perf` Dashboard 继续在 Grafana 中展示，但不作为结果图片来源。

完整测试结果目录固定为 `results/scenario-1` 至 `results/scenario-8`，每个目录直接保存一张 `job-submission.png`、本轮的 `envs.txt` 和 `result-window.txt`，以及 `kueue`、`volcano`、`yunikorn` 三个调度器子目录。每个调度器子目录保存 `window.txt` 和 `report.txt`。完整场景制品先写入独立 staging 目录后原子替换；单调度器运行只原子替换对应调度器子目录，不覆盖完整对比结果。完整 `make` 最终生成 8 个场景目录、8 张图片和 24 组调度器报告；图片渲染失败只记录警告，不影响元数据和结果目录归档。

### 9.2 八个相对时间 Dashboard 模板

相对时间 Dashboard 模板用于将同一场景下 Kueue、Volcano 和 YuniKorn 的指标曲线放到统一时间轴上，直接比较三套调度方案的任务创建和调度速度。时间范围定义如下：

- 起始时间：将 Kueue 场景中首次出现实际工作 Pod Created 指标的时间记为 A，将 Volcano 和 YuniKorn 的对应时间分别记为 B、C。Kueue 曲线保持不变，Volcano 和 YuniKorn 曲线分别按 B、C 与 A 的差值整体平移，使三套曲线的首个实际工作 Pod Created 样本统一对齐到 A，并以 A 作为共同 T+0。
- 终止时间：取三套调度方案中第二套达到当前场景任务要求的时间，即已有任意两套方案达到目标的时刻，再向后增加 `5s`。允许最慢方案尚未完成的后续曲线被截断。

每套调度方案在 Audit Exporter 重置完成后记录指标起点，在最终指标确认被 Prometheus 抓取后记录终点。生成阶段以 `100ms` 查询步长在各自时间窗内查找首个实际工作 Pod Created 样本，并按毫秒计算时间偏移。YuniKorn 的 Created 曲线只统计 Controller Manager 创建的实际工作 Pod；Scheduled 曲线使用 Audit Exporter 关联 Controller Manager 创建事件与对应 Pod binding 事件生成的专用 Counter，因此不会计入 placeholder Pod，也不会因两类累计指标相减而下降。三套方案均按实际工作 Pod 判断是否达到场景目标。四个指标面板的最小查询步长均为 `100ms`。

Audit Exporter 的 ServiceMonitor 抓取间隔和超时均为 `100ms`，并保持 `honorLabels=false`，使实验资源命名空间稳定写入 `exported_namespace`。原 `perf` Dashboard 的 8 个面板和相对 Dashboard 的 4 个指标面板最小查询步长均为 `100ms`；`rate` 计算窗口保持 `5s`，避免瞬时速率曲线过度抖动。

仓库保存一份统一模板。默认完整 `make` 为八个场景依次传入场景编号；每个场景的三套调度方案全部成功后，根据本轮实际指标生成并更新对应 Dashboard，确认 Grafana 加载后再截图和归档。单调度器测试不会生成或覆盖这些 Dashboard。

八个场景统一更新 `scheduling-perf-relative-s1-s8` ConfigMap 中各自的 JSON。八个 Dashboard 的标签统一为 `benchmark`、`relative-time` 和各自的 `scenario-N`。Dashboard UID 固定为 `perf-relative-s1` 至 `perf-relative-s8`，继续支持 Scheduler 多选和 Grafana 原生时间缩放；原 `perf` Dashboard 不受影响。完整 `make` 全部成功时八个 Dashboard 均刷新为本轮数据，任一场景失败时不会为该失败场景生成配置。

# 附录

## 1. 完整的“提交 VC Job 到创建出 Pod”链路是：

```
提交 Volcano Job
  → kube-apiserver
  → Volcano Admission：/jobs/mutate，/jobs/validate
  → 写入 etcd
  → Volcano Job Informer 发现 Job，Volcano Job 进入 WorkQueue
  → vc controller初始化 Job Status，通过 kube-apiserver 创建 PodGroup
  → Volcano Scheduler 将 PodGroup 推进到 Inqueue
  → VC Job Controller 并发调用 kube-apiserver CREATE Pod
  → Volcano Admission：/pods/mutate，/pods/validate
  → 写入 etcd
  → Pod 创建完成，进入 Pending/等待调度状态
```

## 2. 原生 Kubernetes Job 创建 Pod 的流程是：

```
提交 batch/v1 Job
→ kube-apiserver
→ Admission（内置准入及已注册的 Webhook）
→ 写入 etcd
→ kube-controller-manager 的 Job Controller 通过 Informer 发现 Job, Job 进入 Controller WorkQueue
→ Job Controller 分批/并发调用 kube-apiserver CREATE Pod
→ Pod Admission
→ 写入 etcd
→ Pod 创建完成，进入 Pending
→ Scheduler 调度并 Binding
```

## 3. volcano调度周期

Volcano 一轮调度的核心范围是：

```
OpenSession
→ 依次执行 enqueue / allocate / backfill 等 Action
→ CloseSession
```

当前代码使用：

```
wait.Until(pc.runOnce, pc.schedulePeriod, stopCh)
```

而 `wait.Until` 是滑动周期：在 `runOnce` 完全结束后才开始计算等待时间。因此默认 `schedule-period=1s` 的含义就是：

```
本轮CloseSession结束
→ 等待1秒
→ 下一轮开始
```

## 4. Volcano Controller分别创建Kubernetes Client和Volcano Client

虽然只有一组启动参数：

```
--kube-api-qps=1000
--kube-api-burst=1000
```

但Controller用这个配置分别创建两个Client：[server.go (line 143)](/Users/csmvic/Downloads/volcano-versions/volcano/cmd/controller-manager/app/server.go:143)

```
KubeClient    = kubeclientset.NewForConfigOrDie(config)
VolcanoClient = vcclientset.NewForConfigOrDie(config)
```

每次`NewForConfig`都会基于相同的`QPS/Burst`分别创建一个令牌桶，所以实际是：

```
Kubernetes Client
QPS/Burst = 1000/1000
用于Pod、Service、ConfigMap等原生资源

Volcano Client
QPS/Burst = 1000/1000
用于Volcano Job、PodGroup、Queue等CRD
```

两个令牌桶相互独立，不是共同分享1000 QPS。理论上：

```
Kube Client请求上限     ≈ 1000 QPS
Volcano Client请求上限  ≈ 1000 QPS
```

## 5. volcano使用了reclaim、backfill

在场景 2、3 的非 Gang、资源充足且无队列争抢条件下：

- `reclaim` 基本没有实际回收工作，主要增加一次扫描。
- `backfill` 通常也只产生少量额外遍历。
