import Foundation
import FoundationModels

public enum TriageAction: String, Codable, Sendable {
    case ignore
    case digest
    case notifyOnly = "notify_only"
    case dispatchAgent = "dispatch_agent"
}

public struct TriageDecision: Codable, Sendable, Equatable {
    public let action: TriageAction
    public let matchedChimeID: String?
    public let workingDir: String?
    public let confidence: Double
    public let reason: String

    enum CodingKeys: String, CodingKey {
        case action
        case matchedChimeID = "matched_chime_id"
        case workingDir = "working_dir"
        case confidence
        case reason
    }

    public init(
        action: TriageAction,
        matchedChimeID: String? = nil,
        workingDir: String? = nil,
        confidence: Double = 1.0,
        reason: String = ""
    ) {
        self.action = action
        self.matchedChimeID = matchedChimeID
        self.workingDir = workingDir
        self.confidence = confidence
        self.reason = reason
    }
}

public struct TriageRequest: Codable, Sendable {
    public let event: EventEnvelope
    public let candidateRuleID: String
    public let candidateDescription: String
    public let workspaces: [WorkspaceEntry]

    enum CodingKeys: String, CodingKey {
        case event
        case candidateRuleID = "candidate_rule_id"
        case candidateDescription = "candidate_description"
        case workspaces
    }
}

public protocol TriageProvider: Sendable {
    var name: String { get }
    func classify(request: TriageRequest) async -> TriageDecision
}

/// Pass-through provider when deterministic L0 rules are trusted directly (`triage: none`).
public struct PassThroughTriageProvider: TriageProvider {
    public let name = "none"
    public init() {}

    public func classify(request: TriageRequest) async -> TriageDecision {
        TriageDecision(
            action: .dispatchAgent,
            matchedChimeID: request.candidateRuleID,
            workingDir: nil,
            confidence: 1.0,
            reason: "L0 deterministic rule matched (triage disabled)"
        )
    }
}

/// Calls an external HTTP decision gateway (e.g., user's `jev` / Decision API).
public struct DecisionAPITriageProvider: TriageProvider {
    public let name = "decision_api"
    private let endpoint: URL
    private let tokenEnvVar: String
    private let timeoutSeconds: TimeInterval
    private let paths: BianzhongPaths

    public init(
        endpoint: URL,
        tokenEnvVar: String = "BIANZHONG_DECISION_API_KEY",
        timeoutSeconds: TimeInterval = 4.0,
        paths: BianzhongPaths = BianzhongPaths()
    ) {
        self.endpoint = endpoint
        self.tokenEnvVar = tokenEnvVar
        self.timeoutSeconds = timeoutSeconds
        self.paths = paths
    }

    public func classify(request: TriageRequest) async -> TriageDecision {
        var urlRequest = URLRequest(url: endpoint, timeoutInterval: timeoutSeconds)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = SecretStore.resolve(tokenEnvVar, paths: paths), !token.isEmpty {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            urlRequest.httpBody = try JSONEncoder().encode(request)
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return TriageDecision(
                    action: .digest,
                    matchedChimeID: request.candidateRuleID,
                    confidence: 0.0,
                    reason: "Decision API returned non-2xx; deferred to digest"
                )
            }
            if let decoded = try? JSONDecoder().decode(TriageDecision.self, from: data) {
                return decoded
            }
            return parseDecisionJSON(from: String(data: data, encoding: .utf8) ?? "", fallbackRuleID: request.candidateRuleID)
        } catch {
            return TriageDecision(
                action: .digest,
                matchedChimeID: request.candidateRuleID,
                confidence: 0.0,
                reason: "Decision API error: \(error.localizedDescription)"
            )
        }
    }
}

/// Reuses the user's own `omp` or `codex` CLI pinned to a cheap model with tools disabled.
public struct AgentCLITriageProvider: TriageProvider {
    public let name = "agent_cli"
    private let driverName: String
    private let model: String?

    public init(driverName: String = "omp", model: String? = "smol") {
        self.driverName = driverName
        self.model = model
    }

    public func classify(request: TriageRequest) async -> TriageDecision {
        let prompt = buildTriagePrompt(for: request)
        let executable: String
        var args: [String] = []
        let stdinData: Data?
        let promptFileText: String?

        if driverName == "codex" {
            executable = AgentDriverRegistry.resolveBinary(name: "codex") ?? "/Users/blizhan/.local/bin/codex"
            args = ["exec", "--ephemeral", "--skip-git-repo-check", "-s", "read-only"]
            if let model, !model.isEmpty {
                args += ["-m", model]
            }
            args += ["-c", "approval_policy=\"never\"", "-"]
            stdinData = Data(prompt.utf8)
            promptFileText = nil
        } else {
            executable = AgentDriverRegistry.resolveBinary(name: "omp") ?? "/Users/blizhan/.local/bin/omp"
            args = ["-p", "--no-tools", "--no-extensions", "--no-skills", "--no-rules", "--no-context-files", "--no-session", "--no-title", "--thinking=off", "--max-time=20"]
            if let model, !model.isEmpty {
                args += ["--model=\(model)"]
            }
            stdinData = nil
            promptFileText = prompt
        }

        let spec = SpawnSpec(
            executablePath: executable,
            arguments: args,
            environment: ["BIANZHONG_DEPTH": "1"],
            stdinData: stdinData,
            promptFileText: promptFileText,
            workingDirectory: FileManager.default.temporaryDirectory.path
        )
        let result = await AgentProcessRunner.run(spec: spec, timeoutSeconds: 25)
        return parseDecisionJSON(from: result.stdout, fallbackRuleID: request.candidateRuleID)
    }
}

/// On-device macOS 26 FoundationModels classifier (`0` API cost, sensitive text stays local).
public struct AppleFMTriageProvider: TriageProvider {
    public let name = "apple_fm"
    public init() {}

    public func classify(request: TriageRequest) async -> TriageDecision {
        guard SystemLanguageModel.default.isAvailable else {
            return TriageDecision(
                action: .dispatchAgent,
                matchedChimeID: request.candidateRuleID,
                confidence: 0.5,
                reason: "Apple FoundationModels unavailable; fallback dispatch"
            )
        }

        let instructions = """
        You are Bianzhong L1 event triage. Output ONLY raw JSON without markdown fences:
        {"action":"ignore|digest|notify_only|dispatch_agent","matched_chime_id":"string or null","working_dir":"string or null","confidence":0.0,"reason":"short string"}
        Choose ignore for casual chatter/acks, digest for FYI announcements, notify_only for simple reminders, dispatch_agent only for actionable engineering or issue investigation.
        """
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: buildTriagePrompt(for: request))
            return parseDecisionJSON(from: response.content, fallbackRuleID: request.candidateRuleID)
        } catch {
            return TriageDecision(
                action: .digest,
                matchedChimeID: request.candidateRuleID,
                confidence: 0.0,
                reason: "Apple FM error: \(error.localizedDescription)"
            )
        }
    }
}

public enum TriageProviderFactory {
    public static func make(config: AppConfig, override: String?, paths: BianzhongPaths = BianzhongPaths()) -> any TriageProvider {
        let choice = (override ?? config.triageProvider).lowercased()
        switch choice {
        case "decision_api", "jev":
            if let urlString = config.decisionAPIURL, let url = URL(string: urlString) {
                return DecisionAPITriageProvider(
                    endpoint: url,
                    tokenEnvVar: config.decisionAPIKeyEnv,
                    timeoutSeconds: config.decisionAPITimeoutSeconds,
                    paths: paths
                )
            }
            return PassThroughTriageProvider()
        case "agent_cli":
            return AgentCLITriageProvider(driverName: config.agentCLIDriver, model: config.agentCLIModel)
        case "apple_fm":
            return AppleFMTriageProvider()
        default:
            return PassThroughTriageProvider()
        }
    }
}

// MARK: - Shared Prompt & JSON Parsing

private func buildTriagePrompt(for request: TriageRequest) -> String {
    let wsList = request.workspaces.map { "- \($0.name): \($0.path) (\($0.summary))" }.joined(separator: "\n")
    return """
    Rule ID: \(request.candidateRuleID)
    Rule Description: \(request.candidateDescription)
    Event Type: \(request.event.type)
    Correlation Key: \(request.event.correlationKey)
    Title: \(request.event.payload["title"] ?? "")
    Subtitle: \(request.event.payload["subtitle"] ?? "")
    Body:
    \(request.event.payload["body"] ?? request.event.payload["summary"] ?? "")

    Candidate Workspaces:
    \(wsList.isEmpty ? "(none)" : wsList)

    Return strictly one JSON object:
    {"action":"ignore|digest|notify_only|dispatch_agent","matched_chime_id":"\(request.candidateRuleID)","working_dir":null,"confidence":0.8,"reason":"..."}
    """
}

private func parseDecisionJSON(from text: String, fallbackRuleID: String) -> TriageDecision {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") {
        let slice = String(trimmed[start...end])
        if let data = slice.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(TriageDecision.self, from: data) {
            return decoded
        }
    }
    return TriageDecision(
        action: .digest,
        matchedChimeID: fallbackRuleID,
        confidence: 0.2,
        reason: "Unparseable triage output; deferred safely to digest"
    )
}
