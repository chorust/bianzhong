import AppKit
import BianzhongCore
import Foundation
import ServiceManagement
import SwiftUI

enum ConsoleSection: String, CaseIterable, Identifiable {
    case general = "general"
    case rules = "rules"
    case events = "events"
    case webhooks = "webhooks"
    case runs = "runs"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用与终端"
        case .rules: return "规则工作台"
        case .events: return "信号漏斗透视"
        case .webhooks: return "Webhook 与密钥"
        case .runs: return "运行与 Worktree"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .rules: return "slider.horizontal.3"
        case .events: return "waveform.path.ecg"
        case .webhooks: return "network"
        case .runs: return "clock.arrow.circlepath"
        }
    }
}

struct ConsoleWindowView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(ConsoleSection.allCases, selection: $model.consoleSection) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 175, ideal: 190, max: 220)
        } detail: {
            Group {
                switch model.consoleSection {
                case .general:
                    GeneralSettingsPane(model: model)
                case .rules:
                    RulesWorkbenchPane(model: model)
                case .events:
                    EventInspectorPane(model: model)
                case .webhooks:
                    WebhooksAndSecretsPane(model: model)
                case .runs:
                    RunsAndWorktreesPane(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 880, minHeight: 580)
        .onAppear {
            model.refreshConsoleData()
        }
    }
}

// MARK: - 1. General & Terminal Settings

private struct GeneralSettingsPane: View {
    @ObservedObject var model: AppModel
    @State private var draftConfig: AppConfig = AppConfig()
    @State private var launchAtLogin: Bool = false
    @State private var newWSName: String = ""
    @State private var newWSPath: String = ""
    @State private var newWSSummary: String = ""
    @State private var saveToast: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("通用与终端设置")
                            .font(.title2.bold())
                        Text("管理默认终端、开机自启、L1 语义分诊、预算护栏与候选工作区")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let toast = saveToast {
                        Text(toast)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    Button("保存配置") {
                        saveDraft()
                    }
                    .buttonStyle(.borderedProminent)
                }

                GroupBox("终端与系统集成") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("默认接管终端")
                                    .font(.subheadline.bold())
                                Text("点击「终端接管 ↗」或运行配置助手时拉起的终端应用")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Picker("", selection: $draftConfig.terminal) {
                                let autoDetected = TerminalLauncher.detectTerminal(preference: "auto").displayName
                                Text("自动检测（当前：\(autoDetected)）").tag("auto")
                                Divider()
                                ForEach(TerminalLauncher.TerminalApp.allCases) { app in
                                    Text(app.isInstalled ? app.displayName : "\(app.displayName)（未检测到）")
                                        .tag(app.rawValue)
                                }
                            }
                            .frame(width: 240)
                            .onChange(of: draftConfig.terminal) { _, newVal in
                                guard newVal != model.preferredTerminal else { return }
                                model.orchestrator.setPreferredTerminal(newVal)
                                model.refresh()
                            }

                            Button("测试打开") {
                                _ = TerminalLauncher.openInteractiveShell(
                                    at: model.orchestrator.paths.configDir.path,
                                    preferredTerminal: draftConfig.terminal
                                )
                            }
                            .controlSize(.small)
                        }

                        Divider()

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("登录 macOS 时自动启动 Bianzhong")
                                    .font(.subheadline.bold())
                                Text("使用 macOS 原生 SMAppService 管理后台常驻登录项")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { launchAtLogin },
                                set: { toggleLaunchAtLogin($0) }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                        }

                        Divider()

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("飞书通知中心只读监听")
                                    .font(.subheadline.bold())
                                Text(feishuStatusLine)
                                    .font(.caption2)
                                    .foregroundStyle(model.feishuStatus == .needsFullDiskAccess ? .orange : .secondary)
                            }
                            Spacer()
                            if model.feishuEnabled && model.feishuStatus == .needsFullDiskAccess {
                                Button("授予完全磁盘访问权限 ↗") {
                                    model.presentFDAGuideAlert(allowSuppression: false)
                                }
                                .controlSize(.small)
                            }
                            Toggle("", isOn: Binding(
                                get: { model.feishuEnabled },
                                set: {
                                    draftConfig.feishuSensorEnabled = $0
                                    model.setFeishuSensor(enabled: $0)
                                }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                        }

                        Divider()

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Zsh 慢命令失败钩子 (~/.zshrc)")
                                    .font(.subheadline.bold())
                                Text("自动上报耗时 ≥15s 且非 Ctrl+C 中断的失败命令")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { model.cliStatus.isZshHookInstalled },
                                set: { model.setZshHook(enabled: $0) }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                        }
                    }
                    .padding(8)
                }

                GroupBox("L1 语义分诊与运行护栏") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("默认 L1 分诊器")
                                .frame(width: 140, alignment: .leading)
                            Picker("", selection: $draftConfig.triageProvider) {
                                Text("Apple 端侧模型 (apple_fm · 0 费用)").tag("apple_fm")
                                Text("本地 CLI 轻量模型 (agent_cli)").tag("agent_cli")
                                Text("外部 HTTP 决策接口 (decision_api)").tag("decision_api")
                                Text("不启用分诊 (none)").tag("none")
                            }
                            .frame(width: 280)
                            Spacer()
                        }

                        if draftConfig.triageProvider == "agent_cli" {
                            HStack {
                                Text("分诊 CLI 与模型")
                                    .frame(width: 140, alignment: .leading)
                                Picker("", selection: $draftConfig.agentCLIDriver) {
                                    Text("omp").tag("omp")
                                    Text("codex").tag("codex")
                                }
                                .frame(width: 110)
                                TextField("轻量模型名（如 smol / gpt-5-mini）", text: Binding(
                                    get: { draftConfig.agentCLIModel ?? "" },
                                    set: { draftConfig.agentCLIModel = $0.isEmpty ? nil : $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 220)
                                Spacer()
                            }
                        } else if draftConfig.triageProvider == "decision_api" {
                            HStack {
                                Text("Decision API URL")
                                    .frame(width: 140, alignment: .leading)
                                TextField("https://example.com/v1/triage", text: Binding(
                                    get: { draftConfig.decisionAPIURL ?? "" },
                                    set: { draftConfig.decisionAPIURL = $0.isEmpty ? nil : $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                                TextField("密钥名", text: $draftConfig.decisionAPIKeyEnv)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 210)
                            }
                        }

                        Divider()

                        HStack(spacing: 20) {
                            HStack {
                                Text("每日预算上限 ($)")
                                TextField("3.0", value: $draftConfig.dailyMaxCostUSD, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 72)
                            }
                            HStack {
                                Text("每日最大运行数")
                                TextField("30", value: $draftConfig.dailyMaxRuns, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 64)
                            }
                            HStack {
                                Text("连续失败熔断")
                                TextField("3", value: $draftConfig.circuitBreakerFailures, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 56)
                            }
                            HStack {
                                Text("并发上限")
                                TextField("2", value: $draftConfig.maxConcurrentRuns, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 52)
                            }
                        }
                        .font(.caption)
                    }
                    .padding(8)
                }

                GroupBox("候选本地工作区 (Workspaces)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("供 L1 分诊自动路由工作目录或规则参考")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        ForEach(Array(draftConfig.workspaces.enumerated()), id: \.offset) { idx, ws in
                            HStack {
                                Text(ws.name)
                                    .font(.caption.bold())
                                    .frame(width: 110, alignment: .leading)
                                Text(ws.path)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text(ws.summary)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                Spacer()
                                Button {
                                    draftConfig.workspaces.remove(at: idx)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }

                        HStack(spacing: 6) {
                            TextField("名称 (如 demo-api)", text: $newWSName)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 130)
                            TextField("本地路径", text: $newWSPath)
                                .textFieldStyle(.roundedBorder)
                            Button("选择目录...") {
                                if let chosen = pickFolder() {
                                    newWSPath = chosen
                                    if newWSName.isEmpty {
                                        newWSName = URL(fileURLWithPath: chosen).lastPathComponent
                                    }
                                }
                            }
                            .controlSize(.small)
                            TextField("简要职责说明", text: $newWSSummary)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 160)
                            Button("添加") {
                                guard !newWSPath.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                                let name = newWSName.isEmpty ? URL(fileURLWithPath: newWSPath).lastPathComponent : newWSName
                                draftConfig.workspaces.append(WorkspaceEntry(name: name, path: newWSPath, summary: newWSSummary))
                                newWSName = ""
                                newWSPath = ""
                                newWSSummary = ""
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(8)
                }
            }
            .padding(20)
        }
        .onAppear {
            draftConfig = model.orchestrator.currentConfig()
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
        .onChange(of: model.preferredTerminal) { _, updatedTerminal in
            if draftConfig.terminal != updatedTerminal {
                draftConfig.terminal = updatedTerminal
            }
        }
        .onChange(of: model.feishuEnabled) { _, updatedFeishu in
            if draftConfig.feishuSensorEnabled != updatedFeishu {
                draftConfig.feishuSensorEnabled = updatedFeishu
            }
        }
    }

    private var feishuStatusLine: String {
        guard model.feishuEnabled else { return "当前已关闭" }
        switch model.feishuStatus {
        case .watching: return "已连接（实时监听 com.electron.lark 通知）"
        case .needsFullDiskAccess: return "缺少完全磁盘访问权限，点击右侧授权"
        case .unavailable: return model.feishuErrorMessage ?? "通知数据库暂不可读"
        case .disabled: return "已关闭"
        }
    }

    private func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        } catch {
            saveToast = "开机自启设置失败（需从 /Applications/Bianzhong.app 运行）"
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }

    private func saveDraft() {
        do {
            try model.orchestrator.saveConfig(draftConfig)
            model.refresh()
            saveToast = "✓ 已保存到 config.yml 并热加载"
        } catch {
            saveToast = "保存失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 2. Visual Rules Workbench

private struct RulesWorkbenchPane: View {
    @ObservedObject var model: AppModel
    @State private var selectedRuleID: String?
    @State private var editMode: Int = 0 // 0 = Form, 1 = Markdown
    @State private var draftRule: ChimeRule = ChimeRule(id: "new-rule")
    @State private var rawMarkdown: String = ""
    @State private var replaySummaryText: String?
    @State private var isReplaying = false
    @State private var saveMessage: String?

    // Comma-separated form bindings
    @State private var typesText = ""
    @State private var sourcesText = ""
    @State private var titleEqualsText = ""
    @State private var titleAnyText = ""
    @State private var bodyAnyText = ""
    @State private var bodyAllText = ""
    @State private var keywordsAnyText = ""
    @State private var excludeKeywordsText = ""
    @State private var expectEnabled = false
    @State private var expectStart = "09:00"
    @State private var expectEnd = "09:30"
    @State private var webhookURLOrEnv = ""
    @State private var webhookPreset = "raw"
    @State private var webhookSecretEnv = ""

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("规则列表 (\(model.rules.count))")
                        .font(.subheadline.bold())
                    Spacer()
                    Menu("+ 新建") {
                        Button("飞书指定群精准告警排查") {
                            createFromTemplate(.feishuGroup)
                        }
                        Button("预期窗口未收到信号看门狗 (Expect)") {
                            createFromTemplate(.expectWatchdog)
                        }
                        Button("GitHub / Webhook CI 失败诊断") {
                            createFromTemplate(.githubCI)
                        }
                        Button("累计 N 次报错阈值告警") {
                            createFromTemplate(.dailyThreshold)
                        }
                        Divider()
                        Button("打开终端 AI 规则共创助手 (bz config)") {
                            model.openConfigChat()
                        }
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)

                List(selection: $selectedRuleID) {
                    ForEach(model.rules) { r in
                        HStack {
                            Circle()
                                .fill(r.enabled ? Color.green : Color.secondary.opacity(0.4))
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.id)
                                    .font(.caption.bold())
                                Text(r.matchSummary)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .tag(r.id)
                    }
                }
                .onChange(of: selectedRuleID) { _, newID in
                    if let id = newID, let found = model.rules.first(where: { $0.id == id }) {
                        loadRuleIntoEditor(found)
                    }
                }
            }
            .frame(minWidth: 210, idealWidth: 235, maxWidth: 270)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("", selection: $editMode) {
                        Text("可视化表单").tag(0)
                        Text("Markdown 源码").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                    .onChange(of: editMode) { _, mode in
                        if mode == 1 {
                            syncFormIntoDraftRule()
                            rawMarkdown = draftRule.serializeToMarkdown()
                        } else {
                            let reparsed = ChimeRule.parse(markdown: rawMarkdown, defaultID: draftRule.id)
                            var merged = reparsed
                            merged.filePath = draftRule.filePath
                            loadRuleIntoEditor(merged, preserveRaw: true)
                        }
                    }

                    Spacer()

                    if let msg = saveMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    Button(isReplaying ? "回放中..." : "历史 50 条回放试跑") {
                        runHistoricalReplay()
                    }
                    .controlSize(.small)
                    .disabled(isReplaying)

                    Button("删除") {
                        try? model.orchestrator.deleteRule(id: draftRule.id)
                        model.refresh()
                        selectedRuleID = model.rules.first?.id
                    }
                    .controlSize(.small)

                    Button("保存并重载") {
                        saveCurrentRule()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                if let replayText = replaySummaryText {
                    HStack {
                        Image(systemName: "play.circle.fill")
                            .foregroundStyle(.blue)
                        Text(replayText)
                            .font(.caption)
                        Spacer()
                        Button("关闭") { replaySummaryText = nil }
                            .controlSize(.mini)
                    }
                    .padding(8)
                    .background(Color.blue.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                if editMode == 1 {
                    TextEditor(text: $rawMarkdown)
                        .font(.system(.caption, design: .monospaced))
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            GroupBox("基本信息") {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text("规则 ID").frame(width: 90, alignment: .leading)
                                        TextField("unique-rule-id", text: $draftRule.id)
                                            .textFieldStyle(.roundedBorder)
                                        Toggle("启用", isOn: $draftRule.enabled)
                                    }
                                    HStack {
                                        Text("描述").frame(width: 90, alignment: .leading)
                                        TextField("一句话描述规则用途", text: $draftRule.description)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                }
                                .font(.caption)
                                .padding(6)
                            }

                            GroupBox("L0 分字段匹配条件（多项之间为 AND 关系，逗号分隔列表项）") {
                                VStack(alignment: .leading, spacing: 6) {
                                    labeledField("事件类型 type", "dev.bianzhong.feishu.notification", $typesText)
                                    labeledField("来源 source", "bz://sensor/feishu", $sourcesText)
                                    labeledField("标题精确等于", "例如：支付研发群, 核心告警群", $titleEqualsText)
                                    labeledField("标题包含任一", "例如：研发, 值班", $titleAnyText)
                                    labeledField("正文包含任一", "例如：报错, 500, 超时", $bodyAnyText)
                                    labeledField("正文必须全含", "例如：退款, 线上", $bodyAllText)
                                    labeledField("全文任一关键词", "留空不限", $keywordsAnyText)
                                    labeledField("排除词 (拦截)", "例如：收到, 辛苦, 演练", $excludeKeywordsText)
                                }
                                .font(.caption)
                                .padding(6)
                            }

                            GroupBox("漏斗阈值与预期时间窗口 (Watchdog)") {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 14) {
                                        HStack {
                                            Text("防抖(s)")
                                            TextField("5", value: $draftRule.debounceSeconds, format: .number)
                                                .textFieldStyle(.roundedBorder).frame(width: 52)
                                        }
                                        HStack {
                                            Text("去重(s)")
                                            TextField("300", value: $draftRule.dedupTTLSeconds, format: .number)
                                                .textFieldStyle(.roundedBorder).frame(width: 60)
                                        }
                                        HStack {
                                            Text("冷却(s)")
                                            TextField("900", value: $draftRule.cooldownSeconds, format: .number)
                                                .textFieldStyle(.roundedBorder).frame(width: 60)
                                        }
                                        HStack {
                                            Text("累计达 N 次触发")
                                            Stepper("\(draftRule.minCount)", value: $draftRule.minCount, in: 1...50)
                                        }
                                    }
                                    Divider()
                                    HStack(spacing: 12) {
                                        Toggle("启用预期窗口看门狗（窗口内未收到上述匹配消息则触发告警）", isOn: $expectEnabled)
                                        if expectEnabled {
                                            TextField("09:00", text: $expectStart)
                                                .textFieldStyle(.roundedBorder).frame(width: 64)
                                            Text("至")
                                            TextField("09:30", text: $expectEnd)
                                                .textFieldStyle(.roundedBorder).frame(width: 64)
                                        }
                                    }
                                }
                                .font(.caption)
                                .padding(6)
                            }

                            GroupBox("Agent 调度与出站 Webhook 动作") {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 12) {
                                        Text("执行驱动").frame(width: 80, alignment: .leading)
                                        Picker("", selection: $draftRule.driver) {
                                            Text("omp").tag("omp")
                                            Text("codex").tag("codex")
                                            Text("纯动作 (none，不调大模型)").tag("none")
                                        }
                                        .frame(width: 200)

                                        Toggle("Phase 2 隔离 Worktree", isOn: $draftRule.worktreeOnPhase2)
                                    }
                                    HStack {
                                        Text("工作目录").frame(width: 80, alignment: .leading)
                                        TextField("~/path/to/repo 或 $payload.cwd", text: $draftRule.workingDir)
                                            .textFieldStyle(.roundedBorder)
                                        Button("浏览...") {
                                            if let folder = pickFolder() {
                                                draftRule.workingDir = folder
                                            }
                                        }
                                        .controlSize(.small)
                                    }
                                    HStack {
                                        Text("出站 Webhook").frame(width: 80, alignment: .leading)
                                        Picker("", selection: $webhookPreset) {
                                            Text("不额外发 Webhook").tag("off")
                                            ForEach(WebhookPreset.allCases) { p in
                                                Text(p.displayName).tag(p.rawValue)
                                            }
                                        }
                                        .frame(width: 190)
                                        if webhookPreset != "off" {
                                            TextField("URL 或密钥变量名（如 BIANZHONG_WEBHOOK_URL）", text: $webhookURLOrEnv)
                                                .textFieldStyle(.roundedBorder)
                                            if webhookPreset == "feishu_bot" {
                                                TextField("签名密钥名(可选)", text: $webhookSecretEnv)
                                                    .textFieldStyle(.roundedBorder)
                                                    .frame(width: 125)
                                            }
                                        }
                                    }
                                    Text("Phase 1 提示词（只读勘察指令）")
                                        .font(.caption.bold())
                                    TextEditor(text: $draftRule.phase1Prompt)
                                        .font(.caption)
                                        .frame(height: 76)
                                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2)))

                                    Text("Phase 2 提示词（人类批准后执行指令，留空表示无需第二阶段）")
                                        .font(.caption.bold())
                                    TextEditor(text: $draftRule.phase2Prompt)
                                        .font(.caption)
                                        .frame(height: 64)
                                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2)))
                                }
                                .font(.caption)
                                .padding(6)
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
        .onAppear {
            if let requestedID = model.consoleSelectedRuleID,
               let target = model.rules.first(where: { $0.id == requestedID }) {
                selectedRuleID = target.id
                loadRuleIntoEditor(target)
                model.consoleSelectedRuleID = nil
            } else if selectedRuleID == nil, let first = model.rules.first {
                selectedRuleID = first.id
                loadRuleIntoEditor(first)
            }
        }
        .onChange(of: model.consoleSelectedRuleID) { _, newRequestedID in
            if let id = newRequestedID,
               let target = model.rules.first(where: { $0.id == id }) {
                selectedRuleID = target.id
                loadRuleIntoEditor(target)
                model.consoleSelectedRuleID = nil
            }
        }
    }

    private func labeledField(_ label: String, _ placeholder: String, _ binding: Binding<String>) -> some View {
        HStack {
            Text(label).frame(width: 105, alignment: .leading)
            TextField(placeholder, text: binding)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func loadRuleIntoEditor(_ rule: ChimeRule, preserveRaw: Bool = false) {
        draftRule = rule
        typesText = rule.matchTypes.joined(separator: ", ")
        sourcesText = rule.matchSources.joined(separator: ", ")
        titleEqualsText = rule.titleEquals.joined(separator: ", ")
        titleAnyText = rule.titleAny.joined(separator: ", ")
        bodyAnyText = rule.bodyAny.joined(separator: ", ")
        bodyAllText = rule.bodyAll.joined(separator: ", ")
        keywordsAnyText = rule.keywordsAny.joined(separator: ", ")
        excludeKeywordsText = rule.excludeKeywords.joined(separator: ", ")
        if let exp = rule.expectWindow {
            expectEnabled = exp.enabled
            expectStart = exp.windowStart
            expectEnd = exp.windowEnd
        } else {
            expectEnabled = false
        }
        if let wh = rule.onComplete.first(where: { $0.type == .webhook }) {
            webhookPreset = wh.preset ?? "raw"
            webhookURLOrEnv = wh.url ?? wh.urlEnv ?? ""
            webhookSecretEnv = wh.secretEnv ?? ""
        } else {
            webhookPreset = "off"
            webhookURLOrEnv = ""
            webhookSecretEnv = ""
        }
        if !preserveRaw {
            if let path = rule.filePath, let disk = try? String(contentsOfFile: path, encoding: .utf8) {
                rawMarkdown = disk
            } else {
                rawMarkdown = rule.serializeToMarkdown()
            }
        }
        saveMessage = nil
    }

    private func syncFormIntoDraftRule() {
        func splitCSV(_ s: String) -> [String] {
            s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        draftRule.matchTypes = splitCSV(typesText)
        draftRule.matchSources = splitCSV(sourcesText)
        draftRule.titleEquals = splitCSV(titleEqualsText)
        draftRule.titleAny = splitCSV(titleAnyText)
        draftRule.bodyAny = splitCSV(bodyAnyText)
        draftRule.bodyAll = splitCSV(bodyAllText)
        draftRule.keywordsAny = splitCSV(keywordsAnyText)
        draftRule.excludeKeywords = splitCSV(excludeKeywordsText)

        if expectEnabled {
            let prev = draftRule.expectWindow
            draftRule.expectWindow = ExpectWindowSpec(
                enabled: true,
                windowStart: expectStart,
                windowEnd: expectEnd,
                weekdays: prev?.weekdays ?? [1, 2, 3, 4, 5],
                suppressOnMatch: prev?.suppressOnMatch ?? true,
                graceSeconds: prev?.graceSeconds ?? 0
            )
        } else if var prev = draftRule.expectWindow {
            prev.enabled = false
            prev.windowStart = expectStart
            prev.windowEnd = expectEnd
            draftRule.expectWindow = prev
        } else {
            draftRule.expectWindow = nil
        }

        let nonWebhookActions = draftRule.onComplete.filter { $0.type != .webhook }
        let existingWebhooks = draftRule.onComplete.filter { $0.type == .webhook }
        var rebuiltActions = nonWebhookActions

        if webhookPreset != "off", !webhookURLOrEnv.trimmingCharacters(in: .whitespaces).isEmpty {
            let trimmed = webhookURLOrEnv.trimmingCharacters(in: .whitespaces)
            let isURL = trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://")
            var primaryWebhook = existingWebhooks.first ?? ActionSpec(type: .webhook)
            primaryWebhook.preset = webhookPreset
            primaryWebhook.url = isURL ? trimmed : nil
            primaryWebhook.urlEnv = isURL ? nil : trimmed
            primaryWebhook.secretEnv = webhookSecretEnv.trimmingCharacters(in: .whitespaces).isEmpty ? nil : webhookSecretEnv.trimmingCharacters(in: .whitespaces)
            rebuiltActions.append(primaryWebhook)
            if existingWebhooks.count > 1 {
                rebuiltActions.append(contentsOf: existingWebhooks.dropFirst())
            }
        }
        draftRule.onComplete = rebuiltActions
    }

    private func saveCurrentRule() {
        do {
            let saved: ChimeRule
            if editMode == 1 {
                saved = try model.orchestrator.saveRawRuleMarkdown(id: draftRule.id, filePath: draftRule.filePath, markdown: rawMarkdown)
            } else {
                syncFormIntoDraftRule()
                saved = try model.orchestrator.saveRule(draftRule)
            }
            model.refresh()
            selectedRuleID = saved.id
            loadRuleIntoEditor(saved, preserveRaw: editMode == 1)
            saveMessage = "✓ 已保存并热重载"
        } catch {
            saveMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    private func runHistoricalReplay() {
        isReplaying = true
        let ruleSnapshot: ChimeRule
        if editMode == 1 {
            ruleSnapshot = ChimeRule.parse(markdown: rawMarkdown, defaultID: draftRule.id)
        } else {
            syncFormIntoDraftRule()
            ruleSnapshot = draftRule
        }
        Task {
            let events = (try? model.orchestrator.store.listRecentEvents(limit: 50)) ?? []
            var activeRule = ruleSnapshot
            activeRule.enabled = true
            let summary = await RuleSimulator.simulate(
                events: events,
                rules: [activeRule],
                config: model.orchestrator.currentConfig(),
                runL1: false
            )
            let hitCount = summary.wouldWakeAgent + summary.directActionOnly
            replaySummaryText = "回放最近 \(summary.totalEvents) 条真实历史信号：命中 \(hitCount) 条，拦截 \(summary.droppedL0) 条"
            isReplaying = false
        }
    }

    private enum TemplateKind {
        case feishuGroup, expectWatchdog, githubCI, dailyThreshold
    }

    private func createFromTemplate(_ kind: TemplateKind) {
        let suffix = String(UUID().uuidString.prefix(4)).lowercased()
        let tpl: ChimeRule
        switch kind {
        case .feishuGroup:
            tpl = ChimeRule(
                id: "feishu-group-\(suffix)",
                description: "监听指定飞书群中包含报错关键词的通知并只读排查",
                matchTypes: ["dev.bianzhong.feishu.notification"],
                matchSources: ["bz://sensor/feishu"],
                titleEquals: ["支付研发群"],
                bodyAny: ["报错", "500", "异常"],
                driver: "omp",
                workingDir: model.orchestrator.paths.configDir.path,
                phase1Prompt: "请阅读事件上下文，在当前仓库只读排查问题原因并给出 5 行以内的群回复草稿。"
            )
        case .expectWatchdog:
            tpl = ChimeRule(
                id: "daily-watchdog-\(suffix)",
                description: "工作日预期窗口内未收到日报消息时自动提醒",
                matchTypes: ["dev.bianzhong.feishu.notification"],
                titleEquals: ["数据日报群"],
                bodyAny: ["日报已产出"],
                expectWindow: ExpectWindowSpec(enabled: true, windowStart: "09:00", windowEnd: "09:30", weekdays: [1, 2, 3, 4, 5]),
                driver: "none",
                onComplete: [ActionSpec(type: .notify)]
            )
        case .githubCI:
            tpl = ChimeRule(
                id: "github-ci-\(suffix)",
                description: "接收 GitHub Webhook CI 失败信号并在本地仓库定位根因",
                matchTypes: ["dev.bianzhong.ci.failed", "dev.bianzhong.github.*"],
                driver: "codex",
                workingDir: model.orchestrator.currentConfig().workspaces.first?.path ?? "~",
                worktreeOnPhase2: true,
                phase1Prompt: "GitHub Webhook 上报构建失败，请只读分析失败原因并给出最小修复方案。",
                phase2Prompt: "请在独立 Worktree 中完成修复并运行单测验证。审批备注：{{approval.user_comment}}"
            )
        case .dailyThreshold:
            tpl = ChimeRule(
                id: "threshold-alert-\(suffix)",
                description: "同一日内累计出现第 3 次超时告警才唤醒排查",
                matchTypes: ["dev.bianzhong.feishu.notification"],
                bodyAny: ["超时"],
                minCount: 3,
                countWindow: .daily,
                driver: "omp",
                phase1Prompt: "今日已累计多次超时告警，请汇总时间线并排查共性根因。"
            )
        }
        editMode = 0
        loadRuleIntoEditor(tpl)
    }
}

// MARK: - 3. Live Event Funnel Inspector

private struct EventInspectorPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("信号漏斗实时透视")
                        .font(.title2.bold())
                    Text("追踪每一条进入 Bianzhong 的本地信号在 L0/L1 各层的匹配、去重、累计或唤醒轨迹")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    reloadAudit()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }

            HStack(spacing: 10) {
                TextField("搜索标题、群名、来源、规则 ID 或拦截原因...", text: $model.auditSearchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { reloadAudit() }

                Picker("阶段", selection: $model.auditStageFilter) {
                    Text("全部阶段").tag("all")
                    Text("已放行 / 唤醒 (dispatched)").tag("dispatched")
                    Text("防抖合并中 (coalesced)").tag("coalesced")
                    Text("阈值累计中 (dropped_threshold)").tag("dropped_threshold")
                    Text("预期窗口已满足 (expect_satisfied)").tag("expect_satisfied")
                    Text("预期窗口超时告警 (expect_missed)").tag("expect_missed")
                    Text("规则未命中 (dropped_rule)").tag("dropped_rule")
                    Text("全部已拦截").tag("dropped")
                }
                .frame(width: 240)
                .onChange(of: model.auditStageFilter) { _, _ in reloadAudit() }
            }

            if model.auditEvents.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("暂无符合筛选条件的事件记录")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.auditEvents) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            stageBadge(item.funnelStage)
                            Text(item.title)
                                .font(.subheadline.bold())
                                .lineLimit(1)
                            if let chime = item.matchedChimeID {
                                Text("→ \(chime)")
                                    .font(.caption.bold())
                                    .foregroundStyle(.blue)
                            }
                            Spacer()
                            Text(formatTimestamp(item.receivedAt))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }

                        HStack(spacing: 8) {
                            Text("\(item.source) · \(item.type)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            if let reason = item.dropReason, !reason.isEmpty {
                                Text("原因: \(reason)")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }

                        if !item.bodyPreview.isEmpty {
                            Text(item.bodyPreview)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(20)
        .onAppear { reloadAudit() }
    }

    private func reloadAudit() {
        model.loadAuditEvents(stageFilter: model.auditStageFilter, query: model.auditSearchQuery)
    }

    private func stageBadge(_ stage: String) -> some View {
        let color: Color
        switch stage {
        case "dispatched", "coalesced": color = .green
        case "expect_missed": color = .red
        case "expect_satisfied", "dropped_threshold": color = .blue
        default: color = .secondary
        }
        return Text(stage)
            .font(.caption2.monospaced().bold())
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - 4. Bidirectional Webhooks & Secrets Center

private struct WebhooksAndSecretsPane: View {
    @ObservedObject var model: AppModel
    @State private var whEnabled = true
    @State private var whHost = "127.0.0.1"
    @State private var whPort = 17380
    @State private var whCallbackBase = ""
    @State private var tokenRevealed = false
    @State private var inboundTestResult: String?

    @State private var testPreset: WebhookPreset = .feishuBot
    @State private var testOutboundURL = ""
    @State private var testOutboundSecret = ""
    @State private var testOutboundChatID = ""
    @State private var outboundTestResult: String?
    @State private var isTestingOutbound = false

    @State private var newSecretKey = ""
    @State private var newSecretVal = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("双向 Webhook 网关与安全密钥中心")
                    .font(.title2.bold())

                GroupBox("入站 HTTP Webhook 与 URL Scheme（供外部应用调用 Bianzhong）") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Toggle("启用入站 HTTP Webhook 服务", isOn: $whEnabled)
                            Spacer()
                            let st = model.webhookStatus
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(st.running ? Color.green : (st.enabled ? Color.orange : Color.secondary))
                                    .frame(width: 8, height: 8)
                                Text(st.running ? "监听中 http://\(st.host):\(st.port)" : (st.errorMessage ?? "未运行"))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Button("应用端口配置") {
                                applyWebhookConfig()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }

                        HStack(spacing: 12) {
                            Text("绑定地址")
                            TextField("127.0.0.1", text: $whHost)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 130)
                            Text("端口")
                            TextField("17380", value: $whPort, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                            Text("远程审批回调基址(可选)")
                            TextField("如 http://my-mac.tailnet.ts.net:17380", text: $whCallbackBase)
                                .textFieldStyle(.roundedBorder)
                        }
                        .font(.caption)

                        Divider()

                        HStack(spacing: 8) {
                            Text("Bearer Token:")
                                .font(.caption.bold())
                            Text(tokenRevealed ? model.webhookToken : SecretStore.maskedPreview(model.webhookToken))
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            Button(tokenRevealed ? "隐藏" : "显示") {
                                tokenRevealed.toggle()
                            }
                            .controlSize(.mini)
                            Button("复制 Token") {
                                copyToPasteboard(model.webhookToken, concealed: true)
                            }
                            .controlSize(.mini)
                            Button("轮换 Token") {
                                model.rotateWebhookToken()
                            }
                            .controlSize(.mini)
                            Spacer()
                            Button("自测入站 POST") {
                                sendLoopbackInboundTest()
                            }
                            .controlSize(.small)
                        }

                        if let inboundRes = inboundTestResult {
                            Text(inboundRes)
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }

                        let port = Int(model.webhookStatus.port > 0 ? model.webhookStatus.port : UInt16(clamping: whPort))
                        let curlCmd = "curl -X POST http://127.0.0.1:\(port)/v1/emit -H 'Authorization: Bearer \(model.webhookToken)' -H 'Content-Type: application/json' -d '{\"type\":\"dev.bianzhong.webhook.emit\",\"title\":\"外部告警\",\"body\":\"接口延迟升高\"}'"
                        let schemeExample = "open 'bianzhong://emit?type=dev.bianzhong.manual&title=快捷触发&body=请检查当前目录状态&token=\(model.webhookToken)'"

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("通用 HTTP 入站：POST /v1/emit  |  平台预设：POST /v1/hooks/{github|feishu|sentry|grafana}")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("复制 curl 示例") { copyToPasteboard(curlCmd, concealed: true) }
                                    .controlSize(.mini)
                                Button("复制 bianzhong:// 示例") { copyToPasteboard(schemeExample, concealed: true) }
                                    .controlSize(.mini)
                            }
                        }
                    }
                    .padding(8)
                }

                GroupBox("出站 Webhook 快速连通性测试（Bianzhong 主动推送给飞书 / Bark / Slack 等）") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Picker("预设格式", selection: $testPreset) {
                                ForEach(WebhookPreset.allCases) { p in
                                    Text(p.displayName).tag(p)
                                }
                            }
                            .frame(width: 240)

                            TextField("目标 Webhook URL（如飞书机器人地址或 Bark 地址）", text: $testOutboundURL)
                                .textFieldStyle(.roundedBorder)
                        }
                        HStack(spacing: 8) {
                            TextField("签名密钥或密钥变量名（可选，如 FEISHU_BOT_SECRET）", text: $testOutboundSecret)
                                .textFieldStyle(.roundedBorder)
                            if testPreset == .telegram {
                                TextField("Telegram chat_id", text: $testOutboundChatID)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 150)
                            }
                            Button(isTestingOutbound ? "发送中..." : "发送测试卡片") {
                                isTestingOutbound = true
                                Task {
                                    let urlResolved = SecretStore.resolve(testOutboundURL, paths: model.orchestrator.paths) ?? testOutboundURL
                                    let res = await ActionDispatcher.sendTestOutboundWebhook(
                                        preset: testPreset,
                                        urlString: urlResolved,
                                        secretEnvOrRaw: testOutboundSecret,
                                        tokenEnvOrRaw: nil,
                                        chatID: testOutboundChatID,
                                        paths: model.orchestrator.paths
                                    )
                                    outboundTestResult = res.message
                                    isTestingOutbound = false
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(isTestingOutbound || testOutboundURL.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        if let outRes = outboundTestResult {
                            Text(outRes)
                                .font(.caption2)
                                .foregroundStyle(outRes.contains("成功") ? .green : .orange)
                        }
                    }
                    .font(.caption)
                    .padding(8)
                }

                GroupBox("安全密钥中心（本地 0600 隔离存储，不进 Git，解决 GUI 应用读不到 ~/.zshrc 变量的问题）") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Text("常用变量名快捷填入：")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            ForEach(["BIANZHONG_WEBHOOK_URL", "FEISHU_BOT_SECRET", "BIANZHONG_DECISION_API_KEY"], id: \.self) { presetKey in
                                Button(presetKey) {
                                    newSecretKey = presetKey
                                }
                                .controlSize(.mini)
                            }
                        }

                        ForEach(model.storedSecrets.keys.sorted(), id: \.self) { k in
                            if k != SecretStore.webhookTokenKey {
                                HStack {
                                    Text(k)
                                        .font(.caption.monospaced().bold())
                                        .frame(width: 240, alignment: .leading)
                                    Text(SecretStore.maskedPreview(model.storedSecrets[k] ?? ""))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("删除") {
                                        model.deleteSecret(key: k)
                                    }
                                    .controlSize(.mini)
                                }
                            }
                        }

                        HStack(spacing: 8) {
                            TextField("变量名 (如 BIANZHONG_WEBHOOK_URL)", text: $newSecretKey)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 240)
                            SecureField("密钥或 URL 值", text: $newSecretVal)
                                .textFieldStyle(.roundedBorder)
                            Button("保存密钥") {
                                guard !newSecretKey.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                                model.saveSecret(key: newSecretKey, value: newSecretVal)
                                newSecretKey = ""
                                newSecretVal = ""
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(8)
                }
            }
            .padding(20)
        }
        .onAppear {
            let cfg = model.orchestrator.currentConfig()
            whEnabled = cfg.webhookServerEnabled
            whHost = cfg.webhookHost
            whPort = cfg.webhookPort
            whCallbackBase = cfg.webhookCallbackBaseURL ?? ""
            model.refreshConsoleData()
        }
    }

    private func applyWebhookConfig() {
        var cfg = model.orchestrator.currentConfig()
        cfg.webhookServerEnabled = whEnabled
        cfg.webhookHost = whHost.trimmingCharacters(in: .whitespaces)
        cfg.webhookPort = whPort
        let trimmedBase = whCallbackBase.trimmingCharacters(in: .whitespaces)
        cfg.webhookCallbackBaseURL = trimmedBase.isEmpty ? nil : trimmedBase
        try? model.orchestrator.saveConfig(cfg)
        model.refreshConsoleData()
    }

    private func sendLoopbackInboundTest() {
        let st = model.webhookStatus
        guard st.running, st.port > 0 else {
            inboundTestResult = "请先启用入站 HTTP Webhook 服务"
            return
        }
        let targetHost = (st.host == "0.0.0.0" || st.host.lowercased() == "localhost" || st.host.isEmpty) ? "127.0.0.1" : st.host
        guard let url = URL(string: "http://\(targetHost):\(st.port)/v1/emit") else { return }
        var req = URLRequest(url: url, timeoutInterval: 4.0)
        req.httpMethod = "POST"
        req.setValue("Bearer \(model.webhookToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "type": "dev.bianzhong.webhook.self_test",
            "title": "控制台入站自测",
            "body": "HTTP Webhook 链路正常"
        ])
        Task {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let txt = String(data: data, encoding: .utf8) ?? ""
                inboundTestResult = "✓ HTTP \(code)：\(txt)"
                model.refreshConsoleData()
            } catch {
                inboundTestResult = "请求失败：\(error.localizedDescription)"
            }
        }
    }
}

// MARK: - 5. Runs Ledger & Isolated Worktrees

private struct RunsAndWorktreesPane: View {
    @ObservedObject var model: AppModel
    @State private var selectedWorktreeDiff: String?
    @State private var selectedWorktreeName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("运行账本与隔离 Worktree")
                    .font(.title2.bold())
                Spacer()
                Text("今日运行：\(model.todayRunsCount) 次 · 今日花费：$\(String(format: "%.3f", model.todayCostUSD))")
                    .font(.caption.monospaced())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
                Button {
                    model.refreshConsoleData()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }

            GroupBox("隔离 Git Worktree 管理 (Phase 2 产物)") {
                if model.worktrees.isEmpty {
                    Text("当前没有活跃的隔离 Worktree 目录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.worktrees) { wt in
                            HStack {
                                Text(wt.name)
                                    .font(.caption.monospaced().bold())
                                Text(wt.branch)
                                    .font(.caption2.monospaced())
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.blue.opacity(0.14))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                Text(wt.isDirty ? "有未提交修改" : "干净")
                                    .font(.caption2)
                                    .foregroundStyle(wt.isDirty ? .orange : .green)
                                Spacer()
                                Button("查看 Diff") {
                                    selectedWorktreeName = wt.name
                                    selectedWorktreeDiff = model.orchestrator.worktreeDiff(at: wt.path)
                                }
                                .controlSize(.mini)
                                Button("终端打开 ↗") {
                                    _ = TerminalLauncher.openInteractiveShell(
                                        at: wt.path,
                                        preferredTerminal: model.orchestrator.currentConfig().terminal
                                    )
                                }
                                .controlSize(.mini)
                                if !wt.isDirty {
                                    Button("移除") {
                                        try? model.orchestrator.removeWorktree(at: wt.path)
                                        model.refreshConsoleData()
                                    }
                                    .controlSize(.mini)
                                }
                            }
                        }
                        if let diff = selectedWorktreeDiff {
                            Divider()
                            HStack {
                                Text("Worktree 预览：\(selectedWorktreeName ?? "")")
                                    .font(.caption.bold())
                                Spacer()
                                Button("收起") { selectedWorktreeDiff = nil }
                                    .controlSize(.mini)
                            }
                            ScrollView {
                                Text(diff)
                                    .font(.system(.caption2, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(height: 130)
                        }
                    }
                    .padding(6)
                }
            }

            Text("最近 Agent 运行记录")
                .font(.subheadline.bold())

            List(model.recentRuns) { run in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(run.chimeID)
                            .font(.subheadline.bold())
                        Text("\(run.driver) · \(run.phase)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        Text(run.status)
                            .font(.caption2.bold())
                            .foregroundStyle(run.status == "succeeded" || run.status == "waiting_approval" ? .green : .orange)
                        Spacer()
                        Text(String(format: "$%.3f", run.costUSD))
                            .font(.caption2.monospaced())
                        Text(formatTimestamp(run.startedAt))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    if let summary = run.outputSummary, !summary.isEmpty {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 3)
            }
        }
        .padding(20)
        .onAppear { model.refreshConsoleData() }
    }
}

// MARK: - Local UI Helpers

private func pickFolder() -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "选择目录"
    return panel.runModal() == .OK ? panel.url?.path : nil
}

private func copyToPasteboard(_ text: String, concealed: Bool = false) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
    if concealed {
        let empty = Data()
        pb.setData(empty, forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pb.setData(empty, forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pb.setData(empty, forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
    }
}

@MainActor
private let consoleTimestampFormatter: DateFormatter = {
    let fmt = DateFormatter()
    fmt.dateFormat = "MM-dd HH:mm:ss"
    return fmt
}()

@MainActor
private func formatTimestamp(_ ms: Int64) -> String {
    let date = Date(timeIntervalSince1970: Double(ms) / 1000.0)
    return consoleTimestampFormatter.string(from: date)
}
