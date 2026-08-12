---
name: volcano-benchmark-server
description: Connect over SSH to the Volcano kube-scheduling-perf benchmark server defined by BENCHMARK_SERVER. Use when a task requires logging in to the benchmark server or performing user-authorized remote benchmark, cluster, repository, monitoring, or diagnostic work there.
---

# Volcano Benchmark Server

## Connect

Provide the connection through the process environment:

- `BENCHMARK_SERVER`: SSH host or address.
- `BENCHMARK_SERVER_SECRET`: SSH password.
- `BENCHMARK_SERVER_USER`: optional SSH user; defaults to `root`.

Run from the repository root:

```bash
bash .codex/skills/volcano-benchmark-server/scripts/ssh-login.sh
```

The script opens an interactive SSH shell using the configured server. If the variables are absent from the current process, it reloads `~/.zshrc` once before validating them. Keep the session open while completing the authorized remote work, then exit with `exit` or Ctrl-D.

## Rules

- If the user asks only to log in, establish the session and wait.
- When the current request includes remote work, execute only that authorized scope after connecting.
- Never print the password or derived credential variables in chat, commands, logs, or reports.
- Do not display kubeconfig contents, Kubernetes Secrets, tokens, or passwords.
- Use non-interactive remote commands where practical; allocate a PTY for interactive shells or long-running session management.
- Treat SSH/network interruption separately from the remote process state. Reconnect and inspect existing work before deciding whether to rerun anything.

## Implementation

- The login script reads credentials only from the process environment, optionally reloading `~/.zshrc` once, and fails when required variables remain missing.
- It uses `expect` only for initial password authentication, creates a temporary SSH control socket, and enables keepalive checks.
- Host keys use `StrictHostKeyChecking=accept-new`; an existing changed host key still fails closed.
