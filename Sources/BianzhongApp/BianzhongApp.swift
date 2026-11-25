import AppKit
import BianzhongCore
import Combine
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var pendingApprovals: [ApprovalRecord] = []
    @Published var recentRuns: [RunRecord] = []
    @Published var paused = false
    @Published var loadedRulesCount = 0
    @Published var deferredCount = 0
    @Published var feishuEnabled = true
    @Published var feishuStatus: FeishuSensorStatus = .disabled
    @Published var cliStatus: CLIIntegrationStatus = CLIIntegration.currentStatus()

    let orchestrator: Orchestrator
    let notificationManager: NotificationManager
    private var wakeObservers: [Any] = []

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
                self?.refresh()
            }
        }
        wakeObservers = [wsObs, unlockObs]
    }

    func refresh() {
        pendingApprovals = orchestrator.pendingApprovals()
        recentRuns = orchestrator.recentRuns()
        paused = orchestrator.isPaused()
        loadedRulesCount = orchestrator.funnel.currentRules().count
        deferredCount = orchestrator.deferredDigestCount()
        feishuEnabled = orchestrator.currentConfig().feishuSensorEnabled
        feishuStatus = orchestrator.feishuSensorStatus()
        cliStatus = CLIIntegration.currentStatus()
    }

    func reinstallCLISymlink() {
        guard let bz = CLIIntegration.resolveBundledBZPath() else { return }
        CLIIntegration.ensureCLISymlinks(sourceBZPath: bz, force: true)
        refresh()
    }

    func toggleZshHook() {
        let next = !cliStatus.isZshHookInstalled
        if next, let bz = CLIIntegration.resolveBundledBZPath() {
            CLIIntegration.ensureCLISymlinks(sourceBZPath: bz, force: false)
        }
        _ = try? CLIIntegration.setZshHook(enabled: next)
        refresh()
    }

    func toggleFeishuSensor() {
        orchestrator.setFeishuSensorEnabled(!feishuEnabled)
        refresh()
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

struct InboxView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("编钟 · Bianzhong")
                    .font(.headline)
                Spacer()
                Text(model.feishuStatus == .watching ? "飞书已连 · \(model.loadedRulesCount) 规则" : "\(model.loadedRulesCount) 规则")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(model.paused ? "恢复监听" : "暂停 1h") {
                    if model.paused {
                        model.orchestrator.resume()
                    } else {
                        model.orchestrator.pause(forSeconds: 3600)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if model.feishuStatus == .needsFullDiskAccess {
                HStack(spacing: 6) {
                    Text("飞书通知需授予完全磁盘访问权限")
                        .font(.caption2)
                        .lineLimit(1)
                    Spacer()
                    Button("去开启 ↗") {
                        model.openFullDiskAccessSettings()
                    }
                    .controlSize(.mini)
                    Button("重试") {
                        model.orchestrator.retryFeishuSensor()
                    }
                    .controlSize(.mini)
                    Button("关闭") {
                        model.orchestrator.setFeishuSensorEnabled(false)
                    }
                    .controlSize(.mini)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Divider()

            if model.pendingApprovals.isEmpty {
                VStack(alignment: .center, spacing: 6) {
                    Text("听音台暂无待办")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(model.deferredCount > 0 ? "已有 \(model.deferredCount) 条暂存摘要等待唤醒汇总" : "信号会经 L0/L1 漏斗过滤后出现在这里")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
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

            Divider()

            HStack(spacing: 6) {
                Button("+ 配规则") {
                    model.openConfigChat()
                }
                .controlSize(.small)

                Button("调优") {
                    model.openTuneChat()
                }
                .controlSize(.small)

                if model.deferredCount > 0 {
                    Button("汇总(\(model.deferredCount))") {
                        _ = model.orchestrator.flushWakeDigest()
                        model.refresh()
                    }
                    .controlSize(.small)
                }

                Button("重载") {
                    model.orchestrator.reloadConfig()
                }
                .controlSize(.small)

                Menu("集成") {
                    Button(model.cliStatus.isCLIInstalled ? "✓ bz 命令已安装（点击修复）" : "安装 bz 命令行工具") {
                        model.reinstallCLISymlink()
                    }
                    Button(model.cliStatus.isZshHookInstalled ? "✓ Zsh 慢命令钩子已启用" : "写入 Zsh 慢命令钩子 (~/.zshrc)") {
                        model.toggleZshHook()
                    }
                    Divider()
                    Button(model.feishuEnabled ? "关闭飞书通知监听" : "开启飞书通知监听") {
                        model.toggleFeishuSensor()
                    }
                    if model.feishuStatus == .needsFullDiskAccess {
                        Button("打开完全磁盘访问权限设置 ↗") {
                            model.openFullDiskAccessSettings()
                        }
                    }
                }
                .controlSize(.small)

                Spacer()

                Button("退出") {
                    model.orchestrator.stop()
                    NSApp.terminate(nil)
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 430)
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
            InboxView(model: model)
        } label: {
            let count = model.pendingApprovals.count
            Image(systemName: count > 0 ? "bell.badge.fill" : "bell")
            if count > 0 {
                Text("\(count)")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
