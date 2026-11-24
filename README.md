# Bianzhong（编钟）

> **Every signal, a call to action. 诸声汇聚，应声而动。**

面向 **macOS 26 (`arm64`, Swift 6.3)** 的极薄事件驱动主动式 Agent 运行时——连接 macOS 环境信号与用户自备 CLI Agent（`omp`、`codex`、`pi`、`claude`），不做自己的 Agent Harness，不修改上游 Agent 源码。

## 核心架构

1. **钟枚（Thin Sensors）**：
   - `BianzhongFeishuSensor.app`（`bz-feishu-sensor`）：独立只读沙箱隔离进程，通过 `FSEvents` 监听 `~/Library/Group Containers/group.com.apple.usernoted/db2` 并以 `SQLITE_OPEN_READONLY` 仅提取 `com.electron.lark` 飞书通知摘要（唯一需独立授予 Full Disk Access 的进程，主程序与 Agent 保持 Zero-TCC）。
   - **Zsh 慢命令失败钩子**：`eval "$(bz shell-hook zsh)"` 在命令耗时 `>= 15s` 且失败时静默上报目录与退出码。
   - `bz emit` / `ingest.sock` NDJSON：接入 macOS 26 Shortcuts 自动化、Git/CI Hook、Webhook 及可选 Hammerspoon v1（`1.1.1`）`hs.socket` 插件。
2. **钟架与钟律（Event Bus, Funnel, Governance & Chimes）**：
   - **L0 确定性漏斗（0 Token）**：隐私红线熔断（`restricted` 原地销毁）→ 四重防自激（因果深度 `BIANZHONG_DEPTH`、自源排除、活跃写路径租约、回声指纹）→ 规则匹配 → TTL 去重 → 尾随防抖聚窗（Debounce Coalescing）→ 冷却锁。
   - **L1 可插拔分诊（`TriageProvider`）**：支持 `decision_api`（外部 `jev` / Decision API）、`agent_cli`（`omp`/`codex` 指定便宜模型）、`apple_fm`（macOS 26 端侧 `FoundationModels`）与 `none`。
   - **治理与记忆**：20 分钟跨信号关联时间线 + 确定性 `preflight_cmd` 预取 + 全局日度预算上限/连续失败熔断/自动 Worktree GC + 历史回放 `bz simulate` / `bz replay` + 误报样本调优 `bz tune`。
   - **声明式规则剧本**：`~/.config/bianzhong/chimes/*.md`（YAML Frontmatter + Phase 1/2 Markdown Prompt），通过 `bz config` 直接拉起 `omp`/`codex` 对话生成。
3. **执槌与听音台（Drivers, Wake Digest & `on_complete` Actions）**：
   - 按需 `posix_spawn` 独立进程组拉起 `omp`（只读工具集）或 `codex`（`read-only` 沙箱），空闲 0 MB 常驻；支持 `driver: none` 纯动作规则。
   - `Bianzhong.app`（`LSUIElement = true`）承载 `MenuBarExtra` 收件箱、开盖/解锁自动合并的 **晨钟摘要（Wake Digest）** 与 macOS 26 `UNUserNotificationCenter` 交互按钮（后台静默批准、内联附言、复制回复并打开飞书、一键跳默认终端 `--resume` 接管）。
   - **可组合后置动作 (`on_complete`)**：按 `when` 条件路由至 `notify`、`webhook`（离席推手机）、`shortcut`（macOS 快捷指令）、`append_markdown`（每日笔记归档）、`shell`、`clipboard` 与 `chime_sound` / `tts`。

## 目录结构

```text
bianzhong/
├── .github/workflows/             # CI 测试冒烟构建 + v* Tag 自动发布 macOS 26 安装包 (.pkg/.dmg/.tar.gz)
├── Package.swift                  # Swift 6 / macOS 26 零外部依赖工程
├── Sources/
│   ├── BianzhongCore/             # 信封、规则、SQLite WAL、L0 漏斗、L1 分诊、传感器运行器、治理/回放/调优/Actions、Driver、UDS 总线
│   ├── BianzhongApp/              # MenuBarExtra + UNUserNotificationCenter + 唤醒摘要 + --daemon 无头模式
│   ├── bz/                        # 轻量 CLI (init / config / emit / simulate / replay / tune / digest / gc / shell-hook)
│   └── bz-feishu-sensor/          # 独立只读 Feishu (com.electron.lark) 通知传感器
├── Tests/BianzhongCoreTests/      # Swift Testing 单元与集成测试（18 条用例）
├── templates/                     # 默认 config.yml / AGENTS.md / zsh hook / 示例 chimes/*.md
├── scripts/                       # setup-signing-cert.sh / bundle-app.sh / package-release.sh / test.sh
└── docs/                          # 架构蓝图与四篇专题调研报告
```

## 快速构建与验证

```bash
# 1. 编译全部目标
swift build

# 2. 运行全部单元与集成测试
bash scripts/test.sh

# 3. （推荐）生成本地自签名证书，避免重编后丢失 FDA 与通知权限
bash scripts/setup-signing-cert.sh

# 4. 构建并签名 .app Bundle（调试版可加 --debug）
bash scripts/bundle-app.sh --debug

# 5. 一键打包本地安装包（输出 .pkg / .dmg / .tar.gz / SHA256SUMS.txt 到 dist/release/）
bash scripts/package-release.sh 0.1.0

# 6. 初始化默认配置、对话配规则、回放调优与 zsh 钩子
.build/debug/bz init
.build/debug/bz config
.build/debug/bz replay --last 50
eval "$(.build/debug/bz shell-hook zsh)"
```

## 安装包构建与 CI 自动发布

- **CI（[.github/workflows/ci.yml](.github/workflows/ci.yml)）**：每次推送到 `main` 或发起 PR 时在 GitHub `macos-26` (`arm64`) runner 自动编译全部目标、运行 18 项测试，并生成带 commit SHA 后缀的 `.pkg` / `.dmg` / `.tar.gz` 冒烟安装包上传至 Actions Artifacts（保留 7 天）。
- **Release（[.github/workflows/release.yml](.github/workflows/release.yml)）**：推送形如 `v0.1.0` 的 Tag（`git tag v0.1.0 && git push origin v0.1.0`）或手动触发 `workflow_dispatch`，自动打包并创建 GitHub Release，附件包含：
  - `Bianzhong-<version>-macos26-arm64.pkg`（安装两款 `.app` 到 `/Applications/` 并安装 `bz` 到 `/usr/local/bin/bz`）
  - `Bianzhong-<version>-macos26-arm64.dmg`（拖拽安装镜像）
  - `Bianzhong-<version>-macos26-arm64.tar.gz`（免安装便携包）
  - `SHA256SUMS.txt`
- **零 Secret 开箱即用 + 可选 Apple 公证**：未配置证书 Secret 时默认使用 Ad-hoc 签名（`codesign -s -`），首次安装可执行 `xattr -cr /Applications/Bianzhong.app /Applications/BianzhongFeishuSensor.app`；如需正式 Developer ID 签名与公证，可在仓库 Secrets 配置 `MACOS_CERT_P12_BASE64`、`MACOS_CERT_PASSWORD`、`MACOS_CODESIGN_IDENTITY`、`MACOS_INSTALLER_IDENTITY` 及 `APPLE_ID`、`APPLE_TEAM_ID`、`APPLE_APP_SPECIFIC_PASSWORD`。

## 专题文档索引

- [00｜MVP 架构设计与渐进式路线图](docs/00-mvp-architecture-and-roadmap.md)
- [01｜macOS 原生感知与 Hammerspoon 2 深度技术调研](docs/research/01-macos-perception-and-hammerspoon2.md)
- [02｜生态与竞品先驱调研](docs/research/02-ecosystem-and-prior-art.md)
- [03｜Agent 统一调度与生命周期管理深度调研](docs/research/03-agent-dispatch-and-lifecycle.md)
- [04｜事件触发漏斗、权限边界与人机协作（HITL）专题调研](docs/research/04-trigger-funnel-permissions-and-hitl.md)
