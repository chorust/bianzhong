import Foundation

/// Built-in templates installed by `bz init` and `bz config` so the CLI works standalone from any directory.
public enum DefaultTemplates {
    public static let configYAML = """
    # Bianzhong（编钟）全局配置 (~/.config/bianzhong/config.yml)
    terminal: auto                # auto | ghostty | iterm | warp | kitty | wezterm | alacritty | cmux | terminal
    feishu_sensor_enabled: true   # 需在 系统设置 -> 完全磁盘访问权限 中授予 Bianzhong.app
    notch_hud_enabled: true       # 刘海悬浮窗 (录屏隐身，不抢焦点)
    notch_hotkey: option+space    # 全局快捷键，如 option+space | ctrl+space | cmd+shift+b | none
    max_concurrent_runs: 2
    max_causal_depth: 1

    # 入站/出站双向 Webhook 网关（Token 自动保存在本地 0600 secrets.json，不入库 Git）
    webhook_server:
      enabled: true
      host: 127.0.0.1             # 如需内网/Tailscale 回调可改为 0.0.0.0
      port: 17380
      callback_base_url: null     # 例如 https://macbook.tailnet.ts.net:17380

    # 全局预算、熔断与自动清理治理
    governance:
      daily_max_cost_usd: 3.0
      daily_max_runs: 30
      circuit_breaker_failures: 3
      retention_days: 7

    # L1 语义分诊器（当 chime 启用 triage 时生效）
    triage:
      provider: apple_fm          # apple_fm | agent_cli | decision_api | none
      decision_api_url: null      # 例如 https://your-jev.example.com/v1/triage
      decision_api_key_env: BIANZHONG_DECISION_API_KEY
      decision_api_timeout_seconds: 4.0
      agent_cli_driver: omp       # omp | codex
      agent_cli_model: smol       # 如 smol / flash / gpt-5-mini

    # 候选本地工作区目录（供 L1 语义分诊或规则参考）
    workspaces:
      - name: bianzhong
        path: ~/data/code/github/bianzhong
        summary: "Bianzhong macOS event-driven agent runtime"
    """

    public static let agentsMD = """
    # Bianzhong 规则共创指南 (AGENTS.md)

    你正在帮助用户在 `~/.config/bianzhong/` 中创建、修改或调试 **Bianzhong（编钟）** 的事件驱动规则（`chimes/*.md`）与全局配置（`config.yml`）。

    ## 目录结构
    - `config.yml`: 全局分诊器（`triage.provider`: `apple_fm` | `agent_cli` | `decision_api` | `none`）、治理上限（`governance.*`）、默认终端（`terminal`: `auto` | `ghostty` | `iterm` | `warp` | `kitty` | `wezterm` | `alacritty` | `cmux` | `terminal`）、双向 Webhook 网关（`webhook_server.*`）与候选工作区。
    - `chimes/*.md`: 每条触发规则是一个独立的 Markdown 文件（YAML Frontmatter + `## Phase 1` / `## Phase 2` 行动剧本）。
    - 注意：API Key 与 Webhook 密钥推荐通过统一控制台（MenuBar「控制台」或 `⌘,`）保存在应用数据目录 `secrets.json`（`0600` 权限，不写入 `~/.config/bianzhong` 以免泄露到 Git）。

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
      driver: omp-acp                              # omp-acp | opencode-acp | claude-acp | omp | claude | opencode | codex | none
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
        preset: feishu_bot                         # raw | feishu_bot | slack | bark | discord | telegram
        url_env: BIANZHONG_WEBHOOK_URL             # 从本地 secrets.json 或环境变量读取
        secret_env: FEISHU_BOT_SECRET              # 可选：飞书机器人签名校验密钥或出站 HMAC 密钥
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
    - `webhook`: 支持多平台预设（`preset`: `raw` | `feishu_bot` | `slack` | `bark` | `discord` | `telegram`）、飞书加签（`secret_env`）以及带 HMAC 过期签名的远程批准/驳回回调按钮
    - `shortcut`: 执行 `shortcuts run <name>`（stdin 传入摘要）
    - `append_markdown`: 向本地日记追加记录（支持 `{{date}}` 与防自激写租约）
    - `shell`: 运行轻量本地 `/bin/zsh -lc <cmd>`
    - `clipboard`: 写入带 `TransientType` 标记的剪贴板
    - `chime_sound`: 播放 `/System/Library/Sounds/<name>.aiff`，设 `tts: true` 可轻语音播报

    ## 入站网关与 URL Scheme
    - 本地 HTTP Webhook 网关（默认 `http://127.0.0.1:17380`）：支持 `POST /v1/emit` 与 `POST /v1/hooks/{github|feishu|sentry|grafana|alertmanager|generic}`（需携带 `Authorization: Bearer <BIANZHONG_WEBHOOK_TOKEN>` 或 `X-Hub-Signature-256`）。
    - 系统级 URL Scheme：`bianzhong://emit?type=dev.bianzhong.url.emit&title=...&body=...`、`bianzhong://console?tab=rules`、`bianzhong://approve?id=...`。

    ## 常见事件类型 (type)
    - `dev.bianzhong.feishu.notification`: 飞书通知中心传感器捕获的消息（`payload.title` 为群名/联系人，`payload.subtitle` 为发送者，`payload.body` 为正文）。
    - `dev.bianzhong.shell.command_failed`: Zsh 慢命令失败钩子事件（`payload.cwd` 为命令所在目录）。
    - `dev.bianzhong.ci.failed`: 测试或 CI 失败（可通过 `bz emit` 或 Git Hook 推送）。

    帮用户生成或修改规则后，提醒用户：Bianzhong 会热加载 `~/.config/bianzhong/chimes/*.md`，或在终端执行 `bz replay` 验证历史命中效果、点击 MenuBar「重载」立即生效。
    """

    public static let feishuChimeMD = """
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
    """

    public static let testFailureChimeMD = """
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
    """

    public static let shellFailureChimeMD = """
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
    """

    /// Writes default `config.yml`, `AGENTS.md`, and starter chimes if not already present.
    @discardableResult
    public static func installDefaultsIfMissing(paths: BianzhongPaths) throws -> [String] {
        try paths.ensureDirectories()
        let fm = FileManager.default
        var created: [String] = []

        if !fm.fileExists(atPath: paths.configFile.path) {
            try configYAML.write(to: paths.configFile, atomically: true, encoding: .utf8)
            created.append(paths.configFile.path)
        }
        if !fm.fileExists(atPath: paths.agentsFile.path) {
            try agentsMD.write(to: paths.agentsFile, atomically: true, encoding: .utf8)
            created.append(paths.agentsFile.path)
        }

        let existingChimes = (try? fm.contentsOfDirectory(atPath: paths.chimesDir.path)) ?? []
        if existingChimes.filter({ $0.hasSuffix(".md") }).isEmpty {
            let starters: [(String, String)] = [
                ("feishu-oncall-triage.md", feishuChimeMD),
                ("local-test-failure.md", testFailureChimeMD),
                ("shell-long-failure.md", shellFailureChimeMD)
            ]
            for (name, body) in starters {
                let url = paths.chimesDir.appendingPathComponent(name)
                try body.write(to: url, atomically: true, encoding: .utf8)
                created.append(url.path)
            }
        }
        return created
    }
}
