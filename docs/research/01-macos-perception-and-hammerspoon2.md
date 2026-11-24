# 01 — macOS 原生感知与 Hammerspoon 2 深度技术调研

> **调研角色**：Bianzhong（编钟：macOS 事件驱动主动式 Agent 运行时）感知层调研  
> **调研日期**：2026-11-24  
> **核心结论先行**：
> 1. **Hammerspoon 2（`Hammerspoon/Hammerspoon2`, `1.0.0-beta.1`）不适合作为 Bianzhong 的宿主进程**：其强制要求 **macOS 27+**、移除了 `hs.window.filter` / `hs.distributednotifications` / 原始 `hs.socket`、且 `hs.ipc` 改用受 **Team ID 签名校验限制的 XPC Broker**；更重要的是无论 v1（单线程 Lua）还是 v2（单线程 JavaScriptCore），都将因为 Agent 调度逻辑而阻塞桌面热键与窗口交互。
> 2. **macOS 没有任何公开 API 允许第三方读取其他 App 的 `UNUserNotificationCenter` 通知**：强行通过 Accessibility 抓横幅在专注模式/锁屏下必漏且极其脆弱；强行监听 `usernoted` SQLite WAL 在 macOS 15 Sequoia+ 迁移至 `~/Library/Group Containers/group.com.apple.usernoted/db2/db` 后必须获取最高危的 **Full Disk Access（FDA）**。
> 3. **“源头协议 + OS 状态补充”是唯一符合低侵入原则的路径**：事件内容（What）优先从 IM Webhook、Git/GitHub Hook、Shortcuts（macOS 26 Tahoe+ 原生自动化触发）、AppleScript 等源头协议接入；OS 层（Hammerspoon v1/v2、极薄 Swift `LaunchAgent`）仅负责补充用户状态（Context：前台 App、空闲时长、Focus 状态、是否开会、睡眠唤醒、剪切板脱敏信号）。
> 4. **采用可插拔感知协议解耦**：Bianzhong Core 保持 **Zero-TCC（零系统高敏权限）**，对外暴露 **Unix Domain Socket + `bz emit` CLI + JSONL `stdin`**（辅以可选带 Token 的 Localhost HTTP 兼容 Hammerspoon 2），使 Hammerspoon v1/v2、原生 Swift Helper、Apple Shortcuts 与云端 Webhook 全部作为可替换的“薄 Sensor”接入。

---

## 1. Hammerspoon 2 (`cmsj/Hammerspoon2` → `Hammerspoon/Hammerspoon2`) 深度剖析与边界

### 1.1 项目现状、演进路线与系统版本要求

**Hammerspoon 2** 是由 Hammerspoon 原核心维护者 Chris Jones（GitHub ID: `cmsj`）主导的从零重写项目。其公开动机是：经过十余年迭代，经典 Hammerspoon v1 积累了约 10 万行（~100k lines）Objective-C 代码与复杂的自定义 `LuaSkin` C/Lua 双向类型桥接层，维护成本已难以为继；借助现代 **Swift** 与苹果内置的 **JavaScriptCore** 引擎，可实现近乎零胶水代码的对象桥接。

* **仓库迁移与当前状态**：项目早期以 [`cmsj/Hammerspoon2`](https://github.com/cmsj/Hammerspoon2) 孵化，经历 `0.0.6`、`0.0.17`、`0.0.18` 等快速实验构建后，现已正式并入组织仓库 [`Hammerspoon/Hammerspoon2`](https://github.com/Hammerspoon/Hammerspoon2)，并发布了首个测试里程碑 **[`1.0.0-beta.1`](https://github.com/Hammerspoon/Hammerspoon2/releases/tag/1.0.0-beta.1)**，官方门户与迁移文档托管于 [hammerspoon.org/2/](https://www.hammerspoon.org/2/)。据 `cmsj` 在 Hacker News 的公开说明，核心骨架与首批模块由其手工编写，其余大量模块借助 Claude 辅助迁移并经其逐行代码审阅验证。
* **激进的 macOS 版本基线**：
  * 极早期实验版本（`0.0.6` 及以前）曾支持 macOS 15.6（兼容 Intel 与 Apple Silicon）。
  * 随着向 Beta 推进（部分过渡期说明提及 macOS Tahoe/26+），现行 `1.0.0-beta.1` 与官方安装文档明确要求 **macOS 27 及以上**。对于需要覆盖 macOS 13~26 存量用户的 Bianzhong 而言，强依赖 Hammerspoon 2 会直接切断绝大多数桌面环境。
* **作为参照的 Hammerspoon v1 现状**：经典版 [`Hammerspoon/hammerspoon`](https://github.com/Hammerspoon/hammerspoon) 仍在维护关键修复——`1.0.0`（2024-08-06，升级 Lua 5.4.7，要求 macOS 12+）、`1.1.0`（2025-12-24，提升基线至 macOS 13.0 Ventura+，修复 `hs.window.filter` 按 PID 跟踪、修复 `hs.httpserver:start()` WebSocket bug 与 `hs.task` 参数校验）、`1.1.1`（2026-02-26，修复 Gatekeeper 资源分支问题）。v1 处于稳定成熟但以维持性修复为主的阶段。

### 1.2 架构设计变化（Swift + JavaScriptCore）

1. **配置引擎与共存机制**：
   * 入口脚本由 `~/.hammerspoon/init.lua` 变为 JavaScript 的 `init.js`（默认位于 `~/.config/Hammerspoon2/`，早期实验版亦使用过 `~/.config/hammerspoon2/`），同时提供 `hammerspoon.d.ts` 类型声明以支持 TypeScript 编译工作流。
   * 应用包 `Hammerspoon 2.app` 与 v1 完全隔离，**支持与 Hammerspoon 1 同机并行运行**，且官方明确不提供自动配置转换器，需手动按 [Migration Guide](https://www.hammerspoon.org/2/main/js/migration-guide.html) 迁移。
2. **对象生命周期规则（GC 语义反转）**：
   * 在 v1（Lua）中，局部变量创建的 watcher 若未挂到全局表，极易被 Lua GC 静默回收导致监听失效（经典“watcher 神秘停止”坑）。
   * 在 v2（JavaScriptCore）中，正在运行的对象（timer、watcher、task、eventtap）遵循类似浏览器/Node.js 的存活规则：只要尚未结束或显式 stop，即使 JS 侧没有保留引用也会继续触发回调。
3. **统一事件订阅模型与独立 `.spoon2` 分发**：
   * 原先分散的 `*.watcher` 子模块被大幅折叠，统一采用 `.on(event, fn)` / `.off()` / `.once()` 订阅范式。
   * 插件扩展后缀改为 `.spoon2`（CommonJS 风格 JS 模块，使用 `module.exports = { ... }`），放弃集中式 `spoons.hammerspoon.org` 索引，改为通过内置 `hs.spoons.use()` / `hs.spoons.install()` 直接从 GitHub 仓库或 URL 拉取加载。
4. **TCC 权限显式 Promise 化（`hs.permissions`）**：
   * 新增核心模块 `hs.permissions`，提供基于 Promise 的权限检查与申请原语，包括 `checkAccessibility` / `requestAccessibility`、`checkNotifications` / `requestNotifications`、`checkLocation` / `requestLocation`、`checkScreenRecording`、`checkInputMonitoring`、`checkCamera`、`checkMicrophone`、`checkBluetooth`。
   * 许多能力在 v2 中被强制前置权限门控：例如 `hs.notify` 必须先 `hs.permissions.requestNotifications()` 才能弹出通知；`hs.wifi` 获取 SSID/BSSID 必须先取得 `requestLocation()` 权限。

### 1.3 Hammerspoon 2 已实现/重构模块 vs 尚未迁移/刻意移除模块清单

根据 [Hammerspoon 2 Migration Guide](https://www.hammerspoon.org/2/main/js/migration-guide.html) 及文档索引，与 Bianzhong 感知及控制直接相关的 `hs.*` 模块状态如下：

| 类别 | 模块 / 能力 | Hammerspoon 2 状态 | 具体变化与对 Bianzhong 的影响 |
| :--- | :--- | :--- | :--- |
| **应用与窗口** | `hs.application` | **已实现（重构）** | 原 `hs.application.watcher` 折叠为 `hs.application.on('didLaunch', ...)` / `.off()` / `.once()`。 |
| | `hs.appfinder` / `hs.window` / `hs.screen` | **已实现** | `hs.window` **仅保留一次性查询与直接操作**（获取/移动/缩放窗口）。 |
| | `hs.window.filter` | **已移除（无直接替代）** | **重大缺失**。v1 最核心的规则过滤与全局窗口事件订阅引擎在 v2 中被移除；如需响应式监听窗口事件，必须在 `hs.ax` 之上自建 App 级 observer。 |
| | `hs.ax` | **已实现（重构）** | 替代/映射 v1 `hs.axuielement`，采用作用域订阅 `hs.ax.on(element, notification, listener)`。 |
| | `hs.spaces` | **受限/实验性** | 因 macOS 私有 API 限制，仍属实验性能力，依赖对 Dock 的 AX 交互或私有符号。 |
| **系统事件监听** | `hs.distributednotifications` | **已丢弃** | **重大缺失**。v2 宿主内部虽仍使用 `NSDistributedNotificationCenter`，但**不再向 JS 层暴露通用分布式通知监听接口**。 |
| | `hs.fs`（含 PathWatcher） | **已实现（重定位）** | 原 `hs.pathwatcher` 移入 `hs.fs.createPathWatcher(path)`，通过 `.setCallback()` 与 `.start()` 启用，基于 FSEvents 批处理，默认约 1 秒延迟。 |
| | `hs.pasteboard` | **已实现（合并）** | 原 `hs.pasteboard.watcher` 折叠为 `hs.pasteboard.on('change', handler)`，支持多独立监听器。 |
| | `hs.power` | **已实现（合并）** | 合并原 `hs.caffeinate`、`hs.caffeinate.watcher`、`hs.battery` 与 `hs.battery.watcher`；提供 `batteryInfo()`、`lockScreen()`、`preventSleep()`/`allowSleep()` 及 `hs.power.on('change', fn)`。 |
| | `hs.usb` / `hs.wifi` / `hs.audiodevice` / `hs.camera` | **已实现（合并）** | 各自原有 `.watcher` 子模块均折叠为主模块的 `.on()` / `.off()` / `.once()`（`hs.wifi` 需 Location 权限）。 |
| | `hs.network` | **已实现（承接）** | 承接网络信息查询（如原 `hs.host.addresses()` 移至 `hs.network.addresses()`）。 |
| **输入与自动化** | `hs.hotkey` / `hs.eventtap` / `hs.hid` / `hs.mouse` | **已实现** | 核心键鼠热键与低层输入拦截（`hs.eventtap` 需 Input Monitoring / Accessibility 权限）。 |
| | `hs.shortcuts` / `hs.applescript` / `hs.osascript` / `hs.urlevent` | **已实现（JS 化）** | 保留自动化桥接，回调与参数转为 JS 风格。 |
| | `hs.timer` / `hs.task` / `hs.sqlite3` | **已实现** | `hs.sqlite3` 支持 `{ readOnly: true }` 等 JS 风格接口与异常抛出。 |
| **IPC 与网络** | `hs.ipc` | **已实现（彻底重构）** | 底层由裸管道/`CFMessagePort` 改为 **XPC**（经内置 Broker 向 `launchd` 注册），需显式调用 `hs.ipc.start()`；**Release 版强制校验相同 Team ID 签名**。 |
| | `hs.http` / `hs.httpserver` | **已实现（增强 WebSocket）** | `hs.http` 全面 Promise 化（网络失败返回 `{ status: -1 }` 而非 reject），新增 `openWebSocket()`；`hs.httpserver` 提供裸 HTTP(S) 与 WebSocket 服务端，**移除了 `hsminweb` 模板框架**。 |
| | `hs.socket`（`hs.socket.udp`） | **缺失（据 Migration Guide）** | 官方迁移指南明确指出 **未移植原始 TCP/UDP Socket 模块**（含底层流协议与 Unix Domain Socket 能力），建议常规双向通信改用 `hs.http`/`hs.httpserver` 的 WebSocket。（注：部分外部文档站仍混用旧索引提及 `hs.socket`，但迁移指南实证其原始 TCP/UDP 能力已被裁剪。） |
| **UI 与标准库** | `hs.ui` / `hs.canvas` / `hs.chooser` / `hs.menubar` / `hs.notify` | **已实现（重塑）** | `hs.ui` 以 SwiftUI 声明式 UI 取代 `hs.drawing`、`hs.webview`、`hs.dialog`、`hs.alert`、`hs.styledtext`；`hs.notify` 新增按钮、文本回复、线程分组，但仍**只能发/管自身通知**。 |
| | `hs.json` / `hs.math` / `hs.utf8` / `hs.inspect` / `hs.fnutils` | **已移除** | 全部由 JavaScript 原生标准库（`JSON`、`Math`、Array 高阶方法、`console.log`）替代。 |

### 1.4 Hammerspoon v1 vs Hammerspoon v2 感知与通信能力客观对比

| 评估维度 | Hammerspoon v1 (`Hammerspoon/hammerspoon` 1.1.1) | Hammerspoon v2 (`Hammerspoon/Hammerspoon2` 1.0.0-beta.1) |
| :--- | :--- | :--- |
| **最低系统要求** | macOS 13.0 (Ventura)+ | **macOS 27+**（极早期 `0.0.6` 曾试探支持 15.6） |
| **实现栈与脚本层** | Objective-C (`LuaSkin`) + Lua 5.4.7 | 纯 Swift + 原生 `JavaScriptCore`（支持 TS 编译） |
| **当前成熟度** | 极高（十余年生产验证，社区 `.spoon` 生态庞大） | 早期 Beta（核心架构新立，模块仍在社区反馈补齐中） |
| **`hs.application.watcher`** | 成熟独立子模块 | 折叠为 `hs.application.on()`，功能等价 |
| **`hs.window.filter`** | **有且功能完备**（v1.1.0 修复按 PID 跟踪），但首加载需枚举所有窗口，遇 `WebKit.WebContent` 或卡死 App 的 AX 查询可能阻塞数秒 | **已移除**，必须自己通过 `hs.ax` 从零维护窗口与焦点状态机 |
| **`hs.pasteboard.watcher`** | 成熟，底层 0.25s 定时轮询 `changeCount` | 折叠为 `hs.pasteboard.on('change', ...)` |
| **`hs.pathwatcher`** | 成熟独立模块，基于 FSEvents | 移至 `hs.fs.createPathWatcher()`，批处理延迟约 1s |
| **`hs.caffeinate.watcher`** | 成熟，覆盖睡眠/唤醒/锁屏/快速切换用户 | 合并入 `hs.power.on()` |
| **`hs.distributednotifications`** | 成熟（但高负载下不保证 100% 投递） | **已移除 JS 暴露接口** |
| **`hs.ipc` 与 CLI** | `CFMessagePort`（Mach Port）驱动 `hs` CLI；单线程阻塞或重入时报错 `"Instance already recursing, refusing request"` | **XPC + 内嵌 `launchd` Broker** 驱动 `hs2` CLI；需显式 `hs.ipc.start()`；**Release 构建限制同 Team ID 签名才能连入** |
| **`hs.socket` & `hs.httpserver`** | `hs.socket`（CocoaAsyncSocket）完整支持 **Unix Domain Socket** / TCP / UDP；`hs.httpserver` 成熟支持 HTTP/WS | **无原始 TCP/UDP/UDS Socket**；仅保留 `hs.httpserver` 裸 HTTP(S)/WebSocket 与 `hs.http.openWebSocket()` |

### 1.5 对 Bianzhong 的关键警示：IPC 阻断与单线程风险

1. **XPC Team ID 门禁使 `hs.ipc` 无法作为通用外部总线**：在 Hammerspoon 2 中，`hs.ipc` 专为同属 Hammerspoon 签名团队的 `hs2` CLI 与主 App 通信设计。Bianzhong 作为独立守护进程/CLI 二进制（或用户本地编译的 Rust/Go/Swift 工具），在 Release 环境下**根本无法直接通过 XPC 连入 Hammerspoon 2 的 `hs.ipc`**。若需要双向互通，Hammerspoon 2 侧要么通过 `hs.task` 主动调用外部 CLI（如 `bz emit`），要么通过 `hs.http.post` / WebSocket 与 Bianzhong 通信。
2. **主线程阻塞传染**：Hammerspoon v1 与 v2 本质上都是**单线程事件循环**（分别跑在 Lua VM 和 JSContext 主线程上），同时掌管用户的全局快捷键（`hs.hotkey`）、鼠标拦截（`hs.eventtap`）和窗口操控。一旦在 Hammerspoon 内部执行同步阻塞操作、复杂正则/JSON 解析或等待 Agent 响应，**整个 macOS 桌面的热键与窗口响应都会卡死**。另外，用户日常修改 `init.lua`/`init.js` 并触发 `hs.reload()` 时，进程内所有内存状态、队列与子进程句柄都会重置——这决定了 Hammerspoon 只能做**无状态/弱状态的薄传感器与执行胶水**，绝不可承载 Bianzhong 核心运行时。

---

## 2. macOS 原生事件与通知感知的技术现实与权限边界（TCC / SIP / Sandbox）

### 2.1 TCC / SIP / App Sandbox 基础边界

macOS 针对后台常驻型 Agent 构筑了三层刚性防线，任何感知设计都必须把“TCC 权限预算”作为一等约束：

1. **TCC（Transparency, Consent, and Control，由 `tccd` 守护）**：
   * **Full Disk Access (FDA)**：读写邮件（Mail）、信息（Messages `chat.db`）、Safari 数据及 `~/Library/Group Containers/` 下受保护的系统容器（含 macOS 15+ 通知库、Focus 数据库）。苹果近年针对 AI Agent 滥用 FDA 收紧审核，一旦授予几乎等于敞开用户全盘隐私。
   * **Accessibility（辅助功能）**：调用 `AXUIElement` / `AXObserver` 读取其他应用的窗口树、UI 元素、文本焦点或模拟点击按键。
   * **Input Monitoring（输入监控）**：全局监听底层键盘敲击（不含快捷键全局注册和纯空闲时间查询）。
   * **Automation（AppleEvents）**：通过 AppleScript / JXA / `NSAppleEventManager` 控制另一款 App（如读取 Mail、Finder），受目标 App 级独立授权约束，未授权抛出 `-1743` (`errAEEventNotPermitted`)。
   * **Code Responsibility（代码责任链继承）**：从 Terminal / iTerm2 启动的非打包 CLI 脚本或守护进程，默认继承终端宿主的 TCC 权限。这在本地开发中看似便利，但在生产部署中极其危险——给 Terminal 开了 FDA，等于该终端拉起的任何脚本和 Agent 子进程都拥有了 FDA。
2. **App Sandbox (`sandbox.sb`)**：若以 `.app` 沙箱化分发，文件读写将被锁死在自身容器目录，无法随意调用任意 CLI、读写用户代码仓库或自由发送未声明 `scripting-targets` 的 AppleEvents，甚至 Mach/XPC 查找也受限。因此 Bianzhong 核心更适合以非沙箱独立后台进程 + 极小权限独立 Helper 形态运行。
3. **SIP（System Integrity Protection）**：内核级保护系统文件与 `/Library/Application Support/com.apple.TCC/TCC.db` 及用户级 `TCC.db`。即便是 `root` 进程也**无法绕过 SIP 直接写入 TCC 授权**——所有敏感权限都必须由用户在“系统设置 → 隐私与安全性”手工确认（或通过企业 MDM 下发）。

### 2.2 核心难点：第三方应用通知获取的现实壁垒与三条路径对比

> **硬性技术事实**：macOS **不存在任何公开 API** 允许第三方应用或脚本读取其他 App 发出的通知。  
> Apple 的 `UNUserNotificationCenter.current().getDeliveredNotifications()`（以及旧版 `NSUserNotificationCenter`、Hammerspoon 的 `hs.notify`）严格按 App Bundle ID 沙箱隔离——它们**只能读取当前进程自身投递的通知**，对微信、飞书、Slack、Mail、Messages 等其他 App 的通知完全不可见。`NSDistributedNotificationCenter` 则是应用自愿广播的 IPC 消息通道，**不包含**通知中心的弹窗横幅文本。

针对“获取 macOS 上发生了什么通知/消息”，工程上只有三条真实可行的路径：

#### 路径 (a)：Accessibility API（`AXObserver` 监听 `com.apple.notificationcenterui`）

* **实现机理**：通过 `NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui")` 获取 Notification Center 进程 PID，构造 `AXUIElementCreateApplication(pid)`，通过 `AXObserverCreate` 将回调挂载到 `CFRunLoop`，订阅 `kAXCreatedNotification`（或窗口创建事件），在横幅出现的瞬间遍历 `kAXWindowsAttribute` 下的 AX 元素树提取应用名、标题与摘要文本。
* **TCC 权限代价**：仅需 **Accessibility（辅助功能）** 权限，不需要 Full Disk Access（若用户本就给 Hammerspoon 开了 Accessibility，可零新增弹窗复用）。
* **核心缺陷（实证高频失效场景）**：
  1. **专注模式（Focus / DND）与锁屏下彻底漏抓**：当 Focus 模式静音某 App 横幅、设为“锁屏不显示预览”或启用“通知摘要（Scheduled Summary）”时，`com.apple.notificationcenterui` **不会渲染弹窗横幅窗口**，`AXObserver` 回调压根不会触发，重要消息直接丢失。
  2. **跨版本 UI 层级极其脆弱**：从 macOS Ventura (13) → Sonoma (14) → Sequoia (15) → Tahoe (26) / 27，Notification Center 横幅与抽屉控件的 AX 树结构（容器角色、按钮层级、分组方式）屡次变动，一次系统小更新即可导致解析器抓空。
  3. **极短生命周期竞态与进程卡死风险**：横幅通常几秒后自动收起，遍历深层 AX 树时极易遭遇 `kAXErrorInvalidUIElementObserver` 报错；且国内外开发者均记录过因外部 `AXObserver` 频繁钩挂 `com.apple.notificationcenterui` 引发的竞态死锁，导致系统 `NotificationCenter` 进程 CPU 飙升至 100%（需 `killall NotificationCenter` 才能恢复）。
  4. **文本截断**：横幅 UI 本身只显示一两行摘要，长邮件、长聊天或代码片段已被 OS 截断。

#### 路径 (b)：Notification Center SQLite WAL 数据库监听（`db2/db` + `FSEvents`）

* **实现机理**：macOS 通知守护进程 `usernoted` 会将所有送达的通知持久化到 SQLite 数据库（启用 WAL 日志模式）：
  * **macOS 14 Sonoma 及更早版本**：路径位于动态用户临时目录 `$(getconf DARWIN_USER_DIR)/com.apple.notificationcenter/db2/db`（即 `/private/var/folders/<xx>/<id>/0/com.apple.notificationcenter/db2/db`，或 `$TMPDIR/../0/com.apple.notificationcenter/db2/db`）。早期该路径普通用户进程无需 FDA 即可直接读取（安全研究员 Patrick Wardle 发布的 [`objective-see/AuRevoir`](https://github.com/objective-see/AuRevoir) 与 Yogesh Khatri 的 [`MacForensics/macNotifications.py`](https://github.com/ydkhatri/MacForensics/blob/master/macNotifications.py) 均利用了此结构）。
  * **macOS 15 Sequoia 及更高版本**：Apple 出于隐私安全加固（防范本地工具静默收割 2FA 验证码与聊天摘要），将该数据库迁移至受 TCC 严格保护的 Group Container：  
    **`~/Library/Group Containers/group.com.apple.usernoted/db2/db`**。
  * **监听与解析细节**：监听同目录下的 `db-wal`（Write-Ahead Log）文件变更（通过 `FSEvents`），以只读模式查询（注意：必须连同 `db-wal` / `db-shm` 一起读取或以只读 SQLite 事务快照读取，否则会漏掉尚未 checkpoint 到主 `db` 的最新通知）。核心表为 `app`（`app_id`, `identifier`）与 `record`（`rec_id`, `app_id`, `uuid`, `data`, `request_date`, `delivered_date`, `presented`, `style`, `snooze_fire_date`）：
    * `delivered_date` 采用 **Core Data / Mac Absolute Time**（自 `2001-01-01 00:00:00 UTC` 起的秒数，加 `978307200` 转为 Unix Epoch）。
    * `data` 列为二进制 Property List（`bplist00`，常见 `NSKeyedArchiver` 封装），需用 `NSPropertyListSerialization` / `plutil` / `plistlib` 解包获取标题、副标题、正文文本。
* **TCC 权限代价与工程风险**：
  1. **macOS 15+ 强制要求 Full Disk Access (FDA)**：如果让 Bianzhong 主守护进程去读该库，意味着整个 Agent 运行时都要拿最高危的 FDA 权限，极易引起用户拒绝授权与安全合规隐患。
  2. **非公开私有 Schema 风险**：表结构、`bplist` 键名（如 `req.titl` / `req.body`）及路径在苹果大版本迭代中无任何向后兼容承诺；同时若读连接持有共享锁不当，有干扰 `usernoted` 写入甚至损坏只读视图的隐患（且通知正文依然可能受发送方隐私选项/横幅摘要截断）。

#### 路径 (c)：协议层与源头信号接入（强烈推荐作为主路径！）

与其在 UI 渲染尾部（路径 a）或系统私有存储底部（路径 b）“逆向打捞”已被截断的纯文本通知，不如直接从**事件源头或系统公开自动化契约**接入完整结构化信号：

1. **IM / 协作平台 Webhook 与长连接桥接**：
   * 飞书（Feishu/Lark）事件订阅 / WebSocket 长连接、Slack Events API / Socket Mode、Telegram Bot API、GitHub Webhook / `gh` 事件、邮件 IMAP IDLE。
   * **天然优势**：零 macOS TCC 权限；消息字段完整（发送者 ID、群组/频道、Thread ID 可直接映射为 `correlation_key`、原始 Markdown 正文与引用链、消息 Deep Link），彻底消除横幅截断问题；且不依赖本地桌面 App 是否打开或是否被 Focus 静音。
2. **macOS 26 (Tahoe)+ Shortcuts 原生本地自动化触发器**：
   * 自 **macOS 26 (Tahoe)** 起，Apple 为桌面端 Shortcuts 补齐了长期缺失的 **Automation（自动化触发器）**，支持 **Time of Day**、**App（打开/退出）**、**Focus（专注模式开关）**、**Folder（指定目录文件增删改）** 等本地触发条件，并允许选择 **Run Immediately（后台静默立即执行）**。用户只需在快捷指令末尾调用 `bz emit` 或本地 HTTP 请求，即可在 **零 FDA / 零 Accessibility** 的前提下把原生 OS 事件精准送入 Bianzhong。
3. **AppleScript / JXA 脚本字典（Automation 按需授权）**：
   * 针对未开放 Webhook 但具备丰富 Scripting Dictionary 的本地专业软件（如 Apple Mail 规则触发脚本、Messages、Calendar、DEVONthink、Finder），按单 App 粒度授予最小化的 **Automation** 权限即可结构化提取上下文。
4. **`NSDistributedNotificationCenter`（仅作轻量系统态补充）**：
   * 适用于捕获主动发广播的本地进程状态，如 `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked`、`AppleInterfaceThemeChangedNotification`、`AppleSelectedInputSourcesChangedNotification`、媒体播放状态 `com.spotify.client.PlaybackStateChanged` 与 `com.apple.iTunes.playerInfo` 等（调试期可用 `notifyutil -a` 或 Swift `addObserver(forName: nil)` 探查）。但它**不承载其他 App 的用户通知内容**，且系统高负载时无投递保证。

#### 三条通知感知路径综合对比

| 维度 | (a) AXObserver 抓 UI 横幅 | (b) Notification SQLite WAL 监听 | (c) 源头协议 + Shortcuts + 补充广播 |
| :--- | :--- | :--- | :--- |
| **所需最高 TCC 权限** | **Accessibility（辅助功能）** | **Full Disk Access（macOS 15+ 必选）** | **Zero-TCC**（仅 AppleScript 需按 App 授 Automation） |
| **触发延迟** | 毫秒级（弹窗瞬间） | 百毫秒 ~ 1 秒级（WAL 写入 + FSEvents） | 毫秒 ~ 秒级（长连接/Webhook/原生回调） |
| **Focus / 锁屏 / 摘要漏抓** | **严重漏抓**（不弹窗即无事件） | 不漏抓（入库即记录） | **不漏抓**（独立于桌面弹窗渲染） |
| **内容完整性** | 差（仅剩截断后的 UI 纯文本） | 中（受 App 原始通知载荷限制，需解 `bplist`） | **极高**（完整上下文、Thread ID、发送者、附件/链接） |
| **跨 macOS 版本稳定性** | 极脆弱（AX 树常变，易卡死 `NotificationCenter`） | 脆弱（macOS 15 刚迁路径，私有 Schema 无保障） | **极高**（基于公开 Webhook / Shortcuts / 开放协议） |
| **在 Bianzhong 中的定位** | 仅作极少数无协议桌面 App 的**可选兜底插件** | 仅作**完全隔离的只读外部 Sensor**，默认关闭 | **绝对主力信号入口（90%+ 核心业务触发）** |

> **为什么“源头协议 + OS 状态补充”最契合低侵入理念？**  
> 源头协议解决 **“发生了什么事（Event Payload）”**——结构化、高信噪比、自带会话关联键且无需窥探用户整台电脑的私有数据库；而本地 OS 感知只解决 **“用户此刻是否方便被打扰 / 在做什么（Ambient Context）”**。两者正交解耦后，Bianzhong 无需索要全盘访问权，也不会因系统小版本更新把通知中心 UI 改版而崩溃。

---

### 2.3 其他关键 macOS 系统信号感知技术细节

| 信号类型 | 底层原生机制 / API | 性能开销与技术坑点 | TCC 权限与隐私红线 |
| :--- | :--- | :--- | :--- |
| **剪贴板变化** | `NSPasteboard.general.changeCount` 定时轮询（macOS 无原生推送/KVO；Hammerspoon v1 默认 0.25s 一次） | 单纯读取整型 `changeCount` 几乎零 CPU/内存开销；**切忌每次轮询都读取 pasteboard 内容实体**（大图片/富文本序列化开销大）。可在窗口激活切回时补充检测降低空转频率。 | 无独立系统弹窗，但**隐私红线极高**：读取内容前**必须**检查 pasteboard item types 是否包含 [nspasteboard.org](https://nspasteboard.org/) 标准标记——遇到 `org.nspasteboard.ConcealedType`（1Password/Bitwarden 密码/密钥）、`org.nspasteboard.TransientType`（文本扩展器瞬时占位）或 `org.nspasteboard.AutoGeneratedType` 时**必须立即丢弃，严禁写入日志或发送给 LLM**。 |
| **文件系统变化** | CoreServices `FSEventStreamCreate`（传入 `kFSEventStreamCreateFlagFileEvents` 获取文件级事件） | 利用内核级 `latency` 参数（如 0.5s~1.0s）天然实现**事件合并（Coalescing）**，避免 `git checkout` / `npm install` 时事件雪崩（交互式首包才需 `kFSEventStreamCreateFlagNoDefer`）。睡眠唤醒后（`NSWorkspace.didWakeNotification`）需重启或校验 stream，并硬排除 `.git/`、`node_modules/`、构建产物目录。 | 监视普通用户工作区/代码目录无需 FDA；仅监视受保护目录（如 Mail/Messages/Group Containers）触发 FDA。 |
| **前台 App 与窗口焦点** | App 切换：`NSWorkspace.shared.notificationCenter`（`didActivateApplicationNotification`）；窗口标题/文档路径：`AXObserver` | `NSWorkspace` 轻若无物且极稳定；`AXObserver` 遍历卡死进程时可能阻塞调用线程，需设超时并过滤无标题瞬态浮窗。 | `NSWorkspace` **零 TCC 权限**；读取窗口标题与 `AXDocument` 需 **Accessibility**。 |
| **用户空闲时间（Idle Time）** | CoreGraphics `CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)`（对应 C 常量 `kCGAnyInputEventType`，也常用 `.combinedSessionState`；或 `ioreg -c IOHIDSystem` 查 `HIDIdleTime`） | 仅读取距上次键鼠输入的秒数，几乎零消耗，不捕获任何按键内容。 | **无需 Input Monitoring 权限**，纯计数级无侵入感知，是判断“人是否在电脑前”的黄金指标。 |
| **专注模式（Focus / DND）** | 1) 公开 API：`Intents` 框架 `INFocusStatusCenter.default.focusStatus.isFocused`；<br>2) 私有存储：`~/Library/DoNotDisturb/DB/Assertions.json` & `ModeConfigurations.json`；<br>3) macOS 26+ **Shortcuts Focus 自动化** | `INFocusStatusCenter` 仅返回布尔值，无法识别具体 Focus 名称（如 Work vs Sleep）；`Assertions.json` 可通过 `data[].storeAssertionRecords[].assertionDetails.assertionDetailsModeIdentifier` 解析具体模式名，但属于私有内部文件且存在 Schema 变动风险。 | `INFocusStatusCenter` 需 `NSFocusStatusUsageDescription` 并弹窗授权；读取 `~/Library/DoNotDisturb/DB/` 需 **Full Disk Access**；**Shortcuts Focus Trigger（macOS 26+）零 FDA、实时推送且能区分具体模式名，是最佳补充方案**。 |
| **定时、睡眠唤醒与会话** | `LaunchAgent`（`KeepAlive` 保活 / `StartInterval` 周期调度）；`NSWorkspace.willSleepNotification` / `didWakeNotification`、`screensDidSleepNotification`、`IORegisterForSystemPower`、`IOPS`（`IOPowerSources` 电源/电量）；`com.apple.screenIsLocked` | 必须使用 GUI 上下文下的 `LaunchAgent`（而非 root `LaunchDaemon`），才能正常访问用户会话 `NSWorkspace`、`CGEventSource` 与 UDS。睡眠前暂停轮询，唤醒后延迟数秒等网络重连再批量恢复感知。 | **零 TCC 权限**。 |
| **网络与外设 / 会议占用状态** | 网络：`Network.framework` 的 **`NWPathMonitor`**（替代旧版 `SCNetworkReachability`）；<br>外设/会议态：`IOUSBHost`/`IOKit`（USB 扩展坞/显示器）、CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere`（麦克风使用态）、CoreMediaIO `kCMIODevicePropertyDeviceIsRunningSomewhere`（摄像头激活态） | `NWPathMonitor` 可区分 Wi-Fi / 有线 / `.satisfied` / `.unsatisfied` / `isExpensive`；底层设备运行状态属性（如 OverSight 采用的原理）可在不开启音视频流的情况下检测“用户是否正在开视频会议”，从而自动升级免打扰策略。 | `NWPathMonitor` 与底层 CoreAudio / CoreMediaIO 的 `*IsRunningSomewhere` 设备状态属性均**无需 Camera/Microphone TCC 弹窗**（注意：高层 `AVCaptureDevice` / `hs.camera` 枚举则需 Camera TCC 权限）；读取 Wi-Fi 具体 **SSID/BSSID** 在现代 macOS 上强制要求 **Location（定位）** 权限。 |

---

## 3. 面向“薄与低侵入”的感知层架构建议

### 3.1 为什么绝不应把 Bianzhong 核心强绑定在 Hammerspoon 2 进程内部？

1. **进程隔离与桌面稳定性**：无论 Hammerspoon v1（单线程 Lua）还是 Hammerspoon v2（单线程 JavaScriptCore），都承载着用户最敏感的实时交互热路径（快捷键拦截、窗口切换）。将 LLM 分诊、会话路由或外设同步阻塞逻辑塞进 Hammerspoon 进程内，任何卡顿或异常都将直接冻结桌面；且用户日常修改配置触发 `hs.reload()` 会无差别重置进程内存态。
2. **Hammerspoon 2 的工程限制不可忽视**：
   * `1.0.0-beta.1` 强制要求 **macOS 27+**，强绑定将直接抛弃 macOS 14/15/26 全部存量机器；
   * `hs.window.filter`、`hs.distributednotifications`、原始 `hs.socket` 均已移除，许多感知能力在 v2 中反而需要重造轮子；
   * v2 的 `hs.ipc` 改用同 Team ID 校验的 XPC，第三方的外部 Bianzhong 二进制无法直接把 v2 当作通用 IPC 枢纽。
3. **TCC 权限爆炸半径最小化（Blast Radius Isolation）**：如果感知核心绑定在 Hammerspoon 内，Bianzhong 运行时将连带继承 Accessibility、Input Monitoring 甚至 Location/ScreenRecording 权限，导致后续派生的 Agent 子进程或工具链在非沙箱环境下共享过高权限；剥离后，**Bianzhong Core 自身可以实现 100% Zero-TCC**。
4. **生命周期与多生态兼容**：将感知作为可插拔外部协议后，同一个 Bianzhong Daemon 可以同时接收 Hammerspoon v1（macOS 13+ 存量主力）、Hammerspoon v2（macOS 27+ 前沿用户）、独立原生 Swift 微型 Helper、Apple Shortcuts、Git Hooks 乃至云端 IM 网关的信号。

### 3.2 可插拔信号源统一接入协议（三态薄通道）

建议 Bianzhong Core（`bzd`）以纯用户态 `LaunchAgent` 运行，对外只暴露一套极简、语言无关的摄入面，全部投递统一格式的事件信封（JSON Envelope）：

```text
[传感器层 Thin Sensors]                              [Bianzhong 摄入面]
  ├─ IM Webhook / GitHub 长连接桥接 (Zero-TCC) ───────▶ Unix Domain Socket (主通道，NDJSON 流)
  ├─ 原生轻量 Swift Sensor (NSWorkspace/NWPath/Idle) ─▶ ~/Library/Application Support/bianzhong/ingest.sock
  ├─ Hammerspoon v1 (hs.socket 原生 UDS) ─────────────┘
  │
  ├─ Hammerspoon v2 (hs.task 调用) ───────────────────▶ `bz emit` CLI (短连接写 UDS / 离线落盘缓冲)
  ├─ macOS 26+ Shortcuts 自动化 (Run Shell Script) ───▶ `bz emit --source shortcuts --type focus.changed`
  ├─ Git Hook / Claude / OMP Hook ────────────────────┘
  │
  ├─ Hammerspoon v2 (hs.http.post，无需拉起子进程) ─▶ 可选 Localhost HTTP POST 127.0.0.1:<port>/v1/events
  │                                                      (启动时生成随机 Bearer Token 写入 0600 文件鉴权)
  └─ CLI 调试 / 测试回放 / 一次性管道 ────────────────▶ JSONL stdin (`cat fixtures.jsonl | bzd --stdin`)
```

**各通道选型准则**：
* **首选常驻通道 — Unix Domain Socket (`ingest.sock`, `0600` 权限)**：无端口冲突、无需 TLS 配置、内核本地零拷贝流式投递（NDJSON），适合常驻 Swift Helper、IM Bridge 及 Hammerspoon v1（原生 `hs.socket` 支持 UDS）。
* **首选一次性通道 — `bz emit` CLI**：毫秒级启动的静态单二进制，从参数或 `stdin` 读入事件后写入 `ingest.sock` 即刻退出；完美解决 **Hammerspoon 2 缺少 `hs.socket`、Apple Shortcuts、Git Hook、Mail AppleScript 规则** 等“只发不收”的短触达场景。
* **兼容通道 — Localhost HTTP + 本地 Token（可选）**：当 Hammerspoon 2 侧高频上报事件（如窗口焦点或剪贴板）希望避免频繁 `hs.task` fork `bz emit` 进程开销时，可直接用 v2 原生 Promise 化的 `hs.http.post('http://127.0.0.1:.../v1/events')` 或 `hs.http.openWebSocket()` 复用长连接（无需任何 XPC Team ID 绑定）。
* **测试与无守护模式 — JSONL `stdin`**：天然支持管道编排与离线回归测试。

### 3.3 分层“薄 Sensor”部署拓扑建议

为了把侵入感降到最低，建议将感知能力划分为三个独立安装、独立授权的层级：

1. **Layer 1：Zero-TCC 核心信号层（默认启用）**
   * **协议源接入器**：飞书/Slack/Telegram Webhook/WS 桥接、Git/GitHub 事件监听。
   * **Shortcuts 自动化包（macOS 26+）**：提供官方 `.shortcut` 模板（Focus 开关、特定 Folder 文件变更、App 启停），通过 `bz emit` 推送，**零隐私弹窗**。
   * **极薄原生状态 Sensor（Swift `bz-context-sensor`，可合并进 `LaunchAgent`）**：仅使用零 TCC 权限 API——`NSWorkspace`（前台 App 切换、睡眠唤醒）、`NWPathMonitor`（在线/离线）、`CGEventSource.secondsSinceLastEventType`（空闲秒数）、CoreAudio/CoreMediaIO `*IsRunningSomewhere` 属性（麦克风/摄像头开会占用态，避免调用高层 `AVCaptureDevice` 触发权限弹窗）。剪贴板检测可选开启，并在 Sensor 侧**就地丢弃** `org.nspasteboard.ConcealedType` / `TransientType` / `AutoGeneratedType` 数据，不使密码离开本机剪贴板进程。
2. **Layer 2：可选桌面胶水层（Hammerspoon v1 / v2 Sensor）**
   * **不强绑特定版本**：提供极薄的 `bianzhong.spoon`（v1 Lua，兼容 macOS 13+，走 `hs.socket` UDS）与 `bianzhong.spoon2`（v2 JS，兼容 macOS 27+，走 `hs.http.openWebSocket` 或 `hs.task` + `bz emit`）。
   * 仅承担用户已有 Hammerspoon 环境的增量复用：全局热键手工一键唤起 Agent（Push-to-Agent）、窗口标题/`AXDocument` 上下文补充、USB 扩展坞/音频外设触发工作区切换，以及调用 `hs.ui` / `hs.chooser` 承接轻量桌面审批确认卡。
3. **Layer 3：高敏隔离兜底层（默认禁用，按需显式开启）**
   * 仅当用户必须感知**完全封闭且无协议/无 AppleScript 接口的第三方 App 通知**时，才提供完全独立的极薄子进程 `bz-notif-ax`（仅需 Accessibility 监听 `com.apple.notificationcenterui`）或 `bz-notif-db`（独立 Binary，仅由用户单独授予只读用途的 Full Disk Access 读取 `usernoted/db2/db`），其内部完成 `bplist` 解码与敏感字段正则脱敏后，仅通过 `bz emit` 输出最小化摘要，**严禁将 FDA 权限授予 Bianzhong 核心运行时或下属 Agent 进程**。

---

## 4. 参考资料与实证来源

* **Hammerspoon 2 官方与代码仓库**：
  * Hammerspoon 2 GitHub 仓库（原 `cmsj/Hammerspoon2`）：[https://github.com/Hammerspoon/Hammerspoon2](https://github.com/Hammerspoon/Hammerspoon2)
  * Hammerspoon 2 `1.0.0-beta.1` 发布页：[https://github.com/Hammerspoon/Hammerspoon2/releases/tag/1.0.0-beta.1](https://github.com/Hammerspoon/Hammerspoon2/releases/tag/1.0.0-beta.1)
  * Hammerspoon 2 官方文档门户：[https://www.hammerspoon.org/2/](https://www.hammerspoon.org/2/)
  * Hammerspoon 2 官方迁移指南（模块增删与 `hs.ipc`/`hs.socket`/`hs.window.filter` 变更实证）：[https://www.hammerspoon.org/2/main/js/migration-guide.html](https://www.hammerspoon.org/2/main/js/migration-guide.html)
  * 早期 JS API 文档镜像：[https://cmsj.github.io/Hammerspoon2/](https://cmsj.github.io/Hammerspoon2/)
* **Hammerspoon v1 官方与文档**：
  * Hammerspoon v1 GitHub 仓库：[https://github.com/Hammerspoon/hammerspoon](https://github.com/Hammerspoon/hammerspoon)
  * Hammerspoon 官方文档索引：[https://www.hammerspoon.org/docs/](https://www.hammerspoon.org/docs/)（含 [`hs.task`](https://www.hammerspoon.org/docs/hs.task.html)、[`hs.hotkey`](https://www.hammerspoon.org/docs/hs.hotkey.html)、[`hs.eventtap`](https://www.hammerspoon.org/docs/hs.eventtap.html)、[`hs.timer`](https://www.hammerspoon.org/docs/hs.timer.html)、[`hs.urlevent`](https://www.hammerspoon.org/docs/hs.urlevent.html)、[`hs.shortcuts`](https://www.hammerspoon.org/docs/hs.shortcuts.html)、[`hs.osascript`](https://www.hammerspoon.org/docs/hs.osascript.html)）
* **macOS 通知数据库、剪贴板规范与系统感知研究**：
  * Yogesh Khatri — `MacForensics` (`macNotifications.py` SQLite & `bplist` 解析实现)：[https://github.com/ydkhatri/MacForensics/blob/master/macNotifications.py](https://github.com/ydkhatri/MacForensics/blob/master/macNotifications.py)
  * Patrick Wardle / Objective-See — `AuRevoir`（Notification Center DB 工具）：[https://github.com/objective-see/AuRevoir](https://github.com/objective-see/AuRevoir)
  * macOS 剪贴板敏感数据标记社区规范（`ConcealedType` / `TransientType` / `AutoGeneratedType`）：[https://nspasteboard.org/](https://nspasteboard.org/)
  * Apple Developer Frameworks：`UNUserNotificationCenter`、`NSDistributedNotificationCenter`、`INFocusStatusCenter`、`FSEventStreamCreate`、`NWPathMonitor`、`CGEventSourceSecondsSinceLastEventType`、`NSWorkspace`（`developer.apple.com` 官方文档体系）。
