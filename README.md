<h1 align="center">Bianzhong</h1>

<p align="center">
  <img src="assets/branding/bianzhong-mark.png" width="180" alt="Bianzhong 项目标识">
</p>

<p align="center">
  <a href="README.md">简体中文</a> · <a href="README.en.md">English</a>
</p>

**在 macOS 上聚合系统通知与本地信号，按需唤醒你已有的 CLI Agent 执行勘察与行动。**

*Every signal, a call to action.*

Bianzhong（编钟）连接本机事件源与你自备的 CLI / ACP Agent（如 `omp-acp`、`opencode-acp`、`claude`、`opencode`、`omp`、`codex`）。所有事件过滤、SQLite 状态记录和子进程调度均在本地完成，不依赖公网中转服务，也不修改上游 Agent 源码。

项目采用单应用形态打包：一个 `Bianzhong.app` 同时承担菜单栏待办与规则中心、刘海悬浮窗「编钟梁」（`⌥Space`）、统一控制台、Tailscale 手机口袋控制台 PWA、内置飞书通知监听及内嵌 `bz` 命令行工具；首次打开时自动初始化默认配置并将 `bz` 软链到常用 `PATH` 目录。

<p align="center">
  <a href="docs/00-mvp-architecture-and-roadmap.md">架构与路线图</a> · <a href="docs/research/01-macos-perception-and-hammerspoon2.md">macOS 感知调研</a><br>
  <a href="docs/research/03-agent-dispatch-and-lifecycle.md">Agent 调度机制</a> · <a href="docs/research/04-trigger-funnel-permissions-and-hitl.md">触发漏斗与审批</a>
</p>

最新已发布版本为 **v0.5.0**（macOS 26 Apple Silicon 单应用版）；下方安装示例对应 GitHub Release 上的 **v0.5.0** 产物。

[Features](#features) · [Screenshots](#screenshots) · [Install](#install) · [Usage](#usage) · [项目与许可](#项目与许可) · [Dev](#dev)

## Features

- 单应用开箱即用：`Bianzhong.app` 内置 `bz` 命令行、统一控制台（`⌘,`）与飞书通知监听，支持开机自启与默认终端选择（Ghostty、iTerm2、Warp、Kitty、WezTerm、Alacritty、cmux、Terminal）。
- ACP 双向流式引擎与原地热挂起：原生实现 Agent Client Protocol (`stdio` JSON-RPC 2.0)，支持 `omp-acp`、`opencode-acp`、`claude-acp`、`gemini-acp` 实时流式推送与 `session/request_permission` **原地热挂起（Warm-Hold）**——人类批准后 `<5ms` 原地继续执行，也支持行内输入调整意见（`Steer`）或一键中止运行；同时兼容 `claude`、`opencode`、`omp`、`codex` CLI 驱动。
- 刘海悬浮胶囊 HUD「编钟梁」：零辅助功能 TCC 权限占用全局快捷键 `⌥Space`，不抢当前编辑器焦点且投屏/录屏自动隐身（`sharingType = .none`）；自动避让 MacBook 物理刘海，支持彩色 Diff 审阅、回车批准 / 输入重调、拖拽文件投喂诊断，以及一键移交至 **T3 Code / Cursor / Zed / VS Code** 或默认终端。
- Tailscale 手机口袋控制台 PWA：内置深色移动端 Web 控制台（`/pocket`），在控制台「集成」页一键开启 `tailscale serve` 私网 HTTPS 映射并扫码配对，即可在手机端随时查看实时流与 Diff、批准/重调/忽略待办或紧急停止全部任务。
- 多源信号与双向 Webhook 网关：内置只读飞书通知中心监听、Zsh 慢命令失败钩子、入站 HTTP Webhook（`/v1/emit`、`/v1/hooks/{github|feishu|sentry|grafana}`）、`bianzhong://` URL Scheme，以及带 HMAC 签名的飞书/Slack/Bark/Discord/Telegram 出站卡片回调。
- L0 确定性漏斗与运行治理：`restricted` 隐私事件落库前直接丢弃；四层防自激循环（因果深度、自源排除、写路径租约、回声指纹）；支持分字段 AND 匹配、累计次数阈值、预期窗口看门狗（`expect`）、可选 L1 端侧语义分诊（`apple_fm`）、日预算/并发上限、连续失败熔断与隔离 Git Worktree 保护。

## Screenshots

<p align="center">
  <img src="assets/screenshots/menubar-inbox.png" width="760" alt="Bianzhong 菜单栏听音台与 macOS 交互通知">
</p>

<p align="center">
  <em>菜单栏听音台与 macOS 交互通知视图（基于示例事件渲染，展示飞书群排查草稿、测试失败审批卡片、集成菜单与通知操作）。</em>
</p>

<p align="center">
  <img src="assets/screenshots/cli-workflow.png" width="760" alt="bz 命令行初始化、规则模拟与状态检查输出">
</p>

<p align="center">
  <em><code>bz init</code>、<code>bz simulate</code> 与 <code>bz status</code> 的本地运行输出，展示内置规则命中与无关消息拦截结果。</em>
</p>

## Install

需要 **macOS 26**（Apple Silicon / `arm64`）；从源码编译还需要 Swift **6.2+**（Xcode 26 或 Apple Command Line Tools）。

### .dmg 拖拽或 .tar.gz 解压（推荐，单 App 即装即用）

从 [Releases](https://github.com/chorust/bianzhong/releases) 下载最新 `.dmg` 镜像并把 `Bianzhong.app` 拖入 `/Applications/`，打开后即自动完成配置初始化与 `bz` 命令安装。也可以通过终端下载 `.tar.gz` 校验并复制：

```bash
workdir="$(mktemp -d)"
cd "$workdir"
curl -fL -O https://github.com/chorust/bianzhong/releases/download/v0.5.0/Bianzhong-0.5.0-macos26-arm64.tar.gz
curl -fL -O https://github.com/chorust/bianzhong/releases/download/v0.5.0/SHA256SUMS.txt
shasum -a 256 --ignore-missing -c SHA256SUMS.txt
tar -xzf Bianzhong-0.5.0-macos26-arm64.tar.gz
cp -R "Bianzhong-0.5.0/Bianzhong.app" /Applications/
open /Applications/Bianzhong.app
```

如果新终端里找不到 `bz`，确认 `~/.local/bin` 已在 `PATH` 中，或在菜单栏「设置」页开启「Zsh 慢命令钩子」（会一并写入 `export PATH="$HOME/.local/bin:$PATH"`）。

### .pkg 安装包

也可以使用 `.pkg` 安装器一步写入 `/Applications/Bianzhong.app` 与 `/usr/local/bin/bz`：

```bash
workdir="$(mktemp -d)"
cd "$workdir"
curl -fL -O https://github.com/chorust/bianzhong/releases/download/v0.5.0/Bianzhong-0.5.0-macos26-arm64.pkg
curl -fL -O https://github.com/chorust/bianzhong/releases/download/v0.5.0/SHA256SUMS.txt
shasum -a 256 --ignore-missing -c SHA256SUMS.txt
sudo installer -pkg Bianzhong-0.5.0-macos26-arm64.pkg -target /
```

未配置 Apple Developer ID 公证时，首次打开预编译包若遇到 Gatekeeper 提示，确认校验和无误后执行：

```bash
xattr -cr /Applications/Bianzhong.app
```

如果只使用终端慢命令钩子、CI Webhook 与 `bz emit`，不需要任何系统隐私权限；若要直接读取飞书通知中心消息，只需按菜单栏黄色横幅引导「系统设置 -> 隐私与安全性 -> 完全磁盘访问权限」授予 `Bianzhong.app` 一次即可。单应用模式下，由 `Bianzhong.app` 拉起的下游 Agent 会按 macOS TCC 规则继承该权限，介意这一点的环境可在菜单栏或 `config.yml` 中关闭 `feishu_sensor_enabled`。

### 从源码构建

在仓库根目录编译并打包单个 `Bianzhong.app`（调试阶段可加 `--debug`）：

```bash
git clone https://github.com/chorust/bianzhong.git
cd bianzhong
bash scripts/setup-signing-cert.sh
bash scripts/bundle-app.sh
open dist/Bianzhong.app
```

## Usage

### Config

打开 `Bianzhong.app` 后会自动生成配置目录（也可在终端运行 `bz init`）。全局配置位于 `~/.config/bianzhong/config.yml`，规则位于 `~/.config/bianzhong/chimes/*.md`：

```yaml
terminal: auto
feishu_sensor_enabled: true
max_concurrent_runs: 2
max_causal_depth: 1

governance:
  daily_max_cost_usd: 3.0
  daily_max_runs: 30
  circuit_breaker_failures: 3
  retention_days: 7

triage:
  provider: apple_fm          # apple_fm | agent_cli | decision_api | none
  agent_cli_driver: omp
  agent_cli_model: smol

workspaces:
  - name: demo-api
    path: ~/code/demo-api
    summary: "Order and refund service"
```

如果需要调整或新增规则，运行 `bz config` 会以 `~/.config/bianzhong` 为工作目录打开 `omp` 或 `codex`（也可点击菜单栏「+ 配规则」）。修改完成后点击菜单栏「重载」或执行 `bz reload` 生效。

### 使用场景

- **飞书告警群排查与回复拟稿**

  确保飞书通知监听处于开启状态并授予 `Bianzhong.app` 完全磁盘访问权限后，群内的报错、`500` 或 `@` 通知会经 `debounce` 窗口合并，再拉起只读 Agent 结合最近 20 分钟本地时间线排查原因，在通知横幅和菜单栏生成中文答复草稿：

  ```bash
  bz status
  ```

  点击「复制并回飞书」，草稿会带上 `TransientType` 标记写入剪贴板并切回飞书窗口。

- **终端慢命令失败诊断**

  在菜单栏「设置」页开启「Zsh 慢命令钩子」（或运行 `bz install-cli --zsh`），终端里耗时达到 15 秒且非 `Ctrl+C` 中断（`exit_code != 130`）的失败命令会在后台静默上报目录与退出码：

  ```bash
  source ~/.zshrc
  ```

  构建或测试长时间执行失败时，听音台会给出排查摘要，点击「终端接管 ↗」可直接恢复对应 `omp` 或 `codex` 会话继续操作。

- **CI 失败与人工批准后隔离修复**

  外部脚本或 Git Hook 可以通过 `bz emit` 推送失败事件；查看 Phase 1 方案后在终端或菜单栏附言批准，Phase 2 会在独立 Git Worktree 中执行修改：

  ```bash
  bz emit --type dev.bianzhong.ci.failed --cwd "$PWD" --title "swift test failed" --body "testMigration failed"
  bz status
  bz approve <approval-id> --note "只修迁移脚本并补一条回归单测"
  bz takeover <approval-id>
  ```

- **规则试跑、离席推送与误报调优**

  每条 `~/.config/bianzhong/chimes/*.md` 规则支持组合后置动作与专注期延后：

  ```yaml
  funnel:
    debounce: 8s
    defer_on_focus: true
    triage:
      enabled: true
      provider: apple_fm
  on_complete:
    - type: notify
    - type: webhook
      url_env: BIANZHONG_WEBHOOK_URL
      when: "screen_locked == true || idle_seconds > 600"
  ```

  上线前或遇到误触发时，可以用离线试跑和误报调优命令收紧条件，或手动汇总暂存摘要：

  ```bash
  bz simulate --type dev.bianzhong.feishu.notification --source bz://sensor/feishu --title "支付研发群" --body "@你 退款接口 500 报错"
  bz replay --last 50
  bz tune feishu-oncall-triage
  bz digest
  ```

## 项目与许可

Bianzhong 把运行时本身保持精薄，将工具调用循环、上下文压缩和沙箱交给外部 CLI Agent 处理。各模块设计与调研记录见：

[架构设计与路线图](docs/00-mvp-architecture-and-roadmap.md) · [macOS 感知与 Hammerspoon 2 调研](docs/research/01-macos-perception-and-hammerspoon2.md) · [同类生态调研](docs/research/02-ecosystem-and-prior-art.md) · [Agent 调度与生命周期](docs/research/03-agent-dispatch-and-lifecycle.md) · [触发漏斗与 HITL 设计](docs/research/04-trigger-funnel-permissions-and-hitl.md)

软件采用标准 [Apache-2.0](LICENSE) 许可，允许商业使用。所调度的第三方 CLI Agent（如 `omp`、`codex`）、外部模型接口以及本机通知和仓库数据的访问权限各自适用对应软件与来源的规定。

## Dev

在仓库根目录编译、运行测试并打包本地安装包：

```bash
swift build
bash scripts/test.sh
bash scripts/package-release.sh 0.3.0
```

默认测试套件在临时目录离线运行，不访问公网也不调用线上大模型。GitHub Actions 的 [CI 工作流](.github/workflows/ci.yml) 和 [Release 发布工作流](.github/workflows/release.yml) 均运行在 `macos-26` Runner 上，分别用于每次推送验证和 `v*` 标签自动发布安装包。真实通知中心数据库读取、系统通知操作回调与在线模型分诊需要在本地 macOS 26 环境单独验收。
