import AppKit
import BianzhongCore
import Carbon
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

/// Non-activating borderless floating panel anchored to the top-center MacBook Notch (or top bar on external displays).
/// Uses `sharingType = .none` so it is automatically invisible during Zoom / Feishu / TencentMeeting screen sharing.
final class ChimeBeamPanel: NSPanel {
    var allowKeyFocus = false

    override var canBecomeKey: Bool { allowKeyFocus }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.becomesKeyOnlyIfNeeded = true
        self.hidesOnDeactivate = false
        self.sharingType = .none
        self.isReleasedWhenClosed = false
    }
}

enum NotchHUDPhase: Equatable {
    case hidden
    case running
    case readyCompact
    case expanded
}

/// Manages the lifecycle, zero-TCC Carbon hotkey (`⌥Space`), and screen-top geometry of the "编钟梁 (Chime Beam)" Notch HUD.
@MainActor
final class NotchHUDController: ObservableObject {
    @Published var phase: NotchHUDPhase = .hidden
    @Published var steerInput: String = ""
    @Published var dropFeedback: String?
    @Published var notchTopInset: CGFloat = 0

    private weak var model: AppModel?
    private var panel: ChimeBeamPanel?
    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var eventHandlerRef: EventHandlerRef?
    private var autoTuckTask: Task<Void, Never>?
    private var lastAnnouncedApprovalID: String?
    private var manuallyDismissedApprovalID: String?
    private var isPreviewWhenIdle = false

    deinit {
        if let hk = hotKeyRef {
            UnregisterEventHotKey(hk)
        }
        if let eh = eventHandlerRef {
            RemoveEventHandler(eh)
        }
    }

    func attach(to model: AppModel) {
        self.model = model
        if model.notchHUDEnabled {
            registerOptionSpaceHotKey()
        }
        syncPresentation()
    }

    func toggleExpandedFromHotkey() {
        guard let model, model.notchHUDEnabled else { return }
        if phase == .expanded {
            collapse()
        } else {
            isPreviewWhenIdle = model.activeRuns.isEmpty && model.pendingApprovals.isEmpty
            expand(focusInput: true)
        }
    }

    func previewDemo() {
        isPreviewWhenIdle = (model?.activeRuns.isEmpty ?? true) && (model?.pendingApprovals.isEmpty ?? true)
        expand(focusInput: false)
    }

    func expand(focusInput: Bool = false) {
        autoTuckTask?.cancel()
        phase = .expanded
        panel?.allowKeyFocus = true
        presentAndPositionPanel(size: NSSize(width: 500, height: 320))
        if focusInput {
            panel?.makeKey()
        }
    }

    func collapse() {
        autoTuckTask?.cancel()
        isPreviewWhenIdle = false
        panel?.allowKeyFocus = false
        panel?.resignKey()
        steerInput = ""
        if let topID = model?.pendingApprovals.first?.id {
            manuallyDismissedApprovalID = topID
        }
        syncPresentation()
    }

    func syncPresentation() {
        guard let model else { return }
        guard model.notchHUDEnabled else {
            unregisterOptionSpaceHotKey()
            hidePanel()
            return
        }
        registerOptionSpaceHotKey()

        if phase == .expanded {
            if !model.activeRuns.isEmpty || !model.pendingApprovals.isEmpty {
                isPreviewWhenIdle = false
            }
            if model.activeRuns.isEmpty && model.pendingApprovals.isEmpty && dropFeedback == nil && !isPreviewWhenIdle {
                hidePanel()
            } else {
                presentAndPositionPanel(size: NSSize(width: 500, height: 320))
            }
            return
        }

        if !model.activeRuns.isEmpty {
            autoTuckTask?.cancel()
            phase = .running
            panel?.allowKeyFocus = false
            presentAndPositionPanel(size: NSSize(width: 380, height: 48))
            return
        }

        if let topApproval = model.pendingApprovals.first {
            if topApproval.id != manuallyDismissedApprovalID {
                phase = .readyCompact
                panel?.allowKeyFocus = false
                presentAndPositionPanel(size: NSSize(width: 410, height: 48))

                if lastAnnouncedApprovalID != topApproval.id {
                    lastAnnouncedApprovalID = topApproval.id
                    scheduleAutoTuck(for: topApproval.id)
                }
                return
            }
        }

        hidePanel()
    }

    func handleDroppedItems(urls: [URL], texts: [String]) {
        guard let model else { return }
        var title = "刘海投喂诊断"
        var bodyParts: [String] = []
        var cwd = model.orchestrator.currentConfig().workspaces.first?.path ?? model.orchestrator.paths.configDir.path

        for url in urls {
            title = "诊断文件：\(url.lastPathComponent)"
            let dir = url.deletingLastPathComponent().path
            if FileManager.default.fileExists(atPath: dir) {
                cwd = dir
            }
            if let snippet = Self.readBoundedUTF8Prefix(of: url, maxBytes: 8192) {
                bodyParts.append("File: \(url.path)\n\(snippet.prefix(2500))")
            } else {
                bodyParts.append("File Path: \(url.path)")
            }
        }
        for txt in texts where !txt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            bodyParts.append(String(txt.prefix(2500)))
        }
        guard !bodyParts.isEmpty else { return }

        let ev = EventEnvelope(
            source: "bz://notch/drop",
            type: "dev.bianzhong.notch.drop",
            correlationKey: "notch:drop:\(title)",
            privacyLevel: .internal,
            payload: [
                "title": title,
                "body": bodyParts.joined(separator: "\n\n"),
                "cwd": cwd
            ],
            ambientContext: .captureCurrent()
        )
        _ = model.orchestrator.handleBusRequest(BusRequest(action: "emit", event: ev))
        dropFeedback = "✓ 已投喂：\(title)"
        model.refresh()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            self.dropFeedback = nil
            self.syncPresentation()
        }
    }

    private func scheduleAutoTuck(for approvalID: String) {
        autoTuckTask?.cancel()
        autoTuckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(7))
            guard !Task.isCancelled, let self else { return }
            if self.phase == .readyCompact, self.model?.pendingApprovals.first?.id == approvalID {
                self.manuallyDismissedApprovalID = approvalID
                self.syncPresentation()
            }
        }
    }

    private func ensurePanel() -> ChimeBeamPanel {
        if let existing = panel { return existing }
        let p = ChimeBeamPanel(contentRect: NSRect(x: 0, y: 0, width: 410, height: 48))
        if let model {
            let root = NotchHUDView(hud: self, model: model)
            let host = NSHostingView(rootView: root)
            host.sizingOptions = []
            p.contentView = host
        }
        self.panel = p
        return p
    }

    private func presentAndPositionPanel(size: NSSize) {
        let p = ensurePanel()
        let mouseLoc = NSEvent.mouseLocation
        let activeScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen = activeScreen else { return }

        let screenFrame = screen.frame
        let safeTop = max(0, screen.safeAreaInsets.top)
        if notchTopInset != safeTop {
            notchTopInset = safeTop
        }
        let hasPhysicalNotch = safeTop > 0
        let topAnchorY = hasPhysicalNotch ? screenFrame.maxY : (screen.visibleFrame.maxY - 2)
        let effectiveHeight = size.height + safeTop
        let originX = round(screenFrame.midX - size.width / 2.0)
        let originY = round(topAnchorY - effectiveHeight)
        let targetFrame = NSRect(x: originX, y: originY, width: size.width, height: effectiveHeight)

        if !p.isVisible {
            p.setFrame(targetFrame, display: true)
            p.orderFrontRegardless()
        } else if p.frame != targetFrame {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.animator().setFrame(targetFrame, display: true)
            }
        }
    }

    private func hidePanel() {
        autoTuckTask?.cancel()
        isPreviewWhenIdle = false
        phase = .hidden
        panel?.allowKeyFocus = false
        panel?.orderOut(nil)
    }

    private func unregisterOptionSpaceHotKey() {
        if let hk = hotKeyRef {
            UnregisterEventHotKey(hk)
            hotKeyRef = nil
        }
    }

    private static func readBoundedUTF8Prefix(of url: URL, maxBytes: Int) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: maxBytes), !data.isEmpty else { return nil }
        if data.contains(0) {
            return nil // binary/image file -> pass path only
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Registers `⌥Space` using Carbon `RegisterEventHotKey` (requires ZERO Accessibility TCC permissions!).
    private func registerOptionSpaceHotKey() {
        guard hotKeyRef == nil else { return }
        if eventHandlerRef == nil {
            var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()

            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, _, userData -> OSStatus in
                    guard let userData else { return noErr }
                    let controller = Unmanaged<NotchHUDController>.fromOpaque(userData).takeUnretainedValue()
                    Task { @MainActor in
                        controller.toggleExpandedFromHotkey()
                    }
                    return noErr
                },
                1,
                &eventSpec,
                selfPtr,
                &eventHandlerRef
            )
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x425A4844), id: 1) // 'BZHD'
        RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }
}

// MARK: - SwiftUI Notch HUD View ("编钟梁")

private struct NotchHUDView: View {
    @ObservedObject var hud: NotchHUDController
    @ObservedObject var model: AppModel
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch hud.phase {
                case .hidden:
                    EmptyView()
                case .running:
                    runningCapsule
                case .readyCompact:
                    readyCapsule
                case .expanded:
                    expandedCard
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onDrop(of: [.fileURL, .plainText], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
            return true
        }
    }

    private var runningCapsule: some View {
        let topRun = model.activeRuns.first
        return HStack(spacing: 8) {
            Circle()
                .fill(topRun?.status == "warm_hold" ? Color.orange : Color.cyan)
                .frame(width: 7, height: 7)

            Text(topRun?.driver ?? "agent")
                .font(.caption.monospaced().bold())
                .foregroundStyle(.white)

            Text(topRun?.currentActivity ?? "运行中...")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)

            Spacer(minLength: 4)

            if let rid = topRun?.runID {
                Button("中止") {
                    _ = model.orchestrator.stopRun(id: rid)
                    model.refresh()
                }
                .buttonStyle(.plain)
                .font(.caption2.bold())
                .foregroundStyle(.red.opacity(0.9))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.1))
                .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, hud.notchTopInset)
        .frame(height: 36 + hud.notchTopInset)
        .background(notchShapeBackground(cornerRadius: 16))
        .onHover { hovering in
            if hovering { hud.expand(focusInput: false) }
        }
        .onTapGesture {
            hud.expand(focusInput: true)
        }
    }

    private var readyCapsule: some View {
        let top = model.pendingApprovals.first
        return HStack(spacing: 8) {
            Circle()
                .fill(Color.green)
                .frame(width: 7, height: 7)

            Text(top?.title ?? "待办就绪")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer(minLength: 4)

            Text("⌥Space 审阅")
                .font(.caption2.monospaced())
                .foregroundStyle(.white.opacity(0.65))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.1))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.top, hud.notchTopInset)
        .frame(height: 36 + hud.notchTopInset)
        .background(notchShapeBackground(cornerRadius: 16))
        .onHover { hovering in
            if hovering { hud.expand(focusInput: false) }
        }
        .onTapGesture {
            hud.expand(focusInput: true)
        }
    }

    private var expandedCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                if let run = model.activeRuns.first, run.status != "warm_hold" {
                    Circle().fill(Color.cyan).frame(width: 8, height: 8)
                    Text("\(run.driver) · \(run.currentActivity)")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer()
                    Button("中止") {
                        _ = model.orchestrator.stopRun(id: run.runID)
                        model.refresh()
                    }
                    .controlSize(.mini)
                } else if let apr = model.pendingApprovals.first {
                    let warm = model.orchestrator.isWarmHeldApproval(apr.id)
                    Circle().fill(warm ? Color.orange : Color.green).frame(width: 8, height: 8)
                    Text(apr.title)
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer()
                    Text(warm ? "ACP 热挂起" : apr.riskLevel.uppercased())
                        .font(.caption2.monospaced())
                        .foregroundStyle(warm ? .orange : .white.opacity(0.7))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Text(hud.dropFeedback ?? "编钟梁 · 暂无待办（可拖入日志/截图诊断）")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                    Spacer()
                }

                Button {
                    hud.collapse()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.caption.bold())
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }

            if let apr = model.pendingApprovals.first {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(apr.proposedAction)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.88))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)

                        if let diff = apr.diffPreview, !diff.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(diff.split(separator: "\n", omittingEmptySubsequences: false).prefix(18).enumerated()), id: \.offset) { _, rawLine in
                                    let line = String(rawLine)
                                    Text(line)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(diffLineColor(line))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(8)
                            .background(Color.black.opacity(0.45))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }
                .frame(maxHeight: 135)

                TextField("回车直接批准，或输入一句话让 Agent 调整方案...", text: $hud.steerInput)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .onSubmit {
                        submitPrimaryAction(for: apr)
                    }

                HStack(spacing: 8) {
                    Button {
                        submitPrimaryAction(for: apr)
                    } label: {
                        Text(hud.steerInput.trimmingCharacters(in: .whitespaces).isEmpty ? "批准执行 ⏎" : "发送调整 ⏎")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: [])

                    Menu("接管 ↗") {
                        Button("默认终端") {
                            _ = model.orchestrator.launchTakeover(for: apr.id)
                            hud.collapse()
                        }
                        ForEach(TerminalLauncher.installedIDEs) { ide in
                            Button("在 \(ide.displayName) 打开") {
                                _ = model.orchestrator.launchIDEHandoff(for: apr.id, ide: ide)
                                hud.collapse()
                            }
                        }
                    }
                    .controlSize(.small)
                    .frame(width: 88)

                    Spacer()

                    Button("忽略") {
                        _ = model.orchestrator.reject(id: apr.id, comment: "Dismissed from Notch HUD")
                        hud.steerInput = ""
                        model.refresh()
                    }
                    .controlSize(.small)
                }
            } else if let run = model.activeRuns.first {
                if !run.streamPreview.isEmpty {
                    ScrollView {
                        Text(run.streamPreview)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 150)
                }
            } else {
                Text("快捷键 ⌥Space 随时唤起/收起 · 将报错文件或截图拖入此处可直接触发排查")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12 + hud.notchTopInset)
        .padding(.bottom, 14)
        .background(notchShapeBackground(cornerRadius: 18))
    }

    private func submitPrimaryAction(for apr: ApprovalRecord) {
        let trimmed = hud.steerInput.trimmingCharacters(in: .whitespacesAndNewlines)
        hud.steerInput = ""
        if trimmed.isEmpty {
            _ = model.orchestrator.approve(id: apr.id, comment: "Approved from Notch HUD")
        } else {
            _ = model.orchestrator.steer(id: apr.id, instruction: trimmed)
        }
        model.refresh()
    }

    private func diffLineColor(_ line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return Color(red: 1.0, green: 0.45, blue: 0.45) }
        return .white.opacity(0.78)
    }

    private func notchShapeBackground(cornerRadius: CGFloat) -> some View {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: cornerRadius,
            bottomTrailingRadius: cornerRadius,
            topTrailingRadius: 0,
            style: .continuous
        )
        .fill(Color(red: 0.06, green: 0.07, blue: 0.09).opacity(0.94))
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: cornerRadius,
                bottomTrailingRadius: cornerRadius,
                topTrailingRadius: 0,
                style: .continuous
            )
            .strokeBorder(isDropTargeted ? Color.cyan : Color.white.opacity(0.14), lineWidth: isDropTargeted ? 1.5 : 0.8)
        )
        .shadow(color: .black.opacity(0.42), radius: 14, x: 0, y: 6)
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        Task {
            var urls: [URL] = []
            var texts: [String] = []
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                   let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier),
                   let data = item as? Data,
                   let u = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(u)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let item = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier),
                          let str = item as? String {
                    texts.append(str)
                }
            }
            await MainActor.run {
                hud.handleDroppedItems(urls: urls, texts: texts)
            }
        }
    }
}
