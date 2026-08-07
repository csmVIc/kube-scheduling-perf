# `WaitDeployment` 函数分析

位置：`test/utils/utils.go`

```go
func WaitDeployment(ctx context.Context, r *resources.Resources, namespace string) error
```

## 作用

该函数用于等待一次调度压测结束。它每 10 秒查询一次指定命名空间中带有 `test-instance=1` 标签的 Pod；查不到任何匹配 Pod 时返回成功，最长等待 1 小时。

函数名容易产生误解：它不查询或等待 Kubernetes Deployment，而是在等待测试 Pod 被删除。

## 参数与返回值

- `ctx`：控制 Kubernetes API 请求的生命周期；调用方取消上下文时，请求会终止。
- `r`：已配置的 e2e-framework Kubernetes 资源客户端。
- `namespace`：只检查该命名空间，避免其他调度器的测试 Pod 或历史资源干扰结果。
- 返回 `nil`：当前查询已不存在匹配的测试 Pod。
- 返回错误：客户端创建失败、Pod 查询失败、上下文取消，或等待超过 1 小时。

## 执行过程

1. 从 `r` 取得 Kubernetes REST 配置，创建一个新的资源客户端。这样可以单独设置命名空间，不会修改调用方共享的 `r`。
2. 调用 `WithNamespace(namespace)`，把后续 Pod 查询限制在目标测试命名空间。
3. 使用标签选择器 `test-instance == 1` 查询测试 Pod。
4. 设置 `Limit=1`，因为这里只需判断“是否至少存在一个”，无需返回全部 Pod，可降低 API Server 的响应开销。
5. 如果查询结果仍包含 Pod，返回 `false`，10 秒后继续查询。由于没有设置 `wait.WithImmediate()`，第一次查询也会在等待 10 秒后执行。
6. 如果结果为空，返回 `true`，结束等待并返回 `nil`。
7. 整体等待时间超过 1 小时则返回超时错误。

等价逻辑如下：

```text
每 10 秒查询一次指定 namespace
  ├─ 查询出错：立即返回错误
  ├─ 找到测试 Pod：继续等待
  └─ 未找到测试 Pod：返回成功
最长等待 1 小时
```

## 在测试流程中的位置

`TestBatchJob` 先通过 `AddJobs` 创建压测任务，再调用此函数：

- Kueue：检查 `bench-kueue`
- Volcano：检查 `bench-volcano`
- YuniKorn：检查 `bench-yunikorn`

三个任务模板都会给 Pod 添加 `test-instance: "1"`。任务结束后，`ttlSecondsAfterFinished: 1` 触发任务及其 Pod 清理；该函数以这些 Pod 全部消失作为压测结束信号。

## 注意事项

- 函数只判断 Pod 是否存在，不检查任务是否成功。Pod 因失败或被人工删除而消失时，也会被视为完成。
- 存在启动竞态：`AddJobs` 返回后，控制器可能尚未创建 Pod；如果第一次查询结果为空，函数会立即成功。更稳妥的实现应先确认至少观察到一个匹配 Pod，再等待其数量归零，或直接检查 Job/Volcano Job 的完成状态。
- `Limit=1` 只能判断是否还有 Pod，不能用于统计剩余数量或展示进度。
- 回调参数中的 `context.Context` 没有被使用，查询实际使用的是外层 `ctx`。这不影响普通轮询，但 API 请求本身由调用方上下文而非轮询器内部上下文控制。
