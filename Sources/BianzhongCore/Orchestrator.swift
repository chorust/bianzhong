import Foundation

private struct RunContextBundle: Codable {
    let event: EventEnvelope
    let recentTimeline: [TimelineEntry]
    let preflightOutput: String?

    enum CodingKeys: String, CodingKey {
        case event
        case recentTimeline = "recent_timeline"
        case preflightOutput = "preflight_output"
    }
}

public struct ManagedWorktreeInfo: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let branch: String
    public let isDirty: Bool
    public let modifiedAt: Date

    public init(name: String, path: String, branch: String, isDirty: Bool, modifiedAt: Date) {
        self.name = name
        self.path = path
        self.branch = branch
        self.isDirty = isDirty
        self.modifiedAt = modifiedAt
    }
}

public struct WebhookStatusInfo: Sendable, Equatable {
    public let enabled: Bool
    public let running: Bool
    public let host: String
    public let port: UInt16
    public let errorMessage: String?

    public init(enabled: Bool, running: Bool, host: String, port: UInt16, errorMessage: String?) {
        self.enabled = enabled
        self.running = running
        self.host = host
        self.port = port
        self.errorMessage = errorMessage
    }
}

public enum IncomingURLOutcome: Equatable, Sendable {
    case handled(BianzhongURLAction)
    case requiresConfirmation(BianzhongURLAction)
    case unauthorized
    case invalidURL
}

public struct OrchestratorCallbacks: Sendable {
    public var onApprovalUpdated: @Sendable () -> Void
    public var onNotifyApproval: @Sendable (ApprovalRecord) -> Void

    public init(
        onApprovalUpdated: @escaping @Sendable () -> Void = {},
        onNotifyApproval: @escaping @Sendable (ApprovalRecord) -> Void = { _ in }
    ) {
        self.onApprovalUpdated = onApprovalUpdated
        self.onNotifyApproval = onNotifyApproval
    }
}

private struct ParsedAgentOutput {
    var externalSessionID: String?
    var finalText: String?
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cachedTokens: Int = 0
    var costUSD: Double = 0.0
    var errorMessages: [String] = []
}

private actor ConcurrencyGate {
    private var limit: Int
    private var inFlight: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func updateLimit(_ newLimit: Int) {
        limit = max(1, newLimit)
        while inFlight < limit && !waiters.isEmpty {
            inFlight += 1
            let next = waiters.removeFirst()
            next.resume()
        }
    }

    func withPermit<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        if inFlight < limit {
            inFlight += 1
            return
        }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    private func release() {
        inFlight = max(0, inFlight - 1)
        if inFlight < limit, !waiters.isEmpty {
            inFlight += 1
            let next = waiters.removeFirst()
            next.resume()
        }
    }
}

/// Coordinates the socket bus, L0 wakeup funnel, pluggable L1 triage, governance,
/// correlated timeline, preflight hooks, two-phase agent runs, wake digests, and post-actions.
public final class Orchestrator: @unchecked Sendable {
    public let paths: BianzhongPaths
    public let store: SQLiteStore
    public let funnel: WakeupFunnel
    public let governance: RuntimeGovernance
    private let callbacks: OrchestratorCallbacks
    private let actionDispatcher: ActionDispatcher

    private var config: AppConfig
    private var bus: SocketBus?
    private var webhookServer: WebhookServer?
    private var webhookServerSubsystemEnabled = false
    private var webhookServerError: String?
    private var feishuMonitor: FeishuSensorMonitor?
    private var builtInSensorsEnabled = false
    private var customFeishuDBURL: URL?
    private var feishuSkipExistingOnFirstRun = true
    private let stateLock = NSLock()
    private var pausedUntil: Date?
    private var pauseTimer: DispatchSourceTimer?
    private var expectTimer: DispatchSourceTimer?
    private let runGate: ConcurrencyGate

    public init(paths: BianzhongPaths = BianzhongPaths(), callbacks: OrchestratorCallbacks = OrchestratorCallbacks()) throws {
        self.paths = paths
        try paths.ensureDirectories()
        _ = SecretStore.ensureWebhookToken(paths: paths)
        let initialConfig = AppConfig.load(from: paths.configFile)
        self.config = initialConfig
        self.store = try SQLiteStore(dbURL: paths.dbURL)
        let loadedRules = ChimeRule.loadAll(from: paths.chimesDir)
        let funnelInstance = WakeupFunnel(
            store: store,
            rules: loadedRules,
            maxCausalDepth: initialConfig.maxCausalDepth
        )
        self.funnel = funnelInstance
        self.governance = RuntimeGovernance()
        self.callbacks = callbacks
        self.runGate = ConcurrencyGate(limit: initialConfig.maxConcurrentRuns)

        final class WeakOrchestratorRef: @unchecked Sendable {
            weak var value: Orchestrator?
        }
        let weakRef = WeakOrchestratorRef()
        self.actionDispatcher = ActionDispatcher(
            funnel: funnelInstance,
            paths: paths,
            configProvider: { weakRef.value?.currentConfig() ?? initialConfig },
            notifyHandler: callbacks.onNotifyApproval
        )
        weakRef.value = self
    }

    public func start(
        enableBuiltInSensors: Bool = false,
        enableWebhookServer: Bool = false,
        feishuDBURL: URL? = nil,
        skipExistingFeishuOnFirstRun: Bool = true
    ) throws {
        let server = SocketBus(socketURL: paths.socketURL) { [weak self] req in
            guard let self else { return BusResponse(ok: false, message: "Orchestrator deallocated") }
            return self.handleBusRequest(req)
        }
        try server.start()

        stateLock.lock()
        self.bus = server
        self.builtInSensorsEnabled = enableBuiltInSensors
        self.webhookServerSubsystemEnabled = enableWebhookServer
        if let feishuDBURL {
            self.customFeishuDBURL = feishuDBURL
        }
        self.feishuSkipExistingOnFirstRun = skipExistingFeishuOnFirstRun
        stateLock.unlock()

        if enableBuiltInSensors {
            syncFeishuMonitor()
        }
        if enableWebhookServer {
            syncWebhookServer()
        }
        startExpectWindowTimer()

        let retention = currentConfig().retentionDays
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            _ = self.governance.performGC(paths: self.paths, store: self.store, retentionDays: retention)
        }
    }

    public func stop() {
        stateLock.lock()
        let timer = pauseTimer
        pauseTimer = nil
        let expTimer = expectTimer
        expectTimer = nil
        let monitor = feishuMonitor
        feishuMonitor = nil
        let whServer = webhookServer
        webhookServer = nil
        webhookServerSubsystemEnabled = false
        builtInSensorsEnabled = false
        stateLock.unlock()
        timer?.cancel()
        expTimer?.cancel()
        monitor?.stop()
        whServer?.stop()
        bus?.stop()
        bus = nil
    }

    public func webhookStatus() -> WebhookStatusInfo {
        stateLock.withLock {
            WebhookStatusInfo(
                enabled: config.webhookServerEnabled,
                running: webhookServer?.isRunning ?? false,
                host: config.webhookHost,
                port: webhookServer?.boundPort ?? UInt16(clamping: config.webhookPort),
                errorMessage: webhookServerError
            )
        }
    }

    private func syncWebhookServer() {
        let (subsystemActive, enabled, host, port, existing): (Bool, Bool, String, UInt16, WebhookServer?) = stateLock.withLock {
            (
                webhookServerSubsystemEnabled,
                config.webhookServerEnabled,
                config.webhookHost,
                UInt16(clamping: max(0, min(65535, config.webhookPort))),
                webhookServer
            )
        }
        guard subsystemActive else { return }

        if !enabled {
            if let existing {
                stateLock.withLock {
                    webhookServer = nil
                    webhookServerError = nil
                }
                existing.stop()
            }
            return
        }

        if let existing, existing.isRunning, existing.host == host, existing.requestedPort == port {
            return
        }

        existing?.stop()
        let pathsCopy = self.paths
        let server = WebhookServer(
            host: host,
            port: port,
            tokenProvider: {
                SecretStore.ensureWebhookToken(paths: pathsCopy)
            },
            onEmit: { [weak self] event in
                guard let self else { return (false, "stopped") }
                let resp = self.handleBusRequest(BusRequest(action: "emit", event: event))
                return (resp.ok, resp.disposition ?? resp.message)
            },
            onInspectApproval: { [weak self] id in
                guard let self, let rec = try? self.store.getApproval(id: id) else { return nil }
                let isPending = (rec.status == "pending" || rec.status == "deferred")
                return (pending: isPending, title: rec.title)
            },
            onResolveApproval: { [weak self] id, shouldApprove, comment in
                guard let self else { return false }
                if shouldApprove {
                    return self.approve(id: id, comment: comment ?? "Approved via HTTP webhook")
                } else {
                    return self.reject(id: id, comment: comment ?? "Rejected via HTTP webhook")
                }
            }
        )

        do {
            try server.start()
            stateLock.withLock {
                webhookServer = server
                webhookServerError = nil
            }
        } catch {
            stateLock.withLock {
                webhookServer = nil
                webhookServerError = error.localizedDescription
            }
        }
    }

    public func feishuSensorStatus() -> FeishuSensorStatus {
        let monitor = stateLock.withLock { feishuMonitor }
        return monitor?.currentStatus() ?? .disabled
    }

    public func feishuSensorErrorMessage() -> String? {
        let monitor = stateLock.withLock { feishuMonitor }
        return monitor?.currentErrorMessage()
    }

    public func allRules() -> [ChimeRule] {
        funnel.currentRules()
    }

    /// Toggles `enabled: true/false` in a rule's Markdown file and reloads all rules immediately.
    public func setRuleEnabled(id: String, enabled: Bool) throws {
        guard let rule = funnel.currentRules().first(where: { $0.id == id }) else {
            throw NSError(domain: "BianzhongOrchestrator", code: 404, userInfo: [NSLocalizedDescriptionKey: "Rule not found: \(id)"])
        }
        let targetURL: URL
        if let path = rule.filePath {
            targetURL = URL(fileURLWithPath: path)
        } else {
            targetURL = paths.chimesDir.appendingPathComponent("\(id).md")
        }
        try ChimeRule.setEnabled(enabled, in: targetURL)
        reloadConfig()
    }

    private func startExpectWindowTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 5.0, repeating: 30.0)
        timer.setEventHandler { [weak self] in
            _ = self?.checkExpectWindows()
        }
        let previous: DispatchSourceTimer? = stateLock.withLock {
            let old = expectTimer
            expectTimer = timer
            return old
        }
        previous?.cancel()
        timer.resume()
    }

    /// Evaluates all enabled rules with an `expect:` time window.
    /// If a window has elapsed without receiving a matching signal, synthesizes and dispatches
    /// a `dev.bianzhong.expect.missed` event at most once per period.
    @discardableResult
    public func checkExpectWindows(now: Date = Date(), calendar: Calendar = .current) -> [EventEnvelope] {
        guard !isPaused() else { return [] }
        let rules = funnel.currentRules()
        var triggered: [EventEnvelope] = []
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)

        for rule in rules where rule.enabled {
            guard let spec = rule.expectWindow, spec.enabled else { continue }
            guard let resolved = ExpectWindowEvaluator.missedWindow(for: spec, at: now, calendar: calendar) else {
                continue
            }
            let periodKey = resolved.periodKey
            let existingStatus = (try? store.expectWindowStatus(chimeID: rule.id, periodKey: periodKey)) ?? nil
            if existingStatus != nil {
                continue
            }

            // Guard 1: Do not retroactively fire if the rule file was created/enabled after this window already ended
            if let modDate = rule.fileModifiedAt, modDate > resolved.deadline {
                try? store.markExpectWindow(
                    chimeID: rule.id,
                    periodKey: periodKey,
                    status: "satisfied",
                    matchedEventID: "skipped:late_rule_init",
                    nowMs: nowMs
                )
                continue
            }

            // Guard 2: Back-check SQLite events received within [start, deadline] before declaring a miss
            let startMs = Int64(resolved.start.timeIntervalSince1970 * 1000)
            let deadlineMs = Int64(resolved.deadline.timeIntervalSince1970 * 1000)
            if let priorEvents = try? store.listEventsReceivedBetween(startMs: startMs, endMs: deadlineMs),
               let priorHit = priorEvents.first(where: { funnel.matchesRule($0, rule: rule) }) {
                try? store.markExpectWindow(
                    chimeID: rule.id,
                    periodKey: periodKey,
                    status: "satisfied",
                    matchedEventID: priorHit.id,
                    nowMs: nowMs
                )
                continue
            }

            try? store.markExpectWindow(
                chimeID: rule.id,
                periodKey: periodKey,
                status: "missed_triggered",
                matchedEventID: nil,
                nowMs: nowMs
            )

            let descLine = rule.description.isEmpty ? "" : "\n规则说明：\(rule.description)"
            let missedEvent = EventEnvelope(
                source: "bz://watchdog/expect",
                type: "dev.bianzhong.expect.missed",
                correlationKey: "expect:\(rule.id):\(periodKey)",
                privacyLevel: .internal,
                payload: [
                    "title": "未如期收到信号：\(rule.id)",
                    "subtitle": "预期窗口 \(spec.windowStart)–\(spec.windowEnd)",
                    "body": "在预期时间窗口 \(spec.windowStart)–\(spec.windowEnd) (\(periodKey)) 内未收到匹配规则「\(rule.id)」的信号。\(descLine)",
                    "chime_id": rule.id,
                    "window_start": spec.windowStart,
                    "window_end": spec.windowEnd,
                    "period_key": periodKey
                ],
                ambientContext: .captureCurrent()
            )
            try? store.recordEvent(missedEvent, funnelStage: "expect_missed", matchedChimeID: rule.id)
            dispatchMatchedEvent(missedEvent, rule: rule)
            triggered.append(missedEvent)
        }

        return triggered
    }

    /// Directly tests a single target rule from the UI without allowing earlier broad rules to hijack the event.
    public func triggerRuleTest(ruleID: String, event: EventEnvelope) -> (ok: Bool, message: String) {
        guard let rule = funnel.currentRules().first(where: { $0.id == ruleID }) else {
            return (false, "未找到规则：\(ruleID)")
        }
        guard rule.enabled else {
            return (false, "规则当前已停用，请先开启后再触发实测")
        }

        if let spec = rule.expectWindow, spec.enabled {
            let descLine = rule.description.isEmpty ? "" : "\n规则说明：\(rule.description)"
            let testMissed = EventEnvelope(
                source: "bz://test/expect",
                type: "dev.bianzhong.expect.missed",
                correlationKey: "test:expect:\(rule.id)",
                privacyLevel: .internal,
                payload: [
                    "title": "[测试] 未如期收到信号：\(rule.id)",
                    "subtitle": "预期窗口 \(spec.windowStart)–\(spec.windowEnd)",
                    "body": "手动实测预期窗口超时动作（\(spec.windowStart)–\(spec.windowEnd)）。\(descLine)",
                    "chime_id": rule.id
                ],
                ambientContext: .captureCurrent()
            )
            try? store.recordEvent(testMissed, funnelStage: "dispatched", matchedChimeID: rule.id)
            dispatchMatchedEvent(testMissed, rule: rule)
            return (true, "已直接触发规则「\(rule.id)」的超时动作")
        }

        guard funnel.matchesRule(event, rule: rule) else {
            return (false, "当前输入未命中规则「\(rule.id)」的 match 条件，未触发")
        }
        try? store.recordEvent(event, funnelStage: "dispatched", matchedChimeID: rule.id)
        dispatchMatchedEvent(event, rule: rule)
        return (true, "已定向触发规则「\(rule.id)」")
    }

    public func saveConfig(_ newConfig: AppConfig) throws {
        try AppConfig.save(newConfig, to: paths.configFile)
        reloadConfig()
    }

    public func setPreferredTerminal(_ terminal: String) {
        try? AppConfig.setTerminal(terminal, in: paths.configFile)
        reloadConfig()
    }

    @discardableResult
    public func saveRule(_ rule: ChimeRule) throws -> ChimeRule {
        let safeID = Self.sanitizeRuleID(rule.id)
        guard !safeID.isEmpty else {
            throw NSError(domain: "BianzhongOrchestrator", code: 400, userInfo: [NSLocalizedDescriptionKey: "规则 ID 不能为空"])
        }
        var updated = rule
        updated.id = safeID
        let canonicalURL = paths.chimesDir.appendingPathComponent("\(safeID).md")
        let targetURL: URL
        var oldURLToRemove: URL?

        if let existingPath = rule.filePath, !existingPath.isEmpty {
            let existingURL = URL(fileURLWithPath: existingPath)
            let existingStem = existingURL.deletingPathExtension().lastPathComponent
            if existingStem == safeID {
                targetURL = existingURL
            } else {
                targetURL = canonicalURL
                if Self.isSubpath(existingURL, of: paths.chimesDir),
                   existingURL.standardizedFileURL.path != canonicalURL.standardizedFileURL.path {
                    oldURLToRemove = existingURL
                }
            }
        } else {
            targetURL = canonicalURL
        }

        try updated.save(to: targetURL)
        if let oldURLToRemove, FileManager.default.fileExists(atPath: oldURLToRemove.path) {
            try? FileManager.default.removeItem(at: oldURLToRemove)
        }
        reloadConfig()
        return funnel.currentRules().first(where: { $0.id == safeID }) ?? {
            updated.filePath = targetURL.path
            return updated
        }()
    }

    @discardableResult
    public func saveRawRuleMarkdown(id: String, filePath: String?, markdown: String) throws -> ChimeRule {
        let parsed = ChimeRule.parse(markdown: markdown, defaultID: id.isEmpty ? "custom-rule" : id)
        let safeID = Self.sanitizeRuleID(parsed.id)
        guard !safeID.isEmpty else {
            throw NSError(domain: "BianzhongOrchestrator", code: 400, userInfo: [NSLocalizedDescriptionKey: "Markdown 中缺少有效的规则 id"])
        }
        let canonicalURL = paths.chimesDir.appendingPathComponent("\(safeID).md")
        let targetURL: URL
        var oldURLToRemove: URL?

        if let existingPath = filePath, !existingPath.isEmpty {
            let existingURL = URL(fileURLWithPath: existingPath)
            if existingURL.deletingPathExtension().lastPathComponent == safeID {
                targetURL = existingURL
            } else {
                targetURL = canonicalURL
                if Self.isSubpath(existingURL, of: paths.chimesDir),
                   existingURL.standardizedFileURL.path != canonicalURL.standardizedFileURL.path {
                    oldURLToRemove = existingURL
                }
            }
        } else {
            targetURL = canonicalURL
        }

        try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try markdown.write(to: targetURL, atomically: true, encoding: .utf8)
        if let oldURLToRemove, FileManager.default.fileExists(atPath: oldURLToRemove.path) {
            try? FileManager.default.removeItem(at: oldURLToRemove)
        }
        reloadConfig()
        return funnel.currentRules().first(where: { $0.id == safeID }) ?? parsed
    }

    private static func sanitizeRuleID(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: "..", with: "-")
    }

    private static func isSubpath(_ child: URL, of parentDir: URL) -> Bool {
        let childPath = child.standardizedFileURL.resolvingSymlinksInPath().path
        let parentPath = parentDir.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        return childPath.hasPrefix(prefix)
    }

    public func deleteRule(id: String) throws {
        guard let rule = funnel.currentRules().first(where: { $0.id == id }) else { return }
        let path = rule.filePath ?? paths.chimesDir.appendingPathComponent("\(id).md").path
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
        reloadConfig()
    }

    /// Evaluates an incoming `bianzhong://` deep link with CSRF protection:
    /// - Read-only navigation (`openConsole`) executes immediately.
    /// - Mutating actions (`emit`, `approve`, `reject`) execute immediately ONLY when `token` matches `BIANZHONG_WEBHOOK_TOKEN`;
    ///   missing `token` returns `.requiresConfirmation` so the GUI can prompt the user, and invalid `token` returns `.unauthorized`.
    @discardableResult
    public func handleIncomingURL(_ url: URL) -> IncomingURLOutcome {
        guard let action = BianzhongURLRouter.parse(url) else { return .invalidURL }
        if !action.isMutating {
            callbacks.onApprovalUpdated()
            return .handled(action)
        }
        let expectedToken = SecretStore.ensureWebhookToken(paths: paths)
        if let provided = action.providedToken {
            guard OutboundWebhookBuilder.constantTimeEquals(provided, expectedToken) else {
                return .unauthorized
            }
            executeConfirmedURLAction(action)
            return .handled(action)
        }
        return .requiresConfirmation(action)
    }

    public func executeConfirmedURLAction(_ action: BianzhongURLAction) {
        switch action {
        case .emit(let event, _):
            _ = handleBusRequest(BusRequest(action: "emit", event: event))
        case .approve(let id, let comment, _):
            _ = approve(id: id, comment: comment ?? "Approved via bianzhong:// URL")
        case .reject(let id, let comment, _):
            _ = reject(id: id, comment: comment ?? "Rejected via bianzhong:// URL")
        case .openConsole:
            break
        }
        callbacks.onApprovalUpdated()
    }

    public func listManagedWorktrees() -> [ManagedWorktreeInfo] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: paths.worktreesDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls.compactMap { url -> ManagedWorktreeInfo? in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            let branch = runGitCapture(in: url.path, args: ["rev-parse", "--abbrev-ref", "HEAD"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let porcelain = runGitCapture(in: url.path, args: ["status", "--porcelain"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ManagedWorktreeInfo(
                name: url.lastPathComponent,
                path: url.path,
                branch: branch.isEmpty ? "HEAD" : branch,
                isDirty: !porcelain.isEmpty,
                modifiedAt: mtime
            )
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    public func worktreeDiff(at path: String) -> String {
        let status = runGitCapture(in: path, args: ["status", "-s"])
        let diff = runGitCapture(in: path, args: ["diff", "HEAD"])
        let combined = [
            status.isEmpty ? "" : "# git status -s\n\(status)",
            diff.isEmpty ? "" : diff
        ].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return combined.isEmpty ? "（当前 Worktree 无未提交的 Git 差异，可查看 git log -n 3）\n\n" + runGitCapture(in: path, args: ["log", "-n", "3", "--stat"]) : String(combined.prefix(16000))
    }

    public func removeWorktree(at path: String, force: Bool = false) throws {
        let targetURL = URL(fileURLWithPath: path)
        guard Self.isSubpath(targetURL, of: paths.worktreesDir) else {
            throw NSError(domain: "BianzhongOrchestrator", code: 403, userInfo: [NSLocalizedDescriptionKey: "拒绝删除非受管 Worktree 路径：\(path)"])
        }
        if !force {
            let porcelain = runGitCapture(in: targetURL.path, args: ["status", "--porcelain"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !porcelain.isEmpty {
                throw NSError(domain: "BianzhongOrchestrator", code: 409, userInfo: [NSLocalizedDescriptionKey: "Worktree 存在未提交改动，拒绝自动移除"])
            }
        }
        guard RuntimeGovernance.detachAndRemoveWorktreeDir(at: targetURL.path) else {
            throw NSError(domain: "BianzhongOrchestrator", code: 500, userInfo: [NSLocalizedDescriptionKey: "移除 Worktree 失败：\(path)"])
        }
        callbacks.onApprovalUpdated()
    }

    private func runGitCapture(in dir: String, args: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", dir] + args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return "" }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return "" }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
    public func retryFeishuSensor() {
        let monitor = stateLock.withLock { feishuMonitor }
        monitor?.retryNow()
    }

    public func setFeishuSensorEnabled(_ enabled: Bool) {
        try? AppConfig.setFeishuSensorEnabled(enabled, in: paths.configFile)
        reloadConfig()
    }

    private func syncFeishuMonitor() {
        let (sensorsActive, enabled, dbURL, skipExisting, currentMonitor): (Bool, Bool, URL, Bool, FeishuSensorMonitor?) = stateLock.withLock {
            (
                builtInSensorsEnabled,
                config.feishuSensorEnabled,
                customFeishuDBURL ?? FeishuSensorMonitor.defaultUsernotedDBURL(),
                feishuSkipExistingOnFirstRun,
                feishuMonitor
            )
        }

        guard sensorsActive else { return }

        if !enabled {
            if let currentMonitor {
                stateLock.withLock { feishuMonitor = nil }
                currentMonitor.stop()
            }
            return
        }

        if let currentMonitor, currentMonitor.dbURL == dbURL {
            return
        }

        currentMonitor?.stop()
        let newMonitor = FeishuSensorMonitor(
            dbURL: dbURL,
            cursorURL: paths.feishuCursorURL,
            skipExistingOnFirstRun: skipExisting,
            eventSink: { [weak self] event in
                guard let self else { return false }
                return self.handleBusRequest(BusRequest(action: "emit", event: event)).ok
            },
            onStatusChange: { [weak self] _ in
                self?.callbacks.onApprovalUpdated()
            }
        )
        stateLock.withLock {
            feishuMonitor = newMonitor
        }
        newMonitor.start()
    }

    public func currentConfig() -> AppConfig {
        stateLock.lock()
        defer { stateLock.unlock() }
        return config
    }

    public func isPaused() -> Bool {
        stateLock.lock()
        let expiredTimer: DispatchSourceTimer?
        let result: Bool
        if let until = pausedUntil {
            if Date() < until {
                result = true
                expiredTimer = nil
            } else {
                pausedUntil = nil
                expiredTimer = pauseTimer
                pauseTimer = nil
                result = false
            }
        } else {
            expiredTimer = nil
            result = false
        }
        stateLock.unlock()
        expiredTimer?.cancel()
        return result
    }

    public func pausedUntilDate() -> Date? {
        _ = isPaused()
        stateLock.lock()
        defer { stateLock.unlock() }
        return pausedUntil
    }

    public func pause(forSeconds duration: TimeInterval? = 3600) {
        stateLock.lock()
        let oldTimer = pauseTimer
        pauseTimer = nil
        if let duration {
            let clamped = max(0.05, duration)
            pausedUntil = Date().addingTimeInterval(clamped)
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            timer.schedule(deadline: .now() + clamped)
            timer.setEventHandler { [weak self] in
                self?.expirePauseIfNeeded()
            }
            pauseTimer = timer
            stateLock.unlock()
            oldTimer?.cancel()
            timer.resume()
        } else {
            pausedUntil = .distantFuture
            stateLock.unlock()
            oldTimer?.cancel()
        }
        callbacks.onApprovalUpdated()
    }

    public func resume() {
        stateLock.lock()
        pausedUntil = nil
        let oldTimer = pauseTimer
        pauseTimer = nil
        stateLock.unlock()
        oldTimer?.cancel()
        callbacks.onApprovalUpdated()
    }

    public func setPaused(_ value: Bool) {
        if value {
            pause(forSeconds: 3600)
        } else {
            resume()
        }
    }

    private func expirePauseIfNeeded() {
        var didExpire = false
        var oldTimer: DispatchSourceTimer?
        stateLock.lock()
        if let until = pausedUntil, Date() >= until {
            pausedUntil = nil
            oldTimer = pauseTimer
            pauseTimer = nil
            didExpire = true
        }
        stateLock.unlock()
        oldTimer?.cancel()
        if didExpire {
            callbacks.onApprovalUpdated()
        }
    }

    public func reloadConfig() {
        let loadedConfig = AppConfig.load(from: paths.configFile)
        let loadedRules = ChimeRule.loadAll(from: paths.chimesDir)
        stateLock.lock()
        config = loadedConfig
        stateLock.unlock()
        funnel.updateRules(loadedRules)
        funnel.updateMaxCausalDepth(loadedConfig.maxCausalDepth)
        let gate = runGate
        let newMaxRuns = loadedConfig.maxConcurrentRuns
        Task {
            await gate.updateLimit(newMaxRuns)
        }
        syncFeishuMonitor()
        syncWebhookServer()
        callbacks.onApprovalUpdated()
    }

    public func pendingApprovals() -> [ApprovalRecord] {
        (try? store.listPendingApprovals()) ?? []
    }

    public func recentRuns() -> [RunRecord] {
        (try? store.listRecentRuns()) ?? []
    }

    public func deferredDigestCount() -> Int {
        (try? store.listDeferredDigests(limit: 200).count) ?? 0
    }

    /// Processes a bus command synchronously from `SocketBus` or UI triggers.
    public func handleBusRequest(_ request: BusRequest) -> BusResponse {
        switch request.action {
        case "emit":
            guard let event = request.event else {
                return BusResponse(ok: false, message: "Missing event envelope")
            }
            if isPaused() {
                _ = funnel.recordExpectWindowMatchesWhilePaused(event)
                try? store.recordEvent(event, funnelStage: "dropped_paused", dropReason: "daemon_paused")
                return BusResponse(ok: true, message: "Paused", disposition: "paused")
            }
            let disp = funnel.ingest(event) { [weak self] coalesced, rule in
                self?.dispatchMatchedEvent(coalesced, rule: rule)
            }
            let dispLabel: String
            switch disp {
            case .dropped(let stage, let reason): dispLabel = "\(stage):\(reason)"
            case .coalescing(let chime, _): dispLabel = "coalescing:\(chime)"
            case .ready(_, let rule): dispLabel = "ready:\(rule.id)"
            }
            return BusResponse(ok: true, message: "Ingested", disposition: dispLabel)

        case "status":
            let counts = (try? store.countsSummary()) ?? (events: 0, pendingApprovals: 0, runs: 0)
            let summary = BusStatusSummary(
                daemonPID: ProcessInfo.processInfo.processIdentifier,
                loadedRules: funnel.currentRules().count,
                eventsCount: counts.events,
                pendingApprovalsCount: counts.pendingApprovals,
                runsCount: counts.runs,
                paused: isPaused(),
                feishuSensor: feishuSensorStatus().rawValue
            )
            return BusResponse(
                ok: true,
                message: "ok",
                status: summary,
                approvals: pendingApprovals(),
                runs: recentRuns()
            )

        case "list_approvals":
            return BusResponse(ok: true, message: "ok", approvals: pendingApprovals())

        case "approve":
            guard let id = request.approvalID else {
                return BusResponse(ok: false, message: "Missing approval_id")
            }
            approve(id: id, comment: request.comment)
            return BusResponse(ok: true, message: "Approved \(id)")

        case "reject":
            guard let id = request.approvalID else {
                return BusResponse(ok: false, message: "Missing approval_id")
            }
            reject(id: id, comment: request.comment)
            return BusResponse(ok: true, message: "Rejected \(id)")

        case "takeover":
            guard let id = request.approvalID, let cmd = takeoverCommand(for: id) else {
                return BusResponse(ok: false, message: "Approval or session not found")
            }
            _ = launchTakeover(for: id)
            return BusResponse(ok: true, message: "Takeover launched", takeoverCommand: cmd)

        case "flush_digest":
            let digest = flushWakeDigest()
            return BusResponse(
                ok: true,
                message: digest == nil ? "No deferred digest items" : "Flushed wake digest \(digest!.id)",
                digestApproval: digest
            )

        case "gc":
            let report = governance.performGC(
                paths: paths,
                store: store,
                retentionDays: currentConfig().retentionDays
            )
            return BusResponse(
                ok: true,
                message: "GC pruned \(report.prunedEvents) events, \(report.removedRunDirs) runs, \(report.removedWorktrees) worktrees",
                gcReport: report
            )

        case "reset_circuit":
            guard let chimeID = request.chimeID ?? request.approvalID, !chimeID.isEmpty else {
                return BusResponse(ok: false, message: "Missing chime_id")
            }
            governance.resetCircuit(chimeID: chimeID)
            return BusResponse(ok: true, message: "Reset circuit for \(chimeID)")

        case "reload":
            reloadConfig()
            return BusResponse(ok: true, message: "Reloaded \(funnel.currentRules().count) chimes")

        case "pause":
            let seconds = request.durationSeconds.map { TimeInterval($0) } ?? 3600.0
            pause(forSeconds: seconds)
            return BusResponse(ok: true, message: "Paused for \(Int(seconds))s")

        case "resume":
            resume()
            return BusResponse(ok: true, message: "Resumed")

        default:
            return BusResponse(ok: false, message: "Unknown action: \(request.action)")
        }
    }

    // MARK: - Dispatch Pipeline (L1 -> Governance -> Preflight -> Phase 1 -> Actions)

    private func dispatchMatchedEvent(_ event: EventEnvelope, rule: ChimeRule) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let cfg = self.currentConfig()
            var targetWorkingDir = self.resolveWorkingDir(rule: rule, event: event)

            if rule.deferOnFocus && (event.ambientContext.focusActive || event.ambientContext.screenLocked) {
                self.createInboxItem(event: event, rule: rule, kind: "digest", status: "deferred", summary: event.payload["body"] ?? event.type)
                return
            }

            if rule.triageEnabled && event.type != "dev.bianzhong.expect.missed" {
                let provider = TriageProviderFactory.make(config: cfg, override: rule.triageProviderOverride, paths: self.paths)
                let req = TriageRequest(
                    event: event,
                    candidateRuleID: rule.id,
                    candidateDescription: rule.description,
                    workspaces: cfg.workspaces
                )
                let decision = await provider.classify(request: req)
                switch decision.action {
                case .ignore:
                    try? self.store.recordEvent(event, funnelStage: "l1_ignored", matchedChimeID: rule.id, dropReason: decision.reason)
                    return
                case .digest:
                    self.createInboxItem(event: event, rule: rule, kind: "digest", status: "pending", summary: decision.reason)
                    return
                case .notifyOnly:
                    let item = self.createInboxItem(event: event, rule: rule, kind: "notify", status: "pending", summary: decision.reason, notifyImmediately: false)
                    let ctx = ActionContext(event: event, rule: rule, approval: item, phase: "direct", summaryText: item.proposedAction)
                    await self.actionDispatcher.dispatch(specs: rule.onComplete, context: ctx)
                    return
                case .dispatchAgent:
                    if let chosenDir = decision.workingDir, !chosenDir.isEmpty {
                        targetWorkingDir = NSString(string: chosenDir).expandingTildeInPath
                    }
                }
            }

            if rule.autonomy == .observeDigest {
                self.createInboxItem(event: event, rule: rule, kind: "digest", status: "deferred", summary: event.payload["body"] ?? rule.description)
                return
            }

            if rule.driver.lowercased() == "none" {
                await self.runDirectActionRule(event: event, rule: rule, workingDir: targetWorkingDir)
                return
            }

            switch self.governance.checkAdmission(chimeID: rule.id, config: cfg, store: self.store) {
            case .allowed:
                break
            case .blockedDailyCost(let cur, let cap):
                try? self.store.recordEvent(event, funnelStage: "dropped_governance", matchedChimeID: rule.id, dropReason: "daily_cost_cap:\(cur)/\(cap)")
                return
            case .blockedDailyRuns(let cur, let cap):
                try? self.store.recordEvent(event, funnelStage: "dropped_governance", matchedChimeID: rule.id, dropReason: "daily_runs_cap:\(cur)/\(cap)")
                return
            case .circuitOpen(let cid, let failures):
                try? self.store.recordEvent(event, funnelStage: "dropped_governance", matchedChimeID: cid, dropReason: "circuit_open:\(failures)")
                self.createInboxItem(
                    event: event,
                    rule: rule,
                    kind: "notify",
                    status: "pending",
                    summary: "规则 \(cid) 连续失败 \(failures) 次已熔断。修复后执行 `bz reset-circuit \(cid)` 恢复。"
                )
                return
            }

            await self.runPhase1(event: event, rule: rule, workingDir: targetWorkingDir)
        }
    }

    private func resolveWorkingDir(rule: ChimeRule, event: EventEnvelope) -> String {
        if rule.workingDir == "$payload.cwd" || rule.workingDir == "auto" {
            if let cwd = event.payload["cwd"] ?? event.payload["root"], !cwd.isEmpty {
                return NSString(string: cwd).expandingTildeInPath
            }
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        return rule.workingDir
    }

    @discardableResult
    private func createInboxItem(
        event: EventEnvelope,
        rule: ChimeRule,
        kind: String,
        status: String,
        summary: String,
        notifyImmediately: Bool = true
    ) -> ApprovalRecord {
        let runID = "run-\(UUID().uuidString.prefix(8))"
        let approvalID = "apr-\(UUID().uuidString.prefix(8))"
        let now = SQLiteStore.nowMs()
        try? store.insertRun(id: runID, eventID: event.id, sessionID: nil, chimeID: rule.id, phase: "notify", driver: "triage", status: "succeeded")
        let title = event.payload["title"] ?? rule.id
        let body = event.payload["body"] ?? event.payload["summary"] ?? summary
        let approval = ApprovalRecord(
            id: approvalID,
            runID: runID,
            eventID: event.id,
            sessionID: nil,
            chimeID: rule.id,
            kind: kind,
            riskLevel: "low",
            title: title,
            provenanceSummary: "\(event.source) • \(rule.id)",
            proposedAction: body,
            targetRepo: resolveWorkingDir(rule: rule, event: event),
            externalSessionID: nil,
            status: status,
            userComment: nil,
            createdAt: now,
            resolvedAt: nil
        )
        try? store.insertApproval(approval)
        callbacks.onApprovalUpdated()
        if notifyImmediately && status == "pending" {
            callbacks.onNotifyApproval(approval)
        }
        return approval
    }

    private func runDirectActionRule(event: EventEnvelope, rule: ChimeRule, workingDir: String) async {
        let preflight = await executePreflightIfNeeded(rule: rule, event: event, workingDir: workingDir)
        let baseBody = event.payload["body"] ?? event.payload["summary"] ?? rule.description
        let summary = preflight.map { "\(baseBody)\n\n[Preflight]\n\($0)" } ?? baseBody
        let item = createInboxItem(event: event, rule: rule, kind: "notify", status: "pending", summary: summary, notifyImmediately: false)
        let ctx = ActionContext(event: event, rule: rule, approval: item, phase: "direct", summaryText: summary)
        await actionDispatcher.dispatch(specs: rule.onComplete, context: ctx)
    }

    private func runPhase1(event: EventEnvelope, rule: ChimeRule, workingDir: String) async {
        await runGate.withPermit {
            await performPhase1(event: event, rule: rule, workingDir: workingDir)
        }
    }

    private func performPhase1(event: EventEnvelope, rule: ChimeRule, workingDir: String) async {
        let runID = "run-\(UUID().uuidString.prefix(8))"
        let timeline = (try? store.recentTimeline(withinSeconds: 1200, excludingEventID: event.id, limit: 10)) ?? []
        let preflightOut = await executePreflightIfNeeded(rule: rule, event: event, workingDir: workingDir)
        let eventFileURL = writeRunEventFile(event: event, timeline: timeline, preflightOutput: preflightOut, runID: runID)

        let driver = AgentDriverRegistry.driver(named: rule.driver)
        let driverSessionsDir = paths.sessionsDir.appendingPathComponent(driver.id, isDirectory: true)
        try? FileManager.default.createDirectory(at: driverSessionsDir, withIntermediateDirectories: true)

        let existingSession: (id: String, externalSessionID: String, cwd: String)?
        if rule.sessionPolicy != .ephemeral {
            existingSession = try? store.findActiveSession(
                correlationKey: event.correlationKey,
                driver: driver.id,
                policy: rule.sessionPolicy
            )
        } else {
            existingSession = nil
        }

        let timelineSection: String
        if timeline.isEmpty {
            timelineSection = "(no correlated events in last 20m)"
        } else {
            timelineSection = timeline.map { "- [\($0.ts)] \($0.type) (\($0.correlationKey)): \($0.summary)" }.joined(separator: "\n")
        }

        let preflightSection = preflightOut.map { "\nPreflight Output:\n```\n\($0)\n```\n" } ?? ""

        let prompt = """
        [Bianzhong Event Wakeup | rule=\(rule.id) | phase=1_readonly]
        Event File: \(eventFileURL.path)
        Title: \(event.payload["title"] ?? "")
        Sender: \(event.payload["subtitle"] ?? "")
        Message / Summary:
        \(event.payload["body"] ?? event.payload["summary"] ?? "")

        Recent Correlated Timeline (last 20m):
        \(timelineSection)
        \(preflightSection)
        \(rule.phase1Prompt)
        """

        let request = AgentInvocationRequest(
            runID: runID,
            correlationKey: event.correlationKey,
            workingDirectory: workingDir,
            promptText: prompt,
            eventFilePath: eventFileURL.path,
            sessionDir: driverSessionsDir.path,
            permissionProfile: .readOnly,
            modelOverride: rule.model,
            resumeSessionID: existingSession?.externalSessionID,
            worktreeRequested: false,
            ephemeral: rule.sessionPolicy == .ephemeral,
            maxTimeSeconds: rule.phase1MaxTimeSeconds,
            maxCostUSD: rule.phase1MaxCostUSD
        )

        try? store.insertRun(
            id: runID,
            eventID: event.id,
            sessionID: existingSession?.id,
            chimeID: rule.id,
            phase: "draft",
            driver: driver.id,
            status: "running"
        )

        let spec = driver.buildSpawnSpec(request: request)
        let procResult = await AgentProcessRunner.run(spec: spec, timeoutSeconds: rule.phase1MaxTimeSeconds)

        let parsed = parseAgentStdout(procResult.stdout, driver: driver, initialSessionID: existingSession?.externalSessionID)
        let capturedExtSession = parsed.externalSessionID
        let inTok = parsed.inputTokens
        let outTok = parsed.outputTokens
        let cacheTok = parsed.cachedTokens
        let totalCost = parsed.costUSD
        let fallbackMsg = procResult.stderr.isEmpty ? "Completed with exit code \(procResult.exitCode)" : procResult.stderr
        let summary = parsed.finalText ?? (parsed.errorMessages.isEmpty ? fallbackMsg : parsed.errorMessages.joined(separator: "\n"))
        var internalSessionID = existingSession?.id
        if let extID = capturedExtSession, !extID.isEmpty {
            let sid = internalSessionID ?? "ses-\(UUID().uuidString.prefix(8))"
            internalSessionID = sid
            try? store.upsertSession(
                id: sid,
                correlationKey: event.correlationKey,
                driver: driver.id,
                policy: rule.sessionPolicy,
                externalSessionID: extID,
                cwd: workingDir,
                ttlSeconds: rule.sessionTTLSeconds
            )
        }

        let runStatus = procResult.timedOut ? "timeout" : (procResult.exitCode == 0 ? "waiting_approval" : (procResult.exitCode == 3 ? "budget_exceeded" : "failed"))
        try? store.updateRunStatus(
            id: runID,
            sessionID: internalSessionID,
            status: runStatus,
            exitCode: procResult.exitCode,
            inputTokens: inTok,
            outputTokens: outTok,
            cachedTokens: cacheTok,
            costUSD: totalCost,
            outputSummary: String(summary.prefix(4000)),
            errorMessage: procResult.exitCode == 0 ? nil : String(procResult.stderr.prefix(1000))
        )

        let kind = event.type.contains("feishu") ? "question" : "review"
        let approval = ApprovalRecord(
            id: "apr-\(UUID().uuidString.prefix(8))",
            runID: runID,
            eventID: event.id,
            sessionID: internalSessionID,
            chimeID: rule.id,
            kind: kind,
            riskLevel: rule.worktreeOnPhase2 ? "medium" : "high",
            title: event.payload["title"] ?? rule.id,
            provenanceSummary: "\(event.source) • \(rule.id) • \(rule.driver)",
            proposedAction: String(summary.prefix(3500)),
            targetRepo: workingDir,
            externalSessionID: capturedExtSession,
            status: "pending",
            userComment: nil,
            createdAt: SQLiteStore.nowMs(),
            resolvedAt: nil
        )
        try? store.insertApproval(approval)
        callbacks.onApprovalUpdated()

        let actionCtx = ActionContext(
            event: event,
            rule: rule,
            approval: approval,
            phase: "draft",
            summaryText: approval.proposedAction,
            sessionID: capturedExtSession
        )
        await actionDispatcher.dispatch(specs: rule.onComplete, context: actionCtx)

        if rule.autonomy == .boundedAuto && procResult.exitCode == 0 {
            approve(id: approval.id, comment: "Auto-approved by bounded_auto rule")
        }
    }

    private func executePreflightIfNeeded(rule: ChimeRule, event: EventEnvelope, workingDir: String) async -> String? {
        guard let cmd = rule.preflightCmd, !cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let dir = FileManager.default.fileExists(atPath: workingDir)
            ? workingDir
            : FileManager.default.homeDirectoryForCurrentUser.path
        let spec = SpawnSpec(
            executablePath: "/bin/zsh",
            arguments: ["-lc", cmd],
            environment: [
                "BIANZHONG_DEPTH": "1",
                "BIANZHONG_CORRELATION_KEY": event.correlationKey
            ],
            stdinData: nil,
            workingDirectory: dir
        )
        let res = await AgentProcessRunner.run(spec: spec, timeoutSeconds: rule.preflightTimeoutSeconds)
        let combined = [res.stdout, res.stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return combined.isEmpty ? nil : String(combined.prefix(4096))
    }

    @discardableResult
    public func approve(id: String, comment: String?) -> Bool {
        guard let approval = (try? store.resolvePendingApprovalAtomically(id: id, status: "approved", comment: comment)) ?? nil else {
            return false
        }
        callbacks.onApprovalUpdated()

        guard approval.kind != "notify",
              approval.kind != "digest",
              let rule = funnel.currentRules().first(where: { $0.id == approval.chimeID }),
              !rule.phase2Prompt.isEmpty,
              let extSession = approval.externalSessionID else {
            return true
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.runGate.withPermit {
                await self.performPhase2(approval: approval, rule: rule, extSession: extSession, comment: comment)
            }
        }
        return true
    }

    private func performPhase2(approval: ApprovalRecord, rule: ChimeRule, extSession: String, comment: String?) async {
        let runID = "run-\(UUID().uuidString.prefix(8))"
        let driver = AgentDriverRegistry.driver(named: rule.driver)
        let driverSessionsDir = paths.sessionsDir.appendingPathComponent(driver.id, isDirectory: true)
        let baseRepo = approval.targetRepo ?? rule.workingDir

        let execDir: String
        if rule.worktreeOnPhase2 && driver.id != "codex" {
            execDir = TerminalLauncher.prepareWorktreeIfGitRepo(repoPath: baseRepo, runID: runID, worktreesDir: paths.worktreesDir)
        } else {
            execDir = baseRepo
        }

        funnel.registerWriteLease(pathPrefix: baseRepo, ttlSeconds: TimeInterval(rule.phase2MaxTimeSeconds + 5))
        if execDir != baseRepo {
            funnel.registerWriteLease(pathPrefix: execDir, ttlSeconds: TimeInterval(rule.phase2MaxTimeSeconds + 5))
        }
        defer {
            funnel.releaseWriteLease(pathPrefix: baseRepo, graceSeconds: 1.5)
            if execDir != baseRepo {
                funnel.releaseWriteLease(pathPrefix: execDir, graceSeconds: 1.5)
            }
        }

        let prompt = rule.phase2Prompt.replacingOccurrences(
            of: "{{approval.user_comment}}",
            with: comment ?? "无额外附言，请按 Phase 1 方案执行。"
        )
        let request = AgentInvocationRequest(
            runID: runID,
            correlationKey: approval.id,
            workingDirectory: execDir,
            promptText: prompt,
            eventFilePath: paths.runsDir.appendingPathComponent("\(approval.runID)/event.json").path,
            sessionDir: driverSessionsDir.path,
            permissionProfile: .workspaceRW,
            modelOverride: rule.model,
            resumeSessionID: extSession,
            worktreeRequested: rule.worktreeOnPhase2,
            ephemeral: false,
            maxTimeSeconds: rule.phase2MaxTimeSeconds,
            maxCostUSD: rule.phase2MaxCostUSD
        )

        try? store.insertRun(
            id: runID,
            eventID: approval.eventID,
            sessionID: approval.sessionID,
            chimeID: rule.id,
            phase: "execute",
            driver: driver.id,
            status: "running"
        )

        let procResult = await AgentProcessRunner.run(spec: driver.buildSpawnSpec(request: request), timeoutSeconds: rule.phase2MaxTimeSeconds)
        let parsed = parseAgentStdout(procResult.stdout, driver: driver, initialSessionID: extSession)
        let effectiveExtSession = parsed.externalSessionID ?? extSession
        let finalStatus = procResult.timedOut ? "timeout" : (procResult.exitCode == 0 ? "succeeded" : (procResult.exitCode == 3 ? "budget_exceeded" : "failed"))

        let fallbackSummary = procResult.stderr.isEmpty ? String(procResult.stdout.suffix(2000)) : procResult.stderr
        let rawSummary = parsed.finalText ?? (parsed.errorMessages.isEmpty ? fallbackSummary : parsed.errorMessages.joined(separator: "\n"))
        let execSummary = rawSummary.isEmpty ? "Exit code: \(procResult.exitCode)" : String(rawSummary.prefix(3500))

        try? store.updateRunStatus(
            id: runID,
            sessionID: approval.sessionID,
            status: finalStatus,
            exitCode: procResult.exitCode,
            inputTokens: parsed.inputTokens,
            outputTokens: parsed.outputTokens,
            cachedTokens: parsed.cachedTokens,
            costUSD: parsed.costUSD,
            outputSummary: execSummary,
            errorMessage: procResult.exitCode == 0 ? nil : String((parsed.errorMessages.last ?? procResult.stderr).prefix(1000))
        )

        if let sid = approval.sessionID {
            try? store.updateSessionAfterPhase2(
                id: sid,
                externalSessionID: effectiveExtSession,
                cwd: execDir,
                worktreePath: execDir != baseRepo ? execDir : nil
            )
        }
        if effectiveExtSession != extSession || execDir != baseRepo {
            try? store.updateApprovalAfterPhase2(
                id: approval.id,
                externalSessionID: effectiveExtSession,
                targetRepo: execDir
            )
        }

        let phase2Event = EventEnvelope(
            source: "bz://app/phase2",
            type: "dev.bianzhong.phase2.completed",
            correlationKey: approval.id,
            payload: [
                "title": approval.title,
                "body": execSummary,
                "status": finalStatus,
                "kind": "notify"
            ],
            ambientContext: .captureCurrent()
        )
        let execApproval = ApprovalRecord(
            id: "apr-\(UUID().uuidString.prefix(8))",
            runID: runID,
            eventID: approval.eventID,
            sessionID: approval.sessionID,
            chimeID: rule.id,
            kind: "notify",
            riskLevel: finalStatus == "succeeded" ? "low" : "high",
            title: "Phase 2 \(finalStatus): \(approval.title)",
            provenanceSummary: "\(rule.id) • \(rule.driver) • \(execDir)",
            proposedAction: execSummary,
            targetRepo: execDir,
            externalSessionID: effectiveExtSession,
            status: "pending",
            userComment: nil,
            createdAt: SQLiteStore.nowMs(),
            resolvedAt: nil
        )
        try? store.insertApproval(execApproval)
        callbacks.onApprovalUpdated()

        let ctx = ActionContext(
            event: phase2Event,
            rule: rule,
            approval: execApproval,
            phase: "execute",
            summaryText: execApproval.proposedAction,
            sessionID: effectiveExtSession
        )
        if rule.onComplete.isEmpty {
            callbacks.onNotifyApproval(execApproval)
        } else {
            await actionDispatcher.dispatch(specs: rule.onComplete, context: ctx)
        }
    }

    private func parseAgentStdout(
        _ stdout: String,
        driver: any AgentDriver,
        initialSessionID: String?
    ) -> ParsedAgentOutput {
        var out = ParsedAgentOutput(externalSessionID: initialSessionID)
        var finalTexts: [String] = []
        for line in stdout.components(separatedBy: .newlines) where !line.isEmpty {
            for ev in driver.parseStdoutLine(line) {
                switch ev {
                case .sessionStarted(let sid):
                    if !sid.isEmpty {
                        out.externalSessionID = sid
                    }
                case .finalAnswer(let txt):
                    if !txt.isEmpty {
                        finalTexts.append(txt)
                    }
                case .usageReported(let i, let o, let c, let cost):
                    out.inputTokens += i
                    out.outputTokens += o
                    out.cachedTokens += c
                    out.costUSD += cost ?? 0
                case .error(let msg, _):
                    out.errorMessages.append(msg)
                case .textDelta, .toolActivity:
                    break
                }
            }
        }
        out.finalText = finalTexts.last
        return out
    }

    /// Merges all `deferred` digest items (accumulated during Focus or screen lock) into a single summary card.
    @discardableResult
    public func flushWakeDigest() -> ApprovalRecord? {
        guard let deferred = try? store.listDeferredDigests(limit: 100), !deferred.isEmpty else {
            return nil
        }

        let lines = deferred.enumerated().map { idx, item in
            let snippet = item.proposedAction.replacingOccurrences(of: "\n", with: " ").prefix(120)
            return "\(idx + 1). [\(item.chimeID)] \(item.title): \(snippet)"
        }
        let body = lines.joined(separator: "\n")
        let runID = "run-digest-\(UUID().uuidString.prefix(8))"
        let digestID = "apr-digest-\(UUID().uuidString.prefix(8))"
        let firstEventID = deferred[0].eventID

        try? store.insertRun(
            id: runID,
            eventID: firstEventID,
            sessionID: nil,
            chimeID: "wake-digest",
            phase: "notify",
            driver: "digest",
            status: "succeeded"
        )

        let digestRecord = ApprovalRecord(
            id: digestID,
            runID: runID,
            eventID: firstEventID,
            sessionID: nil,
            chimeID: "wake-digest",
            kind: "digest",
            riskLevel: "low",
            title: "晨钟摘要（\(deferred.count) 条待阅信号）",
            provenanceSummary: "Wake/Unlock Digest • \(deferred.count) deferred items",
            proposedAction: String(body.prefix(3500)),
            targetRepo: nil,
            externalSessionID: nil,
            status: "pending",
            userComment: nil,
            createdAt: SQLiteStore.nowMs(),
            resolvedAt: nil
        )

        try? store.insertApproval(digestRecord)
        try? store.markApprovalsStatus(ids: deferred.map { $0.id }, status: "expired")
        callbacks.onApprovalUpdated()
        callbacks.onNotifyApproval(digestRecord)
        return digestRecord
    }

    @discardableResult
    public func reject(id: String, comment: String?) -> Bool {
        guard ((try? store.resolvePendingApprovalAtomically(id: id, status: "rejected", comment: comment)) ?? nil) != nil else {
            return false
        }
        callbacks.onApprovalUpdated()
        return true
    }

    public func copyAndOpenFeishu(id: String) {
        guard let approval = (try? store.resolvePendingApprovalAtomically(id: id, status: "approved", comment: "Copied to Feishu")) ?? nil else {
            return
        }
        TerminalLauncher.copyAndOpenFeishu(text: approval.proposedAction) { [weak self] hash in
            self?.funnel.registerEchoHash(hash, ttlSeconds: 30)
        }
        callbacks.onApprovalUpdated()
    }

    public func takeoverCommand(for approvalID: String) -> String? {
        guard let approval = try? store.getApproval(id: approvalID),
              let extID = approval.externalSessionID else {
            return nil
        }
        let rule = funnel.currentRules().first(where: { $0.id == approval.chimeID })
        let driverName = rule?.driver ?? "omp"
        let driver = AgentDriverRegistry.driver(named: driverName)
        let sessionDir = paths.sessionsDir.appendingPathComponent(driver.id, isDirectory: true).path
        let cwd = approval.targetRepo ?? rule?.workingDir ?? FileManager.default.homeDirectoryForCurrentUser.path
        return driver.buildTakeoverCommand(sessionID: extID, sessionDir: sessionDir, workingDirectory: cwd)
    }

    @discardableResult
    public func launchTakeover(for approvalID: String) -> Bool {
        guard let approval = try? store.getApproval(id: approvalID),
              let cmd = takeoverCommand(for: approvalID) else {
            return false
        }
        let ok = TerminalLauncher.launchCommand(cmd, preferredTerminal: currentConfig().terminal)
        if ok {
            if let sid = approval.sessionID {
                try? store.markSessionHandedOver(id: sid)
            }
            try? store.resolveApproval(id: approvalID, status: "taken_over", comment: "Opened in terminal")
            callbacks.onApprovalUpdated()
        }
        return ok
    }

    private func writeRunEventFile(
        event: EventEnvelope,
        timeline: [TimelineEntry],
        preflightOutput: String?,
        runID: String
    ) -> URL {
        let dir = paths.runsDir.appendingPathComponent(runID, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("event.json")
        let bundle = RunContextBundle(event: event, recentTimeline: timeline, preflightOutput: preflightOutput)
        if let data = try? JSONEncoder.pretty.encode(bundle) {
            try? data.write(to: file)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        return file
    }
}

private extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return enc
    }()
}
