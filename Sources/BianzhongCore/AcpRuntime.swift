import Darwin
import Foundation

/// Live telemetry snapshot of an active or warm-held agent run, streamed to the Notch HUD and Tailscale Pocket PWA.
public struct LiveRunSnapshot: Codable, Sendable, Equatable, Identifiable {
    public var id: String { runID }
    public let runID: String
    public let chimeID: String
    public let driver: String
    public let phase: String
    public let title: String
    public let workingDirectory: String
    public let startedAtMs: Int64
    public var status: String // "running" | "warm_hold" | "stopping"
    public var currentActivity: String
    public var streamPreview: String
    public var diffPreview: String?
    public var pendingApprovalID: String?
    public var pid: Int32

    public init(
        runID: String,
        chimeID: String,
        driver: String,
        phase: String,
        title: String,
        workingDirectory: String,
        startedAtMs: Int64,
        status: String = "running",
        currentActivity: String = "启动中...",
        streamPreview: String = "",
        diffPreview: String? = nil,
        pendingApprovalID: String? = nil,
        pid: Int32 = -1
    ) {
        self.runID = runID
        self.chimeID = chimeID
        self.driver = driver
        self.phase = phase
        self.title = title
        self.workingDirectory = workingDirectory
        self.startedAtMs = startedAtMs
        self.status = status
        self.currentActivity = currentActivity
        self.streamPreview = streamPreview
        self.diffPreview = diffPreview
        self.pendingApprovalID = pendingApprovalID
        self.pid = pid
    }
}

public enum AcpPermissionDecision: Sendable, Equatable {
    case allowOnce(comment: String?)
    case steer(instruction: String)
    case reject
}

public struct AcpPermissionPromptContext: Sendable {
    public let sessionID: String
    public let toolTitle: String
    public let toolKind: String
    public let diffPreview: String?
    public let draftTextSoFar: String
}

/// Thread-safe handle to a live ACP subprocess (`omp --mode=acp`, `opencode acp`, `gemini --acp`, etc.)
/// supporting sub-millisecond warm-hold resume, mid-flight steering, and instant cancellation.
public final class AcpLiveSessionHandle: @unchecked Sendable {
    public let runID: String
    private let lock = NSLock()
    private var pid: pid_t = -1
    private var reaped = false
    private var cancelSender: (@Sendable (String) -> Void)?
    private var sessionID: String?
    private var cancelled = false
    private var pendingDecisionContinuation: CheckedContinuation<AcpPermissionDecision, Never>?

    public init(runID: String) {
        self.runID = runID
    }

    func bindProcess(pid: pid_t, cancelSender: @escaping @Sendable (String) -> Void) {
        let shouldTerminateNow = lock.withLock { () -> Bool in
            self.pid = pid
            self.reaped = false
            self.cancelSender = cancelSender
            return self.cancelled
        }
        if shouldTerminateNow && pid > 0 {
            kill(-pid, SIGTERM)
        }
    }

    func markReaped() {
        lock.withLock {
            reaped = true
            cancelSender = nil
        }
    }

    private func shouldSendSIGKILL(to targetPID: pid_t) -> Bool {
        lock.withLock {
            !reaped && pid == targetPID && targetPID > 0
        }
    }

    func updateSessionID(_ sid: String) {
        lock.withLock {
            self.sessionID = sid
        }
    }

    public var isWaitingPermission: Bool {
        lock.withLock { pendingDecisionContinuation != nil }
    }

    public var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    /// Resolves an active `session/request_permission` warm-hold in `<5ms`.
    @discardableResult
    public func resolvePermission(_ decision: AcpPermissionDecision) -> Bool {
        let cont: CheckedContinuation<AcpPermissionDecision, Never>? = lock.withLock {
            let existing = pendingDecisionContinuation
            pendingDecisionContinuation = nil
            return existing
        }
        guard let cont else { return false }
        cont.resume(returning: decision)
        return true
    }

    func waitForPermissionDecision(timeoutSeconds: Int) async -> AcpPermissionDecision {
        await withTaskGroup(of: AcpPermissionDecision.self) { group in
            group.addTask {
                await withCheckedContinuation { (cont: CheckedContinuation<AcpPermissionDecision, Never>) in
                    let immediateCancel = self.lock.withLock { () -> Bool in
                        if self.cancelled { return true }
                        self.pendingDecisionContinuation = cont
                        return false
                    }
                    if immediateCancel {
                        cont.resume(returning: .reject)
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(max(5, timeoutSeconds)))
                return .reject
            }
            let first = await group.next() ?? .reject
            group.cancelAll()
            _ = self.lock.withLock { () -> CheckedContinuation<AcpPermissionDecision, Never>? in
                let stale = self.pendingDecisionContinuation
                self.pendingDecisionContinuation = nil
                return stale
            }?.resume(returning: first)
            return first
        }
    }

    public func cancel() {
        let (targetPID, alive, sid, sender, cont): (pid_t, Bool, String?, (@Sendable (String) -> Void)?, CheckedContinuation<AcpPermissionDecision, Never>?) = lock.withLock {
            cancelled = true
            let c = pendingDecisionContinuation
            pendingDecisionContinuation = nil
            return (pid, !reaped, sessionID, cancelSender, c)
        }
        cont?.resume(returning: .reject)

        if alive, let sid, !sid.isEmpty {
            sender?(sid)
        }

        if alive && targetPID > 0 {
            kill(-targetPID, SIGTERM)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, self.shouldSendSIGKILL(to: targetPID) else { return }
                kill(-targetPID, SIGKILL)
            }
        }
    }
}

public struct AcpRunOutcome: Sendable {
    public let pid: Int32
    public let externalSessionID: String?
    public let finalText: String
    public let diffPreview: String?
    public let stopReason: String
    public let exitCode: Int32
    public let timedOut: Bool
    public let cancelled: Bool
    public let warmHoldApprovedAndExecuted: Bool
    public let inputTokens: Int
    public let outputTokens: Int
    public let cachedTokens: Int
    public let costUSD: Double
    public let errorMessage: String?

    public init(
        pid: Int32,
        externalSessionID: String?,
        finalText: String,
        diffPreview: String?,
        stopReason: String,
        exitCode: Int32,
        timedOut: Bool,
        cancelled: Bool,
        warmHoldApprovedAndExecuted: Bool,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cachedTokens: Int = 0,
        costUSD: Double = 0,
        errorMessage: String?
    ) {
        self.pid = pid
        self.externalSessionID = externalSessionID
        self.finalText = finalText
        self.diffPreview = diffPreview
        self.stopReason = stopReason
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.cancelled = cancelled
        self.warmHoldApprovedAndExecuted = warmHoldApprovedAndExecuted
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedTokens = cachedTokens
        self.costUSD = costUSD
        self.errorMessage = errorMessage
    }
}

/// Bidirectional stdio JSON-RPC 2.0 runner implementing Agent Client Protocol (ACP v1).
public enum AcpSessionRunner {
    public static func run(
        spec: SpawnSpec,
        request: AgentInvocationRequest,
        handle: AcpLiveSessionHandle,
        warmHoldTimeoutSeconds: Int = 1800,
        onStreamUpdate: @escaping @Sendable (_ activity: String?, _ textSnapshot: String, _ diffSnapshot: String?) -> Void,
        onWarmHoldPermission: @escaping @Sendable (AcpPermissionPromptContext) async -> AcpPermissionDecision
    ) async -> AcpRunOutcome {
        var stdinPipe: [Int32] = [-1, -1]
        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]

        guard pipe(&stdinPipe) == 0, pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            for fd in [stdinPipe[0], stdinPipe[1], stdoutPipe[0], stdoutPipe[1], stderrPipe[0], stderrPipe[1]] where fd >= 0 {
                close(fd)
            }
            return AcpRunOutcome(
                pid: -1,
                externalSessionID: request.resumeSessionID,
                finalText: "",
                diffPreview: nil,
                stopReason: "pipe_error",
                exitCode: -1,
                timedOut: false,
                cancelled: false,
                warmHoldApprovedAndExecuted: false,
                errorMessage: "Failed to allocate ACP stdio pipes"
            )
        }
        _ = fcntl(stdinPipe[1], F_SETNOSIGPIPE, 1)

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        posix_spawn_file_actions_adddup2(&fileActions, stdinPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, stderrPipe[1], STDERR_FILENO)
        for fd in [stdinPipe[0], stdinPipe[1], stdoutPipe[0], stdoutPipe[1], stderrPipe[0], stderrPipe[1]] {
            posix_spawn_file_actions_addclose(&fileActions, fd)
        }
        if FileManager.default.fileExists(atPath: spec.workingDirectory) {
            posix_spawn_file_actions_addchdir(&fileActions, spec.workingDirectory)
        }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)

        var mergedEnv = ProcessInfo.processInfo.environment
        for (k, v) in spec.environment {
            mergedEnv[k] = v
        }

        let argvStrings = [spec.executablePath] + spec.arguments
        let cArgv = argvStrings.map { strdup($0) } + [nil]
        let envStrings = mergedEnv.map { "\($0.key)=\($0.value)" }
        let cEnv = envStrings.map { strdup($0) } + [nil]
        defer {
            cArgv.forEach { if let p = $0 { free(p) } }
            cEnv.forEach { if let p = $0 { free(p) } }
        }

        var pid: pid_t = 0
        let spawnRC = posix_spawn(&pid, spec.executablePath, &fileActions, &attr, cArgv, cEnv)
        close(stdinPipe[0])
        close(stdoutPipe[1])
        close(stderrPipe[1])

        guard spawnRC == 0 else {
            close(stdinPipe[1])
            close(stdoutPipe[0])
            close(stderrPipe[0])
            return AcpRunOutcome(
                pid: -1,
                externalSessionID: request.resumeSessionID,
                finalText: "",
                diffPreview: nil,
                stopReason: "spawn_error",
                exitCode: spawnRC,
                timedOut: false,
                cancelled: false,
                warmHoldApprovedAndExecuted: false,
                errorMessage: "posix_spawn failed (\(spawnRC)): \(String(cString: strerror(spawnRC)))"
            )
        }

        let writeFD = stdinPipe[1]
        let readFD = stdoutPipe[0]
        let errFD = stderrPipe[0]

        final class StderrBox: @unchecked Sendable {
            let lock = NSLock()
            var data = Data()
            func append(_ bytes: [UInt8], count: Int) {
                lock.withLock {
                    if data.count < 16384 {
                        data.append(bytes, count: count)
                    }
                }
            }
            func string() -> String {
                lock.withLock { String(data: data, encoding: .utf8) ?? "" }
            }
        }
        let stderrBox = StderrBox()
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = Darwin.read(errFD, &buf, buf.count)
                if n > 0 {
                    stderrBox.append(buf, count: n)
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            close(errFD)
        }

        let transport = AcpLineTransport(readFD: readFD, writeFD: writeFD)
        handle.bindProcess(pid: pid) { sid in
            try? transport.sendJSON([
                "jsonrpc": "2.0",
                "method": "session/cancel",
                "params": ["sessionId": sid]
            ])
        }
        defer {
            transport.closeWriteEnd()
            var st: Int32 = 0
            if waitpid(pid, &st, WNOHANG) == 0 {
                kill(-pid, SIGTERM)
                usleep(150_000)
                if waitpid(pid, &st, WNOHANG) == 0 {
                    kill(-pid, SIGKILL)
                    _ = waitpid(pid, &st, 0)
                }
            }
            handle.markReaped()
        }

        let state = AcpAccumulator()
        var nextReqID = 1

        func sendRPC(method: String, params: [String: Any]) throws -> Int {
            let id = nextReqID
            nextReqID += 1
            try transport.sendJSON([
                "jsonrpc": "2.0",
                "id": id,
                "method": method,
                "params": params
            ])
            return id
        }

        // Watchdog timer for initial turn timeout (paused while warm-holding for human approval)
        let deadlineBox = DeadlineController(timeoutSeconds: max(10, request.maxTimeSeconds))
        let watchdogTask = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                if deadlineBox.isExpired() {
                    deadlineBox.markTimedOut()
                    handle.cancel()
                    break
                }
            }
        }
        defer { watchdogTask.cancel() }

        func pumpUntilResponse(targetID: Int, currentSessionID: String?) async throws -> [String: Any] {
            while let msg = await transport.nextMessage() {
                if msg["method"] == nil, let rawID = msg["id"] {
                    let matchesID: Bool
                    if let i = rawID as? Int {
                        matchesID = (i == targetID)
                    } else if let n = rawID as? NSNumber {
                        matchesID = (n.intValue == targetID)
                    } else if let s = rawID as? String {
                        matchesID = (s == String(targetID))
                    } else {
                        matchesID = false
                    }
                    if matchesID {
                        if let err = msg["error"] as? [String: Any] {
                            let emsg = (err["message"] as? String) ?? "ACP RPC error"
                            throw NSError(domain: "AcpRunner", code: (err["code"] as? Int) ?? -1, userInfo: [NSLocalizedDescriptionKey: emsg])
                        }
                        let res = (msg["result"] as? [String: Any]) ?? [:]
                        state.ingestUsageIfPresent(res)
                        return res
                    }
                }

                if let method = msg["method"] as? String {
                    if method == "session/update",
                       let params = msg["params"] as? [String: Any],
                       let update = params["update"] as? [String: Any] {
                        let parsedUpdate = state.ingestSessionUpdate(update)
                        onStreamUpdate(parsedUpdate.activity, state.accumulatedText, state.latestDiff)
                    } else if method == "session/request_permission", let reqID = msg["id"] {
                        let params = (msg["params"] as? [String: Any]) ?? [:]
                        let options = (params["options"] as? [[String: Any]]) ?? []
                        let toolCall = (params["toolCall"] as? [String: Any]) ?? [:]
                        let toolKind = ((toolCall["kind"] as? String) ?? "execute").lowercased()
                        let toolTitle = (toolCall["title"] as? String) ?? toolKind
                        let extractedDiff = AcpAccumulator.extractDiffFromToolCall(toolCall) ?? state.latestDiff
                        if let extractedDiff {
                            state.latestDiff = extractedDiff
                        }

                        let allowOptID = Self.pickOptionID(options: options, preferringAllow: true)
                        let rejectOptID = Self.pickOptionID(options: options, preferringAllow: false)
                        let isReadSafe = ["read", "search", "fetch", "think"].contains(toolKind)

                        if request.permissionProfile == .workspaceRW || (request.permissionProfile == .readOnly && isReadSafe) {
                            if let allowOptID {
                                try? transport.sendJSON([
                                    "jsonrpc": "2.0",
                                    "id": reqID,
                                    "result": ["outcome": ["outcome": "selected", "optionId": allowOptID]]
                                ])
                            } else {
                                try? transport.sendJSON([
                                    "jsonrpc": "2.0",
                                    "id": reqID,
                                    "result": ["outcome": ["outcome": "cancelled"]]
                                ])
                            }
                            continue
                        }

                        // Warm-hold in place! Pause deadline clock while waiting on human decision.
                        deadlineBox.setPaused(true)
                        onStreamUpdate("等待批准：\(toolTitle)", state.accumulatedText, state.latestDiff)
                        let ctx = AcpPermissionPromptContext(
                            sessionID: currentSessionID ?? "",
                            toolTitle: toolTitle,
                            toolKind: toolKind,
                            diffPreview: state.latestDiff,
                            draftTextSoFar: state.accumulatedText
                        )
                        let decision = await onWarmHoldPermission(ctx)
                        deadlineBox.extendAfterResume(seconds: max(60, warmHoldTimeoutSeconds))
                        deadlineBox.setPaused(false)

                        switch decision {
                        case .allowOnce:
                            state.warmHoldApproved = true
                            onStreamUpdate("已批准，正在执行：\(toolTitle)", state.accumulatedText, state.latestDiff)
                            if let allowOptID {
                                try? transport.sendJSON([
                                    "jsonrpc": "2.0",
                                    "id": reqID,
                                    "result": ["outcome": ["outcome": "selected", "optionId": allowOptID]]
                                ])
                            } else {
                                try? transport.sendJSON([
                                    "jsonrpc": "2.0",
                                    "id": reqID,
                                    "result": ["outcome": ["outcome": "cancelled"]]
                                ])
                            }
                        case .steer(let instruction):
                            state.pendingSteerInstruction = instruction
                            onStreamUpdate("收到调整指令，重新规划...", state.accumulatedText, state.latestDiff)
                            if let rejectOptID {
                                try? transport.sendJSON([
                                    "jsonrpc": "2.0",
                                    "id": reqID,
                                    "result": ["outcome": ["outcome": "selected", "optionId": rejectOptID]]
                                ])
                            } else {
                                try? transport.sendJSON([
                                    "jsonrpc": "2.0",
                                    "id": reqID,
                                    "result": ["outcome": ["outcome": "cancelled"]]
                                ])
                            }
                        case .reject:
                            state.rejectedByHuman = true
                            try? transport.sendJSON([
                                "jsonrpc": "2.0",
                                "id": reqID,
                                "result": ["outcome": ["outcome": "cancelled"]]
                            ])
                            handle.cancel()
                        }
                    } else if let reqID = msg["id"] {
                        // Unsupported client capability call -> return clean JSON-RPC method-not-found error
                        try? transport.sendJSON([
                            "jsonrpc": "2.0",
                            "id": reqID,
                            "error": ["code": -32601, "message": "Unsupported client method: \(method)"]
                        ])
                    }
                }
            }
            throw NSError(domain: "AcpRunner", code: -2, userInfo: [NSLocalizedDescriptionKey: "ACP stream closed before response"])
        }

        do {
            onStreamUpdate("ACP 握手中...", "", nil)
            let initID = try sendRPC(method: "initialize", params: [
                "protocolVersion": 1,
                "clientCapabilities": [
                    "fs": ["readTextFile": false, "writeTextFile": false],
                    "terminal": false
                ],
                "clientInfo": ["name": "bianzhong", "version": "0.5.0"]
            ])
            let initRes = try await pumpUntilResponse(targetID: initID, currentSessionID: nil)
            let supportsLoadSession = ((initRes["agentCapabilities"] as? [String: Any])?["loadSession"] as? Bool) == true

            var activeSessionID = ""
            var configOptions: [[String: Any]] = []

            if supportsLoadSession, let resumeID = request.resumeSessionID, !resumeID.isEmpty {
                let loadID = try sendRPC(method: "session/load", params: [
                    "sessionId": resumeID,
                    "cwd": spec.workingDirectory,
                    "mcpServers": []
                ])
                if let loadRes = try? await pumpUntilResponse(targetID: loadID, currentSessionID: resumeID) {
                    activeSessionID = (loadRes["sessionId"] as? String) ?? resumeID
                    configOptions = (loadRes["configOptions"] as? [[String: Any]]) ?? []
                }
            }

            if activeSessionID.isEmpty {
                let newID = try sendRPC(method: "session/new", params: [
                    "cwd": spec.workingDirectory,
                    "mcpServers": []
                ])
                let newRes = try await pumpUntilResponse(targetID: newID, currentSessionID: nil)
                activeSessionID = (newRes["sessionId"] as? String) ?? ""
                configOptions = (newRes["configOptions"] as? [[String: Any]]) ?? []
            }

            guard !activeSessionID.isEmpty else {
                throw NSError(domain: "AcpRunner", code: -3, userInfo: [NSLocalizedDescriptionKey: "ACP agent returned empty sessionId"])
            }
            handle.updateSessionID(activeSessionID)

            // Best-effort configure plan mode for read-only Phase 1 or model override if supported
            if request.permissionProfile == .readOnly,
               Self.supportsOption(configOptions, id: "mode", value: "plan") {
                let modeReq = try sendRPC(method: "session/set_config_option", params: [
                    "sessionId": activeSessionID,
                    "configId": "mode",
                    "value": "plan"
                ])
                _ = try? await pumpUntilResponse(targetID: modeReq, currentSessionID: activeSessionID)
            }
            if let model = request.modelOverride, !model.isEmpty,
               configOptions.contains(where: { ($0["id"] as? String) == "model" }) {
                let modelReq = try sendRPC(method: "session/set_config_option", params: [
                    "sessionId": activeSessionID,
                    "configId": "model",
                    "value": model
                ])
                _ = try? await pumpUntilResponse(targetID: modelReq, currentSessionID: activeSessionID)
            }

            onStreamUpdate("分析上下文...", "", nil)
            var currentPrompt = request.promptText
            var stopReason = "end_turn"
            var steerRounds = 0

            while true {
                let promptID = try sendRPC(method: "session/prompt", params: [
                    "sessionId": activeSessionID,
                    "prompt": [
                        ["type": "text", "text": currentPrompt]
                    ]
                ])
                let promptRes = try await pumpUntilResponse(targetID: promptID, currentSessionID: activeSessionID)
                stopReason = (promptRes["stopReason"] as? String) ?? "end_turn"

                if let steerText = state.consumePendingSteer(), steerRounds < 5, !handle.isCancelled {
                    steerRounds += 1
                    state.appendSeparatorBeforeSteer()
                    currentPrompt = "[Human Steer / 调整指令]: \(steerText)"
                    continue
                }
                break
            }

            return AcpRunOutcome(
                pid: pid,
                externalSessionID: activeSessionID,
                finalText: state.accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines),
                diffPreview: state.latestDiff,
                stopReason: stopReason,
                exitCode: state.rejectedByHuman ? 130 : 0,
                timedOut: deadlineBox.didTimeOut(),
                cancelled: handle.isCancelled,
                warmHoldApprovedAndExecuted: state.warmHoldApproved,
                inputTokens: state.inputTokens,
                outputTokens: state.outputTokens,
                cachedTokens: state.cachedTokens,
                costUSD: state.costUSD,
                errorMessage: nil
            )
        } catch {
            let errDetail = stderrBox.string().trimmingCharacters(in: .whitespacesAndNewlines)
            let combinedErr = errDetail.isEmpty ? error.localizedDescription : "\(error.localizedDescription) | \(errDetail.prefix(400))"
            return AcpRunOutcome(
                pid: pid,
                externalSessionID: request.resumeSessionID,
                finalText: state.accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines),
                diffPreview: state.latestDiff,
                stopReason: deadlineBox.didTimeOut() ? "timeout" : (handle.isCancelled ? "cancelled" : "error"),
                exitCode: deadlineBox.didTimeOut() ? 124 : -1,
                timedOut: deadlineBox.didTimeOut(),
                cancelled: handle.isCancelled,
                warmHoldApprovedAndExecuted: state.warmHoldApproved,
                inputTokens: state.inputTokens,
                outputTokens: state.outputTokens,
                cachedTokens: state.cachedTokens,
                costUSD: state.costUSD,
                errorMessage: combinedErr
            )
        }
    }

    private static func pickOptionID(options: [[String: Any]], preferringAllow: Bool) -> String? {
        for opt in options {
            let kind = ((opt["kind"] as? String) ?? "").lowercased()
            if preferringAllow && (kind == "allow_once" || kind.hasPrefix("allow")) {
                return opt["optionId"] as? String
            }
            if !preferringAllow && (kind == "reject_once" || kind.hasPrefix("reject")) {
                return opt["optionId"] as? String
            }
        }
        return options.first?["optionId"] as? String
    }

    private static func supportsOption(_ options: [[String: Any]], id: String, value: String) -> Bool {
        guard let entry = options.first(where: { ($0["id"] as? String) == id }),
              let choices = entry["options"] as? [[String: Any]] else {
            return false
        }
        return choices.contains(where: { ($0["value"] as? String) == value })
    }
}

// MARK: - Internal ACP Transport & Stream Accumulator

private final class DeadlineController: @unchecked Sendable {
    private let lock = NSLock()
    private var deadline: Date
    private var paused = false
    private var timedOut = false

    init(timeoutSeconds: Int) {
        self.deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
    }

    func setPaused(_ value: Bool) {
        lock.withLock { paused = value }
    }

    func extendAfterResume(seconds: Int) {
        lock.withLock {
            deadline = Date().addingTimeInterval(TimeInterval(seconds))
        }
    }

    func isExpired() -> Bool {
        lock.withLock { !paused && Date() >= deadline }
    }

    func markTimedOut() {
        lock.withLock { timedOut = true }
    }

    func didTimeOut() -> Bool {
        lock.withLock { timedOut }
    }
}

private final class AcpAccumulator: @unchecked Sendable {
    var accumulatedText = ""
    var latestDiff: String?
    var warmHoldApproved = false
    var rejectedByHuman = false
    var pendingSteerInstruction: String?
    var inputTokens = 0
    var outputTokens = 0
    var cachedTokens = 0
    var costUSD = 0.0

    func consumePendingSteer() -> String? {
        defer { pendingSteerInstruction = nil }
        return pendingSteerInstruction
    }

    func appendSeparatorBeforeSteer() {
        if !accumulatedText.isEmpty && !accumulatedText.hasSuffix("\n\n") {
            accumulatedText += "\n\n---\n"
        }
    }

    func ingestUsageIfPresent(_ dict: [String: Any]) {
        if let usage = dict["usage"] as? [String: Any] {
            inputTokens += (usage["inputTokens"] as? Int) ?? (usage["input_tokens"] as? Int) ?? (usage["input"] as? Int) ?? 0
            outputTokens += (usage["outputTokens"] as? Int) ?? (usage["output_tokens"] as? Int) ?? (usage["output"] as? Int) ?? 0
            cachedTokens += (usage["cachedReadTokens"] as? Int) ?? (usage["cache_read_input_tokens"] as? Int) ?? (usage["cacheRead"] as? Int) ?? 0
            if let costDict = usage["cost"] as? [String: Any], let total = costDict["total"] as? Double {
                costUSD += total
            } else if let c = usage["costUSD"] as? Double {
                costUSD += c
            }
        }
        if let c = (dict["costUSD"] as? Double) ?? (dict["total_cost_usd"] as? Double) {
            costUSD += c
        }
    }

    func ingestSessionUpdate(_ update: [String: Any]) -> (activity: String?, chunk: String?) {
        ingestUsageIfPresent(update)
        let kind = (update["sessionUpdate"] as? String) ?? ""
        switch kind {
        case "agent_message_chunk":
            if let content = update["content"] as? [String: Any],
               let txt = content["text"] as? String, !txt.isEmpty {
                accumulatedText += txt
                return ("输出结论中...", txt)
            }
        case "agent_thought_chunk", "thought_message_chunk":
            return ("思考推理中...", nil)
        case "tool_call", "tool_call_update":
            let title = (update["title"] as? String)
                ?? (update["toolCallId"] as? String)
                ?? "工具调用"
            let status = (update["status"] as? String) ?? "running"
            if let diff = Self.extractDiffFromToolCall(update) {
                latestDiff = diff
            }
            let prefix = status == "completed" ? "✓" : "⚡"
            return ("\(prefix) \(title)", nil)
        case "plan":
            if let entries = update["entries"] as? [[String: Any]],
               let active = entries.first(where: { ($0["status"] as? String) == "in_progress" }) ?? entries.first,
               let content = active["content"] as? String {
                return ("📋 \(content)", nil)
            }
        default:
            break
        }
        return (nil, nil)
    }

    static func extractDiffFromToolCall(_ obj: [String: Any]) -> String? {
        guard let contentArr = obj["content"] as? [[String: Any]] else { return nil }
        var blocks: [String] = []
        for item in contentArr where (item["type"] as? String) == "diff" {
            let path = (item["path"] as? String) ?? "file"
            let oldText = (item["oldText"] as? String) ?? ""
            let newText = (item["newText"] as? String) ?? ""
            var lines: [String] = ["--- a/\(path)", "+++ b/\(path)"]
            for l in oldText.split(separator: "\n", omittingEmptySubsequences: false).prefix(20) {
                lines.append("-\(l)")
            }
            for l in newText.split(separator: "\n", omittingEmptySubsequences: false).prefix(25) {
                lines.append("+\(l)")
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        return blocks.isEmpty ? nil : blocks.joined(separator: "\n\n")
    }
}

private final class AcpLineTransport: @unchecked Sendable {
    private let writeFD: Int32
    private let writeLock = NSLock()
    private var closed = false
    private var iterator: AsyncStream<[String: Any]>.AsyncIterator
    private let continuation: AsyncStream<[String: Any]>.Continuation

    init(readFD: Int32, writeFD: Int32) {
        self.writeFD = writeFD
        var cont: AsyncStream<[String: Any]>.Continuation!
        let stream = AsyncStream<[String: Any]> { c in cont = c }
        self.continuation = cont
        self.iterator = stream.makeAsyncIterator()

        let rfd = readFD
        let streamCont = cont!
        Thread.detachNewThread {
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 8192)
            while true {
                let n = Darwin.read(rfd, &chunk, chunk.count)
                if n > 0 {
                    buffer.append(chunk, count: n)
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer.subdata(in: 0..<nl)
                        buffer.removeSubrange(0...nl)
                        if !lineData.isEmpty,
                           let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                            streamCont.yield(obj)
                        }
                    }
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            Darwin.close(rfd)
            streamCont.finish()
        }
    }

    func nextMessage() async -> [String: Any]? {
        await iterator.next()
    }

    func sendJSON(_ dict: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: dict)
        var packet = data
        packet.append(0x0A)
        try writeLock.withLock {
            guard !closed, writeFD >= 0 else {
                throw NSError(domain: "AcpTransport", code: -10, userInfo: [NSLocalizedDescriptionKey: "ACP stdin closed"])
            }
            let ok = packet.withUnsafeBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return false }
                var written = 0
                while written < raw.count {
                    let n = Darwin.write(writeFD, base.advanced(by: written), raw.count - written)
                    if n > 0 {
                        written += n
                    } else if n < 0 && errno == EINTR {
                        continue
                    } else {
                        return false
                    }
                }
                return true
            }
            if !ok {
                throw NSError(domain: "AcpTransport", code: -11, userInfo: [NSLocalizedDescriptionKey: "ACP write failed"])
            }
        }
    }

    func closeWriteEnd() {
        writeLock.withLock {
            guard !closed else { return }
            closed = true
            if writeFD >= 0 { Darwin.close(writeFD) }
        }
        continuation.finish()
    }
}
