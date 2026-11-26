import AppKit
import BianzhongCore
import Combine
import Foundation
import SwiftUI

enum MenuBarTab: String, CaseIterable, Identifiable {
    case inbox = "待办"
    case rules = "规则"
    case settings = "设置"

    var id: String { rawValue }
}

struct RuleTestFeedback: Equatable {
    let passed: Bool
    let message: String
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString) else {
            return
        }
        Task { @MainActor in
            AppModel.shared?.handleURL(url)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls {
                AppModel.shared?.handleURL(url)
            }
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static weak var shared: AppModel?

    @Published var selectedTab: MenuBarTab = .inbox
    @Published var consoleSection: ConsoleSection = .general
    @Published var consoleSelectedRuleID: String?
    @Published var auditStageFilter: String = "all"
    @Published var auditSearchQuery: String = ""
    @Published var pendingApprovals: [ApprovalRecord] = []
    @Published var activeRuns: [LiveRunSnapshot] = []
    @Published var recentRuns: [RunRecord] = []
    @Published var rules: [ChimeRule] = []
    @Published var auditEvents: [EventAuditRecord] = []
    @Published var worktrees: [ManagedWorktreeInfo] = []
    @Published var storedSecrets: [String: String] = [:]
    @Published var webhookToken: String = ""
    @Published var webhookStatus: WebhookStatusInfo = WebhookStatusInfo(enabled: true, running: false, host: "127.0.0.1", port: 17380, errorMessage: nil)
    @Published var tailscaleStatus: TailscaleStatusInfo = TailscaleStatusInfo(installed: false)
    @Published var preferredTerminal: String = "auto"
    @Published var notchHUDEnabled: Bool = true
    @Published var notchHotkey: String = "option+space"
    @Published var todayRunsCount: Int = 0
    @Published var todayCostUSD: Double = 0.0
    @Published var paused = false
    @Published var deferredCount = 0
    @Published var feishuEnabled = true
    @Published var feishuStatus: FeishuSensorStatus = .disabled
    @Published var feishuErrorMessage: String?
    @Published var cliStatus: CLIIntegrationStatus = CLIIntegration.currentStatus()
    @Published var statusBannerMessage: String?

    let orchestrator: Orchestrator
    let notificationManager: NotificationManager
    let notchHUD = NotchHUDController()
    private var consoleWindow: NSWindow?
    private var wakeObservers: [Any] = []
    private var promptedFDACurrentSession = false
    private var isPresentingFDAAlert = false
    private let fdaSuppressDefaultsKey = "bz_suppress_fda_alert"

    var enabledRulesCount: Int {
        rules.filter(\.enabled).count
    }

    init() {
        let paths = BianzhongPaths()
        _ = try? DefaultTemplates.installDefaultsIfMissing(paths: paths)
        CLIIntegration.autoInstallOnLaunchIfEligible()

        var capturedSelf: AppModel?
        let callbacks = OrchestratorCallbacks(
            onApprovalUpdated: {
                Task { @MainActor in
                    capturedSelf?.refresh()
                }
            },
            onNotifyApproval: { approval in
                Task { @MainActor in
                    capturedSelf?.notificationManager.postNotification(for: approval)
                }
            },
            onLiveStreamUpdated: {
                Task { @MainActor in
                    capturedSelf?.refreshLiveStreamOnly()
                }
            }
        )

        do {
            self.orchestrator = try Orchestrator(paths: paths, callbacks: callbacks)
        } catch {
            fatalError("Failed to initialize Bianzhong orchestrator: \(error)")
        }
        self.notificationManager = NotificationManager(orchestrator: self.orchestrator)
        capturedSelf = self
        Self.shared = self

        try? orchestrator.start(enableBuiltInSensors: true, enableWebhookServer: true)
        notificationManager.setupIfSupported()
        registerWakeObservers()
        refresh()
        notchHUD.attach(to: self)
    }

    func openConsoleWindow(section: ConsoleSection? = nil, ruleID: String? = nil) {
        if let section {
            consoleSection = section
        }
        if let ruleID {
            consoleSelectedRuleID = ruleID
        }
        refreshConsoleData()

        if let existing = consoleWindow {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = ConsoleWindowView(model: self)
        let hosting = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hosting)
        window.title = "编钟 · 控制台"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 920, height: 620))
        window.center()
        window.isReleasedWhenClosed = false
        self.consoleWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func handleURL(_ url: URL) {
        switch orchestrator.handleIncomingURL(url) {
        case .invalidURL:
            return
        case .unauthorized:
            statusBannerMessage = "已拦截令牌无效的 bianzhong:// 外部请求"
        case .handled(let action):
            refresh()
            if case .openConsole(let tabRaw, let ruleID) = action {
                let sec = tabRaw.flatMap { ConsoleSection.resolve($0) } ?? .general
                openConsoleWindow(section: sec, ruleID: ruleID)
            }
        case .requiresConfirmation(let action):
            confirmExternalURLAction(action)
        }
    }

    private func confirmExternalURLAction(_ action: BianzhongURLAction) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "确认执行外部链接请求？"
        switch action {
        case .emit(let ev, _):
            let title = ev.payload["title"] ?? ev.type
            alert.informativeText = "外部应用请求向 Bianzhong 注入信号：\n类型：\(ev.type)\n标题：\(title)\n\n（提示：在受信任脚本中附带 ?token=<WebhookToken> 可免弹窗静默执行）"
        case .approve(let id, _, _):
            alert.informativeText = "外部链接请求【批准执行】审批单：\(id)\n批准后可能触发 Phase 2 代码修改或本地动作。"
        case .reject(let id, _, _):
            alert.informativeText = "外部链接请求【忽略/驳回】审批单：\(id)"
        case .openConsole:
            return
        }
        alert.addButton(withTitle: "确认执行")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            orchestrator.executeConfirmedURLAction(action)
            refresh()
        }
    }

    private func registerWakeObservers() {
        let wsObs = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                _ = self?.orchestrator.flushWakeDigest()
                _ = self?.orchestrator.checkExpectWindows()
                self?.refresh()
            }
        }

        let unlockObs = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                _ = self?.orchestrator.flushWakeDigest()
                _ = self?.orchestrator.checkExpectWindows()
                self?.refresh()
            }
        }
        wakeObservers = [wsObs, unlockObs]
    }

    func refreshLiveStreamOnly() {
        activeRuns = orchestrator.activeRuns()
        notchHUD.syncPresentation()
    }

    func refresh() {
        let previousFeishuStatus = feishuStatus
        let cfg = orchestrator.currentConfig()
        pendingApprovals = orchestrator.pendingApprovals()
        activeRuns = orchestrator.activeRuns()
        recentRuns = orchestrator.recentRuns()
        rules = orchestrator.allRules()
        paused = orchestrator.isPaused()
        deferredCount = orchestrator.deferredDigestCount()
        feishuEnabled = cfg.feishuSensorEnabled
        preferredTerminal = cfg.terminal
        notchHUDEnabled = cfg.notchHUDEnabled
        notchHotkey = cfg.notchHotkey
        feishuStatus = orchestrator.feishuSensorStatus()
        feishuErrorMessage = orchestrator.feishuSensorErrorMessage()
        webhookStatus = orchestrator.webhookStatus()
        cliStatus = CLIIntegration.currentStatus()
        notchHUD.syncPresentation()

        if consoleWindow?.isVisible == true {
            refreshConsoleData()
        }

        if feishuEnabled,
           feishuStatus == .needsFullDiskAccess,
           previousFeishuStatus != .needsFullDiskAccess,
           !promptedFDACurrentSession,
           !isPresentingFDAAlert,
           !UserDefaults.standard.bool(forKey: fdaSuppressDefaultsKey) {
            promptedFDACurrentSession = true
            DispatchQueue.main.async { [weak self] in
                self?.presentFDAGuideAlert(allowSuppression: true)
            }
        }
    }

    func refreshConsoleData() {
        webhookStatus = orchestrator.webhookStatus()
        webhookToken = SecretStore.ensureWebhookToken(paths: orchestrator.paths)
        storedSecrets = SecretStore.loadAll(paths: orchestrator.paths)
        worktrees = orchestrator.listManagedWorktrees()
        activeRuns = orchestrator.activeRuns()
        recentRuns = orchestrator.recentRuns()
        if let usage = try? orchestrator.store.todayUsageSummary() {
            todayRunsCount = usage.runsCount
            todayCostUSD = usage.totalCostUSD
        }
        loadAuditEvents(stageFilter: auditStageFilter, query: auditSearchQuery)
        let orch = orchestrator
        Task {
            let ts = await Task.detached { orch.tailscaleStatus() }.value
            self.tailscaleStatus = ts
        }
    }

    func setNotchHUD(enabled: Bool) {
        orchestrator.setNotchHUDEnabled(enabled)
        refresh()
    }

    func setNotchHotkey(_ hotkey: String) {
        orchestrator.setNotchHotkey(hotkey)
        refresh()
    }

    func setTailscaleServe(enabled: Bool) async -> String {
        let orch = orchestrator
        let res = await Task.detached { orch.setTailscaleServe(enabled: enabled) }.value
        self.tailscaleStatus = res.status
        return res.message
    }

    func loadAuditEvents(stageFilter: String?, query: String?) {
        auditEvents = (try? orchestrator.store.listEventAuditRecords(limit: 120, stageFilter: stageFilter, searchQuery: query)) ?? []
    }

    func saveSecret(key: String, value: String) {
        try? SecretStore.set(key: key, value: value, paths: orchestrator.paths)
        storedSecrets = SecretStore.loadAll(paths: orchestrator.paths)
    }

    func deleteSecret(key: String) {
        try? SecretStore.remove(key: key, paths: orchestrator.paths)
        storedSecrets = SecretStore.loadAll(paths: orchestrator.paths)
    }

    func rotateWebhookToken() {
        if let rotated = try? SecretStore.rotateWebhookToken(paths: orchestrator.paths) {
            webhookToken = rotated
            storedSecrets = SecretStore.loadAll(paths: orchestrator.paths)
        }
    }

    func setRuleEnabled(rule: ChimeRule, enabled: Bool) {
        do {
            try orchestrator.setRuleEnabled(id: rule.id, enabled: enabled)
            refresh()
        } catch {
            statusBannerMessage = "更新规则失败：\(error.localizedDescription)"
        }
    }

    private func buildTestEvent(for rule: ChimeRule, title: String, subtitle: String, body: String) -> EventEnvelope {
        let base = rule.sampleTestEvent()
        var payload = base.payload
        payload["title"] = title
        payload["subtitle"] = subtitle
        payload["body"] = body
        return EventEnvelope(
            source: base.source,
            type: base.type,
            correlationKey: "test:\(rule.id):\(title)",
            privacyLevel: base.privacyLevel,
            payload: payload,
            ambientContext: .captureCurrent()
        )
    }

    func simulateRule(_ rule: ChimeRule, title: String, subtitle: String, body: String) async -> RuleTestFeedback {
        let sample = buildTestEvent(for: rule, title: title, subtitle: subtitle, body: body)

        if let expect = rule.expectWindow, expect.enabled {
            let matched = orchestrator.funnel.matchesRule(sample, rule: rule)
            if matched {
                return RuleTestFeedback(
                    passed: true,
                    message: "匹配成功：在 \(expect.displayLabel) 窗口内收到此类消息将记为“已如期收到”；超时未收到则触发动作。"
                )
            }
            return RuleTestFeedback(passed: false, message: "未命中规则「\(rule.id)」的 match 条件。")
        }

        let cfg = orchestrator.currentConfig()
        var testRule = rule
        testRule.enabled = true
        let summary = await RuleSimulator.simulate(events: [sample], rules: [testRule], config: cfg, runL1: false)
        guard let first = summary.results.first else {
            return RuleTestFeedback(passed: false, message: "模拟无返回结果")
        }
        if first.matchedChimeID == rule.id {
            let target = rule.driver.lowercased() == "none" ? "直接执行动作" : "拉起 \(rule.driver)"
            return RuleTestFeedback(passed: true, message: "L0 命中（\(target)）")
        }
        if first.l0Outcome.hasPrefix("dropped_threshold:") {
            let ratio = first.l0Outcome.replacingOccurrences(of: "dropped_threshold:threshold:", with: "")
            return RuleTestFeedback(passed: true, message: "L0 匹配成功，已计入窗口阈值（当前 \(ratio)，达到 \(rule.minCount) 次后触发）")
        }
        return RuleTestFeedback(passed: false, message: "未命中：\(first.l0Outcome)")
    }

    func emitRealTestEvent(for rule: ChimeRule, title: String, subtitle: String, body: String) -> RuleTestFeedback {
        let sample = buildTestEvent(for: rule, title: title, subtitle: subtitle, body: body)
        let outcome = orchestrator.triggerRuleTest(ruleID: rule.id, event: sample)
        refresh()
        return RuleTestFeedback(passed: outcome.ok, message: outcome.message)
    }

    func openRuleFile(_ rule: ChimeRule) {
        let path = rule.filePath ?? orchestrator.paths.chimesDir.appendingPathComponent("\(rule.id).md").path
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(orchestrator.paths.chimesDir)
        }
    }

    func openConfigDirectory() {
        NSWorkspace.shared.open(orchestrator.paths.configDir)
    }

    func runGC() {
        let report = orchestrator.governance.performGC(
            paths: orchestrator.paths,
            store: orchestrator.store,
            retentionDays: orchestrator.currentConfig().retentionDays
        )
        statusBannerMessage = "已清理 \(report.prunedEvents) 条事件、\(report.removedRunDirs) 次运行、\(report.removedWorktrees) 个 worktree"
        refresh()
    }

    func reinstallCLISymlink() {
        guard let bz = CLIIntegration.resolveBundledBZPath() else { return }
        CLIIntegration.ensureCLISymlinks(sourceBZPath: bz, force: true)
        refresh()
    }

    func setZshHook(enabled: Bool) {
        if enabled, let bz = CLIIntegration.resolveBundledBZPath() {
            CLIIntegration.ensureCLISymlinks(sourceBZPath: bz, force: false)
        }
        _ = try? CLIIntegration.setZshHook(enabled: enabled)
        refresh()
    }

    func setFeishuSensor(enabled: Bool) {
        orchestrator.setFeishuSensorEnabled(enabled)
        refresh()
        if enabled && feishuStatus == .needsFullDiskAccess {
            DispatchQueue.main.async { [weak self] in
                self?.presentFDAGuideAlert(allowSuppression: false)
            }
        }
    }

    func presentFDAGuideAlert(allowSuppression: Bool) {
        guard !isPresentingFDAAlert else { return }
        isPresentingFDAAlert = true
        defer { isPresentingFDAAlert = false }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "需要授予「完全磁盘访问权限」"
        alert.informativeText = """
        Bianzhong 通过只读方式读取 macOS 通知中心数据库（usernoted）来捕获飞书通知，因此需要「完全磁盘访问权限」。

        授权步骤：
        1. 点击下方「打开系统设置」
        2. 在「完全磁盘访问权限」列表中开启或拖入 Bianzhong.app
        3. 返回菜单栏点击「重检」（若仍未生效请重启 Bianzhong）
        """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        alert.showsSuppressionButton = allowSuppression
        alert.suppressionButton?.title = "不再自动弹出此提示"

        let response = alert.runModal()
        if allowSuppression, alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: fdaSuppressDefaultsKey)
        }
        if response == .alertFirstButtonReturn {
            openFullDiskAccessSettings()
        }
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
        if Bundle.main.bundleURL.pathExtension == "app" {
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        }
    }

    func openConfigChat() {
        let paths = orchestrator.paths
        _ = try? DefaultTemplates.installDefaultsIfMissing(paths: paths)
        let cfgDir = paths.configDir.path
        let cmd: String
        if let omp = AgentDriverRegistry.resolveBinary(name: "omp") {
            cmd = "cd \(shellQuote(cfgDir)) && \(shellQuote(omp)) --cwd \(shellQuote(cfgDir))"
        } else if let codex = AgentDriverRegistry.resolveBinary(name: "codex") {
            cmd = "cd \(shellQuote(cfgDir)) && \(shellQuote(codex)) -C \(shellQuote(cfgDir))"
        } else {
            cmd = "cd \(shellQuote(cfgDir)) && ls -la"
        }
        _ = TerminalLauncher.launchCommand(cmd, preferredTerminal: orchestrator.currentConfig().terminal)
    }

    func openTuneChat() {
        let paths = orchestrator.paths
        guard let tune = try? RuleTuner.prepareTuneSession(paths: paths, store: orchestrator.store, chimeID: nil) else {
            openConfigChat()
            return
        }
        let cfgDir = paths.configDir.path
        let cmd: String
        if let omp = AgentDriverRegistry.resolveBinary(name: "omp") {
            cmd = "cd \(shellQuote(cfgDir)) && \(shellQuote(omp)) --cwd \(shellQuote(cfgDir)) \(shellQuote(tune.prompt))"
        } else if let codex = AgentDriverRegistry.resolveBinary(name: "codex") {
            cmd = "cd \(shellQuote(cfgDir)) && \(shellQuote(codex)) -C \(shellQuote(cfgDir)) \(shellQuote(tune.prompt))"
        } else {
            cmd = "cat \(shellQuote(tune.contextFile.path))"
        }
        _ = TerminalLauncher.launchCommand(cmd, preferredTerminal: orchestrator.currentConfig().terminal)
    }
}

struct MenuBarRootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerBar

            if model.feishuEnabled && model.feishuStatus == .needsFullDiskAccess {
                fdaBanner
            } else if model.feishuEnabled && model.feishuStatus == .unavailable {
                unavailableBanner
            }

            if let msg = model.statusBannerMessage {
                HStack(spacing: 6) {
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        model.statusBannerMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Picker("", selection: $model.selectedTab) {
                Text(model.pendingApprovals.isEmpty ? "待办" : "待办 (\(model.pendingApprovals.count))")
                    .tag(MenuBarTab.inbox)
                Text("规则 (\(model.enabledRulesCount)/\(model.rules.count))")
                    .tag(MenuBarTab.rules)
                Text("设置")
                    .tag(MenuBarTab.settings)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch model.selectedTab {
                case .inbox:
                    InboxTabView(model: model)
                case .rules:
                    RulesTabView(model: model)
                case .settings:
                    SettingsTabView(model: model)
                }
            }
        }
        .padding(12)
        .frame(width: 440)
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text("编钟")
                .font(.headline)

            statusPill

            Spacer()

            Button {
                model.openConsoleWindow()
            } label: {
                Label("控制台", systemImage: "macwindow")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut(",", modifiers: .command)

            Button(model.paused ? "恢复" : "暂停 1h") {
                if model.paused {
                    model.orchestrator.resume()
                } else {
                    model.orchestrator.pause(forSeconds: 3600)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Menu {
                if !model.activeRuns.isEmpty {
                    Button("停止全部运行 (\(model.activeRuns.count))") {
                        _ = model.orchestrator.stopAllActiveRuns()
                        model.refresh()
                    }
                    Divider()
                }
                Button("事件记录...") {
                    model.openConsoleWindow(section: .events)
                }
                Button("集成与密钥...") {
                    model.openConsoleWindow(section: .webhooks)
                }
                Button("运行记录...") {
                    model.openConsoleWindow(section: .runs)
                }
                Divider()
                Button("重载配置") {
                    model.orchestrator.reloadConfig()
                }
                Button("AI 配置助手") {
                    model.openConfigChat()
                }
                Button("误报调优") {
                    model.openTuneChat()
                }
                Divider()
                Button("退出") {
                    model.orchestrator.stop()
                    NSApp.terminate(nil)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        if model.paused {
            pill(color: .orange, text: "已暂停")
        } else if model.feishuEnabled && model.feishuStatus == .needsFullDiskAccess {
            Button {
                model.presentFDAGuideAlert(allowSuppression: false)
            } label: {
                pill(color: .orange, text: "飞书缺权限 ↗")
            }
            .buttonStyle(.plain)
        } else if model.feishuEnabled && model.feishuStatus == .unavailable {
            pill(color: .orange, text: "飞书不可用")
        } else if model.feishuEnabled && model.feishuStatus == .watching {
            pill(color: .green, text: model.webhookStatus.running ? "飞书 · Webhook" : "飞书已连")
        } else {
            pill(color: model.webhookStatus.running ? .green : .secondary, text: model.webhookStatus.running ? "Webhook 就绪" : "仅本地信号")
        }
    }

    private func pill(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.12))
        .clipShape(Capsule())
    }

    private var fdaBanner: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("飞书监听缺少「完全磁盘访问权限」")
                    .font(.caption.bold())
                Text("在系统设置中勾选 Bianzhong.app 后点击重检")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("去授权 ↗") {
                model.presentFDAGuideAlert(allowSuppression: false)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
            Button("重检") {
                model.orchestrator.retryFeishuSensor()
            }
            .controlSize(.mini)
        }
        .padding(8)
        .background(Color.orange.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var unavailableBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("飞书通知数据库暂不可读")
                    .font(.caption.bold())
                if let err = model.feishuErrorMessage, !err.isEmpty {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button("权限设置") {
                model.openFullDiskAccessSettings()
            }
            .controlSize(.mini)
            Button("重检") {
                model.orchestrator.retryFeishuSensor()
            }
            .controlSize(.mini)
        }
        .padding(8)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct InboxTabView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.deferredCount > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "moon.zzz")
                        .foregroundStyle(.secondary)
                    Text("专注期暂存了 \(model.deferredCount) 条信号")
                        .font(.caption)
                    Spacer()
                    Button("立即汇总") {
                        _ = model.orchestrator.flushWakeDigest()
                        model.refresh()
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if !model.activeRuns.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.activeRuns) { run in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(run.status == "warm_hold" ? Color.orange : Color.cyan)
                                .frame(width: 7, height: 7)
                            Text(run.driver)
                                .font(.caption.monospaced().bold())
                            Text(run.currentActivity)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Button("中止") {
                                _ = model.orchestrator.stopRun(id: run.runID)
                                model.refresh()
                            }
                            .controlSize(.mini)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Color.cyan.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                }
            }

            if model.pendingApprovals.isEmpty && model.activeRuns.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                    Text("暂无待办")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else if !model.pendingApprovals.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.pendingApprovals) { item in
                            ApprovalCard(item: item, model: model)
                        }
                    }
                }
                .frame(maxHeight: 340)
            }
        }
    }
}

struct RulesTabView: View {
    @ObservedObject var model: AppModel
    @State private var expandedRuleID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                Button("管理规则 ↗") {
                    model.openConsoleWindow(section: .rules)
                }
                .controlSize(.small)
                Button {
                    model.orchestrator.reloadConfig()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .controlSize(.small)
                .help("重载规则")
            }

            if model.rules.isEmpty {
                VStack(spacing: 6) {
                    Text("暂无规则")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("新建规则") {
                        model.openConsoleWindow(section: .rules)
                    }
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.rules) { rule in
                            RuleRowCard(
                                rule: rule,
                                model: model,
                                isTesting: expandedRuleID == rule.id,
                                onToggleTest: {
                                    if expandedRuleID == rule.id {
                                        expandedRuleID = nil
                                    } else {
                                        expandedRuleID = rule.id
                                    }
                                }
                            )
                        }
                    }
                }
                .frame(maxHeight: 340)
            }
        }
    }
}

struct RuleRowCard: View {
    let rule: ChimeRule
    @ObservedObject var model: AppModel
    let isTesting: Bool
    let onToggleTest: () -> Void

    @State private var testTitle: String = ""
    @State private var testSubtitle: String = ""
    @State private var testBody: String = ""
    @State private var testFeedback: RuleTestFeedback?
    @State private var isSimulating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                Text(rule.id)
                    .font(.subheadline.bold())
                    .foregroundStyle(rule.enabled ? .primary : .secondary)
                    .lineLimit(1)

                tag(rule.driver.lowercased() == "none" ? "纯动作" : rule.driver)

                if rule.minCount > 1 {
                    tag("≥\(rule.minCount)次/\(rule.countWindow.displayLabel)")
                }
                if let exp = rule.expectWindow, exp.enabled {
                    tag("预期 \(exp.displayLabel)")
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { rule.enabled },
                    set: { model.setRuleEnabled(rule: rule, enabled: $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }

            if !rule.description.isEmpty {
                Text(rule.description)
                    .font(.caption)
                    .foregroundStyle(rule.enabled ? .secondary : .tertiary)
                    .lineLimit(2)
            }

            HStack(spacing: 6) {
                Text(rule.matchSummary)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                Button(isTesting ? "收起" : "测试") {
                    if !isTesting {
                        let sample = rule.sampleTestEvent()
                        testTitle = sample.payload["title"] ?? ""
                        testSubtitle = sample.payload["subtitle"] ?? ""
                        testBody = sample.payload["body"] ?? ""
                        testFeedback = nil
                    }
                    onToggleTest()
                }
                .controlSize(.mini)

                Button("编辑") {
                    model.openConsoleWindow(section: .rules, ruleID: rule.id)
                }
                .controlSize(.mini)
            }

            if isTesting {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    TextField("标题 / 群名 (title)", text: $testTitle)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    TextField("正文 (body)", text: $testBody)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)

                    HStack(spacing: 6) {
                        Button(isSimulating ? "检验中..." : "模拟检验 (L0)") {
                            isSimulating = true
                            Task {
                                let res = await model.simulateRule(rule, title: testTitle, subtitle: testSubtitle, body: testBody)
                                testFeedback = res
                                isSimulating = false
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .disabled(isSimulating)

                        Button(rule.expectWindow?.enabled == true ? "触发超时实测" : "真实触发") {
                            testFeedback = model.emitRealTestEvent(for: rule, title: testTitle, subtitle: testSubtitle, body: testBody)
                        }
                        .controlSize(.mini)
                        .disabled(!rule.enabled)
                    }

                    if let feedback = testFeedback {
                        Text(feedback.message)
                            .font(.caption2)
                            .foregroundStyle(feedback.passed ? .green : .orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .opacity(rule.enabled ? 1.0 : 0.72)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct SettingsTabView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("默认终端")
                        .font(.subheadline)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { model.preferredTerminal },
                        set: { newVal in
                            model.orchestrator.setPreferredTerminal(newVal)
                            model.refresh()
                        }
                    )) {
                        let autoName = TerminalLauncher.detectTerminal(preference: "auto").displayName
                        Text("自动 (\(autoName))").tag("auto")
                        Divider()
                        ForEach(TerminalLauncher.TerminalApp.allCases) { app in
                            if app.isInstalled || app == .terminal || app.rawValue == model.preferredTerminal {
                                Text(app.isInstalled ? app.displayName : "\(app.displayName)（未安装）").tag(app.rawValue)
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(width: 165)
                }

                Divider()

                HStack(spacing: 8) {
                    Text("飞书通知监听")
                        .font(.subheadline)
                    if model.feishuEnabled && model.feishuStatus == .needsFullDiskAccess {
                        Button("去授权 ↗") {
                            model.presentFDAGuideAlert(allowSuppression: false)
                        }
                        .controlSize(.mini)
                    } else if model.feishuEnabled && model.feishuStatus == .unavailable {
                        Text("不可用")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { model.feishuEnabled },
                        set: { model.setFeishuSensor(enabled: $0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                }

                Divider()

                HStack(spacing: 8) {
                    Text("Webhook 服务")
                        .font(.subheadline)
                    Spacer()
                    Text(model.webhookStatus.running ? "127.0.0.1:\(model.webhookStatus.port)" : "未启用")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Button("配置 ↗") {
                        model.openConsoleWindow(section: .webhooks)
                    }
                    .controlSize(.small)
                }

                Divider()

                HStack(spacing: 8) {
                    Text("刘海悬浮窗")
                        .font(.subheadline)
                    Spacer()
                    ShortcutRecorderButton(model: model)
                        .disabled(!model.notchHUDEnabled)
                    Toggle("", isOn: Binding(
                        get: { model.notchHUDEnabled },
                        set: { model.setNotchHUD(enabled: $0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                }

                Divider()

                HStack {
                    Text("Zsh 慢命令钩子")
                        .font(.subheadline)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { model.cliStatus.isZshHookInstalled },
                        set: { model.setZshHook(enabled: $0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 6) {
                Button("更多设置 ↗") {
                    model.openConsoleWindow(section: .general)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("事件记录") {
                    model.openConsoleWindow(section: .events)
                }
                .controlSize(.small)

                Spacer()

                Button("清理缓存") {
                    model.runGC()
                }
                .controlSize(.small)
            }
        }
    }
}

struct ApprovalCard: View {
    let item: ApprovalRecord
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.title)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Spacer()
                if model.orchestrator.isWarmHeldApproval(item.id) {
                    Text("热挂起")
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                Text(item.riskLevel.uppercased())
                    .font(.caption2.bold())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            Text(item.provenanceSummary)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(item.proposedAction)
                .font(.caption)
                .lineLimit(5)
                .textSelection(.enabled)

            if let diff = item.diffPreview, !diff.isEmpty {
                Text(diff)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }

            HStack(spacing: 6) {
                if item.kind == "question" {
                    Button("复制并回飞书") {
                        model.orchestrator.copyAndOpenFeishu(id: item.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else if item.kind == "notify" || item.kind == "digest" {
                    Button("已知悉") {
                        model.orchestrator.approve(id: item.id, comment: "Acknowledged")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else {
                    Button("批准执行") {
                        model.orchestrator.approve(id: item.id, comment: nil)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                if item.externalSessionID != nil || item.targetRepo != nil {
                    Menu("接管 ↗") {
                        Button("默认终端") {
                            if !model.orchestrator.launchTakeover(for: item.id),
                               let repo = item.targetRepo {
                                _ = TerminalLauncher.openInteractiveShell(at: repo, preferredTerminal: model.preferredTerminal)
                            }
                        }
                        ForEach(TerminalLauncher.installedIDEs) { ide in
                            Button("在 \(ide.displayName) 打开") {
                                _ = model.orchestrator.launchIDEHandoff(for: item.id, ide: ide)
                            }
                        }
                    }
                    .controlSize(.small)
                    .frame(width: 78)
                }

                Spacer()

                Button("忽略") {
                    model.orchestrator.reject(id: item.id, comment: "Dismissed in MenuBar")
                }
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct BianzhongMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarRootView(model: model)
        } label: {
            let count = model.pendingApprovals.count
            let needsFDA = model.feishuEnabled && model.feishuStatus == .needsFullDiskAccess
            Image(systemName: (count > 0 || needsFDA) ? "bell.badge.fill" : "bell")
            if count > 0 {
                Text("\(count)")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
