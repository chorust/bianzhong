---
id: local-test-failure
enabled: true
description: 监听本地测试或 CI 失败信号，只读定位根因并给出修复补丁方案，批准后在独立 Worktree 执行

match:
  type: ["dev.bianzhong.ci.failed", "dev.bianzhong.test.failed"]
  keywords_any: []
  exclude_keywords: []

funnel:
  dedup_ttl: 300s
  debounce: 5s
  max_wait: 20s
  cooldown: 10m
  defer_on_focus: false
  triage:
    enabled: false
    provider: none

session:
  policy: threaded
  ttl: 24h

execution:
  autonomy: draft_approve
  driver: codex
  model: null
  working_dir: ~/data/code/github/bianzhong
  worktree_on_phase2: true
  preflight_cmd: "git status -s 2>/dev/null || true"
  phase1_max_time_sec: 180
  phase1_max_cost_usd: 0.25
  phase2_max_time_sec: 600
  phase2_max_cost_usd: 1.00

on_complete:
  - type: notify
  - type: chime_sound
    name: Glass
---

## Phase 1
本地测试或 CI 触发失败。当前处于**只读勘察阶段**，请勿修改文件：
1. 读取 `$BIANZHONG_EVENT_FILE` 获取失败模块与错误摘要。
2. 定位根因并列出拟修改文件清单、修复思路与风险等级（low/medium/high）。

## Phase 2
人类已批准执行修复，附加意见：{{approval.user_comment}}
请在当前隔离 Worktree 中完成最小修复并重新运行受影响测试验证通过，输出修改摘要与测试结果。
