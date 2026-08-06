# 常驻集群源码改造验证与完整测试报告

## 1. 结论

常驻集群源码改造、基线纠正、最小测试和两轮独立完整测试均已执行完毕；随后针对第二轮暴露的 Kueue 高基数清理与 Grafana 空图片问题实施最小修复，并完成场景 5 定向复测。完整测试没有重跑，因此完整测试结论仍是“未通过”，但场景 5 的原失败链路已经验证修复。

- 基线纠正后的场景 1 最小测试首轮通过，Kueue、Volcano、YuniKorn 均完成调度和结果采集。
- 第一轮独立完整测试在场景 3 因未经批准加入的 Prometheus `4Gi` 内存上限触发 OOM 而失败；随后只实施了计划允许的一轮修复。
- 第二轮执行完全部 8 个场景，`TestBatchJob` 为 `23/24` 通过；唯一失败是场景 5 Volcano，其上游原因是 Kueue 清理 10000 个 PodGroup 时同步删除超时并保留 resident state。
- 在 `5072e2e` 基础上提交 `708f8fa`：Kueue 命名空间资源改为异步删除并等待最多 10 分钟归零，Grafana 渲染变量改用原生 `$__all`。
- `708f8fa` 的场景 5 定向复测中三套调度器全部通过，Kueue 的 10000 个 PodGroup 清理完成，8 张 Grafana 图片均包含实际曲线。
- 审计日志稀疏 NUL 空洞本轮按约定暂不修复；没有执行第三轮完整测试，`README.md` 保持不变。
- 测试结束后集群已恢复固定基线，`1001/1001` Node、8 个调度组件和监控组件均健康。

## 2. 被测版本和集群基线

### 2.1 Git 版本

| 阶段 | Commit | 说明 |
| --- | --- | --- |
| 常驻集群初版 | `9833dcdeea5fe820fcd6d49f98bbd8e7e3c36367` | `refactor: run scheduler benchmarks on resident cluster` |
| 初版评审修复 | `add6e843ff31ae3c232cfb16c807077cc89245f6` | `fix: harden resident cluster benchmark recovery` |
| 基线纠正后场景 1 最小测试 | `3fedf92c82fce58ca12f1e1551443a55b4e79e97` | 三套调度方案基线纠正和独立评审处理完成 |
| 第一轮独立完整测试 | `73ae14df7f29e6f4e81e34f91e286e1ff7f278cd` | 场景 3 Prometheus OOM，触发唯一一轮修复 |
| 第二轮独立完整测试 | `c3805c84e68fa233f76041ec720b7ccbbb20cbe8` | `fix: tolerate transient metrics outages` |
| 场景 5 定向修复验证 | `708f8fafb2ba9b86641d2f3a8201b168561905b0` | `fix: make Kueue cleanup asynchronous` |

服务器仓库在每轮测试前均同步到表中的对应 Commit。最后一次完整测试使用 `c3805c84e68fa233f76041ec720b7ccbbb20cbe8`；最新场景 5 定向验证使用 `708f8fafb2ba9b86641d2f3a8201b168561905b0`。

### 2.2 集群和组件

| 项目 | 版本或状态 |
| --- | --- |
| Kubernetes | `v1.34.8` |
| Node | `1001/1001 Ready`，其中 1000 个 KWOK Node |
| Volcano | `v1.15.1` |
| Kueue | `v0.19.0` |
| Scheduler Plugins / Coscheduling | `v0.34.7` |
| YuniKorn | `v1.9.0` |
| Audit Exporter | `v0.0.25` |

完整部署来源、镜像摘要和重建方式见 [CLUSTER_DEPLOYMENT_RECORD.md](./CLUSTER_DEPLOYMENT_RECORD.md)。

## 3. 代码评审和修复结果

- 初版提交后由 `gpt-5.6-sol`、`ultra` 推理强度的独立子 Agent 对照 [RESIDENT_CLUSTER_SOURCE_CHANGE_PLAN.md](./RESIDENT_CLUSTER_SOURCE_CHANGE_PLAN.md) 和原源码完成评审。
- 评审问题经判断后完成修复，并提交为 `add6e843ff31ae3c232cfb16c807077cc89245f6`。
- 修复后再次只读复审，结论为“无剩余阻断问题”。
- 评审详情见 [RESIDENT_CLUSTER_CODE_REVIEW.md](./RESIDENT_CLUSTER_CODE_REVIEW.md)。
- 按既定边界，没有新增 `serial-test` 退出保护，也没有处理源码原有的循环依赖提示。

## 4. 最小测试

### 4.1 命令

```bash
make serial-test \
  TEST_TIMEOUT_SECONDS=240 \
  NODES_SIZE=1000 \
  QUEUES_SIZE=1 \
  JOBS_SIZE_PER_QUEUE=1 \
  PODS_SIZE_PER_JOB=2
```

### 4.2 结果

| 项目 | 结果 |
| --- | --- |
| 执行轮次 | 第 1 轮通过；未使用修复和重试机会 |
| 命令时间 | `2026-08-04T18:25:12Z` 至 `2026-08-04T18:29:06Z` |
| 结果采集时间窗 | `1785867912997` 至 `1785868073219` 毫秒 |
| 结果目录 | 服务器 `/root/github/kube-scheduling-perf/results/1785868090` |
| 调度器轮次 | Kueue、Volcano、YuniKorn 均成功 |
| 审计日志 | 3 份均非空：121421、115677、113542 字节 |
| Grafana 图片 | 8 张，PNG 签名和文件大小均有效 |
| Prometheus 时间窗样本 | Kueue 25、Volcano 24、YuniKorn 24 |
| 恢复结果 | resident state、测试资源零残留；组件和 Audit Exporter 恢复到原状态 |

### 4.3 YuniKorn 原副本为 0 的补充验证

额外验证了“测试前 YuniKorn Scheduler 为 0 副本”的恢复分支：Scheduler 保持 0，Admission 保持 1，配置恢复阶段没有强制启动或重启 Scheduler，`make down-yunikorn` 成功且 resident state 清除。

验证过程中曾在 `make prepare-yunikorn` 已包含 `TestInit` 后，又人工重复执行了一次 `make test-init-yunikorn`，因此得到 `configmaps "yunikorn-configs" already exists`。这是重复操作造成的预期冲突，不是源码缺陷，也没有据此修改源码或增加测试轮次。

## 5. 初始部署基线完整测试（历史记录）

第 5 至 10 节记录的是 `add6e843...` 和错误 `512Mi` Kueue 基线下的初始阶段现场，只保留用于说明问题发现过程。其“最终”“停止”和资源建议均只适用于当轮，已由第 11 至 17 节的基线纠正、复测和最终结论取代。

### 5.1 执行信息

| 项目 | 内容 |
| --- | --- |
| 命令 | `make` |
| 开始时间 | `2026-08-04T18:33:10Z` |
| 人工停止时间 | 约 `2026-08-04T18:42:40Z` |
| 首场景指标时间窗 | `1785868390848` 至 `1785868753012` 毫秒 |
| 被测 Commit | `add6e843ff31ae3c232cfb16c807077cc89245f6` |

第 1 个场景的实际参数为：

```text
TEST_TIMEOUT_SECONDS=350
NODES_SIZE=1000
GANG=false
QUEUES_SIZE=1
JOBS_SIZE_PER_QUEUE=10000
PODS_SIZE_PER_JOB=1
```

### 5.2 逐场景结果

| 场景 | Gang | Queue | 每 Queue Job | 每 Job Pod | 超时 | 结果 |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| 1 | false | 1 | 10000 | 1 | 350s | Kueue 失败；Volcano、YuniKorn 未执行 |
| 2 | false | 1 | 500 | 20 | 200s | 未执行 |
| 3 | false | 1 | 20 | 500 | 160s | 未执行 |
| 4 | false | 1 | 1 | 10000 | 190s | 未执行 |
| 5 | true | 1 | 10000 | 1 | 430s | 未执行 |
| 6 | true | 1 | 500 | 20 | 310s | 未执行 |
| 7 | true | 1 | 20 | 500 | 310s | 未执行 |
| 8 | true | 1 | 1 | 10000 | 400s | 未执行 |

场景 1 的 `start-kueue` 返回 `Error 2` 后，`end-kueue` 仍按源码现有的分号串行逻辑进入指标保存和资源清理。首个真实失败已经确定，因此在清理过程中人工中止外层完整测试，避免继续运行 Volcano、YuniKorn 和后续场景。没有修复或重跑完整测试。

## 6. 失败分析

### 6.1 直接失败

`test-kueue` 在运行 `TestBatchJob` 5 分 50 秒后超时：

```text
panic: test timed out after 5m50s
running tests:
        TestBatchJob (5m50s)
```

阻塞栈位于：

```text
test/utils.WaitDeployment
test/kueue_test.TestBatchJob
```

`WaitDeployment` 会持续查询 `bench-kueue` 中带 `test-instance=1` 标签的 Pod，直到数量为 0。超时时该条件仍未满足。

### 6.2 主要原因

现场状态显示：

- Kueue Controller Pod：`kueue-controller-manager-6669c49474-8rck2`
- Deployment：`0/1 Ready`
- Pod：`CrashLoopBackOff`
- 重启次数：6
- 上一次退出：`OOMKilled`，退出码 137
- Kueue Controller 原资源配置：内存 request/limit 均为 `512Mi`，CPU request `500m`、limit `2`

在 10000 Job / 10000 Pod 对象压力下，Kueue Controller 超过 512 MiB 限制并反复 OOM，导致调谐和资源终结处理无法及时收敛。测试超时后仍有大量 Job、Workload 和已完成 Pod 未完成回收，因此 `WaitDeployment` 无法在 350 秒内观察到 Pod 归零。

现场采集到的代表性数据：

- 测试运行约 253 秒时仍有约 9310 个 Job。
- 人工中止清理后仍有 6274 个 Job 和 6735 个 Workload。
- 抽样的 `test-instance=1` Pod 已处于 `Succeeded`，说明失败点不是单纯的 Pod 无法调度，而是高对象量下的控制器稳定性与回收收敛问题。
- Kueue 指标抓取屏障仍成功，记录 `audit_metrics_scraped scheduler=kueue total=37451 sample_millis=1785868752652`。

### 6.3 结论边界

本轮能够确认：当前集群所部署的 Kueue `v0.19.0` Controller 在 512 MiB 内存限制下发生了 `OOMKilled`，本次未能在 350 秒内完成该仓库 10000 Job 首场景。是否能够稳定复现以及实际所需资源仍需专项复测确认。

本轮没有通过调整内存、修改测试超时、改变对象回收策略或修改源码来重新验证性能，因此不对“提高到多少内存即可稳定通过”作结论。这些内容需要下一轮单独设计和授权。

## 7. 日志和结果

### 7.1 最小测试

- 完整结果目录：服务器 `/root/github/kube-scheduling-perf/results/1785868090`
- 包含 `envs.txt`、3 份审计日志、8 张 Grafana PNG 和 `result-window.txt`

### 7.2 完整测试

- 完整测试控制台日志：服务器 `/tmp/resident-full-test.log`，269699 字节
- 首场景部分审计日志：服务器 `/root/github/kube-scheduling-perf/logs/kube-apiserver-audit.kueue.log`，193715982 字节
- 首场景指标时间窗文件仍在服务器仓库 `tmp/` 下
- 因第 1 个场景在保存正式结果前失败，没有生成完整测试结果目录，也没有生成该场景的 8 张正式 Grafana 结果图片

`/tmp/resident-full-test.log` 属于服务器临时文件；本报告已保留关键错误、参数、时间窗和现场状态。

## 8. 集群恢复

Kueue Controller 持续 OOM 时，Workload 终结处理无法推进。为完成测试后的集群恢复，执行了以下临时操作：

1. 清理本轮 Kueue Job。
2. 将 Kueue Controller 内存 request/limit 临时提高到 2 GiB，使 Controller 恢复 Ready 并完成剩余 Workload 清理。
3. 将资源配置精确恢复为原值：内存 request/limit `512Mi`，CPU request `500m`、limit `2`。
4. 等待 512 MiB 配置的新 Pod Ready。
5. 执行源码已有的 `make down`，返回码为 0。

该临时扩容只用于故障后的资源恢复，不是完整测试修复；没有再次运行完整测试，也没有把该配置写入源码或部署记录。

## 9. 初始阶段当轮健康检查

| 检查项 | 结果 |
| --- | --- |
| `.resident-state/` | 不存在 |
| Kueue、Volcano、YuniKorn 测试资源 | 零残留断言全部通过 |
| 8 个调度组件 Deployment | 全部 `spec=1`、`ready=1`、`available=1` |
| Audit Exporter | `1/1`；参数恢复为原始 audit log path，无测试 cluster 标签 |
| Kueue Controller 资源 | 已恢复为 CPU `500m/2`、内存 `512Mi/512Mi` |
| Volcano 配置 | 恢复前后规范化 SHA-256 均为 `9411473dafbda4fa1874e7702a6a11ea0baa47178b37685cb99b1bf06918e91e` |
| YuniKorn `yunikorn-configs` | 不存在，与测试前一致 |
| 基础集群验证 | 通过，Kubernetes client/server 均为 `v1.34.8` |
| Node | `1001/1001 Ready` |
| Scheduler 验证 | Volcano、Kueue、Coscheduling、YuniKorn 均通过 |
| Monitoring 验证 | Audit Exporter、Prometheus、Grafana、Image Renderer 和 Dashboard 均通过 |
| 服务器 Git | HEAD 为 `add6e843...`；仅最小测试结果目录未跟踪 |

## 10. 初始阶段当轮风险记录（后续已处理）

本节是当时的风险判断。第 11 节随后确认 `512Mi` 限制是常驻部署未经批准引入的偏差，并已恢复旧源码 CPU-only 基线；因此下面前两项不再是当前资源基线建议。

- 本次 10000 Job 场景中，Kueue Controller 在 512 MiB 内存限制下发生 OOM；该限制是否构成稳定的容量瓶颈仍未确认。下一轮应先进行专项复测，再决定是否调整固定集群 Kueue 资源基线。
- 如果保持 512 MiB，需要重新评估 10000 Job 场景、350 秒超时和 TTL/终结收敛预期是否仍是有效基线。
- `serial-test` 当前使用分号串行，子阶段失败后仍可能继续执行后续阶段。本次改造按用户确认的范围未增加退出保护；完整测试出现错误时仍需人工监控。
- 服务器 `/tmp/resident-full-test.log` 不是持久存储，后续若需要保留原始完整日志，应在服务器清理或重启前另行归档。

该初始阶段在当时按对应执行方案停止，没有在同一轮内修复或重跑；后续经新的用户授权进入第 11 节起的基线纠正与复测流程。

## 11. 三套调度方案基线审计与首次纠正

### 11.1 审计结论

审计比较了常驻集群改造前提交 `6ce46e0cd2464a5c03331f8ee756980719ca4d69`、本地与远端部署包，以及纠正前实时 Deployment。Kubernetes 和组件版本、1000 个 KWOK Node、三个测试命名空间、Webhook/Admission 隔离及 Volcano 新队列设计均属于已批准变化，继续保留。

未经批准的性能基线变化如下：

| 方案 | 改造前基线 | 纠正前常驻集群 | 判断 |
| --- | --- | --- | --- |
| 全部 8 个调度组件 | CPU request `500m`、limit `8`；无内存 request/limit | 多组不同 CPU 值，并设置 `512Mi` 至 `4Gi` 内存限制 | 全部纠正 |
| Kueue | client `1000/1000`；兼容 Controller 并发 `100`；leader election 关闭 | client `300/500`；并发 `1` 至 `10`；leader election 开启 | 纠正兼容且启用的字段 |
| Coscheduling | Scheduler client `1000/1000`；Controller 参数 `1000/1000/100`，其中 QPS/Burst 因上游缺陷保持默认有效值；Permit 默认 `60s` | Scheduler client 已一致；Controller QPS/Burst 有效值同旧版、workers 回落为 `1`；Permit `10s` | 恢复 Controller 参数与 workers、Permit；不改变旧版相同的 QPS/Burst 有效行为 |
| Volcano | 三个组件 client `1000/1000`；Controller 三类 worker `100` | Scheduler `2000/2000`，Controller `50/100` 与 `3/5/5`，Admission `50/100` 默认值 | 全部纠正 |
| YuniKorn | 测试 ConfigMap 设置 `kubernetes.qps/burst=1000/1000`；无 Go 内存环境变量 | QPS/Burst 仍由源码 TestInit 设置；由内存限制额外生成 `GOMEMLIMIT`、`GOGC` | 保留测试参数，纠正资源与 Go 环境变量 |

没有机械回退以下当前版本差异：Kueue `v1beta2` 配置 API 和 metrics 地址、未启用的 Pod Controller、Volcano 当前版本 Admission 列表、专用命名空间 selector、Volcano `benchmark-root` 队列设计所需的 Scheduler actions/plugins，以及 YuniKorn 1.9 标准 Scheduler 模式。

### 11.2 修复方案与执行结果

- 修改本地部署包并同步到 `/root/benchmark-1348-deploy`，两端 6 个变更文件 SHA-256 全部一致。
- Helm values 直接表达其支持的资源、QPS 和并发值；安装脚本对 Kueue 官方 manifest、Coscheduling Controller、Volcano Admission 和 YuniKorn chart 未暴露或强制生成的字段执行可重复覆盖。
- YuniKorn 1.9 chart 强制要求内存值并生成 Go 内存环境变量，因此保留 chart 输入所需的中间值，Helm 完成后立即把实时 Deployment 精确替换为 CPU-only 资源，并只保留 `NAMESPACE` 环境变量。
- 当前版本二进制已确认仍支持 Coscheduling Controller 的 `--qps/--burst/--workers` 和 Volcano Admission 的 `--kube-api-qps/--kube-api-burst`；Scheduler Plugins 0.34.7 源码确认 Permit 默认值仍为 `60s`。
- 后续评审确认 Scheduler Plugins v0.32.7 与 v0.34.7 存在同一个上游实现缺陷：Controller 的 QPS/Burst 参数虽存在，但修改后的 REST config 没有传给 Manager；因此两版有效行为同为默认限速。本轮保留相同参数，不构建自定义镜像改变旧有效基线。

最终实时基线：

| 组件 | 资源或关键参数 |
| --- | --- |
| 8 个调度组件 | CPU request `500m`、limit `8`；无内存 request/limit |
| Kueue | client `1000/1000`；Job、Workload、LocalQueue、Cohort、ClusterQueue、ResourceFlavor 并发均为 `100`；leader election 关闭 |
| Coscheduling | parallelism `16`；Scheduler client `1000/1000`；Controller 参数 `1000/1000/100`，其中有效 QPS/Burst 与旧版相同为上游默认值、workers 为 `100`；Permit `60s` |
| Volcano | Scheduler、Controller、Admission client 均为 `1000/1000`；Controller Job/GC/PodGroup worker 均为 `100` |
| YuniKorn | 无 `GOMEMLIMIT`、`GOGC`；队列与 Admission 隔离配置不变 |

应用后 8 个 Deployment 全部滚动完成；`verify-base.sh 1000`、`verify-schedulers.sh`、`verify-monitoring.sh` 均通过，Node 为 `1001/1001 Ready`。首次完整测试中 Kueue 的 `512Mi` OOM 是常驻部署时未经批准改变旧资源基线造成的结果，现已修复；本次修复不修改 `RESIDENT_CLUSTER_SOURCE_CHANGE_PLAN.md`。

下一步按执行规划先提交、推送本次纠正，再进行一轮独立配置评审；评审处理后的最终提交同步到服务器后，才执行场景 1 最小测试。

## 12. 独立配置评审处理与追加修订

独立评审针对提交 `cbd8642f8b641a73c54a662ffd323f7ff93c6825` 提出 3 个高、1 个中和一类低严重度问题。主 Agent 处理如下：

| 评审项 | 判断与处理 |
| --- | --- |
| Coscheduling Controller QPS/Burst | 不接受“重建镜像”建议。官方 v0.32.7 与 v0.34.7 源码存在完全相同的 REST config 丢弃逻辑，旧基线的参数同样没有实际生效；修复上游缺陷会改变而不是恢复基线。保留参数并修正文档中的有效值表述。 |
| 控制面参数遗漏 | 接受。恢复 Controller Manager `concurrent-job-syncs=100`、CPU `1/8`，默认 Scheduler QPS/Burst `1000/1000`、CPU `1/8`；保留已经批准且更高的 Controller Manager QPS/Burst `5000/10000`。 |
| YuniKorn Webhook 全局匹配 | 接受。Mutating Webhook 仅匹配 `benchmark.scheduling/base=yunikorn`，Validating Webhook 仅匹配 `kubernetes.io/metadata.name=yunikorn`，内部 regex 继续作为第二层防护。 |
| Kueue WaitForPodsReady | 接受。设置 `DisableWaitForPodsReady=true`，保持旧版省略配置时的关闭语义。 |
| Volcano/YuniKorn 记录错误 | 接受。记录区分 Volcano/YuniKorn 空闲态和 TestInit 测试态，并补记 YuniKorn `kubernetes.qps/burst=1000/1000`。 |

部署包新增可重复执行的控制面基线脚本和 YuniKorn Webhook 作用域脚本，创建集群与安装调度器流程会自动调用；验证脚本新增控制面参数、全部调度 Deployment 精确资源和 YuniKorn selector 断言。

应用与验证结果：

- Controller Manager 和默认 Scheduler 静态 Pod 均完成替换并 Ready；对应参数和 CPU `1/8` 已生效。
- Kueue 新 Pod 以 `DisableWaitForPodsReady=true` 正常启动。
- YuniKorn 两类 Webhook selector 已生效。
- `configure-control-plane-baseline.sh` 重复执行成功且没有无意义重启。
- 首次完整安装脚本复跑暴露 Kueue server-side apply 与 JSON Patch 的字段所有权冲突；增加显式字段接管后，再次从头复跑成功。
- 基础集群、调度器、监控验证全部通过，Node 为 `1001/1001 Ready`。

这些修订恢复遗漏的旧性能/隔离语义，没有改变已批准的常驻集群源码设计，因此仍不修改 `RESIDENT_CLUSTER_SOURCE_CHANGE_PLAN.md`。

## 13. 基线纠正后的场景 1 最小测试

### 13.1 执行信息

| 项目 | 内容 |
| --- | --- |
| 被测 Commit | `3fedf92c82fce58ca12f1e1551443a55b4e79e97` |
| 命令 | `make serial-test TEST_TIMEOUT_SECONDS=350 NODES_SIZE=1000 QUEUES_SIZE=1 JOBS_SIZE_PER_QUEUE=10000 PODS_SIZE_PER_JOB=1` |
| 执行轮次 | 第 1 轮通过；未使用修复和第 2 轮机会 |
| 执行时间 | `2026-08-05T09:55:46Z` 至 `2026-08-05T10:04:32Z` |
| 结果时间窗 | `1785923747415` 至 `1785924196477` 毫秒 |
| 结果目录 | 服务器 `/root/github/kube-scheduling-perf/results/1785924215` |

### 13.2 结果

| 调度器 | TestBatchJob | Prometheus 抓取屏障 | 审计日志大小 |
| --- | ---: | --- | ---: |
| Kueue | 通过，`118.25s` | `total=140057`，`sample_millis=1785923877380` | `706282667` 字节 |
| Volcano | 通过，`122.84s` | `total=130078`，`sample_millis=1785924033926` | `601949788` 字节 |
| YuniKorn | 通过，`118.04s` | `total=120062`，`sample_millis=1785924196411` | `629227162` 字节 |

结果目录包含完整控制台日志、`envs.txt`、`result-window.txt`、3 份非空 API Server 审计日志和 8 张有效 Grafana PNG。测试期间三个调度方案均未出现 OOM 或组件重启。

本轮证明上一轮 Kueue 失败来自常驻部署时未经批准加入的 `512Mi` 内存限制，而不是本次常驻集群源码改造。将三套方案恢复为旧基线的 CPU-only 资源后，同一场景和同一 350 秒超时正常通过，因此没有继续修改源码或设计方案。

场景结束后执行 `make down` 返回 0；基础集群、调度器和监控验证均通过，YuniKorn Webhook 最近 15 分钟失败数为 0。

## 14. 基线纠正后的完整测试

### 14.1 执行信息与结论

| 项目 | 内容 |
| --- | --- |
| 被测 Commit | `3fedf92c82fce58ca12f1e1551443a55b4e79e97` |
| 命令 | `make` |
| 开始时间 | `2026-08-05T10:05:57Z` |
| 最后日志时间 | `2026-08-05T10:08:28Z` |
| 结果 | 未完成；SSH 连接中断导致远端前台 `make` 终止 |
| 重试 | 按批准方案不修复、不重跑完整测试 |
| 部分结果目录 | 服务器 `/root/github/kube-scheduling-perf/results/failed-full-20260805T100557Z` |

完整测试的首场景 Kueue `TestBatchJob` 已通过，耗时 `118.35s`；Prometheus 抓取屏障为 `total=140152`、`sample_millis=1785924488923`，部分时间窗为 `1785924358145` 至 `1785924488940` 毫秒。Kueue 清理完成后，流程开始切换至 Volcano；在等待 Volcano 激活时 SSH 连接被关闭。

重新登录后确认没有残留的 `make` 或 `test-*` 进程，日志没有测试失败、超时、OOM 或退出码记录，`.resident-state` 显示流程停在 Volcano 激活阶段。Volcano 尚未执行 `TestInit` 或 `TestBatchJob`，YuniKorn 和后续七个场景均未执行，也没有生成正式完整测试结果目录。

因此，本轮完整测试的验收结论是“基础设施连接中断导致未完成”。它不是调度器用例失败，也不能作为三套方案完整性能验收通过或失败的依据。根据执行方案，完整测试无论何种失败都不修复、不重跑。

### 14.2 已保存现场

部分结果目录包含：

- `console.log`：19641 字节；
- `logs/kube-apiserver-audit.kueue.log`：706840547 字节；
- `tmp/result-from-millis` 和 `tmp/result-to-millis`：首个 Kueue 子轮次的部分时间窗。

## 15. 本轮最终恢复与健康状态

中断后执行源码已有的 `make down`，返回码为 0。最终状态如下：

| 检查项 | 结果 |
| --- | --- |
| `.resident-state/` | 不存在 |
| Kueue、Volcano、YuniKorn 实验资源 | 零残留断言通过 |
| Kubernetes | client/server 均为 `v1.34.8` |
| Node | `1001/1001 Ready` |
| 8 个调度组件 Pod | 全部 Running/Ready，重启次数均为 0 |
| 控制面性能基线 | Controller Manager Job 并发 `100`、CPU `1/8`；默认 Scheduler QPS/Burst `1000/1000`、CPU `1/8` |
| 调度器基线验证 | 通过；8 个组件均为 CPU `500m/8`、无内存限制 |
| YuniKorn Webhook | 作用域验证通过；最近 15 分钟调用失败数为 0 |
| Monitoring | Audit Exporter、Prometheus、Grafana、Image Renderer 和 Dashboard 全部通过 |

本轮不需要修改 `RESIDENT_CLUSTER_SOURCE_CHANGE_PLAN.md`：配置纠正恢复的是改造前基线，SSH 中断也没有暴露新的源码设计问题。

## 16. 常驻集群第一轮完整测试（失败）

### 16.1 执行信息

| 项目 | 内容 |
| --- | --- |
| 被测 Commit | `73ae14df7f29e6f4e81e34f91e286e1ff7f278cd` |
| 命令 | `make` |
| 独立会话 | `tmux resident-full-20260805T131822Z`，SSH 断开或网络波动不会终止测试 |
| 开始时间 | `2026-08-05T13:20:37Z` |
| 结束时间 | `2026-08-05T13:44:51Z` |
| 总耗时 | `1453.961s`（`24m13.961s`） |
| 退出码 | `2` |
| 结论 | 场景 3 失败；场景 4 至 8 未执行，不能验收为完整测试通过 |
| 失败归档 | 服务器 `/root/github/kube-scheduling-perf/results/failed-full-20260805T132037Z` |

### 16.2 场景执行结果

| 场景 | 参数 | 时间 | 耗时 | 结果目录 | 结果 |
| --- | --- | --- | ---: | --- | --- |
| 1 | 非 Gang，`10000 job × 1 pod` | `13:20:37Z` 至 `13:29:19Z` | `8m42s` | `results/1785936500` | 三套方案通过，结果保存完成 |
| 2 | 非 Gang，`500 job × 20 pod` | `13:29:19Z` 至 `13:34:24Z` | `5m05s` | `results/1785936806` | 三套方案通过，结果保存完成 |
| 3 | 非 Gang，`20 job × 500 pod` | `13:34:24Z` 至 `13:44:51Z` | `10m27s` | 未生成正式目录 | Kueue、Volcano 调度通过；Volcano 指标屏障失败后产生连锁失败，YuniKorn 超时 |
| 4–8 | 剩余非 Gang 与 Gang 场景 | 未执行 | — | — | 未执行 |

共计划执行 `24` 组调度器子测试。本轮执行了 `9` 组 `TestBatchJob`：`8` 组通过、`1` 组超时、`15` 组未执行；执行了 `9` 组 Prometheus 抓取屏障：`8` 组通过、`1` 组失败、`15` 组未执行。

已成功保存的两个结果目录都包含 3 份非空审计日志、8 张 Grafana PNG、环境信息和毫秒级结果时间窗。场景 1 的结果时间窗为 `1785936037922` 至 `1785936482744` 毫秒。

### 16.3 已完成子测试明细

| 场景 | 调度方案 | TestBatchJob | Prometheus 抓取屏障 |
| --- | --- | ---: | --- |
| 1 | Kueue | `118.45s` | 通过，`total=140131` |
| 1 | Volcano | `118.03s` | 通过，`total=130076` |
| 1 | YuniKorn | `118.03s` | 通过，`total=120058` |
| 2 | Kueue | `46.48s` | 通过，`total=64944` |
| 2 | Volcano | `44.06s` | 通过，`total=65059` |
| 2 | YuniKorn | `44.22s` | 通过，`total=70125` |
| 3 | Kueue | `50.25s` | 通过，`total=61181` |
| 3 | Volcano | `40.13s` | 失败，Prometheus 连接被重置 |
| 3 | YuniKorn | `160s`，超时 | 通过，`total=10057` |

### 16.4 根因与连锁影响

测试前 Prometheus 主容器重启次数为 `0`。场景 3 的 Volcano 子轮次结束后，Prometheus 在 `2026-08-05T13:36:06Z` 因 `OOMKilled` 退出，退出码为 `137`，主容器重启次数变为 `1`。它完成 WAL 回放并在约 `13:36:45Z` 恢复服务；期间指标屏障在 `13:36:35Z` 收到 `curl: (56) Recv failure: Connection reset by peer` 并立即退出。

Prometheus 实时资源配置包含 `requests.memory=1Gi`、`limits.memory=4Gi`。常驻集群改造前提交 `6ce46e0cd2464a5c03331f8ee756980719ca4d69` 的 Prometheus CR 没有配置 resources；集群部署方案也没有批准新增 Prometheus 内存上限。因此本轮首要根因是新集群部署时加入的 `4Gi` 内存限制不符合旧源码基线，也不足以承载当前版本在完整压测中的数据量，不是调度器性能用例本身失败。

Volcano 指标屏障异常退出，使本轮状态尚未恢复；随后 YuniKorn 的准备阶段检测到现存 Volcano 状态并失败，但原有串行命令结构继续执行了 YuniKorn 测试，最终造成调度超时和清理阶段 API 限流超时。这些是 Prometheus OOM 后的连锁结果，不作为独立调度器缺陷判断。

### 16.5 唯一一轮修复

- 从 Prometheus 部署 values 中移除整个 resources 配置，恢复旧源码“不设置 CPU/内存 request 或 limit”的行为，避免 `4Gi` cgroup 上限再次终止 Prometheus。
- 常驻模式新增的 `wait-audit-metrics-scraped` 在 Audit Exporter 或 Prometheus 请求短暂失败、响应暂时不可解析时继续使用原有等待窗口重试；成功条件、稳定样本条件和超时失败语义不变。
- 不改动既有串行测试结构，不修改 `RESIDENT_CLUSTER_SOURCE_CHANGE_PLAN.md`，也不修改已明确排除的 `/Users/csmvic/Documents/Codex/2026-08-03/k8s-1-35/`。

失败后执行 `make down` 返回 `0`；`.resident-state` 已清除，实验资源零残留，`1001/1001` Node、8 个调度组件及全部监控组件恢复健康。修复提交并推送后，只再执行一轮完整测试；无论第二轮成功或失败都不再修复或执行第三轮。

## 17. 常驻集群第二轮完整测试（最终失败）

### 17.1 执行信息与验收结论

| 项目 | 内容 |
| --- | --- |
| 被测 Commit | `c3805c84e68fa233f76041ec720b7ccbbb20cbe8` |
| 命令 | `make` |
| 开始时间 | `2026-08-05T14:00:57Z` |
| 结束时间 | `2026-08-05T14:59:26Z` |
| 总耗时 | `3508.883s`（`58m28.883s`） |
| Wrapper 退出码 | `0` |
| 子测试结果 | `23/24` 组 `TestBatchJob` 通过；场景 5 Volcano 失败 |
| 验收结论 | 完整测试失败 |
| 运行归档 | 服务器 `/root/benchmark-full-runs/20260805T140031Z-second` |
| 失败归档 | 服务器 `/root/github/kube-scheduling-perf/results/failed-full-20260805T140057Z` |

Wrapper 退出码为 `0` 只表示顶层命令执行到末尾，不代表 24 组调度器子测试全部成功。场景 5 Volcano 的 `TestBatchJob` 明确返回失败，因此不能用 Wrapper 退出码覆盖子测试结果。

### 17.2 八个场景的时间边界

| 场景 | 模式与参数 | UTC 时间边界 | 耗时 | 结果目录 | 子测试结果 |
| --- | --- | --- | ---: | --- | --- |
| 1 | 非 Gang，`10000 job × 1 pod` | `14:00:57` 至 `14:09:33` | `8m36s` | `results/1785938917` | 3 组通过 |
| 2 | 非 Gang，`500 job × 20 pod` | `14:09:33` 至 `14:14:30` | `4m57s` | `results/1785939214` | 3 组通过 |
| 3 | 非 Gang，`20 job × 500 pod` | `14:14:30` 至 `14:19:23` | `4m53s` | `results/1785939507` | 3 组通过 |
| 4 | 非 Gang，`1 job × 10000 pod` | `14:19:23` 至 `14:24:24` | `5m01s` | `results/1785939808` | 3 组通过 |
| 5 | Gang，`10000 job × 1 pod` | `14:24:24` 至 `14:36:54` | `12m30s` | `results/1785940558` | Kueue、YuniKorn 通过；Volcano 失败 |
| 6 | Gang，`500 job × 20 pod` | `14:36:54` 至 `14:44:37` | `7m43s` | `results/1785941020` | 3 组通过 |
| 7 | Gang，`20 job × 500 pod` | `14:44:37` 至 `14:51:03` | `6m26s` | `results/1785941406` | 3 组通过 |
| 8 | Gang，`1 job × 10000 pod` | `14:51:03` 至 `14:59:26` | `8m23s` | `results/1785941910` | 3 组通过 |

表中场景时间边界取自带 UTC 时间戳的完整日志；秒级边界合计与 Wrapper 记录的精确总耗时 `3508.883s` 一致。

### 17.3 每个调度器的测试和指标屏障

| 场景 | 调度方案 | `TestBatchJob` | Prometheus 抓取屏障 |
| --- | --- | ---: | --- |
| 1 | Kueue | `118.03s` | 通过，`total=140082` |
| 1 | Volcano | `118.04s` | 通过，`total=130064` |
| 1 | YuniKorn | `118.04s` | 通过，`total=120059` |
| 2 | Kueue | `45.96s` | 通过，`total=64903` |
| 2 | Volcano | `44.02s` | 通过，`total=65166` |
| 2 | YuniKorn | `44.42s` | 通过，`total=69250` |
| 3 | Kueue | `40.30s` | 通过，`total=61319` |
| 3 | Volcano | `40.13s` | 通过，`total=56500` |
| 3 | YuniKorn | `50.78s` | 通过，`total=60731` |
| 4 | Kueue | `50.02s` | 通过，`total=59902` |
| 4 | Volcano | `40.03s` | 通过，`total=50817` |
| 4 | YuniKorn | `50.03s` | 通过，`total=60087` |
| 5 | Kueue | `161.25s` | 通过，`total=140210` |
| 5 | Volcano | 失败，`0.01s` | 屏障通过，`total=4`；只证明失败请求已被抓取 |
| 5 | YuniKorn | `118.04s` | 通过，`total=163263` |
| 6 | Kueue | `59.19s` | 通过，`total=64215` |
| 6 | Volcano | `44.05s` | 通过，`total=64445` |
| 6 | YuniKorn | `94.39s` | 通过，`total=104155` |
| 7 | Kueue | `70.75s` | 通过，`total=60425` |
| 7 | Volcano | `50.13s` | 通过，`total=67413` |
| 7 | YuniKorn | `100.60s` | 通过，`total=100313` |
| 8 | Kueue | `100.04s` | 通过，`total=62823` |
| 8 | Volcano | `70.04s` | 通过，`total=65627` |
| 8 | YuniKorn | `170.04s` | 通过，`total=100212` |

本轮执行了全部 24 组 `TestBatchJob`，23 组通过、1 组失败。24 组 Prometheus 抓取屏障都返回成功，但指标屏障通过不能代替调度器子测试通过。

### 17.4 失败链路与问题分类

场景 5 中，Kueue 的 `10000 job × 1 pod` Gang 子测试本身已在 `161.25s` 内通过，指标屏障也已通过。后续 `down-kueue` 对 10000 个 PodGroup 执行同步 `kubectl delete --all --timeout=5m`；API Server 已接受删除请求，但命令在等待高基数资源全部完成删除时达到 5 分钟截止点，以 `client rate limiter Wait ... exceed context deadline` 失败。

清理异常使 Kueue 的 resident state 保留。随后 Volcano 准备阶段因 `Resident state exists` 被拒绝，Volcano 未被正确激活；后续子测试仍尝试创建 Volcano Job，被当时未运行的 Volcano Admission Webhook 以 `connect: connection refused` 拒绝，因此 `TestBatchJob` 在 `0.01s` 后失败。

该问题分类为常驻集群模式在高基数资源下的清理实现缺陷：固定 5 分钟的同步删除方式不适配 10000 个 PodGroup 的清理路径。它不是 Kueue、Volcano 或 YuniKorn 的资源基线偏离，也不是当前 Kubernetes 或调度器版本配置不适配导致的调度缺陷。

第一轮暴露的 Prometheus 问题未复现：本轮前后 Prometheus 主容器的 `restartCount` 均为 `0`，未发生 OOM，所有指标屏障均能完成。第二轮时间窗内 Prometheus 进程 RSS 峰值约为 `19.44GiB`，也直接说明旧 `4Gi` 上限不足。这证明移除该内存上限及对短暂请求失败增加重试的上一轮修复已生效，同时表明后续完整测试仍需预留充足宿主机内存。

### 17.5 结果产物检查

本轮生成了预期的 8 个结果目录：

- `results/1785938917`
- `results/1785939214`
- `results/1785939507`
- `results/1785939808`
- `results/1785940558`
- `results/1785941020`
- `results/1785941406`
- `results/1785941910`

每个目录都有 3 份调度方案审计文件、8 张 PNG、实验环境参数和毫秒级结果时间窗，但产物完整性不等于内容有效：

- 64 张 Grafana PNG 都显示 `No data`，不能作为有效的图形实验结果。使用各目录历史时间窗直接查询 Prometheus 时，除场景 5 本就无效的 Volcano 子测试外，Kueue、Volcano、YuniKorn 的 Created 和 Scheduled 原始指标均可查。
- 从场景 4 开始，审计文件中出现稀疏 NUL 区段，因此这些文件不能按干净的 JSONL 审计日志验收或直接解析。

运行目录和失败归档都保存了追加核验文件：`postflight-panel5-prometheus.tsv`、`postflight-image-sha256.tsv`、`postflight-audit-integrity.tsv`、`postflight-prometheus-memory.txt` 和修正后的 `duration.txt`，分别记录原始指标查询、图片摘要、审计文件首个非 NUL 偏移、Prometheus RSS 峰值与精确总耗时。

### 17.6 最终决定

尽管第二轮 Wrapper 退出码为 `0`、八个场景都执行到结果保存，且 Prometheus OOM 修复验证有效，场景 5 Volcano 的明确失败、64 张 `No data` 图片和场景 4 以后审计文件的 NUL 内容都不符合完整测试验收条件，因此本轮最终判定为失败。

按已确认的执行约束，第二轮完整测试失败后不再修复、不再执行第三轮完整测试。`README.md` 只在完整测试验证通过后才重构，因此本轮不修改 `README.md`。

## 18. 场景 5 清理与 Grafana 定向修复验证（通过）

### 18.1 修复内容

- 从 `5072e2e4286fede42769a21996bd1562ca141c38` 重新形成最小修复提交 `708f8fafb2ba9b86641d2f3a8201b168561905b0`。
- Kueue 的 Job、PodGroup、Workload、LocalQueue 和 Pod 删除改为 `kubectl delete --wait=false`；删除请求提交后等待命名空间资源归零，默认上限 `600` 秒，再删除 ClusterQueue、ResourceFlavor 和 WorkloadPriorityClass并执行最终零残留断言。
- Dashboard 的 8 个面板查询使用 `exported_namespace=~"$namespace"`；渲染 URL 的 resource、user、verb 和 namespace 变量改用 Grafana 原生 `$__all`，cluster 仍显式选择 Kueue、Volcano 和 YuniKorn。
- 历史时间窗验证确认 Grafana 13 能正确解析现有 `panel-1` 至 `panel-8`，因此没有修改 Panel ID。
- 按确认范围，不处理原始审计日志的稀疏 NUL 空洞。

### 18.2 执行结果

| 项目 | 内容 |
| --- | --- |
| 命令 | `make serial-test TEST_TIMEOUT_SECONDS=430 NODES_SIZE=1000 GANG=true QUEUES_SIZE=1 JOBS_SIZE_PER_QUEUE=10000 PODS_SIZE_PER_JOB=1` |
| 独立会话 | `tmux resident-scenario5-20260806T125259Z` |
| 开始时间 | `2026-08-06T12:52:59Z` |
| 结束时间 | `2026-08-06T13:02:45Z` |
| 总耗时 | `9m46s` |
| 退出码 | `0` |
| 结果时间窗 | `1786020779464` 至 `1786021289129` 毫秒 |
| 结果目录 | 服务器 `/root/github/kube-scheduling-perf/results/1786021307` |
| 运行日志 | 服务器 `/root/benchmark-validation-runs/scenario5-20260806T125259Z/run.log` |

| 调度方案 | `TestBatchJob` | Prometheus 抓取屏障 |
| --- | ---: | --- |
| Kueue | 通过，`158.79s` | 通过，`total=140207` |
| Volcano | 通过，`118.21s` | 通过，`total=130064` |
| YuniKorn | 通过，`118.04s` | 通过，`total=164589` |

Kueue 的 10000 个 PodGroup 异步删除请求成功提交，命名空间资源在 10 分钟上限内归零，随后集群级测试资源删除和最终断言均通过。Kueue resident state 正常清除，Volcano 不再被 `Resident state exists` 拒绝，Volcano Admission 也没有再次出现 connection refused。

结果目录包含 3 份审计日志和 8 张 Grafana PNG。8 张图片大小为 `644576` 至 `1201975` 字节，逐张检查均包含 Kueue、Volcano、YuniKorn 的实际曲线；Created、Scheduled、API Calls、调度延迟和 Job 完成指标均不再显示 `No data`。

测试后 `.resident-state` 不存在，三套调度器实验资源零残留；`verify-base.sh 1000`、`verify-schedulers.sh`、`verify-monitoring.sh` 和 Grafana Ingress 验收全部通过，集群保持 `1001/1001 Ready`。本次只证明场景 5 原失败链路和图片问题已修复，不等同于重新完成 8 个场景的完整测试。
