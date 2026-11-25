<h1 align="center">Bianzhong</h1>

<p align="center">
  <img src="assets/branding/bianzhong-mark.png" width="180" alt="Bianzhong project mark">
</p>

<p align="center">
  <a href="README.md">简体中文</a> · <a href="README.en.md">English</a>
</p>

**Aggregate macOS notifications and local signals to wake your existing CLI agents on demand.**

*Every signal, a call to action.*

Bianzhong connects local event sources to CLI agents you already use, such as `omp` and `codex`. Event filtering, SQLite state persistence, and subprocess orchestration stay local by default with no relay service, no custom agent harness, and no patches to upstream agent codebases.

The project ships as a single application bundle: `Bianzhong.app` embeds the menu bar inbox, daemon, in-process Feishu notification monitor, and the `bz` CLI. Opening `Bianzhong.app` initializes default templates and automatically symlinks `bz` into your `PATH`. **Clipboard watching, FSEvents workspace monitoring, built-in cron schedules, and LaunchAgent auto-start are not yet implemented** and belong to later milestones; the current release focuses on read-only Notification Center capture for Feishu, failed slow-command hooks in Zsh, and script ingestion via `bz emit`.

<p align="center">
  <a href="docs/00-mvp-architecture-and-roadmap.md">Architecture & roadmap</a> · <a href="docs/research/01-macos-perception-and-hammerspoon2.md">macOS perception notes</a><br>
  <a href="docs/research/03-agent-dispatch-and-lifecycle.md">Agent dispatch & lifecycle</a> · <a href="docs/research/04-trigger-funnel-permissions-and-hitl.md">Funnel & approval model</a>
</p>

The latest published release is **v0.2.0** (macOS 26 Apple Silicon single-app preview). The install examples below reference the **v0.2.0** release artifacts on GitHub.

[Features](#features) · [Screenshots](#screenshots) · [Install](#install) · [Usage](#usage) · [Project and licensing](#project-and-licensing) · [Dev](#dev)

## Features

- Single-app setup: `Bianzhong.app` bundles both the `bz` CLI and Feishu Notification Center watcher, symlinking `bz` into `~/.local/bin/bz` (and `/opt/homebrew/bin/bz` when writable) on launch, with a menu bar Integrations menu to toggle `~/.zshrc` hooks.
- Multi-source local perception: reads `com.electron.lark` notification records read-only from `usernoted`, receives failed slow commands via `bz shell-hook zsh`, and ingests custom scripts or webhooks through `bz emit` and `ingest.sock`.
- Deterministic L0 funnel: drops `restricted` privacy events before any database write, blocks feedback loops across four layers (causal depth, self-source exclusion, active write leases, and echo hashes), and filters noise via wildcard/keyword rules, TTL dedup, trailing debounce coalescing, and cooldown locks without touching an LLM.
- Pluggable L1 triage: supports on-device macOS 26 `FoundationModels` (`apple_fm`), a lightweight model via `omp` or `codex` (`agent_cli`), an external HTTP `decision_api` gateway, or rule pass-through (`none`).
- Two-phase agent execution: spawns `omp` or `codex` on demand in an isolated process group (`posix_spawn`) with zero idle daemon footprint; Phase 1 runs read-only investigation and drafting, while Phase 2 enters `workspace-write` or an isolated Git worktree only after human approval.
- Menu bar inbox and interactive notifications: `Bianzhong.app` and `UNUserNotificationCenter` actions support background approval, approval comments, copying a reply and activating Feishu, or resuming the exact session in Ghostty, iTerm2, Warp, or Terminal (`omp -r` / `codex resume`); signals arriving during Focus or screen lock can defer into a single wake digest.
- Post-actions and runtime governance: conditional `on_complete` pipelines (`notify`, `webhook`, `shortcut`, `append_markdown`, `shell`, `clipboard`, `chime_sound`) alongside daily cost/run caps, circuit breakers on consecutive failures, and retention GC that preserves dirty Git worktrees.
- Offline simulation and tuning: dry-run single signals with `bz simulate`, replay recorded history with `bz replay`, and inspect rejected samples with `bz tune` to tighten noisy chimes.

## Screenshots

<p align="center">
  <img src="assets/screenshots/menubar-inbox.png" width="760" alt="Bianzhong menu bar inbox and macOS interactive notification">
</p>

<p align="center">
  <em>Menu bar inbox and macOS notification actions rendered from sample events, showing a Feishu reply draft, a test-failure review card, the Integrations menu, and interactive notification controls.</em>
</p>

<p align="center">
  <img src="assets/screenshots/cli-workflow.png" width="760" alt="bz CLI init, simulate, and status output">
</p>

<p align="center">
  <em>Local output from <code>bz init</code>, <code>bz simulate</code>, and <code>bz status</code> demonstrating rule matching and noise suppression.</em>
</p>

## Install

Requires **macOS 26** (Apple Silicon / `arm64`). Building from source requires Swift **6.2+** (Xcode 26 or Apple Command Line Tools).

### .dmg or .tar.gz (single-app install)

Download the latest `.dmg` from [Releases](https://github.com/chorust/bianzhong/releases), drag `Bianzhong.app` into `/Applications/`, and open it once—default configuration and `bz` CLI symlinks are created automatically. Or download and verify the tarball from a terminal:

```bash
workdir="$(mktemp -d)"
cd "$workdir"
curl -fL -O https://github.com/chorust/bianzhong/releases/download/v0.2.0/Bianzhong-0.2.0-macos26-arm64.tar.gz
curl -fL -O https://github.com/chorust/bianzhong/releases/download/v0.2.0/SHA256SUMS.txt
shasum -a 256 --ignore-missing -c SHA256SUMS.txt
tar -xzf Bianzhong-0.2.0-macos26-arm64.tar.gz
cp -R "Bianzhong-0.2.0/Bianzhong.app" /Applications/
open /Applications/Bianzhong.app
```

If `bz` is not yet in your `PATH`, add `~/.local/bin` or click `集成 -> 写入 Zsh 慢命令钩子 (~/.zshrc)` in the menu bar.

### .pkg installer

You can also install `Bianzhong.app` into `/Applications/` and `/usr/local/bin/bz` with the `.pkg` installer:

```bash
workdir="$(mktemp -d)"
cd "$workdir"
curl -fL -O https://github.com/chorust/bianzhong/releases/download/v0.2.0/Bianzhong-0.2.0-macos26-arm64.pkg
curl -fL -O https://github.com/chorust/bianzhong/releases/download/v0.2.0/SHA256SUMS.txt
shasum -a 256 --ignore-missing -c SHA256SUMS.txt
sudo installer -pkg Bianzhong-0.2.0-macos26-arm64.pkg -target /
```

Prebuilt bundles are ad-hoc signed without Apple notarization. After verifying checksums, clear quarantine attributes if Gatekeeper prompts on first launch:

```bash
xattr -cr /Applications/Bianzhong.app
```

Shell hooks, CI webhooks, and `bz emit` require no macOS privacy permissions. For built-in Feishu Notification Center capture, grant Full Disk Access to `/Applications/Bianzhong.app` via System Settings -> Privacy & Security -> Full Disk Access. Note that in single-app mode, child CLI agents spawned by `Bianzhong.app` inherit its TCC permissions under macOS rules; if you prefer zero TCC exposure, disable `feishu_sensor_enabled` in the menu bar or `config.yml`.

### Build from source

From the repository root:

```bash
git clone https://github.com/chorust/bianzhong.git
cd bianzhong
bash scripts/setup-signing-cert.sh
bash scripts/bundle-app.sh
open dist/Bianzhong.app
```

## Usage

### Config

Opening `Bianzhong.app` creates `~/.config/bianzhong/` automatically (or run `bz init`). Global settings live in `~/.config/bianzhong/config.yml` and trigger rules live in `~/.config/bianzhong/chimes/*.md`:

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

Run `bz config` (or click `+ 配规则` in the menu bar) to open `omp` or `codex` in `~/.config/bianzhong` with `AGENTS.md` loaded, then apply edits with `bz reload`.

### Scenarios

- **Feishu on-call triage & reply drafting**

  With `feishu_sensor_enabled: true` and Full Disk Access granted to `Bianzhong.app`, bursts of group messages matching your keywords coalesce within the debounce window, trigger a read-only investigation paired with the last 20 minutes of local timeline context, and surface a short reply draft:

  ```bash
  bz status
  ```

  Clicking "复制并回飞书" copies the draft with `org.nspasteboard.TransientType` metadata and brings Feishu forward.

- **Slow shell command failure diagnosis**

  Enable the Zsh hook from the menu bar Integrations menu (or run `bz install-cli --zsh`) to report commands that run for at least 15 seconds and exit non-zero (excluding `Ctrl+C` exit code `130`):

  ```bash
  source ~/.zshrc
  ```

  Bianzhong surfaces the failure summary in the menu bar so you can jump straight into the underlying agent session with "终端接管 ↗".

- **CI or test failure investigation with worktree execution**

  Push build or test failures from scripts or hooks with `bz emit`, review the Phase 1 analysis, and approve Phase 2 execution in an isolated Git worktree:

  ```bash
  bz emit --type dev.bianzhong.ci.failed --cwd "$PWD" --title "swift test failed" --body "testMigration failed"
  bz status
  bz approve <approval-id> --note "Fix migration idempotency and add a regression test"
  bz takeover <approval-id>
  ```

- **Away-from-keyboard webhooks, dry-run simulation & rule tuning**

  Chime playbooks support conditional `on_complete` actions and Focus deferral:

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

  Test rules offline against past events or review rejected notifications before deploying changes:

  ```bash
  bz simulate --type dev.bianzhong.feishu.notification --source bz://sensor/feishu --title "支付研发群" --body "@你 退款接口 500 报错"
  bz replay --last 50
  bz tune feishu-oncall-triage
  bz digest
  ```

## Project and licensing

Bianzhong keeps its own runtime thin and delegates tool execution, compaction, and sandboxing to external CLI agents. Architecture notes and research reports:

[Architecture & roadmap](docs/00-mvp-architecture-and-roadmap.md) · [macOS perception & Hammerspoon 2](docs/research/01-macos-perception-and-hammerspoon2.md) · [Prior art](docs/research/02-ecosystem-and-prior-art.md) · [Agent dispatch & lifecycle](docs/research/03-agent-dispatch-and-lifecycle.md) · [Funnel & HITL](docs/research/04-trigger-funnel-permissions-and-hitl.md)

Linked architecture and research documents under `docs/` are currently in Chinese.

The software is licensed under [Apache-2.0](LICENSE), allowing commercial use. Licensing, API usage, and local permissions for external CLI agents (`omp`, `codex`), upstream model endpoints, and monitored local data sources remain governed by their respective providers.

## Dev

Build all targets, run the test suite, and package single-app installers locally:

```bash
swift build
bash scripts/test.sh
bash scripts/package-release.sh 0.2.0
```

Tests run offline in isolated temporary directories without network calls or live LLM requests. GitHub Actions runs [CI](.github/workflows/ci.yml) on pushes/PRs and [Release](.github/workflows/release.yml) on `v*` tags using `macos-26` runners. Live `usernoted` database reads, interactive system notification callbacks, terminal handoff launches, and live model triage must be verified locally on macOS 26.
