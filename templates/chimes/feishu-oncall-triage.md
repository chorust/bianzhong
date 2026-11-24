---
id: feishu-oncall-triage
enabled: true
description: 监听飞书研发/告警群的高优通知，聚窗后先在本地代码库只读排查根因并拟定群回复草稿

match:
  type: ["dev.bianzhong.feishu.notification"]
  source: ["bz://sensor/feishu"]
  keywords_any: ["报错", "500", "超时", "异常", "panic", "PR", "帮忙看"]
  exclude_keywords: ["收到", "好的", "谢谢", "辛苦", "团建", "下午茶"]

funnel:
  dedup_ttl: 300s
  debounce: 8s
  max_wait: 30s
  cooldown: 15m
  defer_on_focus: true
  triage:
    enabled: true
    provider: apple_fm

session:
  policy: threaded
  ttl: 24h

execution:
  autonomy: draft_approve
  driver: omp
  model: null
  working_dir: ~/data/code/github/bianzhong
  worktree_on_phase2: false
  preflight_cmd: "git log -n 5 --oneline 2>/dev/null || true"
  phase1_max_time_sec: 180
  phase1_max_cost_usd: 0.25

on_complete:
  - type: notify
  - type: webhook
    url_env: BIANZHONG_WEBHOOK_URL
    when: "screen_locked == true || idle_seconds > 600"
---

## Phase 1
你收到一条（或多条合并后的）飞书群通知。当前处于**只读勘察阶段**，禁止修改任何文件：
1. 阅读事件文件 `$BIANZHONG_EVENT_FILE` 中的群名、发送人、最近 20 分钟相关信号及预取输出。
2. 在当前工作区检索相关代码与配置，定位问题原因或核实具体进展。
3. 直接用中文输出一段**可直接复制回飞书群的精炼答复**（附关键文件/行号依据，控制在 6 行以内）。
