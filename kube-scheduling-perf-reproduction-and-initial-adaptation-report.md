# kube-scheduling-perf 复现与第一版适配报告

更新日期：2026-07-31

## 1. 最终结论

本项目已完成公开源码基线复现、故障定位、第一版兼容修改和八场景正式验证。

- Go 构建环境升级至 1.25。
- scheduler-plugins 从 v0.29.7 升至匹配 Kubernetes 1.32 的 v0.32.7。
- Volcano v1.11.0 源清单保持 `QPS/Burst=1000/1000`；仅在大单 Job 场景运行时把 controller 调为 `100/200`。
- 8 个场景、3 个调度器共 24 个用例全部通过审计终态校验。
- 代码已提交并推送至 `origin/master`：`87289e76430fd3252d26e75fcf80cc474ea3760b`。
- 服务器临时环境已清理，常驻集群恢复为 5001/5001 Node Ready、19/19 Pod Running。

这是一版有明确适配边界的可运行复现，不能表述为对 KubeCon 演示环境和性能的精确复刻。

> 重要：分场景 Volcano QPS/Burst 策略没有写入源码。直接执行裸 `make` 不会自动得到本次正式结果。

## 2. 任务内容

1. 适配 Go 与 scheduler-plugins 版本。
2. 定位 Volcano 大单 Job 超时根因并验证方案。
3. 完成八场景正式实验、结果核验和代码提交。

最终正式环境：

| 项目 | 配置 |
|---|---|
| Kubernetes | v1.32.2 |
| Kueue | v0.10.3 |
| scheduler-plugins | v0.32.7 |
| Volcano | v1.11.0 |
| Go 构建镜像 | golang:1.25 |
| 虚拟节点 | 1000 个 KWOK Node |
| 单场景工作负载 | 10000 个 Pod |
| 组件 CPU 上限 | 8 |
| Kind TCP 参数 | 默认端口范围 `32768–60999`，`tcp_fin_timeout=60` |

## 3. 第一版源码改动

提交 `87289e7` 只修改了 4 个文件：

| 文件 | 改动 |
|---|---|
| `Makefile` | Go 镜像从 1.24 升至 1.25，与 `go.mod` 一致 |
| `scheduler-plugins-controller/deployment.yaml` | controller 从 v0.29.7 升至 v0.32.7 |
| `scheduler/deployment.yaml` | scheduler 升至 v0.32.7，入口改为 `/bin/kube-scheduler` |
| `scheduler-plugins-scheduler_clusterrole.yaml` | 增加 `volumeattachments.storage.k8s.io` 读取权限 |

Volcano 清单没有源码差异，仍保留作者的 `1000/1000`。正式运行时采用：

| 场景 | Job × Pod/Job | Gang | Volcano controller QPS/Burst |
|---:|---:|:---:|---:|
| 1 | 10000 × 1 | false | 1000/1000 |
| 2 | 500 × 20 | false | 1000/1000 |
| 3 | 20 × 500 | false | 100/200 |
| 4 | 1 × 10000 | false | 100/200 |
| 5 | 10000 × 1 | true | 1000/1000 |
| 6 | 500 × 20 | true | 1000/1000 |
| 7 | 20 × 500 | true | 100/200 |
| 8 | 1 × 10000 | true | 100/200 |

只有 `volcano-controllers` 被运行时调整；admission 和 scheduler 始终保持 `1000/1000`。

## 4. 关键问题与诊断结论

### 4.1 Go 版本

`go.mod` 要求 Go 1.25，上游 Makefile 使用 Go 1.24，测试程序无法稳定构建。升级默认构建镜像后，Kueue、Volcano、YuniKorn 三个测试二进制均构建成功。

### 4.2 Kueue Gang 吞吐问题

scheduler-plugins v0.29.7 基于 Kubernetes 1.29，与集群的 Kubernetes 1.32.2 不匹配。降低 QPS/Burst 没有改善吞吐：

| 配置 | 1000 × 1 Gang 结果 |
|---|---|
| v0.29.7，1000/1000 | 180 秒仅完成约 265/1000 |
| v0.29.7，controller 100/200 | 约 246/1000 |
| v0.29.7，controller 与 scheduler 100/200 | 约 233/1000 |
| v0.32.7，1000/1000 | 29 秒完成 1000/1000 |

失败对照没有 API 429/5xx，也没有组件 CPU throttling。结论是版本与调度实现路径问题，不是 Volcano 式的请求风暴；第一版因此采用 v0.32.7。

### 4.3 Volcano 大单 Job 超时

两次基线正式运行都只有场景 3、4、7、8 超时。四个场景横跨 Gang 与非 Gang，唯一共同点是单个 Job 含 500 或 10000 个 Pod。

Volcano v1.11 controller 会高并发展开同一 Job 的缺失 Pod；每个 Pod 又同步进入 Volcano admission 并回查 Kubernetes API。大单 Job 因而形成 Pod Create 与 webhook 请求放大，最终出现：

- admission webhook `context deadline exceeded`；
- 临时端口耗尽或大量 `FIN-WAIT-2`；
- admission 大量 `CLOSE-WAIT` 与文件描述符积压；
- Pod 展开停止，Job 无法完成。

关键对照：

| 对照 | 场景 7 结果 |
|---|---|
| 上游配置，8 CPU | 超时 |
| 扩大端口范围 | 仍超时，错误转为 webhook timeout |
| 提高至 16 CPU | 只创建约 1037/10000 Pod，仍超时 |
| `tcp_fin_timeout=15` | 只创建约 1356/10000 Pod，仍超时 |
| Volcano v1.15.1 | 被新版 `root` Queue 约束阻塞，未进入批量测试 |
| v1.11 controller 100/200 | 140.15 秒完成 20/20 Job、10000 Pod |

`100/200` 通过时 admission `CLOSE-WAIT`、controller `FIN-WAIT-2` 和 CPU throttling 均降为 0，强支持“入口背压消除请求风暴”的判断。

但全局使用 `100/200` 会使大量小 Job 场景吞吐不足：场景 1 在 350 秒内只完成 1629/10000 Job。因此最终采用按 Pod/Job 形状拆分的策略，而不是全局改低 QPS。

## 5. 正式实验结果

正式运行时间：2026-07-31 18:33:39 至 20:40:00（CST）。

| 场景 | Kueue | Volcano | YuniKorn | 结果目录 |
|---:|:---:|:---:|:---:|---|
| 1 | 通过 | 通过 | 通过 | `v1-split-20260731-s1-1785495021` |
| 2 | 通过 | 通过 | 通过 | `v1-split-20260731-s2-1785495655` |
| 3 | 通过 | 通过 | 通过 | `v1-split-20260731-s3-1785496305` |
| 4 | 通过 | 通过 | 通过 | `v1-split-20260731-s4-1785497025` |
| 5 | 通过 | 通过 | 通过 | `v1-split-20260731-s5-1785498262` |
| 6 | 通过 | 通过 | 通过 | `v1-split-20260731-s6-1785499257` |
| 7 | 通过 | 通过 | 通过 | `v1-split-20260731-s7-1785500318` |
| 8 | 通过 | 通过 | 通过 | `v1-split-20260731-s8-1785501589` |

每个用例必须同时满足：

- 初始化和批量测试返回 0；
- 预期 Job 全部完成，Failed Job 为 0；
- 唯一 Job 数精确；
- 唯一工作负载 Pod 数精确为 10000。

### YuniKorn Gang 统计说明

原始运行器把 4 个 YuniKorn Gang 用例标为 `FAIL`，原因是把 10000 个 `tg-*` placeholder 与 10000 个 `yunikorn-job-*` 工作负载 Pod 相加后，直接和预期工作负载 Pod 数比较。

独立审计复核确认每组均为：

- 10000 个工作负载 Pod；
- 10000 个预期 placeholder；
- 0 个未知 Pod；
- Job 全部完成，Failed 为 0。

因此这是校验口径误判，不是实验失败。原始汇总未被覆盖，最终结论为 24 PASS、0 FAIL。

### Grafana 与日志

- 8 个场景各导出 8 张 Grafana PNG，共 64 张，均验证非空。
- 每个场景保存 3 份压缩 apiserver audit log，共 24 份，全部通过 `gzip -t`。
- 实验结束后临时 `overview` 集群已删除，因此目前保留的是静态图片；若下次暂不删除 `overview`，可以通过 SSH 隧道在线查看 Grafana。

## 6. 与源作者结果的差异

KubeCon Europe 2025 的四张 Gang 场景图显示三种调度器均到达目标值，说明作者环境确实完成过这些负载形状。图中也能看到 YuniKorn placeholder 导致创建曲线达到约 20000。

但公开材料没有给出精确 commit、镜像 digest、硬件、内核、Docker 和全部启动参数。公开仓库首次提交时已经同时使用 Kubernetes v1.32.2 与 scheduler-plugins v0.29.7，不存在可见的“后来升级 Kubernetes 却忘记更新插件”提交记录；匹配的 v0.32.7 正式版又晚于演讲发布。

因此作者可能使用更强的控制面环境、未公开开发镜像或不同清单，现有证据无法区分。CPU 性能可能影响临界点，但本次 8→16 CPU 仍失败、仅降低 Volcano controller QPS 即通过，说明不能把差异简单归因于 CPU。

参考资料：

- [KubeCon Europe 2025 演讲](https://www.youtube.com/watch?v=njT5r3JjIaA)
- [scheduler-plugins 兼容矩阵](https://github.com/kubernetes-sigs/scheduler-plugins#compatibility-matrix)
- [Volcano 官方收录的独立性能调优复现](https://volcano.sh/docs/v1.13.0/userguide/user_guide_how_to_tune_volcano_performance/)

## 7. 运行流程与已知风险

裸 `make` 会依次执行 8 个场景；每个场景分别创建 Kueue、Volcano、YuniKorn 临时 Kind 集群，运行 1000 个 KWOK 虚拟节点和 10000 Pod，然后创建 `overview` 集群回放 audit log 并导出 Grafana 图片。

一次完整运行包含 24 次调度器测试和 8 次 overview 汇总。这里的 1000 个节点是 KWOK 虚拟 Node，不是 1000 个 Docker worker 容器。

当前仍需注意：

1. 顶层 Makefile 使用分号串联子命令，可能掩盖中间测试失败。
2. 原测试只等待工作负载 Pod 消失，初始化失败时可能产生“零 Pod 假通过”。
3. Kueue Deployment 更新存在 webhook rollout 竞态；正式实验使用过临时 kubectl guard，但未写入源码。
4. Volcano 分场景 QPS 策略只记录在提交说明和本文，裸 `make` 不会自动应用。
5. 正式验收必须独立核对 Job Complete、Failed 和唯一 Pod 数，不能只看顶层退出码或曲线。

## 8. 证据位置与当前状态

服务器正式汇总：

```text
/root/kube-perf-v1-20260731/formal-split/formal-summary.raw.tsv
/root/kube-perf-v1-20260731/formal-split/formal-summary.validated.tsv
/root/kube-perf-v1-20260731/formal-split/formal-validation.txt
```

正式结果目录：

```text
/root/github/kube-scheduling-perf/results/v1-split-20260731-s1-1785495021
...
/root/github/kube-scheduling-perf/results/v1-split-20260731-s8-1785501589
```

其他对照证据：

```text
/root/kube-perf-v1-20260731/formal/        # 全局 100/200 的失败尝试
/root/kube-perf-v1-20260731/tuning/        # 300/600 边界测试
/root/kube-perf-rerun-20260730/            # 基线与早期定向诊断
```

最终服务器状态：

- 远端 commit：`87289e76430fd3252d26e75fcf80cc474ea3760b`；tracked 工作区干净。
- 无 Kueue、Volcano、YuniKorn、overview 临时集群，无隔离状态。
- 临时运行器、校验脚本和 kubectl guard 均已移除。
- 常驻 `volcano-benchmark-control-plane` Running。
- 5001/5001 Node Ready，19/19 Pod Running。

除非重新明确实验目标，本轮复现不再继续 Volcano v1.15.1 适配、webhook timeout 对照或额外参数搜索。
