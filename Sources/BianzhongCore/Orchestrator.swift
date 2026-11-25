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
    private var feishuMonitor: FeishuSensorMonitor?
    private var builtInSensorsEnabled = false
    private var customFeishuDBURL: URL?
    private var feishuSkipExistingOnFirstRun = true
    private let stateLock = NSLock()
    private var pausedUntil: Date?
    private var pauseTimer: DispatchSourceTimer?
    private let runGate: ConcurrencyGate

    public init(paths: BianzhongPaths = BianzhongPaths(), callbacks: OrchestratorCallbacks = OrchestratorCallbacks()) throws {
        self.paths = paths
        try paths.ensureDirectories()
        self.config = AppConfig.load(from: paths.configFile)
        self.store = try SQLiteStore(dbURL: paths.dbURL)
        let loadedRules = ChimeRule.loadAll(from: paths.chimesDir)
        let funnelInstance = WakeupFunnel(
            store: store,
            rules: loadedRules,
            maxCausalDepth: config.maxCausalDepth
        )
        self.funnel = funnelInstance
        self.governance = RuntimeGovernance()
        self.callbacks = callbacks
        self.actionDispatcher = ActionDispatcher(funnel: funnelInstance, notifyHandler: callbacks.onNotifyApproval)
        self.runGate = ConcurrencyGate(limit: config.maxConcurrentRuns)
    }

    public func start(
        enableBuiltInSensors: Bool = false,
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
        if let feishuDBURL {
            self.customFeishuDBURL = feishuDBURL
        }
        self.feishuSkipExistingOnFirstRun = skipExistingFeishuOnFirstRun
        stateLock.unlock()

        if enableBuiltInSensors {
            syncFeishuMonitor()
        }

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
        let monitor = feishuMonitor
        feishuMonitor = nil
        builtInSensorsEnabled = false
        stateLock.unlock()
        timer?.cancel()
        monitor?.stop()
        bus?.stop()
        bus = nil
    }

    public func feishuSensorStatus() -> FeishuSensorStatus {
        let monitor = stateLock.withLock { feishuMonitor }
        return monitor?.currentStatus() ?? .disabled
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

            if rule.triageEnabled {
                let provider = TriageProviderFactory.make(config: cfg, override: rule.triageProviderOverride)
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

    public func approve(id: String, comment: String?) {
        guard let approval = try? store.getApproval(id: id) else { return }
        try? store.resolveApproval(id: id, status: "approved", comment: comment)
        callbacks.onApprovalUpdated()

        guard approval.kind != "notify",
              approval.kind != "digest",
              let rule = funnel.currentRules().first(where: { $0.id == approval.chimeID }),
              !rule.phase2Prompt.isEmpty,
              let extSession = approval.externalSessionID else {
            return
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.runGate.withPermit {
                await self.performPhase2(approval: approval, rule: rule, extSession: extSession, comment: comment)
            }
        }
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

    public func reject(id: String, comment: String?) {
        try? store.resolveApproval(id: id, status: "rejected", comment: comment)
        callbacks.onApprovalUpdated()
    }

    public func copyAndOpenFeishu(id: String) {
        guard let approval = try? store.getApproval(id: id) else { return }
        TerminalLauncher.copyAndOpenFeishu(text: approval.proposedAction) { [weak self] hash in
            self?.funnel.registerEchoHash(hash, ttlSeconds: 30)
        }
        try? store.resolveApproval(id: id, status: "approved", comment: "Copied to Feishu")
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
