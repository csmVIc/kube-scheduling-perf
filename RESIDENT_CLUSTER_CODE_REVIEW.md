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
