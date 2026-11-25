# Bianzhong 规则共创指南 (AGENTS.md)

你正在帮助用户在 `~/.config/bianzhong/` 中创建、修改或调试 **Bianzhong（编钟）** 的事件驱动规则（`chimes/*.md`）与全局配置（`config.yml`）。

## 目录结构
- `config.yml`: 全局分诊器（`triage.provider`: `apple_fm` | `agent_cli` | `decision_api` | `none`）、治理上限（`governance.*`）、默认终端与候选工作区。
- `chimes/*.md`: 每条触发规则是一个独立的 Markdown 文件（YAML Frontmatter + `## Phase 1` / `## Phase 2` 行动剧本）。

## Chime 规则格式规范
```markdown
---
id: unique-rule-id
enabled: true
description: 一句话描述（L1 分诊也会参考此说明）

match:
  type: ["dev.bianzhong.feishu.notification"]   # 支持 * 通配符，如 dev.bianzhong.*
  source: ["bz://sensor/feishu"]               # 留空匹配所有 source
  title_equals: ["支付研发群"]                  # 精确匹配标题/群名（可与下方字段 AND 组合）
  title_any: ["研发", "告警"]                   # 标题包含任一词（也支持 title_all / title_exclude）
  subtitle_any: ["机器人"]                      # 发送者匹配（也支持 subtitle_equals / subtitle_all / subtitle_exclude）
  body_any: ["报错", "500"]                     # 正文包含任一词
  body_all: ["退款"]                            # 正文必须同时包含全部词（AND；也支持 body_exclude）
  keywords_any: ["报错", "500", "@"]            # 全文任一命中即匹配（留空表示不限关键词）
  keywords_all: ["线上"]                        # 全文必须同时包含全部词（AND）
  exclude_keywords: ["收到", "辛苦", "团建"]    # 命中任意词则直接拦截

funnel:
  dedup_ttl: 300s
  debounce: 8s                                 # 连珠炮消息合并窗口
  max_wait: 30s
  cooldown: 15m
  min_count: 1                                 # 设为 N (>1) 表示在 window 内累计命中第 N 次才触发
  window: daily                                # 累计计数窗口：daily | 30m | 1h | 6h | 24h | 7d
  count_scope: rule                            # rule（按规则计数）| correlation（按群/会话分别计数）
  count_reset_on_trigger: true                 # 触发后清零重新计数
  defer_on_focus: true                         # 专注/锁屏时自动转入 Wake Digest 晨钟摘要
  triage:
    enabled: true
    provider: apple_fm                         # apple_fm | agent_cli | decision_api | none

# 可选：预期时间窗口看门狗（在指定窗口内未收到匹配 match 的消息，则在窗口结束后自动拉起动作/Agent）
# expect:
#   enabled: true
#   window: "09:00-09:30"                      # 或分别写 window_start / window_end (HH:mm)
#   weekdays: ["mon", "tue", "wed", "thu", "fri"]
#   suppress_on_match: true                    # 窗口内正常收到匹配消息时仅记为“已如期收到”，不触发告警
#   grace_seconds: 0

session:
  policy: threaded                             # ephemeral | threaded | rolling_daily
  ttl: 24h

execution:
  autonomy: draft_approve                      # observe_digest | notify | draft_approve | bounded_auto
  driver: omp                                  # omp | codex | none (纯动作不拉大模型)
  model: null
  working_dir: ~/path/to/repo                  # 支持 $payload.cwd 动态跟随触发目录
  worktree_on_phase2: true
  preflight_cmd: "git status -s 2>/dev/null || true"
  preflight_timeout_sec: 10
  phase1_max_time_sec: 180
  phase1_max_cost_usd: 0.25
  phase2_max_time_sec: 600
  phase2_max_cost_usd: 1.00

on_complete:
  - type: notify
  - type: webhook
    url_env: BIANZHONG_WEBHOOK_URL
    when: "screen_locked == true || idle_seconds > 600"
  - type: append_markdown
    path: "~/Notes/Bianzhong/{{date}}.md"
  - type: shortcut
    name: "Bianzhong Add Reminder"
    when: "kind == 'todo'"
---

## Phase 1
这里写只读勘察与拟稿阶段的具体指令（不可写文件，只能读取源码/日志并给出结论）。

## Phase 2
人类批准后执行阶段的具体指令（可引用 {{approval.user_comment}} 获取审批附言）。
```

## 支持的后置动作 (`on_complete`)
- `notify`: 弹出系统交互通知并写入 MenuBar 听音台
- `webhook`: 向 `url` 或环境变量 `url_env` 发送 JSON POST
- `shortcut`: 执行 `shortcuts run <name>`（stdin 传入摘要）
- `append_markdown`: 向本地日记追加记录（支持 `{{date}}` 与防自激写租约）
- `shell`: 运行轻量本地 `/bin/zsh -lc <cmd>`
- `clipboard`: 写入带 `TransientType` 标记的剪贴板
- `chime_sound`: 播放 `/System/Library/Sounds/<name>.aiff`，设 `tts: true` 可轻语音播报

## 常见事件类型 (type)
- `dev.bianzhong.feishu.notification`: 飞书通知中心传感器捕获的消息（`payload.title` 为群名/联系人，`payload.subtitle` 为发送者，`payload.body` 为正文）。
- `dev.bianzhong.shell.command_failed`: Zsh 慢命令失败钩子事件（`payload.cwd` 为命令所在目录）。
- `dev.bianzhong.ci.failed`: 测试或 CI 失败（可通过 `bz emit` 或 Git Hook 推送）。

帮用户生成或修改规则后，提醒用户：Bianzhong 会热加载 `~/.config/bianzhong/chimes/*.md`，或在终端执行 `bz replay` 验证历史命中效果、点击 MenuBar「重载」立即生效。
