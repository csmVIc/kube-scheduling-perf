# 常驻固定集群改造代码评审

评审基线：`9833dcd^..9833dcd`。以下仅列出需要修改的实际问题。

## 高：Grafana 截图时间窗不再覆盖实际实验

- 文件和行号：`Makefile:349-357,384-387`，`hack/save-result-images.sh:12-13`
- 触发条件：正常执行任意一次 `make serial-test`。
- 实际影响：三轮实验全部结束后，`save-result` 先等待 `RESULT_RECENT_DURATION_SECONDS`，随后脚本才把截图区间计算为 `[now-N, now]`。区间起点约等于等待开始时间，三轮实验事件位于该区间之前；依赖 `rate()` 的 API 调用率和调度/完成延迟面板会为空、为零或只剩边界采样，生成有效 PNG 也不能说明其中包含有效实验数据。最小测试若把 N 设为 0，还会得到零长度区间。
- 判断依据：修改前会在等待前创建 overview 集群并启动带 `--replay` 的 Audit Exporter，等待期正是三份静态日志的回放期；本提交删除了 overview/replay，却原样保留了“先等待 N 秒，再查询最近 N 秒”的算法。
- 建议修复方向：在第一轮实验前记录开始时间，在最后一次 Prometheus 抓取后记录结束时间，并把明确的起止时间传给截图脚本；或者恢复对三份已保存审计日志的带标签回放，再沿用当前等待窗口。

## 高：常驻 Audit Exporter 无法提供彼此隔离的三轮结果

- 文件和行号：`Makefile:161-165,384-387`，`hack/save-result-images.sh:19`
- 触发条件：在常驻 exporter/Prometheus 上执行三套调度器，尤其是重复执行 `serial-test` 或连续执行顶层默认测试。
- 实际影响：截断审计文件不会清空 exporter 进程中的 Counter、Histogram 和对象时间状态，也不会清除 Prometheus 中已有序列，因此总量面板会混入本轮 `reset-auditlog` 之前的实验、初始化和清理数据。常驻 exporter 对单一日志未设置每轮调度器标签，而截图又选择全部 namespace；固定 Dashboard 的主要查询按 `(cluster,user)` 聚合并丢弃 namespace，三轮中相同 user-agent 的数据会合并，无法保持修改前按 Kueue、Volcano、YuniKorn 分组的对比语义。除此之外，v0.0.25 只在一次轮询观察到 `newSize < oldOffset` 时识别 truncate；若清空后高并发写入使文件在下一次轮询前重新长过旧 offset，它会从旧 offset 继续读取并漏掉本轮开头。
- 判断依据：修改前每次创建新的 overview 监控环境，并把三份完成后的静态日志分别以 `kueue`、`volcano`、`yunikorn` 标签从 offset 0 回放；当前代码只清空正在被常驻进程跟踪的文件和本地副本，没有重置 exporter、隔离指标状态或补充等价标签。
- 建议修复方向：优先从三份已保存日志为本轮建立独立、带调度器标签的回放结果；若继续使用实时采集，则需要为每轮建立明确的 run/scheduler 维度、可靠重置 exporter 状态，精确过滤三个测试 namespace，并调整 Dashboard 聚合和图例保留该维度，不能把文件 truncate 当作指标重置。

## 高：串行配方会吞掉子阶段失败，并可能归档掉恢复快照

- 文件和行号：`Makefile:349-357,388-393`
- 触发条件：任一非最后的 `prepare-*`、`start-*` 或 `end-*` 子 make 失败，而后续某个子 make 成功。
- 实际影响：foreach 展开后使用分号串联且没有 `set -e` 或 `&&`，shell 会继续执行后续调度器；最终命令成功时，整行会被当成成功并继续 `save-result`。这会把缺轮或失败轮次当成完整结果。若某次配置恢复失败并留下 `tmp/resident-state`，后续命令仍可能成功，随后第 393 行把整个 `tmp` 移入 `results/<timestamp>`，使 `make down` 在固定状态目录找不到恢复快照，集群配置无法再通过正常入口恢复。
- 判断依据：分号串联在修改前已经存在，但临时集群最终被删除；本提交引入了必须留在固定路径、供人工恢复使用的持久状态快照，使继续执行和整体移动 `tmp` 产生了新的集群状态破坏后果。
- 建议修复方向：任一子阶段失败后立即停止串行流程，不运行后续调度器或 `save-result`；归档前强制确认 `resident-state` 为空，并把恢复状态目录从结果归档目录中分离。

## 高：没有保存测试前副本数，恢复路径会强制启动原本停用的组件

- 文件和行号：`Makefile:207-237,282-300,322-325,339-347`
- 触发条件：测试开始前任一相关 Deployment 不是 1 副本，特别是 `yunikorn-scheduler` 为 0 副本。
- 实际影响：所有 activate 路径只修改副本数而不保存原值，所有 deactivate 和顶层 `down` 又无条件把全部组件设为 1，并要求全部调度器通过就绪检查。YuniKorn 配置恢复还无条件执行 `rollout restart`。因此测试前为 0 的 YuniKorn Scheduler 会因测试或仅因恢复配置而被重启，最终保持 1 副本；其他人为停用或调整过副本数的组件同样无法恢复到测试前状态。
- 判断依据：`resident-state` 当前只保存 Volcano/YuniKorn ConfigMap，不包含任何 Deployment 原副本数；这直接违反“恢复到测试前副本状态，YuniKorn 原先未运行时不为恢复配置而强启或重启”的验收要求。
- 建议修复方向：在第一次缩放前原子保存全部相关 Deployment 的原副本数，恢复时逐项还原。YuniKorn 原始值为 0 时先保持/恢复为 0，只恢复 ConfigMap 内容，不执行 rollout restart；等待逻辑也应只等待原本期望运行的组件。

## 高：资源清理既忽略错误又不等待完成，`make down` 可假成功

- 文件和行号：`Makefile:177-205,282-300,339-347`
- 触发条件：API 请求瞬时失败，或 Job、Workload、ClusterQueue、Volcano Queue 等因 finalizer、级联删除或父子依赖而延迟删除；重复执行固定名称测试时尤其容易暴露。
- 实际影响：多数删除命令同时使用 Make 的 `-` 忽略返回值和 `--wait=false`；两个 `get | grep | xargs` 管道也没有 pipefail，会掩盖前段 `kubectl get` 失败。清理目标随后只检查 Deployment、CRD 和 Node，不验证测试资源为零，所以 prepare/down 可以在资源仍存在时成功。下一轮会遇到固定名称 AlreadyExists，或让旧 Queue、Workload、PodGroup、PriorityClass 等参与新实验，导致结果污染和人工恢复误报成功。
- 判断依据：修改前通过删除整套临时 Kind 集群消除资源；本提交新增的常驻清理路径成为唯一隔离屏障，但实现是异步且 best-effort，不能满足重复执行和人工恢复的零残留要求。
- 建议修复方向：只把 NotFound 视为可忽略，其他删除错误必须失败；按依赖顺序阻塞等待对象消失，并在继续 TestInit 或宣告 down 成功前，对三个测试 namespace 和全部固定集群级测试资源执行零残留断言。

## 高：新增的 YuniKorn“重启”不能保证新配置已经加载

- 文件和行号：`test/yunikorn/provider_test.go:61-75`，`test/utils/utils.go:76-92`
- 触发条件：`TestInit` 创建 `yunikorn-configs` 后调用 `RestartDeployment`。
- 实际影响：helper 把 replicas patch 为 0 后不等待旧 Pod 消失，立即 patch 回原副本数。Deployment Controller 可能只观察到最终值，旧 Pod 根本没有重建；随后等待的只是已有 `Available=True` 条件，也可能立即成功。测试因而可能在 YuniKorn 仍使用旧队列配置时创建 Job，表现为队列不存在、任务超时，或产生基于错误配置的性能数据。
- 判断依据：该 helper 和 Volcano 的既有使用不是本次新增问题，但本提交首次把它用于满足 YuniKorn 配置加载要求；其实现没有任何能证明新 ReplicaSet/Pod 已产生的条件，不能满足设计中的“重启或等待配置加载完成”。
- 建议修复方向：使用修改 Pod template 的真正 rollout restart，并等待 observed generation、rollout 完成及新 Pod Ready；或者严格等待副本和旧 Pod 归零后再扩容，并验证新 Pod UID/启动时间后才运行批量测试。

## 中：调度器隔离只提交 scale 请求，没有等待非目标 Pod 归零

- 文件和行号：`Makefile:239-280,302-320`
- 触发条件：切换到任意目标调度器，尤其控制面繁忙、Deployment 缩容处理延迟时。
- 实际影响：`kubectl scale --replicas=0` 只确认期望副本已写入 API；随后的 `wait-resident-*` 仅等待目标组件和基础 Node，不检查非目标 Deployment 的 status replicas 或 Pod 数。TestInit 因而可能在前一调度器、Controller 或 Admission Pod 尚未退出时开始，造成控制面/API 负载、Webhook 处理和指标重叠，破坏“每轮只有目标调度组件运行”的隔离前提。
- 判断依据：三个 activate 目标均连续执行 scale 后立即返回，所有 wait 目标都缺少对被缩容组件的归零检查。
- 建议修复方向：每次切换时等待所有非目标 Deployment 的 `status.replicas/readyReplicas/availableReplicas` 归零，并确认对应 Pod 已不存在，再允许 TestInit 和审计日志重置后的正式测试开始。

## 中：配置快照不是崩溃安全的，人工 `make down` 可能无法恢复

- 文件和行号：`Makefile:171-175,214-237,248-275`
- 触发条件：`kubectl get`、`jq` 失败，或进程在生成/恢复状态文件的任意中间步骤被中断。
- 实际影响：备份通过重定向直接写入 `.raw.json` 和最终 `.json`；失败可留下空文件或半文件。恢复逻辑只用 `-f` 判断最终文件存在，随后先删除集群 ConfigMap，再用可能损坏的快照创建，可能使 Volcano/YuniKorn 配置直接缺失。只有 `.raw.json` 残留时，`make down` 不读取也不清理它，但 `ensure-no-resident-state` 会把任意文件视为未恢复状态，从而永久拒绝后续实验。恢复路径还在 rollout restart 成功前删除正式快照；若此后失败，重试 down 已没有依据再次完成所需重启。
- 判断依据：这些中间文件和恢复顺序均为本提交新增，且与方案要求的“异常中断后由 make down 恢复”直接冲突。
- 建议修复方向：在状态目录外写临时文件，使用 `jq -e` 校验 JSON、对象 kind/name/namespace 和必要数据后原子 rename；恢复前再次验证快照，配置、副本和 rollout 全部成功后才删除正式状态；同时为 raw/pending 状态定义可重试的恢复或安全清理规则。

共发现 8 个需要修改的问题。

## 主评审处理结论

| 问题 | 处理结果 |
|---|---|
| Grafana 时间窗 | 已修复：记录完整串行实验的毫秒级 `FROM/TO`，并显式筛选三套 namespace 和 cluster。 |
| Audit Exporter 隔离 | 已修复：每轮停止旧进程、截断日志、使用独立 cluster 标签启动新进程，并等待 Prometheus 抓取到晚于指标稳定时刻的样本。 |
| 串行配方吞错及快照归档 | 部分采纳：按既定方案不增加 `serial-test` 退出保护；恢复状态移出 `tmp`，结果只移动独立 staging，消除新增的快照丢失风险。 |
| 副本数恢复 | 已修复：保存并恢复八个 Deployment 的实际副本数；YuniKorn 清理不强制扩容，原副本为 0 时保持停用。 |
| 资源清理 | 已修复：删除操作阻塞执行，API 错误不再忽略，结束前断言测试资源零残留。 |
| YuniKorn 重启 | 已修复：通过 Pod template annotation 触发真实 rollout，并等待 Deployment 完整收敛。 |
| 非目标 Pod 归零 | 已修复：切换后同时校验 Deployment 状态和 Pod 列表。 |
| 配置快照 | 已修复：临时文件与正式恢复状态分离、校验后原子提交；恢复时按当前 `resourceVersion` 精确替换，全部恢复成功后才删除快照。 |

修复后二次只读复核结论：无剩余阻断问题。

## 三套调度方案基线纠正独立配置评审

- 被审提交：`cbd8642f8b641a73c54a662ffd323f7ff93c6825`
- 改造前基线：`6ce46e0cd2464a5c03331f8ee756980719ca4d69`
- 核对范围：Kueue v0.19.0 + Scheduler Plugins/Coscheduling v0.34.7、Volcano v1.15.1、YuniKorn v1.9.0；旧基线源码；本地部署包 `/Users/csmvic/Documents/Codex/2026-08-03/k8s-1-35/deploy`；远端部署包 `/root/benchmark-1348-deploy`；Kubernetes v1.34.8 实时集群；`.codex/AGENT.md`、`CLUSTER_DEPLOYMENT_RECORD.md`、两份方案和完整测试报告。远端核对全程只读，未执行 apply、patch、scale、rollout 或冒烟测试。
- 一致性摘要：本地与远端部署包中 `values/`、`manifests/`、`scripts/`、`systemd/` 及关键根文件共 28 个文件的聚合 SHA-256 均为 `c43123141c26aad5a3ae2bf38566bc0447a3c69563e52ee83ccfe5a11e93c739`。实时集群为 `v1.34.8`、`1001/1001 Ready`、其中 1000 个 KWOK Node；8 个调度 Deployment 的镜像、副本、CPU `500m/8`、无内存 request/limit 与部署包一致。

### 高：Coscheduling Controller 的 QPS/Burst 参数在 v0.34.7 中实际不生效

- 位置：部署包 `scripts/install-schedulers.sh:128-129`，`RESIDENT_CLUSTER_FULL_TEST_REPORT.md:231,242,250`，`CLUSTER_DEPLOYMENT_RECORD.md:244`；上游 v0.34.7 `cmd/controller/app/server.go:39-46`。
- 证据：安装脚本和实时 Deployment 都显示 `--qps=1000 --burst=1000 --workers=100`，实时日志也证明两个 Controller 的 worker count 为 100。但 v0.34.7 二进制的上游源码先对局部 `config := ctrl.GetConfigOrDie()` 设置 QPS/Burst，随后却用新的 `ctrl.GetConfigOrDie()` 创建 Manager；已修改的 `config` 未被传入。因此 worker 参数生效，QPS/Burst 仍落到 controller-runtime/client-go 默认值，记录中的 `1000/1000` 只是命令行表象。
- 影响：PodGroup/ElasticQuota Controller 的 API 访问受低默认限速约束，无法恢复旧基线的 `1000/1000/100`，会直接影响 Kueue gang/Coscheduling 轮次的吞吐。`Ready` 和参数存在性检查无法发现此问题。
- 建议：在保持已批准版本边界的前提下，回移上游修复或构建、固定一个将 `config` 传给 `ctrl.NewManager` 的 v0.34.7 镜像；若选择升级组件，应另行获得版本变更批准。在修复并用可观测证据确认实际 client 限速前，不应声称 Controller QPS/Burst 已恢复。

### 高：基线纠正漏掉了直接参与 Job 与调度链路的控制面参数

- 位置：旧基线 `clusters/{kueue,volcano,yunikorn}/kind.yaml:13-29`、`clusters/kueue/Makefile:47-55`、`clusters/{volcano,yunikorn}/Makefile:31-34`；当前部署包 `kind-config.yaml:9-14`、`scripts/create-canary-cluster.sh:32-36`；`test/kueue/batch_job.yaml:12-43`、`test/yunikorn/batch_job.yaml:1-10`。
- 证据：旧三套 Kind 配置都显式设置 `kube-controller-manager --concurrent-job-syncs=100`，并把 Controller Manager 静态 Pod 资源设为 CPU request `1`、limit `8`；Kueue 基线还把默认 `kube-scheduler` 设为 client `1000/1000`、CPU `1/8`。当前本地/远端 `kind-config.yaml` 没有 `concurrent-job-syncs` 和 `scheduler` 配置，也没有静态 Pod 资源覆盖步骤；实时 Controller Manager 为 request `200m`、无 limit，默认 Scheduler 为 request `100m`、无 limit。v1.34.8 实际二进制 `--help` 证明 `concurrent-job-syncs` 仍受支持且默认为 `5`，Scheduler QPS/Burst 默认为 `50/100`；Scheduler 旗标记为 deprecated，但仅在指定 `--config` 时才被忽略，当前静态 Pod 没有 `--config`。
- 影响：Kueue 和 YuniKorn 都创建原生 Kubernetes Job，Job Controller 并发从 100 回落到 5，会限制 Pod 创建、完成与 TTL 清理吞吐。Kueue 非 gang 清单只在 gang 分支写入 `schedulerName: coscheduling`，因此默认 Scheduler 实际是该轮次的直接被测链路；`50/100` 与更低 CPU request 不等价于旧基线。本轮报告仅审计 8 个 Deployment，因而漏掉了这两个直接依赖。
- 边界判断：Controller Manager `5000/10000` 有既有常驻集群部署设计依据，且不低于旧值，不建议回退；问题是未保留 Job 并发、默认 Scheduler client 限速和控制面资源基线，这些旧字段在 v1.34.8 仍可用，不属于版本兼容性必须删除。
- 建议：在部署包和实时集群恢复 `concurrent-job-syncs=100`与默认 Scheduler `1000/1000`；对静态 Pod CPU `1/8` 恢复旧值，或给出明确批准和对等测量依据。把有效 args 和 resources 加入重建步骤与验收脚本，再重测受影响的 Kueue/YuniKorn 场景。

### 高：YuniKorn Mutating Webhook 在非 YuniKorn 轮次仍全局匹配并请求已停止的后端

- 位置：部署包 `values/yunikorn.yaml:27-32`、`scripts/install-schedulers.sh:135-145`，源码 `Makefile:527-547,597-605`。
- 证据：实时 `yunikorn-admission-controller-mutations` 的 `namespaceSelector={}`，rules 匹配所有命名空间的 Pod、Deployment、ReplicaSet、StatefulSet、DaemonSet、Job 和 CronJob，`failurePolicy=Ignore`。`processNamespaces=^bench-yunikorn$` 只是 Webhook 进程内部过滤，不会阻止 API Server 调用 Webhook。而 Kueue/Volcano 轮次会把 `yunikorn-admission-controller` 缩容到 0。API Server 日志在 `2026-08-04T18:33:00Z` 之后记录了至少 1122 次 `Failed calling webhook, failing open admission-webhook.yunikorn.mutate-pods`，直接原因为对 YuniKorn Service 连接被拒绝。
- 影响：非 YuniKorn 的 Job/Pod 写请求仍进入一条失败 Webhook 调用路径，额外消耗 API Server 和网络/日志资源，并将失败开放延迟混入 Kueue/Volcano 性能结果。这不等价于旧独立集群，也不满足记录中“Admission 只处理 `bench-yunikorn`”的隔离语义。
- 建议：为 YuniKorn MutatingWebhookConfiguration 增加基于 `benchmark.scheduling/base=yunikorn` 的 Kubernetes `namespaceSelector`，并在安装脚本中以可重复方式固化；保留 YuniKorn 内部 regex 作为第二层防护。单独评估验证 ConfigMap 的 Webhook，若仅用于 `yunikorn/yunikorn-configs`，应按其真实目标命名空间缩小范围。验收应断言非 YuniKorn 命名空间不匹配该 Webhook，且对应 API Server 失败计数不再增长。

### 中：Kueue v0.19 在配置省略时开启了旧基线未启用的 WaitForPodsReady

- 位置：部署包 `manifests/kueue-manager-config.yaml:7-36`，旧基线 `schedulers/kueue/controller/controller_manager_config.yaml:25-33`；上游 v0.19.0 `apis/config/v1beta2/defaults.go:89-105` 及 `CHANGELOG/CHANGELOG-0.19.md:27,88-90`。
- 证据：当前 ConfigMap 没有 `waitForPodsReady` 或禁用它的 feature gate。Kueue v0.19.0 发布说明明确将 WaitForPodsReady 改为默认开启；默认化源码在字段缺失时创建配置，并设置 30 分钟 timeout/recovery timeout。旧 v0.10.3 基线没有启用该功能；因此简单省略字段在新版本中已不是等价配置。
- 影响：Kueue 会额外跟踪 PodsReady 状态，并在异常或慢 Pod 情况下应用新的超时、配额释放与重排语义。这是组件升级引入的性能/行为基线变化，目前既未显式批准，也未记录或测试。
- 建议：若目标是保持旧语义，使用 v0.19 支持的 `DisableWaitForPodsReady` feature gate 显式禁用；若要保留新默认，必须把它列为已批准的版本行为差异，补充对性能与超时语义的验收，不能将当前空缺配置记为旧基线等价。

### 低：部署记录混合了空闲态和测试态，两项审计描述与可重建状态不符

- Volcano：`CLUSTER_DEPLOYMENT_RECORD.md:198-201` 把 actions `enqueue, allocate, backfill, reclaim` 及 `priority/gang + predicates/capacity` 记为“调度器实际配置”。但实时空闲态及重复执行 `install-schedulers.sh` 后的 Helm 最终 ConfigMap 为 chart 默认：无 `reclaim`，并含 `conformance/overcommit/drf/proportion/nodeorder/binpack`，无 `capacity`。源码 `TestInit` 会在 Volcano 测试期间写入前一套配置，`down-volcano` 再恢复空闲快照；因此测试期间设计未丢失，但记录与安装脚本可重建的最终空闲态不一致。
- YuniKorn：`RESIDENT_CLUSTER_FULL_TEST_REPORT.md:233` 和 `CLUSTER_DEPLOYMENT_RECORD.md:497-503` 称旧基线“无额外吞吐参数/无对应 QPS 项”，但旧基线与当前 `test/yunikorn/init_queue.yaml:7-8` 都明确写有 `kubernetes.qps=1000`、`kubernetes.burst=1000`。当前测试配置没有丢失这两个值，故这是审计记录错误，不是运行回归。
- 建议：在部署记录中分开列出“安装/空闲基线”与“测试 TestInit 临时基线”，并让验证脚本分阶段断言对应配置；补全 YuniKorn QPS/Burst 审计项。

### 核对后未发现的其他回归

- 没有发现 Kubernetes v1.34.8、1000 个 KWOK Node、三个专用测试命名空间、常驻串行设计或 Volcano `benchmark-root` 被错误回退。
- Kueue v1beta2/cohortName、六类显式并发键和关闭 Leader Election 均被 v0.19.0 接受；实时启动日志证明 Job、Workload、LocalQueue、Cohort、ClusterQueue、ResourceFlavor 工作线程为 100。旧配置中未启用 Pod integration 的 `Pod: 100` 未被机械复制，这是正确的兼容性处理。
- Coscheduling Scheduler 的 `parallelism=16`、client `1000/1000`、Leader Election 关闭、Coscheduling MultiPoint/QueueSort 和 Permit `60s` 已生效；Controller worker `100` 已生效，但 QPS/Burst 受上述上游缺陷影响。
- Volcano 三个组件的 client `1000/1000`、Controller 三类 worker `100`、当前 Admission 集合、Webhook 命名空间隔离及测试期间的层级队列/插件设计有效。
- YuniKorn Scheduler/Admission 的 CPU-only 资源和移除 `GOMEMLIMIT`/`GOGC` 已生效；内部 process/bypass namespace regex 值正确，但不能替代上述 Kubernetes Webhook 级隔离。

结论：发现 3 个高严重度性能/隔离问题、1 个中严重度版本语义问题和 1 类低严重度记录错误。在上述高、中问题完成判断/修正并重验前，不应将被审提交记为“三套调度方案性能基线已正确恢复”。

### 主 Agent 处理结论与修订结果

| 评审项 | 结论 | 处理 |
| --- | --- | --- |
| Coscheduling Controller QPS/Burst | 部分事实接受，修复建议不接受 | v0.32.7 与 v0.34.7 官方源码在相同位置都把已修改的 `config` 丢弃并重新调用 `ctrl.GetConfigOrDie()`。旧基线参数也未实际改变限速，因此构建修复镜像会改变基线。保留相同参数和有效默认行为，修正文档，不改镜像。 |
| Controller Manager / 默认 Scheduler | 接受 | 恢复 Job 并发 `100`、控制面 CPU `1/8`、默认 Scheduler `1000/1000`，并固化到 Kind 配置、控制面基线脚本和验证脚本；保留已批准的 Controller Manager `5000/10000`。 |
| YuniKorn Webhook | 接受 | Mutating Webhook 限定到 `benchmark.scheduling/base=yunikorn`；Validating Webhook 限定到 `kubernetes.io/metadata.name=yunikorn`；安装和验证脚本已固化。 |
| Kueue WaitForPodsReady | 接受 | 设置 `DisableWaitForPodsReady=true`，新 Controller 已正常启动。 |
| Volcano/YuniKorn 记录 | 接受 | 区分空闲态与测试态，补记 YuniKorn 测试配置的 `1000/1000`。 |

修订应用后，Controller Manager、默认 Scheduler、Kueue 和 YuniKorn 相关对象均已滚动完成；基础集群、调度器和监控验证通过。控制面基线脚本完成无变更重复执行。完整调度器安装脚本首次复跑发现 Kueue field manager 冲突，增加 `--force-conflicts` 后再次从头执行成功，确认最终状态可以由部署包重复构建。

最终判断：评审中需要恢复的旧性能和隔离语义已修正；Coscheduling Controller 保持与旧版本相同的上游有效行为。可以在提交、推送并让服务器同步最终提交后进入场景 1。
