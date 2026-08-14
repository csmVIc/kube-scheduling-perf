# 背景

## 调度器版本

![image-20260814102915994](/Users/csmvic/Library/Application Support/typora-user-images/image-20260814102915994.png)

## 参数配置

统一了各组件客户端限流配置，QPS/Burst=1000/1000，尽量保证比较公平

## 数据收集方法优化

利用 **audit-exporter** 从 kube-apiserver 中收集信息并记录在 audit.log 来准确地记录具体性能。

使用经过版本优化过后的开源测试工具 **kube-scheduling-perf** 获得测试结果。

# 测试

## 测试cases

本次测试benchmark如下图，在10k总Pod量下，分别在启用/不启用**Gang** Scheduling的情况下，调整Job数量和每Job的Pod数量。

![image-20260814103140184](/Users/csmvic/Library/Application Support/typora-user-images/image-20260814103140184.png)

## 测试结果

> 说明，为了放大三个调度器在初始创建时的细节，可能会截断最慢的调度器，这是有意为之

## 非gang场景

### 场景1

10000个job，每个Job只有1个Pod，有以下现象：

![job-submission](/Users/csmvic/Downloads/volcano-versions/kube-scheduling-perf/results/scenario-1/job-submission.png)

- created和scheduled事件之间的差距很小，调度阶段不是主要瓶颈，此时性能**瓶颈为创建阶段**。

- **volcano整体调度耗时100s**

### 场景2

500个job，每个Job有20个Pod，有以下现象：

![job-submission](/Users/csmvic/Downloads/volcano-versions/kube-scheduling-perf/results/scenario-2/job-submission.png)

- Volcano的调度速度慢于另外两种调度器；
- **scheduled明显滞后于created**，说明调度速度较慢，此时性能**瓶颈为调度**；
- created阶段性突变现象（正常情况下created应该匀速增加，这里的现象说明controller会间歇性卡住一会儿）。可能的原因是Controller 分批处理，以及 create、Webhook 和 scheduler **共同竞争** API Server 导致。
  - Volcano 的 500 个 `Job` 由 Volcano Job Controller 创建；每个 Pod 需要经过 Volcano 的 mutating 和 validating 两个 admission webhook。同时 Volcano 在 Pod 创建尚未结束时，Scheduler 已开始为已创建的 Pod 调度。大量 `CREATE Pod`、Webhook 请求、`UPDATE Job/PodGroup` 和 调度器调度 同时冲击同一个 API Server/etcd，因此曲线出现停顿和分段突增。
  - Kueue 和 YuniKorn 都提交原生 `Job`，实际 Pod 由 Kubernetes Controller Manager 创建；Kueue 没有 Volcano 那套 Pod admission 链路，YuniKorn 的路径也更轻。
- **volcano调度整体耗时25s**

### 场景3

20个job，每个Job有500个Pod，有以下现象：

![job-submission](/Users/csmvic/Downloads/volcano-versions/kube-scheduling-perf/results/scenario-3/job-submission.png)

- Volcano的调度速度仍然慢于另外两种调度器；
- scheduled仍然明显滞后于created，说明调度速度较慢，此时性能**瓶颈为主要是调度器**。
- volcano整体调度耗时20s

### 场景4

只有1个job，每个Job有10000个Pod，有以下现象：

![job-submission](/Users/csmvic/Downloads/volcano-versions/kube-scheduling-perf/results/scenario-4/job-submission.png)

- Volcano调度速度略快于另外两组调度器；
- scheduled仍然明显滞后于created，说明调度速度较慢，此时性能瓶颈为主要是调度器。
- **volcano整体调度耗时接近20s**

#### 总结

1. 整体耗时大致呈现 pod总数一定的情况下，job数量越少，调度越快的趋势；Volcano 的总调度时间基本与 Job 数量成正比，说明其性能**瓶颈主要由 Job 导致**。
2. 当job数量越少，也就是job包含的pod数量越多，此时，scheduled会呈现明显滞后于created的情况，说明此时整体的**性能瓶颈在调度器**。（如图场景2-场景4）

## gang场景

### 场景5

10000个job，每个Job只有1个Pod，有以下现象：

![job-submission](/Users/csmvic/Downloads/volcano-versions/kube-scheduling-perf/results/scenario-5/job-submission.png)

- 和场景1类似，created和scheduled曲线重合，说明调度阶段不为瓶颈，此时**性能瓶颈为创建阶段**。
- **volcano整体调度耗时接近100s**，和场景1耗时接近

### 场景6

500个job，每个Job有20个Pod，有以下现象：

![job-submission](/Users/csmvic/Downloads/volcano-versions/kube-scheduling-perf/results/scenario-6/job-submission.png)

![job-submission](/Users/csmvic/Downloads/volcano-versions/kube-scheduling-perf/results/scenario-2/job-submission.png)

- kueue、yunikorn和场景二的曲线几乎保持一致；不同的是**volcano调度速度明显变快**，从场景2的明显落后于另外两组调度器，到领先另外两组调度器；值得注意的是，**volcano在gang场景下创建pod的速度也变快了**。gang 并未直接优化 Pod 创建逻辑，分析可能的原因是调度请求更加批次化，**减少了与controller争用api-server的情况**，因此间接提高了创建吞吐量。
- **volcano整体调度耗时20s**，和场景2耗时接近

### 场景7🌟

20个job，每个Job有500个Pod，有以下现象：

![job-submission](/Users/csmvic/Downloads/volcano-versions/kube-scheduling-perf/results/scenario-7/job-submission.png)

![job-submission](/Users/csmvic/Downloads/volcano-versions/kube-scheduling-perf/results/scenario-3/job-submission.png)

- 整体created创建曲线和场景3类似，但是除volcano外，**另外两组调度器在gang场景下明显更慢**，yunikorn甚至直接超出画面；相反，**volcano在两种场景下调度速度接近**，因此能够超过kueue、yunikorn。
- **volcano整体调度耗时接近30s**
  - 没有满足job越少，调度时间越短的的情况；可以看到，开始阶段scheduled的pod出现的很晚，推测原因可能是单个 Gang 较大，Scheduler 需要等待整组 Pod 准备并完成整体资源判断所花费较长时间；
  - volcano调度曲线 19:56:35 - 19:56:40所出现的**5s长阶梯**，可能和场景二的原因类似，创建阶段 Controller 分批处理、Webhook等 与 scheduler调度共同竞争 API Server所导致。

### 场景8 🌟

只有1个job，每个Job有10000个Pod，有以下现象：

![job-submission](/Users/csmvic/Downloads/volcano-versions/kube-scheduling-perf/results/scenario-8/job-submission.png)

- created创建曲线和场景4类似，不过由于volcano调度器在gang场景下的优势，10000个pod全部被调度成功的速度最快
- volcano整体调度耗时接近45s

#### 总结

- Gang 场景是 Volcano 的优势场景。场景 5–8 中 Volcano 均较快，尤其场景 6–8 优势明显。

- 场景 7、8 不能简单套用“Job 越少越快”。这可能是因为单个 Gang 越大，Scheduler 越需要等待整组 Pod 准备并完成整体资源判断，因此 `minMember=500/10000` 会增加组就绪和批量绑定开销。

## 最终结果

在所测试八个场景下，volcano表现较好，有其中5个场景（4 ~ 8）volcano是调度速度更快的那个，并且场景1三组调度器的调度速度几乎持平；但在非gang场景下