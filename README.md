<h1 align="center">Bianzhong</h1>

<p align="center">
  <img src="assets/branding/bianzhong-mark.png" width="180" alt="Bianzhong 项目标识">
</p>

<p align="center">
  <a href="README.md">简体中文</a> · <a href="README.en.md">English</a>
</p>

**在 macOS 上聚合系统通知与本地信号，按需唤醒你已有的 CLI Agent 执行勘察与行动。**

*Every signal, a call to action.*

Bianzhong（编钟）连接本机事件源与你自备的 CLI Agent（如 `omp`、`codex`）。所有事件过滤、SQLite 状态记录和子进程调度均在本地完成，不依赖中转服务，也不自研 Agent Harness 或修改上游 Agent 源码。

项目采用单应用形态打包：一个 `Bianzhong.app` 同时承担菜单栏听音台、守护进程、内置飞书通知监听和内嵌 `bz` 命令行工具；首次打开时自动初始化默认配置并将 `bz` 软链到常用 `PATH` 目录。**剪贴板监听、工作区 FSEvents 监听、内置 Cron 调度与 LaunchAgent 开机自启尚未实现**，属于后续里程碑；当前版本聚焦飞书通知中心读取、Zsh 慢命令失败钩子与 `bz emit` 脚本接入。

<p align="center">
  <a href="docs/00-mvp-architecture-and-roadmap.md">架构与路线图</a> · <a href="docs/research/01-macos-perception-and-hammerspoon2.md">macOS 感知调研</a><br>
  <a href="docs/research/03-agent-dispatch-and-lifecycle.md">Agent 调度机制</a> · <a href="docs/research/04-trigger-funnel-permissions-and-hitl.md">触发漏斗与审批</a>
</p>

最新已发布版本为 **v0.3.0**（macOS 26 Apple Silicon 单应用预览版）；下方安装示例对应 GitHub Release 上的 **v0.3.0** 产物。

[Features](#features) · [Screenshots](#screenshots) · [Install](#install) · [Usage](#usage) · [项目与许可](#项目与许可) · [Dev](#dev)

## Features

- 单应用开箱即用：`Bianzhong.app` 内置 `bz` 命令行与飞书通知监听，启动时自动把 `bz` 软链到 `~/.local/bin/bz`（如 `/opt/homebrew/bin` 可写也会一并创建），并在菜单栏「规则 / 设置」标签页中可视化管理规则启停、在线测试与 `~/.zshrc` 钩子。
- 多源本地信号接入：内置传感器只读查询 `usernoted` 中的 `com.electron.lark` 飞书通知（缺权限时自动引导开启完全磁盘访问权限）；Zsh 慢命令钩子自动上报耗时失败命令；外部脚本经 `bz emit` 或 Unix Domain Socket `ingest.sock` 推送事件。
- L0 确定性漏斗与窗口看门狗：`restricted` 隐私事件落库前直接丢弃；通过因果深度、自源排除、写路径租约与回声指纹阻断循环触发；支持按 `title` / `subtitle` / `body` / `cwd` 分字段匹配与 AND 组合、时间窗口累计次数阈值（如 `min_count: 2` + `window: daily`）、预期窗口未收到信号告警（`expect`）、TTL 去重、尾随防抖合并及冷却锁，这一层不调用大模型。
- 可选 L1 语义分诊：支持 macOS 26 本地 `FoundationModels`（`apple_fm`）、指定轻量模型的 `omp` / `codex`（`agent_cli`）、外部 HTTP 接口（`decision_api`）以及直通放行（`none`）。
- 两阶段 Agent 调度：按需通过 `posix_spawn` 在独立进程组拉起 `omp` 或 `codex`，空闲时无常驻进程；Phase 1 限制只读工具集或 `read-only` 沙箱完成勘察与拟稿，批准后再进入可写模式的 Phase 2，并可为修复任务创建独立 Git Worktree。
- 菜单栏与交互通知审批：通过 `Bianzhong.app` 听音台与 `UNUserNotificationCenter` 通知按钮完成后台批准、附言执行、复制回复并唤起飞书，或在 Ghostty、iTerm2、Warp、Terminal 中直接接管原会话（`omp -r` / `codex resume`）；专注或锁屏期间的信号可暂存，解锁后合并为单条摘要。
- 后置动作与运行治理：`on_complete` 按 `when` 条件触发 `notify`、`webhook`、`shortcut`、`append_markdown`、`shell`、`clipboard` 与 `chime_sound`；内置日度花费和运行次数上限、连续失败熔断，以及保护未提交改动的 Worktree 清理。
- 离线试跑与误报调优：`bz simulate` 支持单条信号试跑，`bz replay` 重放历史事件，`bz tune` 导出被忽略样本并拉起配置助手收紧规则。

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
curl -fL -O https://github.com/chorust/bianzhong/releases/download/v0.3.0/Bianzhong-0.3.0-macos26-arm64.tar.gz
curl -fL -O https://github.com/chorust/bianzhong/releases/download/v0.3.0/SHA256SUMS.txt
shasum -a 256 --ignore-missing -c SHA256SUMS.txt
tar -xzf Bianzhong-0.3.0-macos26-arm64.tar.gz
cp -R "Bianzhong-0.3.0/Bianzhong.app" /Applications/
open /Applications/Bianzhong.app
```

如果新终端里找不到 `bz`，确认 `~/.local/bin` 已在 `PATH` 中，或在菜单栏「设置」页开启「Zsh 慢命令钩子」（会一并写入 `export PATH="$HOME/.local/bin:$PATH"`）。

### .pkg 安装包

也可以使用 `.pkg` 安装器一步写入 `/Applications/Bianzhong.app` 与 `/usr/local/bin/bz`：

```bash
workdir="$(mktemp -d)"
cd "$workdir"
curl -fL -O https://github.com/chorust/bianzhong/releases/download/v0.3.0/Bianzhong-0.3.0-macos26-arm64.pkg
curl -fL -O https://github.com/chorust/bianzhong/releases/download/v0.3.0/SHA256SUMS.txt
shasum -a 256 --ignore-missing -c SHA256SUMS.txt
sudo installer -pkg Bianzhong-0.3.0-macos26-arm64.pkg -target /
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
