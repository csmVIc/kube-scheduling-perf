---
name: run-full-integrity-test
description: Run one complete eight-scenario kube-scheduling-perf benchmark on the resident server cluster, restore the idle baseline with make down, and publish the generated results with a timestamped full_test_report_MMDDHH.md in one commit. Use when the user asks to run a complete/full/integrity benchmark test or generate its report.
---

# Run Full Integrity Test

## Environment

- Local repository: `/Users/csmvic/Downloads/volcano-versions/kube-scheduling-perf`
- Server repository: `/root/github/kube-scheduling-perf`
- Read `CLUSTER_DEPLOYMENT_RECORD.md` before operating the cluster.
- Use `$volcano-benchmark-server` from `.codex/skills/volcano-benchmark-server/` to connect, and do not expose credentials, kubeconfig contents, Secrets, or tokens.

## 1. Prepare

1. Require the local repository to be on `master`, clean, and fully pushed to `origin/master`.
2. Require the server repository to have no tracked changes, then fast-forward it to `origin/master`.
3. Record the CST start time immediately before creating the server session.
4. Name the report `full_test_report_MMDDHH.md` using the start month, day, and hour. Example: `2026-08-12 09:23:10` becomes `full_test_report_081209.md`.
5. If that report name already exists, append the first available numeric suffix: `_2`, `_3`, and so on. Never overwrite an existing report.
6. Create a unique temporary working directory under `/tmp/` and a unique `tmux` session name using the full start timestamp.

## 2. Execute

Copy this Skill's `scripts/run-full-test.sh` into the temporary working directory, mark it executable, and launch that copy in a detached `tmux` session. Pass the server repository and temporary working directory as arguments.

The wrapper performs the following work:

- Runs one top-level `make` and saves a CST-timestamped console log.
- Saves the tested Commit and the start/end times.
- Records result manifests before and after the run.
- Preserves the `make` exit code.
- Runs `make down` after `make` finishes, including when `make` fails, and saves its exit code.
- Writes a completion marker.

Monitor the completion marker so an SSH or network interruption does not interrupt or restart the test. If the wrapper terminates without a completion marker and no test process remains, run one manual `make down`, record the recovery, and end the run without restarting the full test.

## 3. Evaluate

Use the temporary logs, exit-code files, result manifests, and `results/scenario-N` metadata. A run passes only when:

- `make` exits `0`.
- `24/24` `TestBatchJob` cases pass with no failures or timeouts.
- All eight scenario directories are updated and contain `envs.txt` and `result-window.txt`.
- `make down` exits `0` and all experiment resources are removed.
- All scheduler components and Audit Exporter return to the fixed one-replica idle baseline.

A missing or failed `job-submission.png` is recorded but does not fail an otherwise successful test.

Derive each scenario's CST boundary from the timestamped start of its `make serial-test` command to the next scenario boundary, using the end of top-level `make` for scenario 8. Read the exact metric window from its `result-window.txt`.

## 4. Create the report

Create the report in the server repository root with exactly these sections:

```markdown
# 完整性测试报告（通过或失败）

## 1. 执行概要

## 2. 八个场景的时间边界与结果目录

## 3. 问题说明

## 4. 最终结论
```

### 执行概要

Record the tested Commit, command, `tmux` session, CST start/end in `YYYY-MM-DD HH:mm:ss`, precise duration, both exit codes, passed Case count, updated scenario count, and overall status.

### 八个场景的时间边界与结果目录

Use this table:

| 场景 | 模式与参数 | CST（UTC+8）时间边界 | 耗时 | 指标时间窗（毫秒） | 结果目录 | 结果 |

Use `YYYY-MM-DD HH:mm:ss` timestamps. Mark scenarios not produced by the current run as `未执行` or `未更新`.

### 问题说明

If no issue occurred, state that no problem affecting the conclusion was found. Otherwise record the symptom, supported direct cause, impact, and evidence location. Distinguish non-blocking image failures from test failures. Leave source repair or another full run for a separate user request.

### 最终结论

State `通过` or `失败` and summarize the eight scenarios, 24 Cases, and idle-baseline restoration.

## 5. Publish and clean up

After creating the report:

1. Run `git add -A -- results <current-report-name>`.
2. Confirm every staged path is under `results/` or is the current report.
3. Commit both as `results: full test MMDDHH` and push `master`.
4. Fast-forward the local repository.
5. Delete the server temporary working directory after its evidence has been incorporated into the report.

## 6. Return

Return the overall result, report path, combined publication commit, and any non-blocking anomaly.
