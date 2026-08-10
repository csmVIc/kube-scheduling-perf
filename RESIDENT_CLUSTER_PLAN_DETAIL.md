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

## 3. Makefile 方案细节

### 3.1 常驻集群参数

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

### 3.2 `make up`

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

### 3.3 `up-<scheduler>`

保留现有目标名称，但改为选择本轮被测调度器。【可以删除这句话了】

【修改：不用原子保留调度前的信息了，调度后，直接恢复一个副本即可；原因：当前每次保留调度器测试前的配置和副本非常没必要，因为我们的集群只会用于测试，所以调度器的配置和副本一直都是不变的，不用保存；所以测试前不保存配置和副本数，那么测试后恢复阶段应该就直接恢复为一个默认一个副本数就可以了。后面我就不标注了，你自己改动】

每轮在任何清理、配置修改或 Deployment 缩放前，原子保存全部调度组件的实际副本数，并记录当前调度器。正式状态保存在仓库 `./.resident-state/`，临时快照写入被忽略的 `./tmp/resident-state-snapshots/` 后再原子提交；两者都不会随结果目录归档，正式状态目录也加入 Git 忽略规则。

#### `up-kueue`

- 将 Volcano 和 YuniKorn 相关 Deployment 缩容到 0
- 将 Kueue Controller、Coscheduling Scheduler 和 Controller 恢复到 1
- 等待非目标 Deployment 和 Pod 全部归零、目标组件 Ready
- 清理上次遗留的 Kueue、Coscheduling 测试资源并确认零残留

#### `up-volcano`

- 原子保存当前 Volcano Scheduler ConfigMap
- 将 Kueue、Coscheduling 和 YuniKorn 相关 Deployment 缩容到 0
- 将 Volcano Scheduler、Controller 和 Admission 恢复到 1
- 等待非目标 Deployment 和 Pod 全部归零、目标组件 Ready
- 清理上次遗留的 Volcano 测试资源并确认零残留

#### `up-yunikorn`

- 原子记录测试前是否存在 `yunikorn-configs` 以及原始内容
- 将 Volcano、Kueue 和 Coscheduling 相关 Deployment 缩容到 0
- 暂停 YuniKorn 后清理遗留资源和旧测试 ConfigMap
- 将 YuniKorn Scheduler 和 Admission 恢复到 1
- 等待非目标 Deployment 和 Pod 全部归零、目标组件 Ready

### 3.4 `wait-<scheduler>`

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

### 3.5 `test-init-<scheduler>`

继续执行现有 `TestInit`，但统一使用常驻集群 kubeconfig。

`TestInit` 只负责创建或更新本轮实验配置：

- Kueue：ResourceFlavor、WorkloadPriorityClass、ClusterQueue、LocalQueue
- Volcano：Scheduler ConfigMap、`benchmark-root`、子 Queue、PriorityClass
- YuniKorn：`yunikorn-configs`

`TestInit` 不再创建 Node。

### 3.6 `start-<scheduler>`

保留现有执行结构：

1. `reset-auditlog-<scheduler>`
2. `test-batch-job-<scheduler>`

两者统一使用常驻集群和常驻控制面容器。

### 3.7 `reset-auditlog-<scheduler>`

沿用当前源码的处理时机，不在 `make up` 中统一清理日志。每个目标在对应调度器任务开始前：

1. 保存 Audit Exporter 原参数和副本数。
2. 将 Exporter 缩容到 0 并等待 Pod 完全退出。
3. 清空常驻集群中的 API Server 审计文件。
4. 使用本轮调度器名称作为 `--cluster-label`，以全新进程启动 Exporter。
5. 清空本调度器对应的本地结果文件。

审计文件为：

```text
/var/log/kubernetes/kube-apiserver-audit.log
```

本地结果文件为：

```text
reset-auditlog-kueue      -> ./logs/kube-apiserver-audit.kueue.log
reset-auditlog-volcano    -> ./logs/kube-apiserver-audit.volcano.log
reset-auditlog-yunikorn   -> ./logs/kube-apiserver-audit.yunikorn.log
```

Exporter 停止后才截断日志，避免旧 offset、进程内 Counter/Histogram 和对象时间状态污染本轮。Kueue、Volcano、YuniKorn 分别生成独立 `cluster` 标签。本地文件仍使用截断清空，不删除整个 `./logs` 目录。清空后再创建本轮 Job。

### 3.8 `test-batch-job-<scheduler>`

统一使用：

```text
/root/benchmark-1348-deploy/kubeconfig
```

测试参数继续由 Makefile 传入，Job 只创建在对应测试命名空间。

### 3.9 `end-<scheduler>`

调整为：

1. 等待 Exporter 指标稳定，并确认 Prometheus 中存在晚于稳定时刻的最终抓取样本
2. 以 epoch 毫秒记录本轮结果时间窗结束时间
3. 将常驻集群审计日志复制到对应文件
4. 停止本轮 Exporter并恢复其测试前参数和副本数
5. 调用 `down-<scheduler>`

日志文件固定为：

```text
./logs/kube-apiserver-audit.kueue.log
./logs/kube-apiserver-audit.volcano.log
./logs/kube-apiserver-audit.yunikorn.log
```

### 3.10 `down-<scheduler>`

#### `down-kueue`

- 使用 `kubectl delete --wait=false` 异步提交 `bench-kueue` 中 Job、Pod、Workload、LocalQueue 和 PodGroup 的删除请求
- 默认等待最多 `600` 秒，确认上述命名空间资源全部归零
- 删除测试创建的 ClusterQueue、ResourceFlavor、WorkloadPriorityClass
- 对命名空间和集群级测试资源执行最终零残留断言
- 将全部调度相关 Deployment 恢复到测试前记录的实际副本数
- 按原副本数等待运行组件 Ready 或停用组件归零

#### `down-volcano`

- 删除 `bench-volcano` 中的 Volcano Job 和 Pod
- 删除测试创建的子 Queue、`benchmark-root` 和 PriorityClass
- 使用当前 `resourceVersion` 精确替换为测试前保存的 Volcano Scheduler ConfigMap
- 将全部调度相关 Deployment 恢复到测试前记录的实际副本数
- Volcano Scheduler 原副本数为 0 时先等待 Pod 归零再恢复配置；原副本数大于 0 时才重启并等待 Ready

#### `down-yunikorn`

- 删除 `bench-yunikorn` 中的 Kubernetes Job 和 Pod
- 如果测试前不存在 `yunikorn-configs`，删除本轮创建的 ConfigMap
- 如果测试前已经存在，使用当前 `resourceVersion` 精确替换为原始内容
- 将全部调度相关 Deployment 恢复到测试前记录的实际副本数
- 清理 YuniKorn Job 和 Pod 不主动扩容 Scheduler 或 Admission
- YuniKorn Scheduler 原副本数为 0 时先等待 Pod 归零再恢复配置；原副本数大于 0 时才重启并等待 Ready

### 3.11 顶层 `make down`

将顶层 `down` 改为人工恢复入口：

- 依次执行三套调度器资源清理
- 根据 `./.resident-state/` 恢复可变配置、Audit Exporter 和调度组件副本数
- 有快照时恢复测试前实际副本值；没有快照时不擅自启动测试前已停用的组件
- 按保存的副本状态等待恢复完成
- 阻塞清理并确认三套测试资源全部为零
- 验证 `1001/1001` Node Ready

`down` 不再移动结果目录，也不执行任何 Kind 集群删除操作。

### 3.12 `serial-test`

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

save-result
```

删除 `prepare-overview`、`start-overview` 和 `end-overview` 调用。

本轮不增加自动退出恢复机制。异常中断后由人工执行：

```bash
make down
```

### 3.13 `save-result`

删除其中的：

```makefile
make down
```

`save-result` 只负责：

- 使用串行实验开始前记录的毫秒级 `FROM` 和最后一次 Prometheus 抓取后的毫秒级 `TO` 调用 `save-result-images.sh`
- 保存实验环境参数
- 只将 `output`、`./logs` 和结果元数据归档到独立 staging 目录，不移动整个 `./tmp`

## 4. Go 测试方案细节

### 4.1 删除 Node 创建路径

从三套测试中删除：

- `TestInit` 对 `provider.AddNodes` 的调用
- KueueProvider、VolcanoProvider、YunikornProvider 的 `AddNodes` 方法
- Go Options 中只服务于 Node 创建的 NodeSize、CpuPerNode 和 MemoryPerNode 字段及 flag

### 4.2 限定测试命名空间

固定使用：

| 调度方案 | 命名空间 |
|---|---|
| Kueue + Coscheduling | `bench-kueue` |
| Volcano | `bench-volcano` |
| YuniKorn | `bench-yunikorn` |

所有 Job、LocalQueue、PodGroup 和其他 namespaced 测试资源都改到对应命名空间。

### 4.3 调整完成等待逻辑

`WaitDeployment` 增加目标 namespace 参数，只检查对应测试命名空间中带 `test-instance=1` 的 Pod，避免被其他调度器或历史资源干扰。

`RestartDeployment` 使用 Pod template annotation 触发真实 rollout，并等待 generation 和 updated/ready/available replicas 全部收敛；原副本数为 0 时直接保持停用状态。

## 5. Kueue 测试资源方案细节

- 将测试 API 升级为 `kueue.x-k8s.io/v1beta2`
- 将 ClusterQueue 的 `cohort` 改为 `cohortName`
- 删除 ResourceFlavor、WorkloadPriorityClass 和 ClusterQueue 中的 namespace
- ClusterQueue 的 namespaceSelector 只匹配 `bench-kueue`
- LocalQueue 和 Job 使用 `bench-kueue`
- Gang 测试的 PodGroup 使用 `bench-kueue`
- 每轮开始前和结束后清理固定名称资源，继续串行复用相同名称

## 6. Volcano 测试资源方案细节

### 6.1 专用父队列

删除对内置 `root` Queue 的 capability、deserved 和 guarantee 修改。

新增固定父队列：

```yaml
apiVersion: scheduling.volcano.sh/v1beta1
kind: Queue
metadata:
  name: benchmark-root
spec:
  parent: root
  reclaimable: true
  capability:
    cpu: <全部测试队列 CPU 总上限>
    memory: <全部测试队列内存总上限>
```

所有 `test-queue-*` 增加：

```yaml
spec:
  parent: benchmark-root
```

这样继续保留“所有测试队列共享统一总容量上限”的设计，同时不修改 Volcano 内置 `root` Queue。

### 6.2 Scheduler 配置

- Capacity Plugin 的 `enableHierarchy` 固定开启
- Gang 和 Preemption 仍根据本轮实验参数生成
- 更新 `volcano-scheduler-configmap` 后重启 Scheduler
- `down-volcano` 恢复测试前保存的 ConfigMap

### 6.3 资源作用域

- Volcano Job 使用 `bench-volcano`
- Queue 是集群级资源，删除无效  namespace
- 每轮清理 `benchmark-root`、全部 `test-queue-*` 和测试 PriorityClass

## 7. YuniKorn 测试资源方案细节

- Job 使用 `bench-yunikorn`
- `yunikorn-configs` 继续写入 `yunikorn` namespace
- 每轮写入源码生成的 Queue 配置后，通过真实 rollout 等待 YuniKorn Scheduler 完成配置加载
- Job 保留 application ID、queue、gang scheduling annotations
- `down-yunikorn` 恢复或删除 `yunikorn-configs`；测试前 Scheduler 为 0 副本时不因配置恢复启动或重启它

## 8. 结果采集方案细节

### 8.1 删除 overview 生命周期

从顶层 Makefile 删除以下结果采集步骤：

- `prepare-overview`
- `start-overview`
- `end-overview`

结果图片直接从常驻集群的 Grafana 和 Prometheus 生成。

### 8.2 保留仓库日志目录

每轮实验结束后，将常驻审计日志复制到仓库 `./logs`，然后由 `save-result` 按现有目录结构归档。

不把结果归档路径改成 `/root/benchmark-1348-deploy/logs`。

已观察到截断正在写入的主审计文件可能产生稀疏 NUL 空洞；当前结果分析不使用原始审计文件，本轮暂不修改该链路。

### 8.3 调整图片筛选条件

`save-result-images.sh` 保留 `127.0.0.1:8080/grafana`。Dashboard 全部 8 个面板的查询将实验命名空间标签统一为 `exported_namespace=~"$namespace"`；渲染 URL 的 resource、user、verb 和 namespace 变量使用 Grafana 原生 `$__all`，cluster 仍显式选择 `kueue`、`volcano` 和 `yunikorn`。

图片使用完整串行实验的绝对 `FROM/TO` 时间窗，不再使用“等待后查询最近 N 秒”。Grafana 13 已验证能用现有 `panel-1` 至 `panel-8` 映射全部 8 个面板，不修改 Panel ID。

### 8.4 固化八个相对时间 Dashboard

仓库保存一份统一的相对时间 Dashboard 模板。默认完整 `make` 为八个场景依次传入内部场景编号；每个场景的三套调度方案全部成功、结果完成归档后，才根据该场景的实际指标生成并更新对应 Dashboard。直接执行 `serial-test`、单调度器测试、单场景冒烟或结果保存时不会设置该内部编号，因此不会生成或覆盖这些 Dashboard。

每套调度方案在 Audit Exporter 重置完成后记录本轮指标起点，在最终指标确认被 Prometheus 抓取后记录终点。生成阶段在各自时间窗内查找第一个 Pod 创建样本，以 Kueue 为共同 T+0，计算 Volcano 和 YuniKorn 的相对偏移，并据三者对齐后的最晚结束时间设置默认展示范围。

八个场景统一更新 `scheduling-perf-relative-s1-s7` ConfigMap 中各自的 JSON；该 ConfigMap 名称仅为历史遗留名称，不再表示只包含场景 1 至 7。场景 8 首次按新方案刷新后删除旧的 `scheduling-perf-relative-s8` ConfigMap，避免 Grafana 加载重复 Dashboard。八个 Dashboard 的标签统一为 `benchmark`、`relative-time` 和各自的 `scenario-N`。Dashboard UID 固定为 `perf-relative-s1` 至 `perf-relative-s8`，继续支持 Scheduler 多选和 Grafana 原生时间缩放；原 `perf` Dashboard 不受影响。完整 `make` 全部成功时八个 Dashboard 均刷新为本轮数据，任一场景失败时不会为该失败场景生成配置。
