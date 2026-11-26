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
    public var onLiveStreamUpdated: @Sendable () -> Void

    public init(
        onApprovalUpdated: @escaping @Sendable () -> Void = {},
        onNotifyApproval: @escaping @Sendable (ApprovalRecord) -> Void = { _ in },
        onLiveStreamUpdated: @escaping @Sendable () -> Void = {}
    ) {
        self.onApprovalUpdated = onApprovalUpdated
        self.onNotifyApproval = onNotifyApproval
        self.onLiveStreamUpdated = onLiveStreamUpdated
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
    private var liveRuns: [String: LiveRunSnapshot] = [:]
    private var activeProcessHandles: [String: ActiveProcessHandle] = [:]
    private var activeAcpHandles: [String: AcpLiveSessionHandle] = [:]
    private var warmHoldApprovalToRunID: [String: String] = [:]

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
            },
            onPocketState: { [weak self] in
                guard let self else { return Data("{}".utf8) }
                return self.buildPocketStateJSON()
            },
            onPocketAction: { [weak self] body in
                guard let self else { return (false, "Orchestrator stopped") }
                return self.handlePocketAction(body)
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

    public func setNotchHUDEnabled(_ enabled: Bool) {
        try? AppConfig.setNotchHUDEnabled(enabled, in: paths.configFile)
        reloadConfig()
    }

    public func tailscaleStatus() -> TailscaleStatusInfo {
        let port = webhookStatus().port > 0 ? webhookStatus().port : UInt16(clamping: currentConfig().webhookPort)
        return TailscaleBridge.queryStatus(localPort: port)
    }

    public func setTailscaleServe(enabled: Bool) -> (ok: Bool, status: TailscaleStatusInfo, message: String) {
        if enabled && !currentConfig().webhookServerEnabled {
            var cfg = currentConfig()
            cfg.webhookServerEnabled = true
            try? saveConfig(cfg)
        }
        let port = webhookStatus().port > 0 ? webhookStatus().port : UInt16(clamping: currentConfig().webhookPort)
        let res = TailscaleBridge.setServe(enabled: enabled, localPort: port)
        if res.ok, enabled, let httpsBase = res.status.httpsBaseURL {
            var cfg = currentConfig()
            if (cfg.webhookCallbackBaseURL ?? "").isEmpty {
                cfg.webhookCallbackBaseURL = httpsBase
                try? saveConfig(cfg)
            }
        }
        callbacks.onApprovalUpdated()
        return res
    }

    public func activeRuns() -> [LiveRunSnapshot] {
        stateLock.withLock {
            Array(liveRuns.values).sorted { $0.startedAtMs > $1.startedAtMs }
        }
    }

    public func isWarmHeldApproval(_ approvalID: String) -> Bool {
        stateLock.withLock {
            guard let rid = warmHoldApprovalToRunID[approvalID],
                  let acp = activeAcpHandles[rid] else {
                return false
            }
            return acp.isWaitingPermission
        }
    }

    @discardableResult
    public func stopRun(id runID: String) -> Bool {
        let (procHandle, acpHandle): (ActiveProcessHandle?, AcpLiveSessionHandle?) = stateLock.withLock {
            if var snap = liveRuns[runID] {
                snap.status = "stopping"
                snap.currentActivity = "正在中止..."
                liveRuns[runID] = snap
            }
            return (activeProcessHandles[runID], activeAcpHandles[runID])
        }
        guard procHandle != nil || acpHandle != nil else { return false }
        procHandle?.cancel()
        acpHandle?.cancel()
        callbacks.onApprovalUpdated()
        return true
    }

    @discardableResult
    public func stopAllActiveRuns() -> Int {
        let ids = stateLock.withLock { Array(liveRuns.keys) }
        var stopped = 0
        for id in ids where stopRun(id: id) {
            stopped += 1
        }
        return stopped
    }

    private func upsertLiveRun(_ snapshot: LiveRunSnapshot) {
        stateLock.withLock {
            liveRuns[snapshot.runID] = snapshot
        }
        callbacks.onApprovalUpdated()
    }

    private func mutateLiveRun(id runID: String, notify: Bool = true, _ body: (inout LiveRunSnapshot) -> Void) {
        var didMutate = false
        stateLock.withLock {
            if var snap = liveRuns[runID] {
                body(&snap)
                liveRuns[runID] = snap
                didMutate = true
            }
        }
        if didMutate && notify {
            callbacks.onLiveStreamUpdated()
        }
    }

    private func removeLiveRun(id runID: String) {
        stateLock.withLock {
            liveRuns.removeValue(forKey: runID)
            activeProcessHandles.removeValue(forKey: runID)
            activeAcpHandles.removeValue(forKey: runID)
            warmHoldApprovalToRunID = warmHoldApprovalToRunID.filter { $0.value != runID }
        }
        callbacks.onApprovalUpdated()
    }

    private func buildPocketStateJSON() -> Data {
        struct PocketEnvelope: Encodable {
            let paused: Bool
            let today_runs_count: Int
            let today_cost_usd: Double
            let active_runs: [LiveRunSnapshot]
            let approvals: [ApprovalRecord]
            let recent_runs: [RunRecord]
        }
        let usage = (try? store.todayUsageSummary()) ?? (runsCount: 0, totalCostUSD: 0.0)
        let env = PocketEnvelope(
            paused: isPaused(),
            today_runs_count: usage.runsCount,
            today_cost_usd: usage.totalCostUSD,
            active_runs: activeRuns(),
            approvals: pendingApprovals(),
            recent_runs: recentRuns()
        )
        return (try? JSONEncoder().encode(env)) ?? Data("{}".utf8)
    }

    private func handlePocketAction(_ body: [String: Any]) -> (ok: Bool, message: String) {
        let action = ((body["action"] as? String) ?? "").lowercased()
        let approvalID = (body["approval_id"] as? String) ?? ""
        let comment = ((body["comment"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let nonEmptyComment = comment.isEmpty ? nil : comment

        switch action {
        case "approve":
            guard !approvalID.isEmpty else { return (false, "缺少 approval_id") }
            let ok = approve(id: approvalID, comment: nonEmptyComment ?? "Approved via Tailscale Pocket")
            return (ok, ok ? "已批准执行" : "该待办已处理或不存在")
        case "steer":
            guard !approvalID.isEmpty else { return (false, "缺少 approval_id") }
            guard let instruction = nonEmptyComment else { return (false, "请先输入调整指令") }
            let ok = steer(id: approvalID, instruction: instruction)
            return (ok, ok ? "已发送调整指令" : "无法调整该待办")
        case "reject":
            guard !approvalID.isEmpty else { return (false, "缺少 approval_id") }
            let ok = reject(id: approvalID, comment: nonEmptyComment ?? "Dismissed via Tailscale Pocket")
            return (ok, ok ? "已忽略" : "该待办已处理或不存在")
        case "stop_run":
            let runID = (body["run_id"] as? String) ?? ""
            let ok = stopRun(id: runID)
            return (ok, ok ? "已发送中止信号" : "运行已结束")
        case "stop_all":
            let count = stopAllActiveRuns()
            return (true, "已中止 \(count) 个活跃任务")
        case "pause":
            let secs = (body["seconds"] as? Double)
                ?? (body["seconds"] as? Int).map(Double.init)
                ?? 3600.0
            let bounded = max(0.2, secs)
            pause(forSeconds: bounded)
            return (true, "已暂停 \(Int(ceil(bounded))) 秒")
        case "resume":
            resume()
            return (true, "已恢复运行")
        case "emit":
            let title = (body["title"] as? String) ?? "手机远程触发"
            let msg = (body["body"] as? String) ?? ""
            let ev = EventEnvelope(
                source: "bz://pocket/pwa",
                type: "dev.bianzhong.pocket.emit",
                correlationKey: "pocket:\(title)",
                privacyLevel: .internal,
                payload: ["title": title, "body": msg],
                ambientContext: .captureCurrent()
            )
            let resp = handleBusRequest(BusRequest(action: "emit", event: ev))
            return (resp.ok, "已派发（\(resp.disposition ?? resp.message)）")
        default:
            return (false, "未知操作：\(action)")
        }
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

        let displayTitle = event.payload["title"] ?? rule.id
        upsertLiveRun(
            LiveRunSnapshot(
                runID: runID,
                chimeID: rule.id,
                driver: driver.id,
                phase: "draft",
                title: displayTitle,
                workingDirectory: workingDir,
                startedAtMs: SQLiteStore.nowMs(),
                status: "running",
                currentActivity: "启动 \(driver.id)..."
            )
        )
        defer { removeLiveRun(id: runID) }

        if let acpDriver = driver as? AcpAgentDriver {
            await performAcpPhase1(
                acpDriver: acpDriver,
                request: request,
                event: event,
                rule: rule,
                workingDir: workingDir,
                runID: runID,
                existingSession: existingSession
            )
            return
        }

        let procHandle = ActiveProcessHandle()
        stateLock.withLock { activeProcessHandles[runID] = procHandle }
        let throttle = StreamThrottleBox()
        let spec = driver.buildSpawnSpec(request: request)
        let procResult = await AgentProcessRunner.run(
            spec: spec,
            timeoutSeconds: rule.phase1MaxTimeSeconds,
            handle: procHandle
        ) { [weak self] line in
            guard let self else { return }
            let evs = driver.parseStdoutLine(line)
            var latestActivity: String?
            var deltaChunk = ""
            for ev in evs {
                switch ev {
                case .toolActivity(let name, _):
                    latestActivity = "⚡ \(name)"
                case .textDelta(let chunk):
                    deltaChunk += chunk
                case .finalAnswer(let text):
                    deltaChunk = text
                default:
                    break
                }
            }
            if latestActivity != nil || !deltaChunk.isEmpty {
                let shouldNotify = latestActivity != nil || throttle.shouldEmit()
                self.mutateLiveRun(id: runID, notify: shouldNotify) { snap in
                    if let act = latestActivity { snap.currentActivity = act }
                    if !deltaChunk.isEmpty {
                        snap.streamPreview = String((snap.streamPreview + deltaChunk).suffix(800))
                    }
                }
            }
        }

        let parsed = parseAgentStdout(procResult.stdout, driver: driver, initialSessionID: existingSession?.externalSessionID)
        let capturedExtSession = parsed.externalSessionID
        let inTok = parsed.inputTokens
        let outTok = parsed.outputTokens
        let cacheTok = parsed.cachedTokens
        let totalCost = parsed.costUSD
        let fallbackMsg = procHandle.isCancelled ? "已手动中止" : (procResult.stderr.isEmpty ? "Completed with exit code \(procResult.exitCode)" : procResult.stderr)
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

        let runStatus: String
        if procHandle.isCancelled {
            runStatus = "cancelled"
        } else if procResult.timedOut {
            runStatus = "timeout"
        } else if procResult.exitCode == 0 {
            runStatus = "waiting_approval"
        } else if procResult.exitCode == 3 {
            runStatus = "budget_exceeded"
        } else {
            runStatus = "failed"
        }

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

        guard !procHandle.isCancelled else { return }

        let diffText = captureGitDiffPreview(in: workingDir)
        let kind = event.type.contains("feishu") ? "question" : "review"
        let approval = ApprovalRecord(
            id: "apr-\(UUID().uuidString.prefix(8))",
            runID: runID,
            eventID: event.id,
            sessionID: internalSessionID,
            chimeID: rule.id,
            kind: kind,
            riskLevel: rule.worktreeOnPhase2 ? "medium" : "high",
            title: displayTitle,
            provenanceSummary: "\(event.source) • \(rule.id) • \(rule.driver)",
            proposedAction: String(summary.prefix(3500)),
            targetRepo: workingDir,
            externalSessionID: capturedExtSession,
            status: "pending",
            userComment: nil,
            createdAt: SQLiteStore.nowMs(),
            resolvedAt: nil,
            diffPreview: diffText
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

    private func performAcpPhase1(
        acpDriver: AcpAgentDriver,
        request: AgentInvocationRequest,
        event: EventEnvelope,
        rule: ChimeRule,
        workingDir: String,
        runID: String,
        existingSession: (id: String, externalSessionID: String, cwd: String)?
    ) async {
        let acpExecDir: String
        if rule.worktreeOnPhase2 && !Self.isSubpath(URL(fileURLWithPath: workingDir), of: paths.worktreesDir) {
            acpExecDir = TerminalLauncher.prepareWorktreeIfGitRepo(repoPath: workingDir, runID: runID, worktreesDir: paths.worktreesDir)
        } else {
            acpExecDir = workingDir
        }
        let acpRequest = AgentInvocationRequest(
            runID: request.runID,
            correlationKey: request.correlationKey,
            workingDirectory: acpExecDir,
            promptText: request.promptText,
            eventFilePath: request.eventFilePath,
            sessionDir: request.sessionDir,
            permissionProfile: request.permissionProfile,
            modelOverride: request.modelOverride,
            resumeSessionID: request.resumeSessionID,
            worktreeRequested: rule.worktreeOnPhase2,
            ephemeral: request.ephemeral,
            maxTimeSeconds: request.maxTimeSeconds,
            maxCostUSD: request.maxCostUSD
        )
        mutateLiveRun(id: runID, notify: false) { snap in
            snap = LiveRunSnapshot(
                runID: snap.runID,
                chimeID: snap.chimeID,
                driver: snap.driver,
                phase: snap.phase,
                title: snap.title,
                workingDirectory: acpExecDir,
                startedAtMs: snap.startedAtMs,
                status: snap.status,
                currentActivity: snap.currentActivity,
                streamPreview: snap.streamPreview,
                diffPreview: snap.diffPreview,
                pendingApprovalID: snap.pendingApprovalID,
                pid: snap.pid
            )
        }

        let leaseActive = LockedValueBox<Bool>(false)
        let leaseTTL = TimeInterval(max(rule.phase1MaxTimeSeconds, rule.phase2MaxTimeSeconds) + 15)
        if rule.autonomy == .boundedAuto {
            funnel.registerWriteLease(pathPrefix: workingDir, ttlSeconds: leaseTTL)
            if acpExecDir != workingDir {
                funnel.registerWriteLease(pathPrefix: acpExecDir, ttlSeconds: leaseTTL)
            }
            leaseActive.set(true)
        }
        defer {
            if leaseActive.get() {
                funnel.releaseWriteLease(pathPrefix: workingDir, graceSeconds: 1.5)
                if acpExecDir != workingDir {
                    funnel.releaseWriteLease(pathPrefix: acpExecDir, graceSeconds: 1.5)
                }
            }
        }

        let acpHandle = AcpLiveSessionHandle(runID: runID)
        stateLock.withLock { activeAcpHandles[runID] = acpDriver.id.isEmpty ? nil : acpHandle }
        let throttle = StreamThrottleBox()
        let displayTitle = event.payload["title"] ?? rule.id

        let outcome = await AcpSessionRunner.run(
            spec: acpDriver.buildAcpSpawnSpec(request: acpRequest),
            request: acpRequest,
            handle: acpHandle,
            warmHoldTimeoutSeconds: max(600, rule.phase2MaxTimeSeconds),
            onStreamUpdate: { [weak self] activity, fullText, diffSnap in
                guard let self else { return }
                let shouldNotify = activity != nil || throttle.shouldEmit()
                self.mutateLiveRun(id: runID, notify: shouldNotify) { snap in
                    if let act = activity { snap.currentActivity = act }
                    if !fullText.isEmpty { snap.streamPreview = String(fullText.suffix(800)) }
                    if let diffSnap { snap.diffPreview = diffSnap }
                }
            },
            onWarmHoldPermission: { [weak self] permCtx in
                guard let self else { return .reject }
                if rule.autonomy == .boundedAuto {
                    return .allowOnce(comment: "Auto-approved by bounded_auto")
                }
                let aprID = "apr-\(UUID().uuidString.prefix(8))"
                var internalSID = existingSession?.id
                if !permCtx.sessionID.isEmpty {
                    let sid = internalSID ?? "ses-\(UUID().uuidString.prefix(8))"
                    internalSID = sid
                    try? self.store.upsertSession(
                        id: sid,
                        correlationKey: event.correlationKey,
                        driver: acpDriver.id,
                        policy: rule.sessionPolicy,
                        externalSessionID: permCtx.sessionID,
                        cwd: acpExecDir,
                        ttlSeconds: rule.sessionTTLSeconds
                    )
                }
                let draftBody = permCtx.draftTextSoFar.isEmpty
                    ? "ACP 会话请求执行：\(permCtx.toolTitle)"
                    : "\(permCtx.draftTextSoFar)\n\n[待批操作] \(permCtx.toolTitle)"
                let apr = ApprovalRecord(
                    id: aprID,
                    runID: runID,
                    eventID: event.id,
                    sessionID: internalSID,
                    chimeID: rule.id,
                    kind: "review",
                    riskLevel: rule.worktreeOnPhase2 ? "medium" : "high",
                    title: displayTitle,
                    provenanceSummary: "\(event.source) • \(acpDriver.id) • 热挂起待批",
                    proposedAction: String(draftBody.prefix(3500)),
                    targetRepo: acpExecDir,
                    externalSessionID: permCtx.sessionID.isEmpty ? nil : permCtx.sessionID,
                    status: "pending",
                    userComment: nil,
                    createdAt: SQLiteStore.nowMs(),
                    resolvedAt: nil,
                    diffPreview: permCtx.diffPreview
                )
                try? self.store.insertApproval(apr)
                self.stateLock.withLock {
                    self.warmHoldApprovalToRunID[aprID] = runID
                    if var snap = self.liveRuns[runID] {
                        snap.status = "warm_hold"
                        snap.pendingApprovalID = aprID
                        snap.currentActivity = "热挂起等待批准：\(permCtx.toolTitle)"
                        snap.diffPreview = permCtx.diffPreview ?? snap.diffPreview
                        self.liveRuns[runID] = snap
                    }
                }
                self.callbacks.onApprovalUpdated()
                self.callbacks.onNotifyApproval(apr)

                let decision = await acpHandle.waitForPermissionDecision(timeoutSeconds: max(600, rule.phase2MaxTimeSeconds))
                self.stateLock.withLock {
                    _ = self.warmHoldApprovalToRunID.removeValue(forKey: aprID)
                    if var snap = self.liveRuns[runID] {
                        snap.status = "running"
                        snap.pendingApprovalID = nil
                        self.liveRuns[runID] = snap
                    }
                }
                // Clean up ghost pending approval if cancelled via stopRun() or timed out without approve/steer/reject
                if (try? self.store.getApproval(id: aprID))?.status == "pending" {
                    let reason = acpHandle.isCancelled ? "Cancelled by stopRun" : "Warm-hold timed out"
                    _ = try? self.store.resolvePendingApprovalAtomically(id: aprID, status: "expired", comment: reason)
                    self.callbacks.onApprovalUpdated()
                }
                if case .allowOnce = decision, !leaseActive.get() {
                    self.funnel.registerWriteLease(pathPrefix: workingDir, ttlSeconds: leaseTTL)
                    if acpExecDir != workingDir {
                        self.funnel.registerWriteLease(pathPrefix: acpExecDir, ttlSeconds: leaseTTL)
                    }
                    leaseActive.set(true)
                }
                return decision
            }
        )

        var internalSessionID = existingSession?.id
        if let extID = outcome.externalSessionID, !extID.isEmpty {
            let sid = internalSessionID ?? "ses-\(UUID().uuidString.prefix(8))"
            internalSessionID = sid
            try? store.upsertSession(
                id: sid,
                correlationKey: event.correlationKey,
                driver: acpDriver.id,
                policy: rule.sessionPolicy,
                externalSessionID: extID,
                cwd: acpExecDir,
                ttlSeconds: rule.sessionTTLSeconds
            )
        }

        let summary = outcome.finalText.isEmpty ? (outcome.errorMessage ?? "ACP run finished (\(outcome.stopReason))") : outcome.finalText
        let runStatus: String
        if outcome.cancelled {
            runStatus = "cancelled"
        } else if outcome.timedOut {
            runStatus = "timeout"
        } else if outcome.exitCode == 0 {
            runStatus = outcome.warmHoldApprovedAndExecuted ? "succeeded" : "waiting_approval"
        } else {
            runStatus = "failed"
        }

        try? store.updateRunStatus(
            id: runID,
            sessionID: internalSessionID,
            status: runStatus,
            exitCode: outcome.exitCode,
            inputTokens: outcome.inputTokens,
            outputTokens: outcome.outputTokens,
            cachedTokens: outcome.cachedTokens,
            costUSD: outcome.costUSD,
            outputSummary: String(summary.prefix(4000)),
            errorMessage: outcome.errorMessage.map { String($0.prefix(1000)) }
        )

        if outcome.cancelled {
            if acpExecDir != workingDir {
                try? removeWorktree(at: acpExecDir)
            }
            return
        }

        let finalDiff = outcome.diffPreview ?? captureGitDiffPreview(in: acpExecDir)

        // If the ACP session already warm-held, got approved in-place, and completed the edit, post a completion notice!
        if outcome.warmHoldApprovedAndExecuted {
            if let sid = internalSessionID, acpExecDir != workingDir {
                try? store.updateSessionAfterPhase2(id: sid, externalSessionID: outcome.externalSessionID ?? "", cwd: acpExecDir, worktreePath: acpExecDir)
            }
            let doneApr = ApprovalRecord(
                id: "apr-\(UUID().uuidString.prefix(8))",
                runID: runID,
                eventID: event.id,
                sessionID: internalSessionID,
                chimeID: rule.id,
                kind: "notify",
                riskLevel: "low",
                title: "✓ 已完成：\(displayTitle)",
                provenanceSummary: "\(acpDriver.id) • 原位热恢复执行完成",
                proposedAction: String(summary.prefix(3500)),
                targetRepo: acpExecDir,
                externalSessionID: outcome.externalSessionID,
                status: "pending",
                userComment: nil,
                createdAt: SQLiteStore.nowMs(),
                resolvedAt: nil,
                diffPreview: finalDiff
            )
            try? store.insertApproval(doneApr)
            callbacks.onApprovalUpdated()
            let ctx = ActionContext(event: event, rule: rule, approval: doneApr, phase: "execute", summaryText: doneApr.proposedAction, sessionID: outcome.externalSessionID)
            await actionDispatcher.dispatch(specs: rule.onComplete, context: ctx)
            return
        }

        let kind = event.type.contains("feishu") ? "question" : "review"
        let approval = ApprovalRecord(
            id: "apr-\(UUID().uuidString.prefix(8))",
            runID: runID,
            eventID: event.id,
            sessionID: internalSessionID,
            chimeID: rule.id,
            kind: kind,
            riskLevel: rule.worktreeOnPhase2 ? "medium" : "high",
            title: displayTitle,
            provenanceSummary: "\(event.source) • \(rule.id) • \(acpDriver.id)",
            proposedAction: String(summary.prefix(3500)),
            targetRepo: acpExecDir,
            externalSessionID: outcome.externalSessionID,
            status: "pending",
            userComment: nil,
            createdAt: SQLiteStore.nowMs(),
            resolvedAt: nil,
            diffPreview: finalDiff
        )
        try? store.insertApproval(approval)
        callbacks.onApprovalUpdated()

        let actionCtx = ActionContext(
            event: event,
            rule: rule,
            approval: approval,
            phase: "draft",
            summaryText: approval.proposedAction,
            sessionID: outcome.externalSessionID
        )
        await actionDispatcher.dispatch(specs: rule.onComplete, context: actionCtx)

        if rule.autonomy == .boundedAuto && outcome.exitCode == 0 {
            approve(id: approval.id, comment: "Auto-approved by bounded_auto rule")
        }
    }

    private func captureGitDiffPreview(in directory: String) -> String? {
        guard FileManager.default.fileExists(atPath: directory) else { return nil }
        let raw = runGitCapture(in: directory, args: ["diff", "--no-ext-diff", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : String(raw.prefix(6000))
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
        let warmAcpHandle: AcpLiveSessionHandle? = stateLock.withLock {
            guard let rid = warmHoldApprovalToRunID[id] else { return nil }
            return activeAcpHandles[rid]
        }

        guard let approval = (try? store.resolvePendingApprovalAtomically(id: id, status: "approved", comment: comment)) ?? nil else {
            return false
        }
        callbacks.onApprovalUpdated()

        // Fast path: resume warm-held ACP subprocess in-place (<5ms)!
        if let warmAcpHandle, warmAcpHandle.resolvePermission(.allowOnce(comment: comment)) {
            return true
        }

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

    /// Steers a warm-held ACP session in-place or spawns a refined follow-up turn with the user's instruction.
    @discardableResult
    public func steer(id: String, instruction: String) -> Bool {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let warmAcpHandle: AcpLiveSessionHandle? = stateLock.withLock {
            guard let rid = warmHoldApprovalToRunID[id] else { return nil }
            return activeAcpHandles[rid]
        }

        guard let approval = (try? store.resolvePendingApprovalAtomically(id: id, status: "edited", comment: trimmed)) ?? nil else {
            return false
        }
        callbacks.onApprovalUpdated()

        if let warmAcpHandle, warmAcpHandle.resolvePermission(.steer(instruction: trimmed)) {
            return true
        }

        guard let rule = funnel.currentRules().first(where: { $0.id == approval.chimeID }) else {
            return true
        }
        let workingDir = approval.targetRepo ?? rule.workingDir
        var refinedRule = rule
        refinedRule.phase1Prompt = "\(rule.phase1Prompt)\n\n[Human Steer / 用户补充调整要求]: \(trimmed)"
        let steerCorrKey = "steer:\(approval.id)"
        if let extSID = approval.externalSessionID, !extSID.isEmpty {
            if refinedRule.sessionPolicy == .ephemeral {
                refinedRule.sessionPolicy = .threaded
            }
            let drvID = AgentDriverRegistry.driver(named: refinedRule.driver).id
            try? store.upsertSession(
                id: "ses-\(UUID().uuidString.prefix(8))",
                correlationKey: steerCorrKey,
                driver: drvID,
                policy: refinedRule.sessionPolicy,
                externalSessionID: extSID,
                cwd: workingDir,
                ttlSeconds: max(3600, refinedRule.sessionTTLSeconds)
            )
        }
        let steerEvent = EventEnvelope(
            source: "bz://steer/human",
            type: "dev.bianzhong.steer",
            correlationKey: steerCorrKey,
            payload: [
                "title": approval.title,
                "body": "\(approval.proposedAction)\n\n[调整要求] \(trimmed)"
            ],
            ambientContext: .captureCurrent()
        )
        try? store.recordEvent(steerEvent, funnelStage: "dispatched", matchedChimeID: rule.id)

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.runPhase1(event: steerEvent, rule: refinedRule, workingDir: workingDir)
        }
        return true
    }

    private func performPhase2(approval: ApprovalRecord, rule: ChimeRule, extSession: String, comment: String?) async {
        let runID = "run-\(UUID().uuidString.prefix(8))"
        let driver = AgentDriverRegistry.driver(named: rule.driver)
        let driverSessionsDir = paths.sessionsDir.appendingPathComponent(driver.id, isDirectory: true)
        let baseRepo = approval.targetRepo ?? rule.workingDir

        let execDir: String
        if rule.worktreeOnPhase2 && driver.id != "codex" && !Self.isSubpath(URL(fileURLWithPath: baseRepo), of: paths.worktreesDir) {
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

        upsertLiveRun(
            LiveRunSnapshot(
                runID: runID,
                chimeID: rule.id,
                driver: driver.id,
                phase: "execute",
                title: approval.title,
                workingDirectory: execDir,
                startedAtMs: SQLiteStore.nowMs(),
                status: "running",
                currentActivity: "Phase 2 执行中 (\(driver.id))..."
            )
        )
        defer { removeLiveRun(id: runID) }

        let finalStatus: String
        let exitCode: Int32
        let execSummary: String
        let effectiveExtSession: String
        let inTok: Int
        let outTok: Int
        let cacheTok: Int
        let costUSD: Double
        let errText: String?
        var capturedDiff: String?

        if let acpDriver = driver as? AcpAgentDriver {
            let acpHandle = AcpLiveSessionHandle(runID: runID)
            stateLock.withLock { activeAcpHandles[runID] = acpHandle }
            let throttle = StreamThrottleBox()
            let acpOut = await AcpSessionRunner.run(
                spec: acpDriver.buildAcpSpawnSpec(request: request),
                request: request,
                handle: acpHandle,
                warmHoldTimeoutSeconds: rule.phase2MaxTimeSeconds,
                onStreamUpdate: { [weak self] activity, fullText, diffSnap in
                    guard let self else { return }
                    let shouldNotify = activity != nil || throttle.shouldEmit()
                    self.mutateLiveRun(id: runID, notify: shouldNotify) { snap in
                        if let act = activity { snap.currentActivity = act }
                        if !fullText.isEmpty { snap.streamPreview = String(fullText.suffix(800)) }
                        if let diffSnap { snap.diffPreview = diffSnap }
                    }
                },
                onWarmHoldPermission: { _ in .allowOnce(comment: comment) }
            )
            effectiveExtSession = acpOut.externalSessionID ?? extSession
            exitCode = acpOut.exitCode
            finalStatus = acpOut.cancelled ? "cancelled" : (acpOut.timedOut ? "timeout" : (acpOut.exitCode == 0 ? "succeeded" : "failed"))
            let raw = acpOut.finalText.isEmpty ? (acpOut.errorMessage ?? "ACP Phase 2 completed") : acpOut.finalText
            execSummary = String(raw.prefix(3500))
            inTok = acpOut.inputTokens
            outTok = acpOut.outputTokens
            cacheTok = acpOut.cachedTokens
            costUSD = acpOut.costUSD
            errText = acpOut.errorMessage
            capturedDiff = acpOut.diffPreview
        } else {
            let procHandle = ActiveProcessHandle()
            stateLock.withLock { activeProcessHandles[runID] = procHandle }
            let throttle = StreamThrottleBox()
            let procResult = await AgentProcessRunner.run(
                spec: driver.buildSpawnSpec(request: request),
                timeoutSeconds: rule.phase2MaxTimeSeconds,
                handle: procHandle
            ) { [weak self] line in
                guard let self else { return }
                for ev in driver.parseStdoutLine(line) {
                    switch ev {
                    case .toolActivity(let name, _):
                        self.mutateLiveRun(id: runID, notify: true) { $0.currentActivity = "⚡ \(name)" }
                    case .textDelta(let chunk):
                        self.mutateLiveRun(id: runID, notify: throttle.shouldEmit()) {
                            $0.streamPreview = String(($0.streamPreview + chunk).suffix(800))
                        }
                    default: break
                    }
                }
            }
            let parsed = parseAgentStdout(procResult.stdout, driver: driver, initialSessionID: extSession)
            effectiveExtSession = parsed.externalSessionID ?? extSession
            exitCode = procResult.exitCode
            finalStatus = procHandle.isCancelled ? "cancelled" : (procResult.timedOut ? "timeout" : (procResult.exitCode == 0 ? "succeeded" : (procResult.exitCode == 3 ? "budget_exceeded" : "failed")))
            let fallbackSummary = procResult.stderr.isEmpty ? String(procResult.stdout.suffix(2000)) : procResult.stderr
            let rawSummary = parsed.finalText ?? (parsed.errorMessages.isEmpty ? fallbackSummary : parsed.errorMessages.joined(separator: "\n"))
            execSummary = rawSummary.isEmpty ? "Exit code: \(procResult.exitCode)" : String(rawSummary.prefix(3500))
            inTok = parsed.inputTokens
            outTok = parsed.outputTokens
            cacheTok = parsed.cachedTokens
            costUSD = parsed.costUSD
            errText = procResult.exitCode == 0 ? nil : String((parsed.errorMessages.last ?? procResult.stderr).prefix(1000))
        }
        capturedDiff = capturedDiff ?? captureGitDiffPreview(in: execDir)

        try? store.updateRunStatus(
            id: runID,
            sessionID: approval.sessionID,
            status: finalStatus,
            exitCode: exitCode,
            inputTokens: inTok,
            outputTokens: outTok,
            cachedTokens: cacheTok,
            costUSD: costUSD,
            outputSummary: execSummary,
            errorMessage: errText
        )

        guard finalStatus != "cancelled" else {
            if execDir != baseRepo {
                try? removeWorktree(at: execDir)
            }
            return
        }

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
            resolvedAt: nil,
            diffPreview: capturedDiff
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
        var deltaText = ""
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
                case .textDelta(let chunk):
                    deltaText += chunk
                case .usageReported(let i, let o, let c, let cost):
                    out.inputTokens += i
                    out.outputTokens += o
                    out.cachedTokens += c
                    out.costUSD += cost ?? 0
                case .error(let msg, _):
                    out.errorMessages.append(msg)
                case .toolActivity:
                    break
                }
            }
        }
        out.finalText = finalTexts.last ?? (deltaText.isEmpty ? nil : deltaText)
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
        let warmAcpHandle: AcpLiveSessionHandle? = stateLock.withLock {
            guard let rid = warmHoldApprovalToRunID[id] else { return nil }
            return activeAcpHandles[rid]
        }
        guard ((try? store.resolvePendingApprovalAtomically(id: id, status: "rejected", comment: comment)) ?? nil) != nil else {
            return false
        }
        _ = warmAcpHandle?.resolvePermission(.reject)
        callbacks.onApprovalUpdated()
        return true
    }

    @discardableResult
    public func launchIDEHandoff(for approvalID: String, ide: TerminalLauncher.IDEApp) -> Bool {
        guard let approval = try? store.getApproval(id: approvalID) else { return false }
        let rule = funnel.currentRules().first(where: { $0.id == approval.chimeID })
        let cwd = approval.targetRepo ?? rule?.workingDir ?? FileManager.default.homeDirectoryForCurrentUser.path
        let ok = TerminalLauncher.openInIDE(ide, directory: cwd)
        if ok {
            if let sid = approval.sessionID {
                try? store.markSessionHandedOver(id: sid)
            }
            _ = try? store.resolvePendingApprovalAtomically(id: approvalID, status: "taken_over", comment: "Opened in \(ide.displayName)")
            callbacks.onApprovalUpdated()
        }
        return ok
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

private final class StreamThrottleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lastMs: Int64 = 0

    func shouldEmit(minIntervalMs: Int64 = 180) -> Bool {
        lock.withLock {
            let now = SQLiteStore.nowMs()
            if now - lastMs >= minIntervalMs {
                lastMs = now
                return true
            }
            return false
        }
    }
}

private final class LockedValueBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var val: T
    init(_ initial: T) { self.val = initial }
    func set(_ v: T) { lock.withLock { val = v } }
    func get() -> T { lock.withLock { val } }
}

private extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return enc
    }()
}
