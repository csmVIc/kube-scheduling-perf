# 常驻集群源码改造验证与完整测试报告

## 1. 结论

本次常驻集群源码改造已完成代码评审、评审问题修复、提交、推送、服务器同步和最小测试。

- 最小测试在首轮通过，Kueue、Volcano、YuniKorn 三轮和结果采集链路均正常。
- 正式完整测试失败，失败点是第 1 个场景的 Kueue `TestBatchJob`。
- 直接表现为测试运行 350 秒后仍未满足测试命名空间内 `test-instance=1` Pod 数量归零，最终触发 Go 测试超时。
- 现场的 Kueue Controller 在 512 MiB 内存限制下反复被 `OOMKilled`，进入 `CrashLoopBackOff`；这是本轮失败的主要原因。
- 按执行方案，完整测试失败后未修改源码、未重跑完整测试，后续场景也未继续执行。
- 集群已恢复到测试前固定基线，资源、配置、副本、监控和节点检查均通过。

## 2. 被测版本和集群基线

### 2.1 Git 版本

| 阶段 | Commit | 说明 |
| --- | --- | --- |
| 常驻集群初版 | `9833dcdeea5fe820fcd6d49f98bbd8e7e3c36367` | `refactor: run scheduler benchmarks on resident cluster` |
| 评审修复及最终被测版本 | `add6e843ff31ae3c232cfb16c807077cc89245f6` | `fix: harden resident cluster benchmark recovery` |

服务器仓库在测试前已重置并同步到 `add6e843ff31ae3c232cfb16c807077cc89245f6`。

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

## 5. 完整测试

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

## 9. 最终健康检查

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

## 10. 未解决风险和后续建议

- 本次 10000 Job 场景中，Kueue Controller 在 512 MiB 内存限制下发生 OOM；该限制是否构成稳定的容量瓶颈仍未确认。下一轮应先进行专项复测，再决定是否调整固定集群 Kueue 资源基线。
- 如果保持 512 MiB，需要重新评估 10000 Job 场景、350 秒超时和 TTL/终结收敛预期是否仍是有效基线。
- `serial-test` 当前使用分号串行，子阶段失败后仍可能继续执行后续阶段。本次改造按用户确认的范围未增加退出保护；完整测试出现错误时仍需人工监控。
- 服务器 `/tmp/resident-full-test.log` 不是持久存储，后续若需要保留原始完整日志，应在服务器清理或重启前另行归档。

本报告生成后，按执行方案停止：不修复完整测试问题、不重跑、不创建新提交、不再次推送。

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
