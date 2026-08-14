# 常驻集群源码改造验证与完整测试报告

## 1. 结论

常驻集群源码改造、基线纠正、最小测试及多轮独立完整测试均已执行完毕。第二轮暴露的 Kueue 高基数清理与 Grafana 空图片问题经过最小修复、场景 5 定向复测和后续完整复测后均未复现；最新的固定空闲基线与 `500ms` 采集完整测试中，8 个场景、24 组 Case 和 24 个 Prometheus 抓取屏障全部通过。

- 基线纠正后的场景 1 最小测试首轮通过，Kueue、Volcano、YuniKorn 均完成调度和结果采集。
- 第一轮独立完整测试在场景 3 因未经批准加入的 Prometheus `4Gi` 内存上限触发 OOM 而失败；随后只实施了计划允许的一轮修复。
- 第二轮执行完全部 8 个场景，`TestBatchJob` 为 `23/24` 通过；唯一失败是场景 5 Volcano，其上游原因是 Kueue 清理 10000 个 PodGroup 时同步删除超时并保留 resident state。
- 在 `5072e2e` 基础上提交 `708f8fa`：Kueue 命名空间资源改为异步删除并等待最多 10 分钟归零，Grafana 渲染变量改用原生 `$__all`。
- `708f8fa` 的场景 5 定向复测中三套调度器全部通过，Kueue 的 10000 个 PodGroup 清理完成，8 张 Grafana 图片均包含实际曲线。
- 第三轮使用 `b2fd509` 在独立 `tmux` 中运行完整 `make`，24/24 组 Case 通过，8/8 个结果目录完成，64 张 Grafana 图片均包含实际曲线，总耗时 `54m59s`。
- 固定空闲基线与 `500ms` 采集改造后，首轮暴露并定向修复了新增时间窗的 Make 转义错误；修复轮使用 `d774bda` 再次完成全部 24 组 Case，总耗时 `51m55.34s`。
- 审计日志稀疏 NUL 空洞按约定只检查和记录、不作为失败条件且暂不修复；完整测试通过后 `README.md` 已按常驻集群流程重构。
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
| 第三轮独立完整测试 | `b2fd509cabfd837e34fe9439d5855c32c531c710` | 24/24 组 Case 通过，常驻集群方案最终验收通过 |
| 固定空闲基线与 500ms 完整测试 | `d774bda446a55279ad3d95a2e9523fe1c9b2316b` | 24/24 组 Case 与 24/24 个指标屏障通过 |

服务器仓库在每轮测试前均同步到表中的对应 Commit。最新一次完整测试使用 `d774bda446a55279ad3d95a2e9523fe1c9b2316b`，详细结果见第 20 节。

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

- 初版提交后由 `gpt-5.6-sol`、`ultra` 推理强度的独立子 Agent 对照 [RESIDENT_CLUSTER_PLAN_DETAIL.md](./RESIDENT_CLUSTER_PLAN_DETAIL.md) 和原源码完成评审。
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

应用后 8 个 Deployment 全部滚动完成；`verify-base.sh 1000`、`verify-schedulers.sh`、`verify-monitoring.sh` 均通过，Node 为 `1001/1001 Ready`。首次完整测试中 Kueue 的 `512Mi` OOM 是常驻部署时未经批准改变旧资源基线造成的结果，现已修复；本次修复不修改 `RESIDENT_CLUSTER_PLAN_DETAIL.md`。

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

这些修订恢复遗漏的旧性能/隔离语义，没有改变已批准的常驻集群源码设计，因此仍不修改 `RESIDENT_CLUSTER_PLAN_DETAIL.md`。

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

本轮不需要修改 `RESIDENT_CLUSTER_PLAN_DETAIL.md`：配置纠正恢复的是改造前基线，SSH 中断也没有暴露新的源码设计问题。

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
- 不改动既有串行测试结构，不修改 `RESIDENT_CLUSTER_PLAN_DETAIL.md`，也不修改已明确排除的 `/Users/csmvic/Documents/Codex/2026-08-03/k8s-1-35/`。

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

## 19. 异步清理修复后的完整测试（通过）

### 19.1 执行概要

| 项目 | 内容 |
| --- | --- |
| 被测 Commit | `b2fd509cabfd837e34fe9439d5855c32c531c710` |
| 命令 | `make` |
| 独立会话 | `tmux resident-full-t0-20260806T133924Z` |
| CST（UTC+8）时间 | `2026-08-06 21:39:34` 至 `2026-08-06 22:34:33` |
| 总耗时 | `3299s`（`54m59s`） |
| Wrapper 退出码 | `0` |
| 子测试结果 | `24/24` 组 `TestBatchJob` 全部通过 |
| 结果保存 | `8/8` 个场景目录完成 |
| 验收结论 | 完整测试通过 |
| 运行归档 | 服务器 `/root/benchmark-full-runs/full-t0-20260806T133924Z` |
| 完整日志 | 服务器 `/root/benchmark-full-runs/full-t0-20260806T133924Z/run.log` |

测试在服务器独立 `tmux` 会话中运行。本地 SSH 控制连接在场景 7 与场景 8 之间失效过一次，重新连接后确认服务器测试持续运行，未中止、未重启，也没有改变实验时间边界。本轮 T0 直接通过，因此没有进入任何修复轮次，也没有在完整测试期间修改源码。

### 19.2 各调度方案的实际配置

本轮三个对比方案并非都由同一种组件直接完成 Pod 调度。CPU、内存、Kubernetes 客户端限速和并发等公共性能参数统一列在下表；同一单元格中的 request/limit 均按该顺序记录。

| 对比方案 | 组件与作用 | CPU request/limit | 内存 request/limit | Kubernetes client QPS/Burst | 并发或 Worker |
| --- | --- | --- | --- | --- | --- |
| Kueue 非 Gang | 默认 `kube-scheduler`，实际调度 Pod | `1 / 8` | 未设置 | `1000/1000` | 未额外修改 |
| Kueue 准入 | `kueue-controller-manager`，负责准入和队列控制 | `500m / 8` | 未设置 | `1000/1000` | Job、Workload、LocalQueue、Cohort、ClusterQueue、ResourceFlavor 均为 `100` |
| Kueue Gang | `coscheduling`，实际调度 Pod | `500m / 8` | 未设置 | `1000/1000` | Scheduler `parallelism=16` |
| Kueue Gang 辅助 | `scheduler-plugins-controller`，管理 PodGroup/ElasticQuota | `500m / 8` | 未设置 | 参数为 `1000/1000`；因上游缺陷，有效值仍为 controller-runtime 默认值 | `workers=100` |
| Volcano | `volcano-scheduler`，实际调度 Pod | `500m / 8` | 未设置 | `1000/1000` | 未额外修改 |
| Volcano | `volcano-controllers`，管理 Job、PodGroup 和 Queue | `500m / 8` | 未设置 | `1000/1000` | Job、GC、PodGroup worker 均为 `100` |
| Volcano | `volcano-admission`，负责准入 | `500m / 8` | 未设置 | `1000/1000` | 未额外修改 |
| YuniKorn | `yunikorn-scheduler`，实际调度 Pod | `500m / 8` | 未设置 | 测试 ConfigMap 设置 `1000/1000` | 未额外修改 |
| YuniKorn | `yunikorn-admission-controller`，负责注入和校验 | `500m / 8` | 未设置 | 未单独覆盖，使用上游默认值 | 未额外修改 |

除默认 `kube-scheduler` 外，Kueue、Coscheduling、Volcano 和 YuniKorn 的 8 个 Deployment 均采用 `500m/8 CPU` 且不设置内存 request/limit。YuniKorn Scheduler 与 Admission 也不设置 `GOMEMLIMIT` 或 `GOGC`。

#### Kueue 与 Coscheduling

- Kueue 版本为 `v0.19.0`。Kueue 自身负责工作负载准入，不直接替代 Pod Scheduler。
- 每个测试队列由命名空间 `bench-kueue` 中的 LocalQueue 关联一个 ClusterQueue；ClusterQueue 只选择该测试命名空间，加入 Cohort `team`，使用 ResourceFlavor `default`，CPU/内存名义配额取本轮队列容量。
- 本轮 `PREEMPTION=false`，因此 ClusterQueue 不配置 Kueue preemption 策略。
- 非 Gang 场景没有设置 `schedulerName`；Kueue 准入并解除 Job 的 suspend 后，Pod 由 Kubernetes `v1.34.8` 默认 `kube-scheduler` 调度。
- Gang 场景额外创建 PodGroup，`minMember` 等于该 Job 的 Pod 数、`scheduleTimeoutSeconds=300`；Pod 设置 `schedulerName: coscheduling` 并关联 PodGroup。
- Coscheduling 来自 Scheduler Plugins `v0.34.7`，启用 `Coscheduling` MultiPoint 插件，并将 QueueSort 独占配置为 `Coscheduling`；Permit 等待上限为 `60s`。
- Kueue Controller 关闭 leader election，并设置 `DisableWaitForPodsReady=true`。

#### Volcano

- Volcano 版本为 `v1.15.1`，所有测试 Pod 都使用 `schedulerName: volcano`。
- `TestInit` 在每个 Volcano Case 前临时替换 Scheduler ConfigMap。本轮 `PREEMPTION=false`，实际 actions 为 `enqueue, allocate, backfill, reclaim`，没有启用 `preempt` action。
- 非 Gang 场景的第一层插件为 `priority`；Gang 场景为 `priority` 和 `gang`，其中 `gang.enablePreemptable=false`。
- 两种模式的第二层插件均为 `predicates` 和 `capacity`，并设置 `capacity.enableHierarchy=true`。因此本轮实验没有使用空闲基线中的 `drf`、`proportion`、`nodeorder` 或 `binpack` 插件链。
- 测试创建专用父队列 `benchmark-root`（父级为内置 `root`），将总 CPU/内存容量写入该父队列；所有 `test-queue-*` 都以它为 parent。队列允许 reclaim，PriorityClass 的 `preemptionPolicy` 为 `Never`。

#### YuniKorn

- YuniKorn 版本为 `v1.9.0`，所有测试 Pod 都使用 `schedulerName: yunikorn`。
- `TestInit` 临时创建 `yunikorn-configs`，并创建 `root.sandbox` 下的专用测试叶子队列；本轮普通队列为 `root.sandbox.long-term-research-0`。
- 叶子队列的 guaranteed/max CPU 和内存来自本轮队列容量；不同优先级队列使用 `priority.offset`：普通 `0`、business-impacting `1000`、human-critical `1000000`。本轮只创建 1 个普通队列，且 `PREEMPTION=false`，未配置 YuniKorn preemption policy。
- Gang 场景通过 Job PodTemplate 注解声明 TaskGroup，`minMember` 等于 Job Pod 数，`gangSchedulingStyle=Hard`，`placeholderTimeoutInSeconds=600`；非 Gang 场景不写入这些 TaskGroup/Gang 注解。

#### 三套方案共同的工作负载约束

- 每个场景均使用 1000 个 KWOK Worker Node；测试 Pod 固定选择 `type=kwok`，并容忍 `kwok.x-k8s.io/node=fake:NoSchedule`。
- 每个 Pod 默认请求并限制 `1 CPU / 1Gi`，每个场景总计 10000 个 Pod；默认队列总容量为 `10000 CPU / 10000Gi`。
- 本轮 `PREEMPTION=false`，场景 1 至 4 为非 Gang，场景 5 至 8 为 Gang；除了 Gang 相关差异，三套方案使用相同的 Job/Pod 规模和节点约束。

### 19.3 八个场景的时间边界与结果目录

以下 `CST` 均指中国标准时间（UTC+8）。

| 场景 | 模式与参数 | CST（UTC+8）时间边界 | 耗时 | 指标时间窗（毫秒） | 结果目录 |
| ---: | --- | --- | ---: | --- | --- |
| 1 | 非 Gang，`10000 job × 1 pod` | `2026-08-06 21:39:34` 至 `2026-08-06 21:48:13` | `8m39s` | `1786023574969` 至 `1786024017486` | `results/1786024035` |
| 2 | 非 Gang，`500 job × 20 pod` | `2026-08-06 21:48:13` 至 `2026-08-06 21:53:14` | `5m01s` | `1786024093526` 至 `1786024318944` | `results/1786024336` |
| 3 | 非 Gang，`20 job × 500 pod` | `2026-08-06 21:53:14` 至 `2026-08-06 21:58:15` | `5m01s` | `1786024395118` 至 `1786024619685` | `results/1786024637` |
| 4 | 非 Gang，`1 job × 10000 pod` | `2026-08-06 21:58:15` 至 `2026-08-06 22:03:23` | `5m08s` | `1786024695535` 至 `1786024927127` | `results/1786024945` |
| 5 | Gang，`10000 job × 1 pod` | `2026-08-06 22:03:23` 至 `2026-08-06 22:13:13` | `9m50s` | `1786025003815` 至 `1786025516190` | `results/1786025534` |
| 6 | Gang，`500 job × 20 pod` | `2026-08-06 22:13:13` 至 `2026-08-06 22:19:25` | `6m12s` | `1786025593294` 至 `1786025889158` | `results/1786025907` |
| 7 | Gang，`20 job × 500 pod` | `2026-08-06 22:19:25` 至 `2026-08-06 22:25:59` | `6m34s` | `1786025965417` 至 `1786026282026` | `results/1786026301` |
| 8 | Gang，`1 job × 10000 pod` | `2026-08-06 22:25:59` 至 `2026-08-06 22:34:33` | `8m34s` | `1786026360099` 至 `1786026796787` | `results/1786026814` |

场景边界包含调度组件切换、三套调度器测试、恢复及结果图片保存；八行耗时合计为 `54m59s`，与 Wrapper 总时间一致。

### 19.4 二十四个调度器 Case 的时间与指标屏障

| 场景 | 调度方案 | CST（UTC+8）起止时间 | `TestBatchJob` | Prometheus 抓取屏障 |
| ---: | --- | --- | ---: | --- |
| 1 | Kueue | `2026-08-06 21:39:42` 至 `2026-08-06 21:41:41` | 通过，`119.00s` | 通过，`total=140171` |
| 1 | Volcano | `2026-08-06 21:42:14` 至 `2026-08-06 21:44:12` | 通过，`118.10s` | 通过，`total=130095` |
| 1 | YuniKorn | `2026-08-06 21:44:55` 至 `2026-08-06 21:46:53` | 通过，`118.04s` | 通过，`total=120167` |
| 2 | Kueue | `2026-08-06 21:48:20` 至 `2026-08-06 21:49:07` | 通过，`47.09s` | 通过，`total=64967` |
| 2 | Volcano | `2026-08-06 21:49:40` 至 `2026-08-06 21:50:23` | 通过，`43.63s` | 通过，`total=65190` |
| 2 | YuniKorn | `2026-08-06 21:51:08` 至 `2026-08-06 21:51:53` | 通过，`44.55s` | 通过，`total=68917` |
| 3 | Kueue | `2026-08-06 21:53:24` 至 `2026-08-06 21:54:04` | 通过，`40.30s` | 通过，`total=61060` |
| 3 | Volcano | `2026-08-06 21:54:37` 至 `2026-08-06 21:55:17` | 通过，`40.12s` | 通过，`total=55819` |
| 3 | YuniKorn | `2026-08-06 21:56:04` 至 `2026-08-06 21:56:55` | 通过，`51.36s` | 通过，`total=60815` |
| 4 | Kueue | `2026-08-06 21:58:23` 至 `2026-08-06 21:59:13` | 通过，`50.03s` | 通过，`total=60080` |
| 4 | Volcano | `2026-08-06 21:59:47` 至 `2026-08-06 22:00:27` | 通过，`40.03s` | 通过，`total=51534` |
| 4 | YuniKorn | `2026-08-06 22:01:12` 至 `2026-08-06 22:02:02` | 通过，`50.04s` | 通过，`total=60082` |
| 5 | Kueue | `2026-08-06 22:03:32` 至 `2026-08-06 22:06:13` | 通过，`160.76s` | 通过，`total=140225` |
| 5 | Volcano | `2026-08-06 22:07:12` 至 `2026-08-06 22:09:10` | 通过，`118.29s` | 通过，`total=130073` |
| 5 | YuniKorn | `2026-08-06 22:09:53` 至 `2026-08-06 22:11:51` | 通过，`118.03s` | 通过，`total=163595` |
| 6 | Kueue | `2026-08-06 22:13:22` 至 `2026-08-06 22:14:22` | 通过，`59.87s` | 通过，`total=64235` |
| 6 | Volcano | `2026-08-06 22:14:54` 至 `2026-08-06 22:15:38` | 通过，`44.05s` | 通过，`total=64526` |
| 6 | YuniKorn | `2026-08-06 22:16:30` 至 `2026-08-06 22:18:04` | 通过，`94.17s` | 通过，`total=104253` |
| 7 | Kueue | `2026-08-06 22:19:33` 至 `2026-08-06 22:20:44` | 通过，`70.56s` | 通过，`total=60699` |
| 7 | Volcano | `2026-08-06 22:21:14` 至 `2026-08-06 22:22:05` | 通过，`50.14s` | 通过，`total=59204` |
| 7 | YuniKorn | `2026-08-06 22:22:57` 至 `2026-08-06 22:24:37` | 通过，`100.57s` | 通过，`total=100242` |
| 8 | Kueue | `2026-08-06 22:26:08` 至 `2026-08-06 22:27:48` | 通过，`100.03s` | 通过，`total=62689` |
| 8 | Volcano | `2026-08-06 22:28:19` 至 `2026-08-06 22:29:39` | 通过，`80.03s` | 通过，`total=66594` |
| 8 | YuniKorn | `2026-08-06 22:30:22` 至 `2026-08-06 22:33:12` | 通过，`170.03s` | 通过，`total=101070` |

24 组 Case 均出现明确的 `--- PASS: TestBatchJob`，没有 `FAIL`、Go test timeout、组件连接拒绝或 resident state 冲突。24 个 Audit Exporter 指标稳定屏障也全部完成，且 Prometheus 样本时间均晚于对应 Exporter 稳定时刻。

### 19.5 结果制品检查

八个结果目录均包含 `envs.txt`、`result-window.txt`、三份非空调度方案审计文件和八张 Grafana PNG，共计 24 份审计文件与 64 张图片。

64 张图片均为 `10000 × 5000` PNG。逐场景生成合并视图后检查，全部八个面板在八个场景中都包含实际数据曲线，没有出现 `No data`。Created、Scheduled、API Calls、API Calls Rate、Pod Scheduling Latency 和 BatchJob Completion Latency 均能看到 Kueue、Volcano、YuniKorn 三段实验数据。每个场景的八张图片总大小为约 `7.2 MB` 至 `8.4 MB`。

审计文件按约定执行了完整性观察但不作为本轮通过条件：

- 24 份文件的末条记录都能由 `jq` 解析，且包含 `kind`、`verb`、`requestURI` 和 `stage` 等审计事件字段。
- 场景 1 的 YuniKorn 文件没有稀疏区，整份约 `566 MB` 的 JSON 对象流通过完整 `jq` 校验。
- 其余 23 份文件的磁盘分配大小明显小于表观大小，确认存在截断后继续写入形成的稀疏 NUL 空洞，因此不能视为严格有效的纯 JSONL 文件。
- 该 NUL 问题与此前决定一致，本轮不修复；Prometheus 指标、Grafana 曲线和测试判定均未受影响。

### 19.6 测试后恢复验收

测试结束后执行并通过：

- `.resident-state` 不存在，临时状态已清除。
- `assert-no-kueue-resources`、`assert-no-volcano-resources`、`assert-no-yunikorn-resources` 全部通过。
- `verify-base.sh 1000` 通过，Kubernetes 客户端和服务器均为 `v1.34.8`，节点为 `1001/1001 Ready`，审计日志继续写入。
- `verify-schedulers.sh` 通过，Kueue、Coscheduling、Volcano 和 YuniKorn 共八个 Deployment 均恢复并 Ready，资源基线仍为 `500m/8 CPU` 且无内存限制。
- `verify-monitoring.sh` 通过，Audit Exporter、Prometheus、Grafana、Image Renderer、Operator 和 kube-state-metrics 均健康。
- Grafana Ingress `verify.sh` 通过，服务器回环入口与持久 Ingress 均正常。

### 19.7 最终结论

异步 Kueue 高基数清理与 Grafana Dashboard 变量修复已经通过完整 8 场景、24 Case 验证。此前场景 5 的 Kueue 清理超时、Volcano resident state/Admission 连锁失败和 64 张 `No data` 图片均未复现。本轮在 T0 直接满足全部强制验收条件，最终判定为完整测试通过。

## 20. 500ms 采集与固定空闲基线改造后的完整测试（通过）

### 20.1 执行概要

本轮验证 Audit Exporter `500ms` 抓取、主 Dashboard 与八个相对时间 Dashboard 的 `500ms` 查询步长，以及不再保存/恢复调度组件快照的固定空闲基线流程。测试在服务器独立 `tmux` 会话中运行，SSH 或网络波动不会终止测试。

| 项目 | 首轮 T0 | 修复后 T1 |
| --- | --- | --- |
| 被测 Commit | `1bac63e74bd57890f076ba5990e2b6a8596dd311` | `d774bda446a55279ad3d95a2e9523fe1c9b2316b` |
| 命令 | `make` | `make` |
| 独立会话 | `tmux resident-full-500ms-20260810T113814Z` | `tmux resident-full-500ms-t1-20260810T114842Z` |
| CST（UTC+8）时间 | `2026-08-10 19:38:14` 至 `2026-08-10 19:45:40` | `2026-08-10 19:48:42` 至 `2026-08-10 20:40:37` |
| 总耗时 | `445.69s`（`7m25.69s`） | `3115.34s`（`51m55.34s`） |
| Wrapper 退出码 | `2` | `0` |
| `make down` 退出码 | `0` | `0` |
| 子测试结果 | 场景 1 的 `3/3` Case 通过，保存结果前失败 | `24/24` Case 全部通过 |
| 结果保存 | 未生成正式场景目录 | `8/8` 个场景目录完成 |
| 结论 | 源码新增时间窗写入错误，定向修复后重测 | 完整测试通过 |
| 运行归档 | `/root/benchmark-full-runs/full-500ms-20260810T113814Z` | `/root/benchmark-full-runs/full-500ms-t1-20260810T114842Z` |

### 20.2 T0 失败、根因与定向修复

T0 中场景 1 的 Kueue、Volcano、YuniKorn 均通过，耗时分别为 `118.03s`、`118.04s`、`118.04s`，三个 Prometheus 抓取屏障也全部通过。随后 `save-result-images.sh` 在参数校验阶段退出，尚未向 Grafana 发起渲染请求。

直接根因是新增每调度器毫秒时间窗时，在 `define test-scheduler` 经 `eval` 展开两次的上下文中只使用了一层 Make 美元符转义。生成的 shell 命令把 `result-<scheduler>-to-millis` 和 `result-to-millis` 写成字符串 `imestamp`，而不是 13 位 epoch 毫秒。该问题是本轮新增源码造成，不是 500ms 抓取、Grafana、调度器或集群问题。

提交 `d774bda446a55279ad3d95a2e9523fe1c9b2316b` 只增加缺失的一层美元符转义。修复后 `make -n end-kueue/end-volcano/end-yunikorn` 均展开为正确的 `timestamp="$(date +%s%3N)"` 和 `$timestamp` 写入；T1 首个 Kueue Case 又确认两个结束时间文件均为正确的 13 位毫秒值。本轮没有扩大修复范围。

### 20.3 各调度方案与公共配置

组件版本和资源基线与第 19.2 节一致。公共性能参数如下：

| 对比方案 | 组件与作用 | CPU request/limit | 内存 request/limit | Kubernetes client QPS/Burst | 并发或 Worker |
| --- | --- | --- | --- | --- | --- |
| Kueue 非 Gang | 默认 `kube-scheduler`，实际调度 Pod | `1 / 8` | 未设置 | `1000/1000` | 未额外修改 |
| Kueue 准入 | `kueue-controller-manager` | `500m / 8` | 未设置 | `1000/1000` | 六类已启用 Controller 均为 `100` |
| Kueue Gang | `coscheduling`，实际调度 Pod | `500m / 8` | 未设置 | `1000/1000` | Scheduler `parallelism=16` |
| Kueue Gang 辅助 | `scheduler-plugins-controller` | `500m / 8` | 未设置 | 配置 `1000/1000`，受上游缺陷影响仍使用默认有效值 | `workers=100` |
| Volcano | Scheduler、Controller、Admission | `500m / 8` | 未设置 | 均为 `1000/1000` | Controller 三类 worker 均为 `100` |
| YuniKorn | Scheduler | `500m / 8` | 未设置 | 测试 ConfigMap 设置 `1000/1000` | 未额外修改 |
| YuniKorn | Admission Controller | `500m / 8` | 未设置 | 使用上游默认值 | 未额外修改 |

- Kueue `v0.19.0` 负责准入。非 Gang Pod 由 Kubernetes `v1.34.8` 默认 Scheduler 调度；Gang Pod 使用 Scheduler Plugins `v0.34.7` 的 Coscheduling，并创建对应 PodGroup。
- Volcano `v1.15.1` 使用 `enqueue, allocate, backfill, reclaim` actions；非 Gang 第一层为 `priority`，Gang 为 `priority/gang`；第二层为 `predicates/capacity`，并启用层级 Capacity。测试队列统一挂在 `benchmark-root` 下。
- YuniKorn `v1.9.0` 使用 `root.sandbox` 下的测试叶子队列；Gang 场景使用 Hard TaskGroup、`minMember` 和 `placeholderTimeoutInSeconds=600`。
- 三套方案均使用 1000 个 KWOK Worker Node；每个场景 10,000 个工作负载 Pod，每个 Pod 请求/限制 `1 CPU / 1Gi`，本轮 `PREEMPTION=false`。
- `up-<scheduler>` 不再保存 Deployment、ConfigMap 或 Audit Exporter 快照，只将目标调度组件设为 `1`、其他组件设为 `0`。Volcano 和 YuniKorn ConfigMap 仅在内容变化时原地更新并重启 Scheduler；内容一致时不操作。每轮结束和 `make down` 都将八个调度组件及 Audit Exporter 收敛到 `1` 副本，不执行配置恢复。
- Audit Exporter ServiceMonitor 的抓取间隔和超时均为 `500ms`；主 Dashboard 的 8 个面板和相对 Dashboard 的 4 个指标面板最小查询步长均为 `500ms`。`rate` 窗口继续使用 `5s`。

### 20.4 八个场景的时间边界与结果目录

以下时间均为 CST（UTC+8），格式可以直接用于 Grafana。场景边界包含三套调度器切换、测试、清理、结果保存和相对 Dashboard 更新；指标时间窗是 `result-window.txt` 中的精确 epoch 毫秒。

| 场景 | 模式与参数 | CST（UTC+8）时间边界 | 耗时 | 指标时间窗（毫秒） | 结果目录 |
| ---: | --- | --- | ---: | --- | --- |
| 1 | 非 Gang，`10000 job × 1 pod` | `2026-08-10 19:48:42` 至 `2026-08-10 19:56:57` | `8m14s` | `1786362522857` 至 `1786362943807` | `results/1786362958` |
| 2 | 非 Gang，`500 job × 20 pod` | `2026-08-10 19:56:57` 至 `2026-08-10 20:01:30` | `4m33s` | `1786363017319` 至 `1786363216815` | `results/1786363231` |
| 3 | 非 Gang，`20 job × 500 pod` | `2026-08-10 20:01:30` 至 `2026-08-10 20:06:01` | `4m31s` | `1786363290282` 至 `1786363486458` | `results/1786363502` |
| 4 | 非 Gang，`1 job × 10000 pod` | `2026-08-10 20:06:01` 至 `2026-08-10 20:10:43` | `4m42s` | `1786363561133` 至 `1786363769603` | `results/1786363784` |
| 5 | Gang，`10000 job × 1 pod` | `2026-08-10 20:10:43` 至 `2026-08-10 20:20:09` | `9m26s` | `1786363843099` 至 `1786364334979` | `results/1786364350` |
| 6 | Gang，`500 job × 20 pod` | `2026-08-10 20:20:09` 至 `2026-08-10 20:26:05` | `5m57s` | `1786364409403` 至 `1786364692013` | `results/1786364707` |
| 7 | Gang，`20 job × 500 pod` | `2026-08-10 20:26:05` 至 `2026-08-10 20:32:35` | `6m30s` | `1786364765957` 至 `1786365082255` | `results/1786365097` |
| 8 | Gang，`1 job × 10000 pod` | `2026-08-10 20:32:35` 至 `2026-08-10 20:40:37` | `8m02s` | `1786365155845` 至 `1786365563233` | `results/1786365579` |

八行场景耗时合计为 `51m55s`，与 Wrapper 的精确 `3115.34s` 一致。

### 20.5 二十四个 Case 与指标屏障

由于 Go test 输出只记录 Case 耗时、不附绝对时间，以下绝对边界采用可由 Prometheus/Grafana 直接复核的“首个 Pod 创建样本至最终抓取屏障”时间；`TestBatchJob` 列仍是 Go test 的权威完整耗时。所有时间均为 CST（UTC+8）。

| 场景 | 调度方案 | 首个 Pod 至最终抓取屏障 | `TestBatchJob` | Prometheus 抓取屏障 |
| ---: | --- | --- | ---: | --- |
| 1 | Kueue | `2026-08-10 19:48:59` 至 `2026-08-10 19:50:52` | 通过，`118.24s` | 通过，`total=140064` |
| 1 | Volcano | `2026-08-10 19:51:30` 至 `2026-08-10 19:53:17` | 通过，`118.10s` | 通过，`total=130079` |
| 1 | YuniKorn | `2026-08-10 19:53:59` 至 `2026-08-10 19:55:43` | 通过，`118.08s` | 通过，`total=120069` |
| 2 | Kueue | `2026-08-10 19:57:29` 至 `2026-08-10 19:57:56` | 通过，`46.45s` | 通过，`total=65041` |
| 2 | Volcano | `2026-08-10 19:58:45` 至 `2026-08-10 19:59:05` | 通过，`44.04s` | 通过，`total=64976` |
| 2 | YuniKorn | `2026-08-10 19:59:58` 至 `2026-08-10 20:00:16` | 通过，`44.26s` | 通过，`total=69832` |
| 3 | Kueue | `2026-08-10 20:02:10` 至 `2026-08-10 20:02:21` | 通过，`40.28s` | 通过，`total=61034` |
| 3 | Volcano | `2026-08-10 20:03:17` 至 `2026-08-10 20:03:28` | 通过，`40.13s` | 通过，`total=56084` |
| 3 | YuniKorn | `2026-08-10 20:04:28` 至 `2026-08-10 20:04:46` | 通过，`50.56s` | 通过，`total=60744` |
| 4 | Kueue | `2026-08-10 20:06:47` 至 `2026-08-10 20:07:02` | 通过，`50.04s` | 通过，`total=60080` |
| 4 | Volcano | `2026-08-10 20:08:06` 至 `2026-08-10 20:08:12` | 通过，`40.04s` | 通过，`total=50899` |
| 4 | YuniKorn | `2026-08-10 20:09:19` 至 `2026-08-10 20:09:29` | 通过，`50.04s` | 通过，`total=60083` |
| 5 | Kueue | `2026-08-10 20:11:39` 至 `2026-08-10 20:13:37` | 通过，`162.75s` | 通过，`total=140194` |
| 5 | Volcano | `2026-08-10 20:15:17` 至 `2026-08-10 20:16:28` | 通过，`118.12s` | 通过，`total=130070` |
| 5 | YuniKorn | `2026-08-10 20:17:47` 至 `2026-08-10 20:18:54` | 通过，`118.03s` | 通过，`total=165674` |
| 6 | Kueue | `2026-08-10 20:21:20` 至 `2026-08-10 20:21:27` | 通过，`59.24s` | 通过，`total=64246` |
| 6 | Volcano | `2026-08-10 20:22:55` 至 `2026-08-10 20:23:01` | 通过，`44.24s` | 通过，`total=64547` |
| 6 | YuniKorn | `2026-08-10 20:24:33` 至 `2026-08-10 20:24:52` | 通过，`84.68s` | 通过，`total=104213` |
| 7 | Kueue | `2026-08-10 20:27:26` 至 `2026-08-10 20:27:32` | 通过，`70.72s` | 通过，`total=60849` |
| 7 | Volcano | `2026-08-10 20:29:06` 至 `2026-08-10 20:29:15` | 通过，`60.13s` | 通过，`total=71079` |
| 7 | YuniKorn | `2026-08-10 20:29:38` 至 `2026-08-10 20:31:21` | 通过，`100.47s` | 通过，`total=100153` |
| 8 | Kueue | `2026-08-10 20:32:49` 至 `2026-08-10 20:34:27` | 通过，`100.04s` | 通过，`total=62880` |
| 8 | Volcano | `2026-08-10 20:34:57` 至 `2026-08-10 20:36:03` | 通过，`70.04s` | 通过，`total=64755` |
| 8 | YuniKorn | `2026-08-10 20:36:39` 至 `2026-08-10 20:39:22` | 通过，`170.27s` | 通过，`total=100218` |

运行日志包含 24 个明确的 `--- PASS: TestBatchJob`，没有 `--- FAIL`、Go test timeout、OOM、Webhook connection refused 或调度器状态冲突。24 个指标屏障均确认 Prometheus 样本时间晚于 Exporter 稳定时间。

### 20.6 500ms 指标与 Dashboard 验证

- Prometheus `/api/v1/targets` 显示 Audit Exporter 目标为 `scrapeInterval=500ms`、`scrapeTimeout=500ms`、`health=up`。
- `Scheduling Performance`（UID `perf`）仍为 8 个面板，8 个面板的最小查询步长均为 `500ms`。
- 当时使用的 `scheduling-perf-relative-s1-s7`（后续已更名为 `scheduling-perf-relative-s1-s8`）包含 `relative-s1.json` 至 `relative-s8.json` 八个键；UID 为 `perf-relative-s1` 至 `perf-relative-s8`，标签统一为 `benchmark, relative-time, scenario-N`，四个指标面板均为 `500ms`，没有未替换模板占位符。旧 `scheduling-perf-relative-s8` ConfigMap 已删除。
- 每个场景都按 `500ms` 步长查询对应历史时间窗。Kueue 和 Volcano 的 Created/Scheduled 均为 `10000/10000`；YuniKorn 非 Gang 场景为 `10000/10000`，Gang 场景因 10,000 个 placeholder Pod 加 10,000 个实际 Pod 为 `20000/20000`，符合 YuniKorn Gang 设计。
- 八个相对 Dashboard 的 T+0 均取各场景三套方案中首个 Kueue Pod 样本，Volcano/YuniKorn 使用毫秒级 PromQL offset；场景 8 的偏移为 `128500ms` 和 `230000ms`，证明不再回退到整秒计算。

### 20.7 结果制品与审计日志观察

用户已明确图片或原始审计日志保存失败不作为本轮失败条件；本轮实际仍完整保存了全部制品：

- 8 个结果目录均包含 `envs.txt`、`result-window.txt`、3 份审计文件和 8 张 PNG，共 `24` 份审计文件、`64` 张图片。
- 64 张图片均为 `10000 × 5000`、PNG 签名有效，SHA-256 共 64 个唯一值。每场景图片总大小为 `6,766,916` 至 `8,077,627` 字节，单张为 `470,919` 至 `1,443,972` 字节。
- 图片内容不作为本轮通过条件；对应历史时间窗的 Prometheus Created/Scheduled 查询已逐场景验证有数据，Grafana 可直接使用第 20.4 节时间查看。
- 24 份审计文件的末条非 NUL 记录均能由 `jq` 解析，并包含 `kind`、`verb`、`requestURI`、`stage`。
- 其中 23 份文件的磁盘分配小于表观大小，仍存在已知的截断后稀疏 NUL 空洞；该问题未修复，也不影响 Prometheus/Grafana 指标或本轮通过判定。

### 20.8 测试后恢复验收

T1 完成后 Wrapper 自动执行 `make down` 并返回 `0`，随后人工复核：

- `assert-no-kueue-resources`、`assert-no-volcano-resources`、`assert-no-yunikorn-resources` 全部通过。
- `.resident-state` 不存在，没有活动的 `make` 或 `test-kueue/test-volcano/test-yunikorn` 进程。
- `verify-base.sh 1000` 通过：Kubernetes client/server 均为 `v1.34.8`，`1001/1001` Node Ready，审计日志继续写入。
- `verify-schedulers.sh` 通过：Kueue、Coscheduling、Volcano、YuniKorn 共八个 Deployment 全部为 `1/1 Ready`，资源基线仍是 `500m/8 CPU` 且无内存限制。
- Audit Exporter 为 `1/1 Ready`；`verify-monitoring.sh` 通过，Prometheus、Grafana、Image Renderer、Operator 和 kube-state-metrics 健康，Prometheus 主容器 restartCount 为 `0`。
- Grafana Ingress `verify.sh` 通过，服务器回环入口和 `http://104.105.137.213:31005/grafana/d/perf/?theme=light` 均正常。

### 20.9 最终结论

固定空闲副本基线、ConfigMap 内容相同时不操作、Audit Exporter 持续保留最近标签、`500ms` 抓取与查询步长、毫秒级相对 Dashboard 对齐均通过完整 8 场景、24 Case 验证。T0 只暴露并修复了新增时间窗代码中的单一 Make 转义错误；T1 没有再出现该错误，也没有出现旧的 Kueue 高基数清理、resident state、Admission、Prometheus OOM 或 Dashboard 无数据问题。本轮最终判定为通过。

## 21. 100ms 采集与单相对面板归档完整测试（通过）

### 21.1 执行概要

本轮验证 Audit Exporter `100ms` 抓取、主 Dashboard 与八个相对 Dashboard 的 `100ms` 查询步长，以及每场景只归档一张 `Job Submission — Created vs Scheduled` 相对面板图片的新结果保存流程。测试在服务器独立 `tmux` 会话中运行，两次 SSH 连接中断均未终止或重启测试。

| 项目 | 内容 |
| --- | --- |
| 主体源码 Commit | `4fa30be14eff9b522ea1ab027d057f8b971ce281` |
| 标签语义修复 Commit | `69142a954a17bef64133662ce041a1c291651586` |
| 命令 | `make` |
| 独立会话 | `tmux resident-full-100ms-single-panel-20260811T040535Z` |
| CST（UTC+8）时间 | `2026-08-11 12:05:35` 至 `2026-08-11 12:50:26` |
| 总耗时 | `2691.248s`（`44m51.248s`） |
| `make` 退出码 | `0` |
| `make down` 退出码 | `0` |
| 子测试结果 | `24/24` 组 `TestBatchJob` 全部通过 |
| 指标屏障 | `24/24` 全部通过 |
| 结果保存 | `8/8` 个元数据目录；`6/8` 张相对面板 PNG |
| 运行归档 | `/root/benchmark-full-runs/full-100ms-single-panel-20260811T040535Z` |
| 完整日志 | `/root/benchmark-full-runs/full-100ms-single-panel-20260811T040535Z/run.log` |
| 验收结论 | 完整测试通过；图片按既定规则为非阻断观察项 |

八个场景完成结果归档的时间合计为 `2680s`（`44m40s`）；最后一次结果归档后，Wrapper 又使用 `11.248s` 完成最终 `make down` 和运行记录写入，因此精确总耗时为 `2691.248s`。

### 21.2 本轮源码与运行配置

- Audit Exporter ServiceMonitor 的 `interval` 与 `scrapeTimeout` 均由 `500ms` 调整为 `100ms`；主 `perf` Dashboard 的 8 个面板、8 个相对 Dashboard 的 4 个指标面板和相对面板生成查询同步使用 `100ms`。`rate` 窗口继续为 `5s`。
- 三套调度方案、1000 个 KWOK Worker Node、每场景 10,000 个实际工作 Pod、资源/QPS/Burst/并发和调度插件配置均与第 20.3 节相同，本轮没有调整调度器性能参数。
- `serial-test` 在三套调度器完成后先更新本场景相对 Dashboard，再执行 `save-result`。归档继续保存 `envs.txt` 与 `result-window.txt`，并只尝试保存 `output/job-submission.png`；不再渲染原 `perf` Dashboard 的 8 个面板。
- 源码不再创建 `./logs/kube-apiserver-audit.<scheduler>.log`，也不再把 `./logs` 移入结果目录；每轮仍停止 Audit Exporter、截断集群主审计日志、切换 `cluster` 标签并重启 Exporter。
- 图片渲染失败只记录 warning，不阻断元数据归档或后续场景；原 `perf` Dashboard 继续保留在 Grafana 中。

### 21.3 八个场景的时间边界与结果目录

以下时间均为 CST（UTC+8），可直接粘贴到 Grafana。场景边界包含三套调度器切换、测试、清理、相对 Dashboard 更新和结果保存；指标时间窗来自各结果目录的 `result-window.txt`。

| 场景 | 模式与参数 | CST（UTC+8）时间边界 | 耗时 | 指标时间窗（毫秒） | 结果目录 |
| ---: | --- | --- | ---: | --- | --- |
| 1 | 非 Gang，`10000 job × 1 pod` | `2026-08-11 12:05:35` 至 `2026-08-11 12:12:52` | `7m17s` | `1786421135459` 至 `1786421556770` | `results/scenario-1` |
| 2 | 非 Gang，`500 job × 20 pod` | `2026-08-11 12:12:52` 至 `2026-08-11 12:16:28` | `3m36s` | `1786421572718` 至 `1786421773983` | `results/scenario-2` |
| 3 | 非 Gang，`20 job × 500 pod` | `2026-08-11 12:16:28` 至 `2026-08-11 12:20:12` | `3m44s` | `1786421788823` 至 `1786421997721` | `results/scenario-3` |
| 4 | 非 Gang，`1 job × 10000 pod` | `2026-08-11 12:20:12` 至 `2026-08-11 12:24:11` | `3m59s` | `1786422018261` 至 `1786422235920` | `results/scenario-4` |
| 5 | Gang，`10000 job × 1 pod` | `2026-08-11 12:24:11` 至 `2026-08-11 12:32:41` | `8m30s` | `1786422258533` 至 `1786422746680` | `results/scenario-5` |
| 6 | Gang，`500 job × 20 pod` | `2026-08-11 12:32:41` 至 `2026-08-11 12:38:09` | `5m28s` | `1786422768318` 至 `1786423074628` | `results/scenario-6` |
| 7 | Gang，`20 job × 500 pod` | `2026-08-11 12:38:09` 至 `2026-08-11 12:43:16` | `5m07s` | `1786423096288` 至 `1786423381702` | `results/scenario-7` |
| 8 | Gang，`1 job × 10000 pod` | `2026-08-11 12:43:16` 至 `2026-08-11 12:50:15` | `6m59s` | `1786423403376` 至 `1786423800482` | `results/scenario-8` |

最终恢复与 Wrapper 收尾结束时间为 `2026-08-11 12:50:26`。

### 21.4 二十四个 Case 与指标屏障

绝对边界采用可由 Prometheus/Grafana 复核的“首个实际工作 Pod 创建样本至最终抓取屏障”；`TestBatchJob` 列为 Go test 的权威完整耗时。所有时间均为 CST（UTC+8）。

| 场景 | 调度方案 | 首个 Pod 至最终抓取屏障 | `TestBatchJob` | Prometheus 抓取屏障 |
| ---: | --- | --- | ---: | --- |
| 1 | Kueue | `2026-08-11 12:05:59` 至 `2026-08-11 12:07:46` | 通过，`118.38s` | 通过，`total=140135` |
| 1 | Volcano | `2026-08-11 12:08:31` 至 `2026-08-11 12:10:11` | 通过，`118.11s` | 通过，`total=130076` |
| 1 | YuniKorn | `2026-08-11 12:10:57` 至 `2026-08-11 12:12:36` | 通过，`118.04s` | 通过，`total=120070` |
| 2 | Kueue | `2026-08-11 12:13:31` 至 `2026-08-11 12:13:53` | 通过，`46.21s` | 通过，`total=64814` |
| 2 | Volcano | `2026-08-11 12:14:48` 至 `2026-08-11 12:15:03` | 通过，`43.93s` | 通过，`total=65155` |
| 2 | YuniKorn | `2026-08-11 12:15:59` 至 `2026-08-11 12:16:13` | 通过，`44.41s` | 通过，`total=69797` |
| 3 | Kueue | `2026-08-11 12:17:14` 至 `2026-08-11 12:17:30` | 通过，`50.35s` | 通过，`total=61149` |
| 3 | Volcano | `2026-08-11 12:18:32` 至 `2026-08-11 12:18:39` | 通过，`40.18s` | 通过，`total=56316` |
| 3 | YuniKorn | `2026-08-11 12:19:45` 至 `2026-08-11 12:19:57` | 通过，`50.52s` | 通过，`total=60710` |
| 4 | Kueue | `2026-08-11 12:21:10` 至 `2026-08-11 12:21:21` | 通过，`50.03s` | 通过，`total=60080` |
| 4 | Volcano | `2026-08-11 12:22:29` 至 `2026-08-11 12:22:36` | 通过，`40.03s` | 通过，`total=50904` |
| 4 | YuniKorn | `2026-08-11 12:23:48` 至 `2026-08-11 12:23:55` | 通过，`50.04s` | 通过，`total=60085` |
| 5 | Kueue | `2026-08-11 12:25:20` 至 `2026-08-11 12:27:12` | 通过，`161.55s` | 通过，`total=140209` |
| 5 | Volcano | `2026-08-11 12:28:57` 至 `2026-08-11 12:30:02` | 通过，`118.03s` | 通过，`total=130066` |
| 5 | YuniKorn | `2026-08-11 12:31:26` 至 `2026-08-11 12:32:26` | 通过，`118.04s` | 通过，`total=164278` |
| 6 | Kueue | `2026-08-11 12:34:04` 至 `2026-08-11 12:34:11` | 通过，`59.47s` | 通过，`total=64235` |
| 6 | Volcano | `2026-08-11 12:35:44` 至 `2026-08-11 12:35:52` | 通过，`44.31s` | 通过，`total=64417` |
| 6 | YuniKorn | `2026-08-11 12:37:31` 至 `2026-08-11 12:37:54` | 通过，`94.66s` | 通过，`total=103998` |
| 7 | Kueue | `2026-08-11 12:38:25` 至 `2026-08-11 12:39:38` | 通过，`70.67s` | 通过，`total=60575` |
| 7 | Volcano | `2026-08-11 12:40:04` 至 `2026-08-11 12:40:55` | 通过，`50.14s` | 通过，`total=68113` |
| 7 | YuniKorn | `2026-08-11 12:41:23` 至 `2026-08-11 12:43:01` | 通过，`100.90s` | 通过，`total=100235` |
| 8 | Kueue | `2026-08-11 12:43:41` 至 `2026-08-11 12:45:06` | 通过，`90.04s` | 通过，`total=62582` |
| 8 | Volcano | `2026-08-11 12:45:42` 至 `2026-08-11 12:46:43` | 通过，`70.03s` | 通过，`total=64631` |
| 8 | YuniKorn | `2026-08-11 12:47:20` 至 `2026-08-11 12:50:00` | 通过，`170.04s` | 通过，`total=101016` |

运行日志包含 24 个明确的 `--- PASS: TestBatchJob` 和 24 个 `audit_metrics_scraped`，没有 `--- FAIL`、Go test timeout、OOM、Webhook connection refused 或调度器状态冲突。

### 21.5 100ms 抓取与 Dashboard 验证

- Prometheus 当前目标为 `health=up`、`scrapeInterval=100ms`、`scrapeTimeout=100ms`。完整测试窗口内 `min_over_time(up[46m])=1`，没有失败抓取样本。
- 完整窗口的 `scrape_duration_seconds` 平均为 `1.143ms`、P99 为 `1.721ms`、最大为 `2.129ms`，均显著低于 `100ms` 超时。
- `Scheduling Performance`（UID `perf`）仍有 8 个面板，8 个面板的最小查询步长均为 `100ms`；原 Dashboard 未被删除，也不再作为结果图片来源。
- 测试完成后统一 ConfigMap 已更名为 `scheduling-perf-relative-s1-s8`，仍包含 `relative-s1.json` 至 `relative-s8.json`；仅修正名称，UID、标签、Scheduler 变量和 Dashboard 内容保持不变，4 个指标面板的最小查询步长均为 `100ms`。
- 场景 3 至 8 的相对 Dashboard 均使用本轮首个实际工作 Pod 作为 T+0，并按“第二套方案达到实际 `Scheduled=10000` 后 5 秒”确定截止时间。YuniKorn 的 Created/Scheduled 均排除 placeholder Pod。

### 21.6 场景 1–2 图片失败、根因与修复

测试开始前将仓库 ServiceMonitor 整份重新应用到集群。远端权威部署包原本未设置 `honorLabels`，有效值为 `false`；仓库文件却机械保留了旧的 `honorLabels: true`。重新应用后，场景 1–2 的实验命名空间保留为 `namespace`，而 Dashboard 和相对面板生成器按既定设计查询 `exported_namespace`。生成器因此得到零时间，临时生成 `1970-01-01` 时间窗，Grafana API 等待校验失败，图片保存按设计降级为 warning。

该问题不是调度器、100ms 抓取性能或图片脚本本身失败，而是部署基线与仓库 ServiceMonitor 的机械复制不适配。场景 2 结束后只将 `honorLabels` 修正为 `false`；源码修复提交为 `69142a954a17bef64133662ce041a1c291651586`。Prometheus 随即恢复 `exported_namespace`，场景 3 至 8 的相对 Dashboard 和图片全部成功。测试结束后，场景 1–2 的 Grafana Dashboard 已恢复为 2026-08-10 上一轮有效历史视图，避免保留 1970 坏面板；它们不冒充本轮结果。

### 21.7 结果制品

- 本轮 8 个结果目录已按新规则重命名为 `results/scenario-1` 至 `results/scenario-8`；全部包含 `envs.txt` 和 `result-window.txt`，后续同场景运行会直接替换上一轮目录。
- 场景 3 至 8 各包含且仅包含 `output/job-submission.png`；六张图片均为有效 `3200×1800` PNG，大小为 `171152` 至 `259283` 字节，SHA-256 六个值全部不同。
- 场景 1–2 只有元数据，没有空文件或空 `output/` 目录。按已确认的验收规则，图片失败不影响 24 Case 完整测试判定。
- 8 个新结果目录均没有 `logs/`，仓库根目录也没有新的 `./logs/kube-apiserver-audit.<scheduler>.log`。集群主审计日志重置和 Audit Exporter 重启流程仍正常执行。

### 21.8 测试后恢复与最终结论

- Wrapper 的最终 `make down` 返回 `0`；`.resident-state` 不存在，没有活动的 `make` 或 `test-kueue/test-volcano/test-yunikorn` 进程。
- `assert-no-kueue-resources`、`assert-no-volcano-resources`、`assert-no-yunikorn-resources` 全部通过。
- `verify-base.sh 1000` 通过，`1001/1001` Node Ready；Kueue、Coscheduling、Volcano、YuniKorn 的 8 个 Deployment 与 Audit Exporter 均为 `1/1 Ready`。
- Audit Exporter 当前继续以 `100ms/100ms`、`honorLabels=false` 运行；服务器仓库已快进到修复提交 `69142a9`。

按既定“图片为非阻断观察项”的验收规则，本轮完整测试最终判定为通过：8 个场景、24/24 Case、24/24 指标屏障、8/8 元数据归档和最终固定基线恢复全部成功。单相对面板归档链路在标签修复后的场景 3–8 连续验证成功；场景 1–2 缺图及其基线不一致根因已完整记录并修复，没有扩大修改范围，也没有重复执行完整测试。

## 22. 场景 7 YuniKorn 单轮性能离群记录

### 22.1 现象

在三轮完整性测试的场景 7（Gang，`20 Job × 500 Pod`）中，提交 `73eac2fc0abf67ba386eaeddd16f50b3f8820da3` 与 `344bcb6538488d708e19994733402b5e73aaca72` 的相对 Dashboard 结果基本一致；提交 `e4ffe56887784733ccdf02fc8496d58cc08269be` 中 YuniKorn Scheduled 曲线明显更晚开始增长，并在 Dashboard 截止时只显示较少的已调度工作 Pod。

三轮 TestBatchJob 均通过，因此该现象不是 Case 失败。Dashboard 采用“第二套调度方案达到实际 `Scheduled=10000` 后 5 秒”作为截止时间，最慢的 YuniKorn 后续曲线会被截断；但 `e4ffe568` 与另外两轮的可见差异不能只由该截断规则解释。

### 22.2 审计日志核对

服务器保留的 API Server 审计日志完整覆盖 `e4ffe568` 和 `344bcb6` 两轮场景 7 的 YuniKorn Case。按 Pod 名称关联由 `kube-controller-manager` 创建的实际工作 Pod 和对应 `pods/binding` 事件后，得到：

| 场景 7 YuniKorn | `e4ffe568` | `344bcb6` |
| --- | ---: | ---: |
| 创建完 10,000 个实际工作 Pod | `9.60s` | `10.27s` |
| 首个实际工作 Pod binding 距首个工作 Pod 创建 | `33.11s` | `16.22s` |
| 完成 10,000 个实际工作 Pod binding 距首个工作 Pod 创建 | `118.50s` | `92.02s` |
| 10,000 个 placeholder binding 的执行跨度 | `107.54s` | `78.01s` |

两轮审计日志中均存在完整的 10,000 个实际工作 Pod create、10,000 个实际工作 Pod binding 和 10,000 个 placeholder binding，没有发现审计事件丢失。Dashboard 曲线的时间和数量与原始审计事件一致。

### 22.3 当前结论

`e4ffe568` 的差异不是 Dashboard、Audit Exporter 或审计日志统计错误，也不是 Job Controller 创建工作 Pod 变慢；原始事件证明该轮 YuniKorn 的 placeholder 和实际工作 Pod binding 阶段确实更慢。现有三轮结果中只有 `e4ffe568` 出现该表现，因此当前将其记录为场景 7 YuniKorn 的单轮性能离群。

审计日志只能定位到 YuniKorn 调度阶段，不能解释调度器内部为何该轮处理更慢；该轮 YuniKorn Scheduler 组件日志未保留，当前无法进一步确认内部根因。后续若再次出现同类离群，应在测试结束后立即保留对应的 YuniKorn Scheduler 日志，再结合审计事件分析。
