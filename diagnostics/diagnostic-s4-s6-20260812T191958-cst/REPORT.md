# 场景 4、6 重复性诊断报告

## 1. 执行概要

- 被测 Commit：`e18a931df71bc0d88e603a69a932209ddb6037fe`
- 执行时间：2026-08-12 19:20:25 至 19:41:55 CST
- 场景 4（非 Gang，1 Job × 10000 Pods）和场景 6（Gang，500 Jobs × 20 Pods）各执行两轮。
- 三套调度器共 12 个 `TestBatchJob`，全部通过；结束后 `make down` 成功。
- 每个调度器分别保存原始 API Server 审计日志、相关控制面与调度组件日志、100ms Prometheus 序列以及精确时间窗。

## 2. 结论

曲线差异的主要原因已经定位：Benchmark 工作负载本身的实际执行较稳定；不稳定的是 Audit Exporter 对稀疏审计文件的读取时间。

`reset-audit-exporter` 使用 shell 重定向清空 Kind 控制面容器中的审计文件。API Server 仍持有原文件描述符和旧偏移量，下一次写入从旧偏移继续，文件开头形成巨大的 NUL 空洞。Exporter 必须先扫描空洞，随后才集中处理真正的审计事件，因此 Prometheus 中的 Created/Scheduled 曲线会被人为压缩、延迟或改变形状。

在本次实验中，场景 4 第一轮至场景 6 第一轮 Volcano 的 NUL 前缀从约 7.95GB 增至 10.09GB；随后审计文件发生轮转，场景 6 第一轮 YuniKorn 的前缀变为 0，后续又从约 0.42GB 增长。曲线变化点与这一轮转边界吻合。

## 3. 关键证据

### 3.1 原始审计事件较稳定

场景 4 两轮真实 Pod binding 用时：

| 调度器 | 第 1 轮 | 第 2 轮 |
| --- | ---: | ---: |
| Kueue | 19.916s | 19.702s |
| Volcano | 16.803s | 17.391s |
| YuniKorn | 18.196s | 18.091s |

场景 6 两轮真实 Pod binding 用时：

| 调度器 | 第 1 轮 | 第 2 轮 |
| --- | ---: | ---: |
| Kueue | 50.927s | 49.723s |
| Volcano | 18.027s | 19.010s |
| YuniKorn | 50.650s* | 78.414s |

`*` 第一轮 YuniKorn 保存的审计文件开始于轮转后，缺少最早一部分 Job/placeholder 事件，因此不能与第二轮作完整等价比较；实际工作 Pod 的 Prometheus Scheduled 达到 10000 分别为 9.1s 和 73.3s，恰好说明轮转会改变 Exporter 看到事件的节奏。

### 3.2 Prometheus 曲线与真实审计时序不一致

场景 4 Kueue 的原始 binding 用时约 20s，但 Prometheus 两轮都显示约 1.7s。场景 6 Kueue 原始 binding 两轮分别约 50.9s 和 49.7s，Prometheus 却分别显示 3.3s 和 49.0s。调度器实际性能没有发生同等幅度变化，差异来自采集链路。

完整数值见 `audit-timing.tsv`、`prometheus-timing.tsv` 和 `audit-nul-prefix.tsv`。

## 4. 对 Benchmark 的判断

- 工作负载创建、控制器处理和调度器执行没有发现能够解释原图片巨大差异的设计错误。
- 当前 Dashboard 数据不适合用于稳定排名，因为重置审计日志的方法破坏了 Exporter 的实时性。
- 需要先修复审计文件重置方式，再重新验证曲线重复性。推荐让 API Server 自己重新打开文件，或用文件轮转/替换方式生成真正从偏移 0 开始的新文件；不能继续只对已打开文件执行截断。
- 在该问题修复前，即使增加完整测试轮数，也只会继续采集受空洞扫描影响的数据。

## 5. 数据说明

- `scenario-*/round-*/<scheduler>/kube-apiserver-audit.jsonl.zst`：原始审计日志；由于已知的稀疏文件问题，解压后的逻辑大小可达数 GB，但压缩文件最大约 14.8MB。
- `*.log.zst`：Audit Exporter、API Server、etcd、controller-manager 及相关调度组件日志。
- `prometheus-*.json.gz`：100ms 查询步长的原始指标响应。
- `window.txt`：单调度器采集时间窗。
- `files.tsv`、`SHA256SUMS`：文件索引与校验值。
