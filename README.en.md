<h1 align="center">Bianzhong</h1>

<p align="center">
  <img src="assets/branding/bianzhong-mark.png" width="180" alt="Bianzhong project mark">
</p>

<p align="center">
  <a href="README.md">简体中文</a> · <a href="README.en.md">English</a>
</p>

**Aggregate macOS notifications and local signals to wake your existing CLI agents on demand.**

*Every signal, a call to action.*

Bianzhong connects local event sources to CLI & ACP agents you already use (`omp-acp`, `opencode-acp`, `claude`, `opencode`, `omp`, `codex`). Event filtering, SQLite state persistence, and subprocess orchestration stay local by default with no public relay service and no patches to upstream agent codebases.

The project ships as a single application bundle: `Bianzhong.app` embeds the menu bar inbox, the non-activating Notch HUD ("Chime Beam", `⌥Space`), the unified Console (`⌘,`), the Tailscale Mobile Pocket Console PWA (`/pocket`), the in-process Feishu notification monitor, and the `bz` CLI.

<p align="center">
  <a href="docs/00-mvp-architecture-and-roadmap.md">Architecture & roadmap</a> · <a href="docs/research/01-macos-perception-and-hammerspoon2.md">macOS perception notes</a><br>
  <a href="docs/research/03-agent-dispatch-and-lifecycle.md">Agent dispatch & lifecycle</a> · <a href="docs/research/04-trigger-funnel-permissions-and-hitl.md">Funnel & approval model</a>
</p>

The latest published release is **v0.5.0** (macOS 26 Apple Silicon single-app bundle). The install examples below reference the **v0.5.0** release artifacts on GitHub.

[Features](#features) · [Screenshots](#screenshots) · [Install](#install) · [Usage](#usage) · [Project and licensing](#project-and-licensing) · [Dev](#dev)

## Features

- Single-app setup: `Bianzhong.app` bundles the `bz` CLI, unified Console (`⌘,`), Launch-at-Login toggle, and terminal selector (Ghostty, iTerm2, Warp, Kitty, WezTerm, Alacritty, cmux, Terminal).
- ACP bidirectional streaming & warm-hold: native Agent Client Protocol (`stdio` JSON-RPC 2.0) runner supporting `omp-acp`, `opencode-acp`, `claude-acp`, and `gemini-acp` with live `session/update` telemetry, `<5ms` in-place **warm-hold** resume on `session/request_permission`, inline mid-flight steering (`Steer`), and 1-click task cancellation—alongside `claude`, `opencode`, `omp`, and `codex` CLI drivers.
- Non-activating Notch HUD ("Chime Beam"): zero-TCC Carbon hotkey (`⌥Space`), `sharingType = .none` screen-share invisibility, hardware notch safe-area alignment, syntax-colored diff preview, drag-and-drop file diagnosis, and 1-click worktree handoff to **T3 Code, Cursor, Zed, VS Code**, or your preferred terminal.
- Tailscale Mobile Pocket Console PWA: built-in standalone mobile console (`/pocket`) paired via QR code over private `tailscale serve` HTTPS—review diffs, approve/steer/dismiss items, or stop all active runs from your phone with zero public IP exposure.
- Bidirectional webhooks & L0/L1 funnel: inbound `/v1/emit`, `/v1/hooks/{github|feishu|sentry|grafana}`, `bianzhong://` deep links, signed outbound cards (Feishu Bot, Slack, Bark, Discord, Telegram), four-layer loop prevention, window watchdogs (`expect`), on-device `FoundationModels` triage (`apple_fm`), and isolated Git worktrees.

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
curl -fL -O https://github.com/chorust/bianzhong/releases/download/v0.5.0/Bianzhong-0.5.0-macos26-arm64.tar.gz
curl -fL -O https://github.com/chorust/bianzhong/releases/download/v0.5.0/SHA256SUMS.txt
shasum -a 256 --ignore-missing -c SHA256SUMS.txt
tar -xzf Bianzhong-0.5.0-macos26-arm64.tar.gz
cp -R "Bianzhong-0.5.0/Bianzhong.app" /Applications/
open /Applications/Bianzhong.app
```

If `bz` is not yet in your `PATH`, add `~/.local/bin` or enable the Zsh hook in the menu bar `设置` (Settings) tab.

### .pkg installer

You can also install `Bianzhong.app` into `/Applications/` and `/usr/local/bin/bz` with the `.pkg` installer:

```bash
workdir="$(mktemp -d)"
cd "$workdir"
curl -fL -O https://github.com/chorust/bianzhong/releases/download/v0.5.0/Bianzhong-0.5.0-macos26-arm64.pkg
curl -fL -O https://github.com/chorust/bianzhong/releases/download/v0.5.0/SHA256SUMS.txt
shasum -a 256 --ignore-missing -c SHA256SUMS.txt
sudo installer -pkg Bianzhong-0.5.0-macos26-arm64.pkg -target /
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

  Enable the Zsh hook from the menu bar `设置` (Settings) tab (or run `bz install-cli --zsh`) to report commands that run for at least 15 seconds and exit non-zero (excluding `Ctrl+C` exit code `130`):

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
bash scripts/package-release.sh 0.3.0
```

Tests run offline in isolated temporary directories without network calls or live LLM requests. GitHub Actions runs [CI](.github/workflows/ci.yml) on pushes/PRs and [Release](.github/workflows/release.yml) on `v*` tags using `macos-26` runners. Live `usernoted` database reads, interactive system notification callbacks, terminal handoff launches, and live model triage must be verified locally on macOS 26.
