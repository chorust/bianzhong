import AppKit
import BianzhongCore
import Combine
import Foundation
import SwiftUI

enum MenuBarTab: String, CaseIterable, Identifiable {
    case inbox = "听音台"
    case rules = "规则"
    case settings = "设置"

    var id: String { rawValue }
}

struct RuleTestFeedback: Equatable {
    let passed: Bool
    let message: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedTab: MenuBarTab = .inbox
    @Published var pendingApprovals: [ApprovalRecord] = []
    @Published var recentRuns: [RunRecord] = []
    @Published var rules: [ChimeRule] = []
    @Published var paused = false
    @Published var deferredCount = 0
    @Published var feishuEnabled = true
    @Published var feishuStatus: FeishuSensorStatus = .disabled
    @Published var feishuErrorMessage: String?
    @Published var cliStatus: CLIIntegrationStatus = CLIIntegration.currentStatus()
    @Published var statusBannerMessage: String?

    let orchestrator: Orchestrator
    let notificationManager: NotificationManager
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
            }
        )

        do {
            self.orchestrator = try Orchestrator(paths: paths, callbacks: callbacks)
        } catch {
            fatalError("Failed to initialize Bianzhong orchestrator: \(error)")
        }
        self.notificationManager = NotificationManager(orchestrator: self.orchestrator)
        capturedSelf = self

        try? orchestrator.start(enableBuiltInSensors: true)
        notificationManager.setupIfSupported()
        registerWakeObservers()
        refresh()
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

    func refresh() {
        let previousFeishuStatus = feishuStatus
        pendingApprovals = orchestrator.pendingApprovals()
        recentRuns = orchestrator.recentRuns()
        rules = orchestrator.allRules()
        paused = orchestrator.isPaused()
        deferredCount = orchestrator.deferredDigestCount()
        feishuEnabled = orchestrator.currentConfig().feishuSensorEnabled
        feishuStatus = orchestrator.feishuSensorStatus()
        feishuErrorMessage = orchestrator.feishuSensorErrorMessage()
        cliStatus = CLIIntegration.currentStatus()

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
                Text(model.pendingApprovals.isEmpty ? "听音台" : "听音台 (\(model.pendingApprovals.count))")
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
                Button("重载配置与规则") {
                    model.orchestrator.reloadConfig()
                }
                Button("打开规则配置助手") {
                    model.openConfigChat()
                }
                Button("误报调优") {
                    model.openTuneChat()
                }
                Button("打开配置目录") {
                    model.openConfigDirectory()
                }
                Divider()
                Button("退出 Bianzhong") {
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
            pill(color: .green, text: "飞书已连")
        } else {
            pill(color: .secondary, text: "仅本地信号")
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

            if model.pendingApprovals.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "bell.and.waves.left.and.right")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                    Text("听音台暂无待办")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("命中规则的信号经 L0/L1 过滤后会出现在这里")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 130)
            } else {
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
                Text("已启用 \(model.enabledRulesCount) / 共 \(model.rules.count) 条")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("+ 新建规则") {
                    model.openConfigChat()
                }
                .controlSize(.small)
                Button {
                    model.orchestrator.reloadConfig()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .controlSize(.small)
                .help("重新加载 ~/.config/bianzhong/chimes/*.md")
            }

            if model.rules.isEmpty {
                VStack(spacing: 6) {
                    Text("尚未加载任何规则")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("创建第一条规则") {
                        model.openConfigChat()
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
                    model.openRuleFile(rule)
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
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("飞书通知监听")
                            .font(.subheadline.bold())
                        Text(feishuSubtitle)
                            .font(.caption2)
                            .foregroundStyle(model.feishuStatus == .needsFullDiskAccess ? .orange : .secondary)
                    }
                    Spacer()
                    if model.feishuEnabled && model.feishuStatus == .needsFullDiskAccess {
                        Button("去授权 ↗") {
                            model.presentFDAGuideAlert(allowSuppression: false)
                        }
                        .controlSize(.mini)
                    }
                    Toggle("", isOn: Binding(
                        get: { model.feishuEnabled },
                        set: { model.setFeishuSensor(enabled: $0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Zsh 慢命令钩子")
                            .font(.subheadline.bold())
                        Text("自动在 ~/.zshrc 监听耗时 ≥15s 的失败命令")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { model.cliStatus.isZshHookInstalled },
                        set: { model.setZshHook(enabled: $0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("bz 命令行工具")
                            .font(.subheadline.bold())
                        Text(model.cliStatus.isCLIInstalled ? "已安装，可在终端直接使用 bz" : "未安装到 PATH")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(model.cliStatus.isCLIInstalled ? "修复链接" : "安装") {
                        model.reinstallCLISymlink()
                    }
                    .controlSize(.small)
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 6) {
                Button("规则调优") {
                    model.openTuneChat()
                }
                .controlSize(.small)

                Button("配置目录") {
                    model.openConfigDirectory()
                }
                .controlSize(.small)

                Button("清理过期数据") {
                    model.runGC()
                }
                .controlSize(.small)

                Spacer()
            }
        }
    }

    private var feishuSubtitle: String {
        guard model.feishuEnabled else { return "已关闭" }
        switch model.feishuStatus {
        case .watching: return "已连接（只读监听通知中心）"
        case .needsFullDiskAccess: return "缺少完全磁盘访问权限"
        case .unavailable: return model.feishuErrorMessage ?? "通知数据库暂不可读"
        case .disabled: return "已关闭"
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

                if item.externalSessionID != nil {
                    Button("终端接管 ↗") {
                        _ = model.orchestrator.launchTakeover(for: item.id)
                    }
                    .controlSize(.small)
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
