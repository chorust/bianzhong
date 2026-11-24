import Darwin
import Foundation

public enum AgentPermissionProfile: String, Codable, Sendable {
    case noTools
    case readOnly
    case workspaceRW
}

public struct AgentInvocationRequest: Sendable {
    public let runID: String
    public let correlationKey: String
    public let workingDirectory: String
    public let promptText: String
    public let eventFilePath: String
    public let sessionDir: String
    public let permissionProfile: AgentPermissionProfile
    public let modelOverride: String?
    public let resumeSessionID: String?
    public let worktreeRequested: Bool
    public let ephemeral: Bool
    public let maxTimeSeconds: Int
    public let maxCostUSD: Double?

    public init(
        runID: String,
        correlationKey: String,
        workingDirectory: String,
        promptText: String,
        eventFilePath: String,
        sessionDir: String,
        permissionProfile: AgentPermissionProfile,
        modelOverride: String? = nil,
        resumeSessionID: String? = nil,
        worktreeRequested: Bool = false,
        ephemeral: Bool = false,
        maxTimeSeconds: Int = 180,
        maxCostUSD: Double? = nil
    ) {
        self.runID = runID
        self.correlationKey = correlationKey
        self.workingDirectory = workingDirectory
        self.promptText = promptText
        self.eventFilePath = eventFilePath
        self.sessionDir = sessionDir
        self.permissionProfile = permissionProfile
        self.modelOverride = modelOverride
        self.resumeSessionID = resumeSessionID
        self.worktreeRequested = worktreeRequested
        self.ephemeral = ephemeral
        self.maxTimeSeconds = maxTimeSeconds
        self.maxCostUSD = maxCostUSD
    }
}

public struct SpawnSpec: Sendable, Equatable {
    public let executablePath: String
    public let arguments: [String]
    public let environment: [String: String]
    public let stdinData: Data?
    public let promptFileText: String?
    public let workingDirectory: String

    public init(
        executablePath: String,
        arguments: [String],
        environment: [String: String] = [:],
        stdinData: Data? = nil,
        promptFileText: String? = nil,
        workingDirectory: String
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.stdinData = stdinData
        self.promptFileText = promptFileText
        self.workingDirectory = workingDirectory
    }
}

public enum NormalizedAgentEvent: Sendable, Equatable {
    case sessionStarted(externalSessionID: String)
    case textDelta(chunk: String)
    case toolActivity(name: String, status: String)
    case usageReported(input: Int, output: Int, cached: Int, costUSD: Double?)
    case finalAnswer(text: String)
    case error(message: String, isBudgetOrTimeout: Bool)
}

public protocol AgentDriver: Sendable {
    var id: String { get }
    func buildSpawnSpec(request: AgentInvocationRequest) -> SpawnSpec
    func parseStdoutLine(_ line: String) -> [NormalizedAgentEvent]
    func isSuccessExit(exitCode: Int32, lastEvents: [NormalizedAgentEvent]) -> Bool
    func buildTakeoverCommand(sessionID: String, sessionDir: String, workingDirectory: String) -> String
}

/// Driver for Oh-My-Pi (`omp v19.1.1`) verified CLI flags & JSONL stream.
public struct OmpDriver: AgentDriver {
    public let id = "omp"
    private let executablePath: String

    public init(executablePath: String? = nil) {
        self.executablePath = executablePath ?? AgentDriverRegistry.resolveBinary(name: "omp") ?? "/Users/blizhan/.local/bin/omp"
    }

    public func buildSpawnSpec(request: AgentInvocationRequest) -> SpawnSpec {
        var args: [String] = ["-p", "--mode=json", "--no-title", "--cwd", request.workingDirectory]

        if request.ephemeral {
            args.append("--no-session")
        } else {
            args += ["--session-dir", request.sessionDir]
        }

        if let resumeID = request.resumeSessionID, !resumeID.isEmpty {
            args += ["-r", resumeID]
        }

        switch request.permissionProfile {
        case .noTools:
            args += ["--no-tools", "--no-extensions", "--no-skills", "--no-rules", "--no-context-files", "--thinking=off"]
        case .readOnly:
            args += ["--tools=read,grep,glob", "--no-extensions"]
        case .workspaceRW:
            args += ["--tools=read,grep,glob,edit,write,bash", "--auto-approve"]
        }

        if let model = request.modelOverride, !model.isEmpty {
            args += ["--model", model]
        }
        if request.maxTimeSeconds > 0 {
            args += ["--max-time", "\(request.maxTimeSeconds)"]
        }
        if let cost = request.maxCostUSD, cost > 0 {
            args += ["--max-cost", String(format: "%.2f", cost)]
        }

        let env = [
            "BIANZHONG_RUN_ID": request.runID,
            "BIANZHONG_EVENT_FILE": request.eventFilePath,
            "BIANZHONG_CORRELATION_KEY": request.correlationKey,
            "BIANZHONG_DEPTH": "1"
        ]

        return SpawnSpec(
            executablePath: executablePath,
            arguments: args,
            environment: env,
            stdinData: nil,
            promptFileText: request.promptText,
            workingDirectory: request.workingDirectory
        )
    }

    public func parseStdoutLine(_ line: String) -> [NormalizedAgentEvent] {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            return []
        }

        var events: [NormalizedAgentEvent] = []
        switch type {
        case "session":
            if let sid = obj["id"] as? String {
                events.append(.sessionStarted(externalSessionID: sid))
            }
        case "message_end":
            if let msg = obj["message"] as? [String: Any], (msg["role"] as? String) == "assistant" {
                let text = extractAssistantText(msg["content"])
                if !text.isEmpty {
                    events.append(.finalAnswer(text: text))
                }
                if let usage = msg["usage"] as? [String: Any] {
                    let input = usage["input"] as? Int ?? 0
                    let output = usage["output"] as? Int ?? 0
                    let cached = usage["cacheRead"] as? Int ?? 0
                    let cost = (usage["cost"] as? [String: Any])?["total"] as? Double
                    events.append(.usageReported(input: input, output: output, cached: cached, costUSD: cost))
                }
            }
        case "tool_execution_start":
            if let name = obj["toolName"] as? String {
                events.append(.toolActivity(name: name, status: "running"))
            }
        case "error":
            if let msg = obj["message"] as? String {
                events.append(.error(message: msg, isBudgetOrTimeout: false))
            }
        default:
            break
        }
        return events
    }

    public func isSuccessExit(exitCode: Int32, lastEvents: [NormalizedAgentEvent]) -> Bool {
        exitCode == 0
    }

    public func buildTakeoverCommand(sessionID: String, sessionDir: String, workingDirectory: String) -> String {
        "cd \(shellQuote(workingDirectory)) && \(shellQuote(executablePath)) -r \(shellQuote(sessionID)) --session-dir \(shellQuote(sessionDir))"
    }

    private func extractAssistantText(_ content: Any?) -> String {
        if let str = content as? String { return str }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
    }
}

/// Driver for OpenAI Codex CLI (`codex-cli 0.172.0`) respecting `exec fork --worktree` boundaries.
public struct CodexDriver: AgentDriver {
    public let id = "codex"
    private let executablePath: String

    public init(executablePath: String? = nil) {
        self.executablePath = executablePath ?? AgentDriverRegistry.resolveBinary(name: "codex") ?? "/Users/blizhan/.local/bin/codex"
    }

    public func buildSpawnSpec(request: AgentInvocationRequest) -> SpawnSpec {
        var args: [String] = []

        if let resumeID = request.resumeSessionID, !resumeID.isEmpty, request.permissionProfile == .workspaceRW {
            // `codex exec resume` rejects `--worktree` and `-s`, so use `exec fork <id> --worktree`
            // when isolated write execution is requested.
            if request.worktreeRequested {
                args = ["exec", "fork", resumeID, "--worktree", "-c", "sandbox_mode=\"workspace-write\"", "-c", "approval_policy=\"never\"", "--json"]
            } else {
                args = ["exec", "resume", resumeID, "-c", "sandbox_mode=\"workspace-write\"", "-c", "approval_policy=\"never\"", "--json"]
            }
        } else {
            args = ["exec", "--json", "--skip-git-repo-check", "-C", request.workingDirectory, "-c", "approval_policy=\"never\""]
            if request.ephemeral {
                args.append("--ephemeral")
            }
            switch request.permissionProfile {
            case .noTools, .readOnly:
                args += ["-s", "read-only"]
            case .workspaceRW:
                args += ["-s", "workspace-write"]
                if request.worktreeRequested {
                    args.append("--worktree")
                }
            }
        }

        if let model = request.modelOverride, !model.isEmpty {
            args += ["-m", model]
        }

        // Pass prompt via stdin (`-`) to keep large contexts out of `ps` argv
        args.append("-")

        let env = [
            "BIANZHONG_RUN_ID": request.runID,
            "BIANZHONG_EVENT_FILE": request.eventFilePath,
            "BIANZHONG_CORRELATION_KEY": request.correlationKey,
            "BIANZHONG_DEPTH": "1"
        ]

        return SpawnSpec(
            executablePath: executablePath,
            arguments: args,
            environment: env,
            stdinData: request.promptText.data(using: .utf8),
            workingDirectory: request.workingDirectory
        )
    }

    public func parseStdoutLine(_ line: String) -> [NormalizedAgentEvent] {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            return []
        }

        var events: [NormalizedAgentEvent] = []
        switch type {
        case "thread.started":
            if let tid = obj["thread_id"] as? String {
                events.append(.sessionStarted(externalSessionID: tid))
            }
        case "item.completed":
            if let item = obj["item"] as? [String: Any], (item["type"] as? String) == "agent_message",
               let text = item["text"] as? String {
                events.append(.finalAnswer(text: text))
            }
        case "turn.completed":
            if let usage = obj["usage"] as? [String: Any] {
                let input = usage["input_tokens"] as? Int ?? 0
                let output = usage["output_tokens"] as? Int ?? 0
                let cached = usage["cached_input_tokens"] as? Int ?? 0
                events.append(.usageReported(input: input, output: output, cached: cached, costUSD: nil))
            }
        case "error":
            if let msg = obj["message"] as? String {
                events.append(.error(message: msg, isBudgetOrTimeout: false))
            }
        default:
            break
        }
        return events
    }

    public func isSuccessExit(exitCode: Int32, lastEvents: [NormalizedAgentEvent]) -> Bool {
        exitCode == 0
    }

    public func buildTakeoverCommand(sessionID: String, sessionDir: String, workingDirectory: String) -> String {
        "cd \(shellQuote(workingDirectory)) && \(shellQuote(executablePath)) resume \(shellQuote(sessionID))"
    }
}

public enum AgentDriverRegistry {
    private final class RegistryStorage: @unchecked Sendable {
        let lock = NSLock()
        var customDrivers: [String: any AgentDriver] = [:]
    }

    private static let storage = RegistryStorage()

    public static func register(_ driver: any AgentDriver) {
        storage.lock.withLock {
            storage.customDrivers[driver.id.lowercased()] = driver
        }
    }

    public static func unregister(id: String) {
        storage.lock.withLock {
            _ = storage.customDrivers.removeValue(forKey: id.lowercased())
        }
    }

    public static func driver(named name: String) -> any AgentDriver {
        let key = name.lowercased()
        if let custom = storage.lock.withLock({ storage.customDrivers[key] }) {
            return custom
        }
        switch key {
        case "codex":
            return CodexDriver()
        default:
            return OmpDriver()
        }
    }

    public static func resolveBinary(name: String) -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)"
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = "\(dir)/\(name)"
                if fm.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return nil
    }
}

public struct ProcessRunResult: Sendable {
    public let pid: Int32
    public let pgid: Int32
    public let exitCode: Int32
    public let timedOut: Bool
    public let stdout: String
    public let stderr: String
}

/// Spawns external agent subprocesses in an isolated process group (`pgid == pid`)
/// with bounded wall-clock execution and clean `SIGTERM -> SIGKILL` group teardown.
public enum AgentProcessRunner {
    public static func run(spec: SpawnSpec, timeoutSeconds: Int) async -> ProcessRunResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = runSync(spec: spec, timeoutSeconds: timeoutSeconds)
                continuation.resume(returning: result)
            }
        }
    }

    private static func runSync(spec: SpawnSpec, timeoutSeconds: Int) -> ProcessRunResult {
        var tempPromptPath: String?
        if let promptText = spec.promptFileText {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("bz-prompt-\(UUID().uuidString).txt")
                .path
            let fd = Darwin.open(path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
            guard fd >= 0 else {
                return ProcessRunResult(
                    pid: -1,
                    pgid: -1,
                    exitCode: -1,
                    timedOut: false,
                    stdout: "",
                    stderr: "Failed to create prompt temp file"
                )
            }
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
            let data = Data(promptText.utf8)
            let wroteAll = data.withUnsafeBytes { raw -> Bool in
                guard let base = raw.baseAddress, raw.count > 0 else { return true }
                return writeAllIgnoringPipe(fd: fd, buffer: base, length: raw.count)
            }
            Darwin.close(fd)
            if !wroteAll {
                Darwin.unlink(path)
                return ProcessRunResult(
                    pid: -1,
                    pgid: -1,
                    exitCode: -1,
                    timedOut: false,
                    stdout: "",
                    stderr: "Failed to write prompt temp file"
                )
            }
            tempPromptPath = path
        }
        defer {
            if let tempPromptPath {
                Darwin.unlink(tempPromptPath)
            }
        }

        var stdinPipe: [Int32] = [-1, -1]
        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]

        guard pipe(&stdinPipe) == 0, pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            for fd in [stdinPipe[0], stdinPipe[1], stdoutPipe[0], stdoutPipe[1], stderrPipe[0], stderrPipe[1]] where fd >= 0 {
                close(fd)
            }
            return ProcessRunResult(pid: -1, pgid: -1, exitCode: -1, timedOut: false, stdout: "", stderr: "Failed to create pipes")
        }
        _ = fcntl(stdinPipe[1], F_SETNOSIGPIPE, 1)

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        posix_spawn_file_actions_adddup2(&fileActions, stdinPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, stderrPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, stdinPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, stdinPipe[1])
        posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[1])
        posix_spawn_file_actions_addclose(&fileActions, stderrPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, stderrPipe[1])
        posix_spawn_file_actions_addchdir(&fileActions, spec.workingDirectory)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)

        var mergedEnv = ProcessInfo.processInfo.environment
        for (k, v) in spec.environment {
            mergedEnv[k] = v
        }

        var argvStrings = [spec.executablePath] + spec.arguments
        if let tempPromptPath {
            argvStrings.append("@\(tempPromptPath)")
        }
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
            return ProcessRunResult(
                pid: -1,
                pgid: -1,
                exitCode: spawnRC,
                timedOut: false,
                stdout: "",
                stderr: "posix_spawn failed (\(spawnRC)): \(String(cString: strerror(spawnRC)))"
            )
        }

        final class DataBox: @unchecked Sendable {
            var value = Data()
        }

        let stdoutBox = DataBox()
        let stderrBox = DataBox()
        let group = DispatchGroup()

        let stdoutReadFD = stdoutPipe[0]
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutBox.value = readAllFD(stdoutReadFD)
            close(stdoutReadFD)
            group.leave()
        }

        let stderrReadFD = stderrPipe[0]
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrBox.value = readAllFD(stderrReadFD)
            close(stderrReadFD)
            group.leave()
        }

        if let stdinData = spec.stdinData, !stdinData.isEmpty {
            let stdinWriteFD = stdinPipe[1]
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                _ = stdinData.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress, raw.count > 0 else { return true }
                    return writeAllIgnoringPipe(fd: stdinWriteFD, buffer: base, length: raw.count)
                }
                close(stdinWriteFD)
                group.leave()
            }
        } else {
            close(stdinPipe[1])
        }

        var timedOut = false
        let deadline = Date().addingTimeInterval(TimeInterval(max(1, timeoutSeconds)))
        var status: Int32 = 0

        while true {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid || waited == -1 {
                break
            }
            if Date() >= deadline {
                timedOut = true
                kill(-pid, SIGTERM)
                Thread.sleep(forTimeInterval: 1.0)
                if waitpid(pid, &status, WNOHANG) == 0 {
                    kill(-pid, SIGKILL)
                    waitpid(pid, &status, 0)
                }
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        _ = group.wait(timeout: .now() + 2.0)

        let exitCode: Int32
        if timedOut {
            exitCode = 124
        } else if (status & 0x7f) == 0 {
            exitCode = (status >> 8) & 0xff
        } else {
            exitCode = 128 + (status & 0x7f)
        }

        return ProcessRunResult(
            pid: pid,
            pgid: pid,
            exitCode: exitCode,
            timedOut: timedOut,
            stdout: String(data: stdoutBox.value, encoding: .utf8) ?? "",
            stderr: String(data: stderrBox.value, encoding: .utf8) ?? ""
        )
    }

    private static func readAllFD(_ fd: Int32) -> Data {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n > 0 {
                data.append(buf, count: n)
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        return data
    }

    @discardableResult
    private static func writeAllIgnoringPipe(fd: Int32, buffer: UnsafeRawPointer, length: Int) -> Bool {
        var written = 0
        while written < length {
            let n = Darwin.write(fd, buffer.advanced(by: written), length - written)
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
}

public func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
