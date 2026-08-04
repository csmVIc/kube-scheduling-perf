# 常驻集群源码改造最终方案

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

## 2. 源码改造前的集群调整

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

## 3. Makefile 改造

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

保留现有目标名称，但改为选择本轮被测调度器。

#### `up-kueue`

- 清理上次遗留的 Kueue、Coscheduling 测试资源
- 将 Volcano 和 YuniKorn 相关 Deployment 缩容到 0
- 将 Kueue Controller、Coscheduling Scheduler 和 Controller 恢复到 1

#### `up-volcano`

- 清理上次遗留的 Volcano 测试资源
- 保存当前 Volcano Scheduler ConfigMap
- 将 Kueue、Coscheduling 和 YuniKorn 相关 Deployment 缩容到 0
- 将 Volcano Scheduler、Controller 和 Admission 恢复到 1

#### `up-yunikorn`

- 清理上次遗留的 YuniKorn 测试资源
- 记录测试前是否存在 `yunikorn-configs` 以及原始内容
- 将 Volcano、Kueue 和 Coscheduling 相关 Deployment 缩容到 0
- 将 YuniKorn Scheduler 和 Admission 恢复到 1

可恢复状态保存在仓库 `./tmp/resident-state/`，供对应 `down` 目标使用。

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

等待完成后再次确认 `1001/1001` Node Ready。

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

沿用当前源码的处理时机，不在 `make up` 中统一清理日志。每个目标在对应调度器任务开始前执行两项清理：

1. 清空常驻集群中的 API Server 审计文件：

```text
/var/log/kubernetes/kube-apiserver-audit.log
```

2. 清空该调度器对应的本地结果文件：

```text
reset-auditlog-kueue      -> ./logs/kube-apiserver-audit.kueue.log
reset-auditlog-volcano    -> ./logs/kube-apiserver-audit.volcano.log
reset-auditlog-yunikorn   -> ./logs/kube-apiserver-audit.yunikorn.log
```

本地文件使用截断清空，与当前源码的 `true > file` 行为保持一致，不删除整个 `./logs` 目录，也不影响其他调度器的日志。清空后再创建本轮 Job，确保旧日志不会混入本轮结果。

### 3.8 `test-batch-job-<scheduler>`

统一使用：

```text
/root/benchmark-1348-deploy/kubeconfig
```

测试参数继续由 Makefile 传入，Job 只创建在对应测试命名空间。

### 3.9 `end-<scheduler>`

调整为：

1. 将常驻集群审计日志复制到对应文件
2. 调用 `down-<scheduler>`

日志文件固定为：

```text
./logs/kube-apiserver-audit.kueue.log
./logs/kube-apiserver-audit.volcano.log
./logs/kube-apiserver-audit.yunikorn.log
```

### 3.10 `down-<scheduler>`

#### `down-kueue`

- 删除 `bench-kueue` 中的 Job、Pod、Workload、LocalQueue 和 PodGroup
- 删除测试创建的 ClusterQueue、ResourceFlavor、WorkloadPriorityClass
- 将三套调度相关 Deployment 恢复到默认副本数 1
- 等待全部基础组件 Ready

#### `down-volcano`

- 删除 `bench-volcano` 中的 Volcano Job 和 Pod
- 删除测试创建的子 Queue、`benchmark-root` 和 PriorityClass
- 恢复测试前保存的 Volcano Scheduler ConfigMap
- 重启并等待 Volcano Scheduler Ready
- 将三套调度相关 Deployment 恢复到默认副本数 1

#### `down-yunikorn`

- 删除 `bench-yunikorn` 中的 Kubernetes Job 和 Pod
- 如果测试前不存在 `yunikorn-configs`，删除本轮创建的 ConfigMap
- 如果测试前已经存在，恢复其原始内容
- 重启并等待 YuniKorn Scheduler Ready
- 将三套调度相关 Deployment 恢复到默认副本数 1

### 3.11 顶层 `make down`

将顶层 `down` 改为人工恢复入口：

- 依次执行三套调度器资源清理
- 根据 `./tmp/resident-state/` 恢复可变配置
- 将全部调度组件恢复为 1 副本
- 等待全部基础组件 Ready
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

- 等待指标窗口完成
- 调用 `save-result-images.sh`
- 保存实验环境参数
- 将 `output` 和 `./logs` 归档到结果目录

## 4. Go 测试代码改造

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

## 5. Kueue 测试资源改造

- 将测试 API 升级为 `kueue.x-k8s.io/v1beta2`
- 将 ClusterQueue 的 `cohort` 改为 `cohortName`
- 删除 ResourceFlavor、WorkloadPriorityClass 和 ClusterQueue 中的 namespace
- ClusterQueue 的 namespaceSelector 只匹配 `bench-kueue`
- LocalQueue 和 Job 使用 `bench-kueue`
- Gang 测试的 PodGroup 使用 `bench-kueue`
- 每轮开始前和结束后清理固定名称资源，继续串行复用相同名称

## 6. Volcano 测试资源改造

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

## 7. YuniKorn 测试资源改造

- Job 使用 `bench-yunikorn`
- `yunikorn-configs` 继续写入 `yunikorn` namespace
- 每轮写入源码生成的 Queue 配置后，重启或等待 YuniKorn Scheduler 完成配置加载
- Job 保留 application ID、queue、gang scheduling annotations
- `down-yunikorn` 恢复或删除 `yunikorn-configs`

## 8. 结果采集改造

### 8.1 删除 overview 生命周期

从顶层 Makefile 删除以下结果采集步骤：

- `prepare-overview`
- `start-overview`
- `end-overview`

结果图片直接从常驻集群的 Grafana 和 Prometheus 生成。

### 8.2 保留仓库日志目录

每轮实验结束后，将常驻审计日志复制到仓库 `./logs`，然后由 `save-result` 按现有目录结构归档。

不把结果归档路径改成 `/root/benchmark-1348-deploy/logs`。

### 8.3 调整图片筛选条件

`save-result-images.sh` 保留 `127.0.0.1:8080/grafana`，但 namespace 过滤不能继续固定为 `default`。

改为覆盖：

- `bench-kueue`
- `bench-volcano`
- `bench-yunikorn`

可以使用 Dashboard 的 All namespace 选项生成统一对比图。

## 9. 主要修改文件

| 文件 | 修改内容 |
|---|---|
| `Makefile` | 常驻集群生命周期、串行流程、down 恢复、移除 overview 调用、save-result 不再 down |
| `hack/save-result-images.sh` | namespace 筛选适配三个测试命名空间 |
| `test/utils/option.go` | 删除 Node 创建参数 |
| `test/utils/utils.go` | WaitDeployment 限定 namespace |
| `test/*/batch_job_test.go` | 删除 AddNodes 调用 |
| `test/*/provider_test.go` | 删除 AddNodes，适配当前组件配置和命名空间 |
| `test/kueue/*.yaml` | v1beta2、cohortName、作用域和 namespace |
| `test/volcano/*.yaml` | benchmark-root、parent、namespace 和层级配置 |
| `test/yunikorn/*.yaml` | namespace 和当前 YuniKorn 配置 |

## 10. 验收顺序

### 10.1 集群调整验收

- `1001/1001` Node Ready
- 恰好 `1000` 个 KWOK Node
- Grafana `127.0.0.1:8080/grafana` 可用
- `perf` Dashboard 和图片渲染接口可用
- Prometheus、Audit Exporter 正常

### 10.2 单调度器冒烟

每套调度器分别执行：

```text
1 Queue
1 Job
2 Pods
```

检查任务完成、日志生成和 `down-<scheduler>` 恢复结果。

### 10.3 串行验收

- 按 Kueue、Volcano、YuniKorn 顺序完成
- 每轮只有目标调度组件运行
- 每个 `reset-auditlog-<scheduler>` 已清空集群审计文件和本调度器的旧结果文件
- 三份审计日志正确写入 `./logs`
- `save-result` 生成图片和归档目录
- 执行结束后全部调度组件恢复到 1 副本
- 无测试 Job、Queue、Workload、PodGroup 或 PriorityClass 残留
- 最终保持 `1001/1001` Node Ready

### 10.4 人工恢复验收

在任意一套测试执行中途停止后运行：

```bash
make down
```

确认配置、副本数、测试资源和集群健康状态全部恢复。
