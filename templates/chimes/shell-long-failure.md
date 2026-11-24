---
id: shell-long-failure
enabled: true
description: 监听终端耗时超过 15 秒且失败的命令，自动在原工作目录只读排查失败原因

match:
  type: ["dev.bianzhong.shell.command_failed"]
  source: ["bz://sensor/shell/zsh"]
  keywords_any: []
  exclude_keywords: []

funnel:
  dedup_ttl: 120s
  debounce: 3s
  max_wait: 10s
  cooldown: 5m
  defer_on_focus: false
  triage:
    enabled: false
    provider: none

session:
  policy: threaded
  ttl: 12h

execution:
  autonomy: draft_approve
  driver: omp
  model: null
  working_dir: $payload.cwd
  worktree_on_phase2: true
  preflight_cmd: "git status -s 2>/dev/null || true"
  phase1_max_time_sec: 120
  phase1_max_cost_usd: 0.20
  phase2_max_time_sec: 480
  phase2_max_cost_usd: 0.80

on_complete:
  - type: notify
---

## Phase 1
一条长时间运行的终端命令刚刚以非零状态退出。当前处于**只读勘察阶段**，请勿修改文件：
1. 读取 `$BIANZHONG_EVENT_FILE` 中的命令文本、退出码、工作目录与预取的 Git 状态。
2. 在当前工作目录检查相关构建配置/代码/最近变更，给出失败根因与建议修复命令或补丁方案。

## Phase 2
人类已批准修复，附加意见：{{approval.user_comment}}
请在隔离 Worktree 中实施修复并复跑失败的命令验证通过。
