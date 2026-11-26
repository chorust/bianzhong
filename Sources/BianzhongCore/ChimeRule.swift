import Foundation

public enum SessionPolicy: String, Codable, Sendable {
    case ephemeral
    case threaded
    case rollingDaily = "rolling_daily"
}

public enum AutonomyMode: String, Codable, Sendable {
    case observeDigest = "observe_digest"
    case notify
    case draftApprove = "draft_approve"
    case boundedAuto = "bounded_auto"
}

public enum CountWindow: Codable, Sendable, Equatable {
    case daily
    case sliding(seconds: Int)

    public var displayLabel: String {
        switch self {
        case .daily:
            return "当日"
        case .sliding(let sec):
            if sec % 86400 == 0 { return "\(sec / 86400)d" }
            if sec % 3600 == 0 { return "\(sec / 3600)h" }
            if sec % 60 == 0 { return "\(sec / 60)m" }
            return "\(sec)s"
        }
    }
}

public enum CountScope: String, Codable, Sendable, Equatable {
    case rule
    case correlation
}

/// Watchdog specification for "expected signal did not arrive within time window".
public struct ExpectWindowSpec: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// Local wall-clock window start in `HH:mm` (e.g. `"09:00"`).
    public var windowStart: String
    /// Local wall-clock window end in `HH:mm` (e.g. `"09:30"`).
    public var windowEnd: String
    /// ISO weekdays `1...7` (`1 = Monday ... 7 = Sunday`). Empty means every day.
    public var weekdays: [Int]
    /// When `true` (default), a matching signal inside the window satisfies the expectation without triggering the missed-signal action.
    public var suppressOnMatch: Bool
    /// Optional grace period after `windowEnd` before firing missed-signal action.
    public var graceSeconds: Int

    public init(
        enabled: Bool = true,
        windowStart: String,
        windowEnd: String,
        weekdays: [Int] = [],
        suppressOnMatch: Bool = true,
        graceSeconds: Int = 0
    ) {
        self.enabled = enabled
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.weekdays = weekdays
        self.suppressOnMatch = suppressOnMatch
        self.graceSeconds = max(0, graceSeconds)
    }

    public var displayLabel: String {
        "\(windowStart)–\(windowEnd)"
    }
}

public struct WorkspaceEntry: Codable, Sendable, Equatable {
    public let name: String
    public let path: String
    public let summary: String

    public init(name: String, path: String, summary: String) {
        self.name = name
        self.path = path
        self.summary = summary
    }
}

public enum ActionType: String, Codable, Sendable, Equatable {
    case notify
    case webhook
    case shortcut
    case appendMarkdown = "append_markdown"
    case shell
    case clipboard
    case chimeSound = "chime_sound"
}

public struct ActionSpec: Codable, Sendable, Equatable {
    public var type: ActionType
    public var whenCondition: String?
    public var preset: String?
    public var url: String?
    public var urlEnv: String?
    public var secretEnv: String?
    public var tokenEnv: String?
    public var chatID: String?
    public var path: String?
    public var name: String?
    public var command: String?
    public var template: String?
    public var tts: Bool

    enum CodingKeys: String, CodingKey {
        case type
        case whenCondition = "when"
        case preset
        case url
        case urlEnv = "url_env"
        case secretEnv = "secret_env"
        case tokenEnv = "token_env"
        case chatID = "chat_id"
        case path
        case name
        case command = "cmd"
        case template
        case tts
    }

    public init(
        type: ActionType,
        whenCondition: String? = nil,
        preset: String? = nil,
        url: String? = nil,
        urlEnv: String? = nil,
        secretEnv: String? = nil,
        tokenEnv: String? = nil,
        chatID: String? = nil,
        path: String? = nil,
        name: String? = nil,
        command: String? = nil,
        template: String? = nil,
        tts: Bool = false
    ) {
        self.type = type
        self.whenCondition = whenCondition
        self.preset = preset
        self.url = url
        self.urlEnv = urlEnv
        self.secretEnv = secretEnv
        self.tokenEnv = tokenEnv
        self.chatID = chatID
        self.path = path
        self.name = name
        self.command = command
        self.template = template
        self.tts = tts
    }
}

/// Global Bianzhong configuration loaded from `~/.config/bianzhong/config.yml`.
public struct AppConfig: Sendable, Equatable {
    public var triageProvider: String
    public var decisionAPIURL: String?
    public var decisionAPIKeyEnv: String
    public var decisionAPITimeoutSeconds: Double
    public var agentCLIDriver: String
    public var agentCLIModel: String?
    public var terminal: String
    public var feishuSensorEnabled: Bool
    public var webhookServerEnabled: Bool
    public var webhookHost: String
    public var webhookPort: Int
    public var webhookCallbackBaseURL: String?
    public var maxConcurrentRuns: Int
    public var maxCausalDepth: Int
    public var dailyMaxCostUSD: Double
    public var dailyMaxRuns: Int
    public var circuitBreakerFailures: Int
    public var retentionDays: Int
    public var workspaces: [WorkspaceEntry]

    public init(
        triageProvider: String = "apple_fm",
        decisionAPIURL: String? = nil,
        decisionAPIKeyEnv: String = "BIANZHONG_DECISION_API_KEY",
        decisionAPITimeoutSeconds: Double = 4.0,
        agentCLIDriver: String = "omp",
        agentCLIModel: String? = "smol",
        terminal: String = "auto",
        feishuSensorEnabled: Bool = true,
        webhookServerEnabled: Bool = true,
        webhookHost: String = "127.0.0.1",
        webhookPort: Int = 17380,
        webhookCallbackBaseURL: String? = nil,
        maxConcurrentRuns: Int = 2,
        maxCausalDepth: Int = 1,
        dailyMaxCostUSD: Double = 3.0,
        dailyMaxRuns: Int = 30,
        circuitBreakerFailures: Int = 3,
        retentionDays: Int = 7,
        workspaces: [WorkspaceEntry] = []
    ) {
        self.triageProvider = triageProvider
        self.decisionAPIURL = decisionAPIURL
        self.decisionAPIKeyEnv = decisionAPIKeyEnv
        self.decisionAPITimeoutSeconds = decisionAPITimeoutSeconds
        self.agentCLIDriver = agentCLIDriver
        self.agentCLIModel = agentCLIModel
        self.terminal = terminal
        self.feishuSensorEnabled = feishuSensorEnabled
        self.webhookServerEnabled = webhookServerEnabled
        self.webhookHost = webhookHost
        self.webhookPort = webhookPort
        self.webhookCallbackBaseURL = webhookCallbackBaseURL
        self.maxConcurrentRuns = maxConcurrentRuns
        self.maxCausalDepth = maxCausalDepth
        self.dailyMaxCostUSD = dailyMaxCostUSD
        self.dailyMaxRuns = dailyMaxRuns
        self.circuitBreakerFailures = circuitBreakerFailures
        self.retentionDays = retentionDays
        self.workspaces = workspaces
    }

    public static func load(from url: URL) -> AppConfig {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return AppConfig()
        }
        return parse(yaml: content)
    }

    /// Minimal indentation-aware YAML subset parser for `config.yml`.
    public static func parse(yaml: String) -> AppConfig {
        var config = AppConfig()
        var section = ""
        var currentWorkspace: [String: String] = [:]

        func flushWorkspace() {
            if let path = currentWorkspace["path"], !path.isEmpty {
                let name = currentWorkspace["name"] ?? URL(fileURLWithPath: path).lastPathComponent
                let summary = currentWorkspace["summary"] ?? ""
                config.workspaces.append(WorkspaceEntry(name: name, path: expandTilde(path), summary: summary))
            }
            currentWorkspace = [:]
        }

        for rawLine in splitLines(yaml) {
            let trimmed = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let indent = rawLine.prefix { $0 == " " }.count

            if indent == 0 {
                flushWorkspace()
                if trimmed.hasSuffix(":") {
                    section = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
                    continue
                }
                section = ""
                if let (k, v) = splitKeyValue(trimmed) {
                    applyGlobal(k, v, to: &config)
                }
                continue
            }

            if section == "workspaces" {
                if trimmed.hasPrefix("- ") {
                    flushWorkspace()
                    let rest = String(trimmed.dropFirst(2))
                    if let (k, v) = splitKeyValue(rest) {
                        currentWorkspace[k] = unquote(v)
                    }
                } else if let (k, v) = splitKeyValue(trimmed) {
                    currentWorkspace[k] = unquote(v)
                }
                continue
            }

            if let (k, v) = splitKeyValue(trimmed) {
                switch section {
                case "triage":
                    applyTriage(k, v, to: &config)
                case "webhook_server", "webhook":
                    applyWebhookServer(k, v, to: &config)
                case "governance":
                    applyGlobal(k, v, to: &config)
                default:
                    applyGlobal(k, v, to: &config)
                }
            }
        }

        flushWorkspace()
        return config
    }

    private static func applyGlobal(_ key: String, _ value: String, to config: inout AppConfig) {
        let val = unquote(value)
        switch key {
        case "terminal": config.terminal = val
        case "feishu_sensor_enabled": config.feishuSensorEnabled = parseBool(val, default: config.feishuSensorEnabled)
        case "webhook_server_enabled": config.webhookServerEnabled = parseBool(val, default: config.webhookServerEnabled)
        case "webhook_host": config.webhookHost = val.isEmpty ? config.webhookHost : val
        case "webhook_port": config.webhookPort = max(0, min(65535, Int(val) ?? config.webhookPort))
        case "webhook_callback_base_url": config.webhookCallbackBaseURL = (val.isEmpty || val == "null") ? nil : val
        case "max_concurrent_runs": config.maxConcurrentRuns = max(1, Int(val) ?? config.maxConcurrentRuns)
        case "max_causal_depth": config.maxCausalDepth = max(1, Int(val) ?? config.maxCausalDepth)
        case "daily_max_cost_usd": config.dailyMaxCostUSD = max(0, Double(val) ?? config.dailyMaxCostUSD)
        case "daily_max_runs": config.dailyMaxRuns = max(1, Int(val) ?? config.dailyMaxRuns)
        case "circuit_breaker_failures": config.circuitBreakerFailures = max(1, Int(val) ?? config.circuitBreakerFailures)
        case "retention_days": config.retentionDays = max(1, Int(val) ?? config.retentionDays)
        default: break
        }
    }

    private static func applyWebhookServer(_ key: String, _ value: String, to config: inout AppConfig) {
        let val = unquote(value)
        switch key {
        case "enabled": config.webhookServerEnabled = parseBool(val, default: config.webhookServerEnabled)
        case "host", "bind_host": config.webhookHost = val.isEmpty ? config.webhookHost : val
        case "port": config.webhookPort = max(0, min(65535, Int(val) ?? config.webhookPort))
        case "callback_base_url": config.webhookCallbackBaseURL = (val.isEmpty || val == "null") ? nil : val
        default: break
        }
    }

    /// Serializes and writes the complete `AppConfig` cleanly to `~/.config/bianzhong/config.yml`.
    public static func save(_ config: AppConfig, to configFile: URL) throws {
        var out: [String] = [
            "# Bianzhong（编钟）全局配置 (~/.config/bianzhong/config.yml)",
            "terminal: \(yamlScalar(config.terminal))",
            "feishu_sensor_enabled: \(config.feishuSensorEnabled)",
            "max_concurrent_runs: \(config.maxConcurrentRuns)",
            "max_causal_depth: \(config.maxCausalDepth)",
            "",
            "# 入站 HTTP Webhook 网关（默认仅监听本机 127.0.0.1，Bearer Token 存于安全密钥库）",
            "webhook_server:",
            "  enabled: \(config.webhookServerEnabled)",
            "  host: \(yamlScalar(config.webhookHost))",
            "  port: \(config.webhookPort)",
            "  callback_base_url: \(config.webhookCallbackBaseURL.map(yamlScalar) ?? "null")",
            "",
            "# 全局预算、熔断与自动清理治理",
            "governance:",
            "  daily_max_cost_usd: \(String(format: "%.2f", config.dailyMaxCostUSD))",
            "  daily_max_runs: \(config.dailyMaxRuns)",
            "  circuit_breaker_failures: \(config.circuitBreakerFailures)",
            "  retention_days: \(config.retentionDays)",
            "",
            "# L1 语义分诊器（当 chime 启用 triage 时生效）",
            "triage:",
            "  provider: \(yamlScalar(config.triageProvider))",
            "  decision_api_url: \(config.decisionAPIURL.map(yamlScalar) ?? "null")",
            "  decision_api_key_env: \(yamlScalar(config.decisionAPIKeyEnv))",
            "  decision_api_timeout_seconds: \(String(format: "%.1f", config.decisionAPITimeoutSeconds))",
            "  agent_cli_driver: \(yamlScalar(config.agentCLIDriver))",
            "  agent_cli_model: \(config.agentCLIModel.map(yamlScalar) ?? "null")",
            ""
        ]

        if config.workspaces.isEmpty {
            out.append("workspaces: []")
        } else {
            out.append("# 候选本地工作区目录（供 L1 语义分诊或规则参考）")
            out.append("workspaces:")
            for ws in config.workspaces {
                out.append("  - name: \(yamlScalar(ws.name))")
                out.append("    path: \(yamlScalar(ws.path))")
                out.append("    summary: \(yamlQuote(ws.summary))")
            }
        }
        out.append("")

        try FileManager.default.createDirectory(at: configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try out.joined(separator: "\n").write(to: configFile, atomically: true, encoding: .utf8)
    }

    /// Updates or inserts `terminal` at top level inside `config.yml` without disturbing nested keys or comments.
    public static func setTerminal(_ terminal: String, in configFile: URL) throws {
        try setTopLevelScalar(key: "terminal", renderedValue: yamlScalar(terminal), in: configFile)
    }

    /// Updates or inserts `feishu_sensor_enabled` at top level inside `config.yml` without disturbing nested keys or comments.
    public static func setFeishuSensorEnabled(_ enabled: Bool, in configFile: URL) throws {
        try setTopLevelScalar(key: "feishu_sensor_enabled", renderedValue: "\(enabled)", in: configFile)
    }

    private static func setTopLevelScalar(key: String, renderedValue: String, in configFile: URL) throws {
        let existing = (try? String(contentsOf: configFile, encoding: .utf8)) ?? ""
        var lines = splitLines(existing)
        var replaced = false
        for idx in lines.indices {
            let line = lines[idx]
            let isTopLevel = line.prefix { $0 == " " || $0 == "\t" }.isEmpty
            guard isTopLevel,
                  let (k, _) = splitKeyValue(stripComment(line)),
                  k == key else {
                continue
            }
            if let hashIdx = line.firstIndex(of: "#") {
                lines[idx] = "\(key): \(renderedValue)   \(line[hashIdx...])"
            } else {
                lines[idx] = "\(key): \(renderedValue)"
            }
            replaced = true
            break
        }
        if !replaced {
            if let firstNonComment = lines.firstIndex(where: { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return !t.isEmpty && !t.hasPrefix("#")
            }) {
                lines.insert("\(key): \(renderedValue)", at: firstNonComment)
            } else {
                lines.append("\(key): \(renderedValue)")
            }
        }
        try FileManager.default.createDirectory(at: configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let content = lines.joined(separator: "\n")
        try (content.hasSuffix("\n") ? content : content + "\n")
            .write(to: configFile, atomically: true, encoding: .utf8)
    }

    private static func applyTriage(_ key: String, _ value: String, to config: inout AppConfig) {
        let val = unquote(value)
        switch key {
        case "provider": config.triageProvider = val
        case "decision_api_url": config.decisionAPIURL = val.isEmpty || val == "null" ? nil : val
        case "decision_api_key_env": config.decisionAPIKeyEnv = val
        case "decision_api_timeout_seconds": config.decisionAPITimeoutSeconds = Double(val) ?? config.decisionAPITimeoutSeconds
        case "agent_cli_driver": config.agentCLIDriver = val
        case "agent_cli_model": config.agentCLIModel = val.isEmpty || val == "null" ? nil : val
        default: break
        }
    }
}

/// Declarative trigger + funnel + execution playbook loaded from `chimes/*.md`.
public struct ChimeRule: Sendable, Equatable, Identifiable {
    public var id: String
    public var filePath: String?
    public var fileModifiedAt: Date?
    public var enabled: Bool
    public var description: String
    public var matchTypes: [String]
    public var matchSources: [String]
    public var keywordsAny: [String]
    public var keywordsAll: [String]
    public var excludeKeywords: [String]
    public var titleEquals: [String]
    public var titleAny: [String]
    public var titleAll: [String]
    public var titleExclude: [String]
    public var subtitleEquals: [String]
    public var subtitleAny: [String]
    public var subtitleAll: [String]
    public var subtitleExclude: [String]
    public var bodyAny: [String]
    public var bodyAll: [String]
    public var bodyExclude: [String]
    public var cwdPrefix: [String]
    public var dedupTTLSeconds: Int
    public var debounceSeconds: Double
    public var maxWaitSeconds: Double
    public var cooldownSeconds: Int
    public var minCount: Int
    public var countWindow: CountWindow
    public var countScope: CountScope
    public var countResetOnTrigger: Bool
    public var expectWindow: ExpectWindowSpec?
    public var deferOnFocus: Bool
    public var triageEnabled: Bool
    public var triageProviderOverride: String?
    public var sessionPolicy: SessionPolicy
    public var sessionTTLSeconds: Int
    public var autonomy: AutonomyMode
    public var driver: String
    public var model: String?
    public var workingDir: String
    public var worktreeOnPhase2: Bool
    public var phase1MaxTimeSeconds: Int
    public var phase1MaxCostUSD: Double
    public var phase2MaxTimeSeconds: Int
    public var phase2MaxCostUSD: Double
    public var preflightCmd: String?
    public var preflightTimeoutSeconds: Int
    public var onComplete: [ActionSpec]
    public var phase1Prompt: String
    public var phase2Prompt: String

    public init(
        id: String,
        filePath: String? = nil,
        fileModifiedAt: Date? = nil,
        enabled: Bool = true,
        description: String = "",
        matchTypes: [String] = [],
        matchSources: [String] = [],
        keywordsAny: [String] = [],
        keywordsAll: [String] = [],
        excludeKeywords: [String] = [],
        titleEquals: [String] = [],
        titleAny: [String] = [],
        titleAll: [String] = [],
        titleExclude: [String] = [],
        subtitleEquals: [String] = [],
        subtitleAny: [String] = [],
        subtitleAll: [String] = [],
        subtitleExclude: [String] = [],
        bodyAny: [String] = [],
        bodyAll: [String] = [],
        bodyExclude: [String] = [],
        cwdPrefix: [String] = [],
        dedupTTLSeconds: Int = 300,
        debounceSeconds: Double = 5.0,
        maxWaitSeconds: Double = 30.0,
        cooldownSeconds: Int = 900,
        minCount: Int = 1,
        countWindow: CountWindow = .daily,
        countScope: CountScope = .rule,
        countResetOnTrigger: Bool = true,
        expectWindow: ExpectWindowSpec? = nil,
        deferOnFocus: Bool = true,
        triageEnabled: Bool = false,
        triageProviderOverride: String? = nil,
        sessionPolicy: SessionPolicy = .threaded,
        sessionTTLSeconds: Int = 86400,
        autonomy: AutonomyMode = .draftApprove,
        driver: String = "omp",
        model: String? = nil,
        workingDir: String = ".",
        worktreeOnPhase2: Bool = true,
        phase1MaxTimeSeconds: Int = 180,
        phase1MaxCostUSD: Double = 0.25,
        phase2MaxTimeSeconds: Int = 600,
        phase2MaxCostUSD: Double = 1.0,
        preflightCmd: String? = nil,
        preflightTimeoutSeconds: Int = 10,
        onComplete: [ActionSpec] = [ActionSpec(type: .notify)],
        phase1Prompt: String = "",
        phase2Prompt: String = ""
    ) {
        self.id = id
        self.filePath = filePath
        self.fileModifiedAt = fileModifiedAt
        self.enabled = enabled
        self.description = description
        self.matchTypes = matchTypes
        self.matchSources = matchSources
        self.keywordsAny = keywordsAny
        self.keywordsAll = keywordsAll
        self.excludeKeywords = excludeKeywords
        self.titleEquals = titleEquals
        self.titleAny = titleAny
        self.titleAll = titleAll
        self.titleExclude = titleExclude
        self.subtitleEquals = subtitleEquals
        self.subtitleAny = subtitleAny
        self.subtitleAll = subtitleAll
        self.subtitleExclude = subtitleExclude
        self.bodyAny = bodyAny
        self.bodyAll = bodyAll
        self.bodyExclude = bodyExclude
        self.cwdPrefix = cwdPrefix
        self.dedupTTLSeconds = dedupTTLSeconds
        self.debounceSeconds = debounceSeconds
        self.maxWaitSeconds = maxWaitSeconds
        self.cooldownSeconds = cooldownSeconds
        self.minCount = max(1, minCount)
        self.countWindow = countWindow
        self.countScope = countScope
        self.countResetOnTrigger = countResetOnTrigger
        self.expectWindow = expectWindow
        self.deferOnFocus = deferOnFocus
        self.triageEnabled = triageEnabled
        self.triageProviderOverride = triageProviderOverride
        self.sessionPolicy = sessionPolicy
        self.sessionTTLSeconds = sessionTTLSeconds
        self.autonomy = autonomy
        self.driver = driver
        self.model = model
        self.workingDir = workingDir
        self.worktreeOnPhase2 = worktreeOnPhase2
        self.phase1MaxTimeSeconds = phase1MaxTimeSeconds
        self.phase1MaxCostUSD = phase1MaxCostUSD
        self.phase2MaxTimeSeconds = phase2MaxTimeSeconds
        self.phase2MaxCostUSD = phase2MaxCostUSD
        self.preflightCmd = preflightCmd
        self.preflightTimeoutSeconds = preflightTimeoutSeconds
        self.onComplete = onComplete
        self.phase1Prompt = phase1Prompt
        self.phase2Prompt = phase2Prompt
    }

    public static func loadAll(from chimesDir: URL) -> [ChimeRule] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: chimesDir, includingPropertiesForKeys: nil) else {
            return []
        }
        return urls
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let fallbackID = url.deletingPathExtension().lastPathComponent
                var rule = parse(markdown: content, defaultID: fallbackID)
                rule.filePath = url.path
                rule.fileModifiedAt = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
                return rule
            }
    }

    /// Updates or inserts `enabled: true/false` in the YAML frontmatter of a chime `.md` file without disturbing other fields.
    public static func setEnabled(_ enabled: Bool, in fileURL: URL) throws {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        var lines = splitLines(content)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            let updated = "---\nenabled: \(enabled)\n---\n\n\(content)"
            try updated.write(to: fileURL, atomically: true, encoding: .utf8)
            return
        }

        var closingIndex: Int?
        var replaced = false
        for idx in 1..<lines.count {
            let trimmed = lines[idx].trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                closingIndex = idx
                break
            }
            let isTopLevel = lines[idx].prefix { $0 == " " || $0 == "\t" }.isEmpty
            if isTopLevel,
               let (k, _) = splitKeyValue(stripComment(lines[idx])),
               k == "enabled" {
                if let hashIdx = lines[idx].firstIndex(of: "#") {
                    lines[idx] = "enabled: \(enabled)   \(lines[idx][hashIdx...])"
                } else {
                    lines[idx] = "enabled: \(enabled)"
                }
                replaced = true
                break
            }
        }

        if !replaced {
            let insertAt = min(closingIndex ?? lines.count, lines.count)
            // Prefer inserting right after `id:` if present
            if let idIdx = (1..<insertAt).first(where: { idx in
                let isTopLevel = lines[idx].prefix { $0 == " " || $0 == "\t" }.isEmpty
                return isTopLevel && splitKeyValue(stripComment(lines[idx]))?.0 == "id"
            }) {
                lines.insert("enabled: \(enabled)", at: idIdx + 1)
            } else {
                lines.insert("enabled: \(enabled)", at: min(1, lines.count))
            }
        }

        let joined = lines.joined(separator: "\n")
        try joined.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Builds a concise human-readable match summary for UI display.
    public var matchSummary: String {
        var parts: [String] = []
        if !titleEquals.isEmpty {
            parts.append("标题=\(titleEquals.prefix(2).joined(separator: "/"))")
        } else if !titleAny.isEmpty {
            parts.append("标题含 \(titleAny.prefix(2).joined(separator: "/"))")
        } else if !titleAll.isEmpty {
            parts.append("标题全含 \(titleAll.prefix(2).joined(separator: "+"))")
        }
        if !bodyAll.isEmpty {
            parts.append("正文全含 \(bodyAll.prefix(2).joined(separator: "+"))")
        } else if !bodyAny.isEmpty {
            parts.append("正文含 \(bodyAny.prefix(2).joined(separator: "/"))")
        }
        if !keywordsAll.isEmpty {
            parts.append("全含 \(keywordsAll.prefix(2).joined(separator: "+"))")
        } else if !keywordsAny.isEmpty {
            parts.append("含 \(keywordsAny.prefix(3).joined(separator: "/"))")
        }
        if parts.isEmpty, !matchTypes.isEmpty {
            parts.append(matchTypes.prefix(2).joined(separator: ", "))
        }
        return parts.isEmpty ? "全部事件" : parts.joined(separator: " · ")
    }

    /// Generates a synthetic matching event suitable for quick interactive testing in MenuBar/CLI.
    public func sampleTestEvent() -> EventEnvelope {
        let type = matchTypes.first.map { $0.replacingOccurrences(of: "*", with: "test") } ?? "dev.bianzhong.manual"
        let source = matchSources.first.map { $0.replacingOccurrences(of: "*", with: "test") } ?? "bz://test/menubar"
        let title = titleEquals.first ?? titleAll.joined(separator: " ") .nilIfEmpty ?? titleAny.first ?? "测试信号 (\(id))"
        let subtitle = subtitleEquals.first ?? subtitleAll.joined(separator: " ").nilIfEmpty ?? subtitleAny.first ?? "Bianzhong Test"
        var bodyTokens: [String] = []
        bodyTokens.append(contentsOf: bodyAll)
        if let firstBodyAny = bodyAny.first { bodyTokens.append(firstBodyAny) }
        bodyTokens.append(contentsOf: keywordsAll)
        if let firstKwAny = keywordsAny.first { bodyTokens.append(firstKwAny) }
        let body = bodyTokens.isEmpty ? "测试规则 \(id) 的模拟消息" : "测试信号：\(bodyTokens.joined(separator: " "))"

        var payload: [String: String] = [
            "title": title,
            "subtitle": subtitle,
            "body": body
        ]
        if let cwd = cwdPrefix.first {
            payload["cwd"] = cwd
        } else if workingDir != "$payload.cwd" && workingDir != "auto" && workingDir != "." {
            payload["cwd"] = workingDir
        }
        return EventEnvelope(
            source: source,
            type: type,
            correlationKey: "test:\(id):\(title)",
            privacyLevel: .internal,
            payload: payload,
            ambientContext: .captureCurrent()
        )
    }

    /// Parses YAML frontmatter (`--- ... ---`) plus `## Phase 1` and `## Phase 2` Markdown bodies.
    public static func parse(markdown: String, defaultID: String) -> ChimeRule {
        let lines = splitLines(markdown)
        var frontmatterLines: [String] = []
        var bodyLines: [String] = []

        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            var idx = 1
            var foundEnd = false
            while idx < lines.count {
                if lines[idx].trimmingCharacters(in: .whitespaces) == "---" {
                    foundEnd = true
                    idx += 1
                    break
                }
                frontmatterLines.append(lines[idx])
                idx += 1
            }
            if foundEnd && idx < lines.count {
                bodyLines = Array(lines[idx...])
            } else if !foundEnd {
                bodyLines = lines
                frontmatterLines = []
            }
        } else {
            bodyLines = lines
        }

        var rule = ChimeRule(id: defaultID)
        var path: [(indent: Int, key: String)] = []
        var sawOnComplete = false
        var parsedActions: [ActionSpec] = []
        var currentAction: ActionSpec?
        var expectEnabled: Bool?
        var expectStart: String?
        var expectEnd: String?
        var expectWeekdays: [Int] = []
        var expectSuppressOnMatch: Bool = true
        var expectGraceSeconds: Int = 0

        func flushAction() {
            if let action = currentAction {
                parsedActions.append(action)
                currentAction = nil
            }
        }

        func applyActionField(_ key: String, _ value: String) {
            let val = unquote(value)
            if key == "type" {
                if let actionType = ActionType(rawValue: val) {
                    if currentAction == nil {
                        currentAction = ActionSpec(type: actionType)
                    } else {
                        currentAction?.type = actionType
                    }
                }
                return
            }
            guard currentAction != nil else { return }
            switch key {
            case "when": currentAction?.whenCondition = (val.isEmpty || val == "null") ? nil : val
            case "preset": currentAction?.preset = (val.isEmpty || val == "null") ? nil : val
            case "url": currentAction?.url = (val.isEmpty || val == "null") ? nil : val
            case "url_env": currentAction?.urlEnv = (val.isEmpty || val == "null") ? nil : val
            case "secret_env": currentAction?.secretEnv = (val.isEmpty || val == "null") ? nil : val
            case "token_env": currentAction?.tokenEnv = (val.isEmpty || val == "null") ? nil : val
            case "chat_id": currentAction?.chatID = (val.isEmpty || val == "null") ? nil : val
            case "path": currentAction?.path = (val.isEmpty || val == "null") ? nil : expandTilde(val)
            case "name": currentAction?.name = (val.isEmpty || val == "null") ? nil : val
            case "cmd", "command": currentAction?.command = (val.isEmpty || val == "null") ? nil : val
            case "template": currentAction?.template = (val.isEmpty || val == "null") ? nil : val
            case "tts": currentAction?.tts = parseBool(val, default: false)
            default: break
            }
        }

        func appendListItem(_ rawItem: String, for keys: [String]) {
            let item = unquote(rawItem)
            guard !item.isEmpty, item != "null" else { return }
            let sec = keys.first ?? ""
            let sub = keys.count >= 3 ? keys[1] : ""
            let leaf = keys.count >= 2 ? keys.last! : ""
            switch (sec, sub, leaf) {
            case ("match", "", "type"): rule.matchTypes.append(item)
            case ("match", "", "source"): rule.matchSources.append(item)
            case ("match", "", "keywords_any"): rule.keywordsAny.append(item)
            case ("match", "", "keywords_all"): rule.keywordsAll.append(item)
            case ("match", "", "exclude_keywords"): rule.excludeKeywords.append(item)
            case ("match", "", "title_equals"), ("match", "title", "equals"): rule.titleEquals.append(item)
            case ("match", "", "title_any"), ("match", "", "title_contains"), ("match", "title", "any"), ("match", "title", "contains"):
                rule.titleAny.append(item)
            case ("match", "", "title_all"), ("match", "title", "all"): rule.titleAll.append(item)
            case ("match", "", "title_exclude"), ("match", "title", "exclude"): rule.titleExclude.append(item)
            case ("match", "", "subtitle_equals"), ("match", "subtitle", "equals"): rule.subtitleEquals.append(item)
            case ("match", "", "subtitle_any"), ("match", "", "subtitle_contains"), ("match", "subtitle", "any"), ("match", "subtitle", "contains"):
                rule.subtitleAny.append(item)
            case ("match", "", "subtitle_all"), ("match", "subtitle", "all"): rule.subtitleAll.append(item)
            case ("match", "", "subtitle_exclude"), ("match", "subtitle", "exclude"): rule.subtitleExclude.append(item)
            case ("match", "", "body_any"), ("match", "", "body_contains"), ("match", "body", "any"), ("match", "body", "contains"):
                rule.bodyAny.append(item)
            case ("match", "", "body_all"), ("match", "body", "all"): rule.bodyAll.append(item)
            case ("match", "", "body_exclude"), ("match", "body", "exclude"): rule.bodyExclude.append(item)
            case ("match", "", "cwd_prefix"), ("match", "cwd", "prefix"):
                rule.cwdPrefix.append(expandTilde(item))
            case ("expect", "", "weekdays"):
                let parsed = parseWeekdays(item)
                if item.lowercased() == "*" || item.lowercased() == "all" || item.lowercased() == "daily" || item.lowercased() == "everyday" {
                    expectWeekdays = []
                } else {
                    expectWeekdays = Array(Set(expectWeekdays + parsed)).sorted()
                }
            default:
                break
            }
        }

        for rawLine in frontmatterLines {
            let clean = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if clean.isEmpty { continue }
            let indent = rawLine.prefix { $0 == " " }.count

            if indent == 0 {
                flushAction()
                path.removeAll()
                if clean.hasSuffix(":") {
                    let topKey = String(clean.dropLast()).trimmingCharacters(in: .whitespaces)
                    path.append((indent: 0, key: topKey))
                    if topKey == "on_complete" {
                        sawOnComplete = true
                    }
                    continue
                }
            } else if path.first?.key == "on_complete" {
                if clean.hasPrefix("- ") {
                    flushAction()
                    let rest = String(clean.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    if let (k, v) = splitKeyValue(rest) {
                        applyActionField(k, v)
                    }
                } else if let (k, v) = splitKeyValue(clean) {
                    applyActionField(k, v)
                }
                continue
            } else {
                if clean.hasPrefix("- ") {
                    while let last = path.last, last.indent >= indent {
                        path.removeLast()
                    }
                    let rest = String(clean.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    appendListItem(rest, for: path.map(\.key))
                    continue
                }
                while let last = path.last, last.indent >= indent {
                    path.removeLast()
                }
                if clean.hasSuffix(":") {
                    let subKey = String(clean.dropLast()).trimmingCharacters(in: .whitespaces)
                    path.append((indent: indent, key: subKey))
                    continue
                }
            }

            guard let (key, value) = splitKeyValue(clean) else { continue }
            let val = unquote(value)
            let section = path.first?.key ?? ""
            let subSection = path.count >= 2 ? path[1].key : ""

            switch (section, subSection, key) {
            case ("", "", "id"): rule.id = val
            case ("", "", "enabled"): rule.enabled = parseBool(val, default: rule.enabled)
            case ("", "", "description"): rule.description = val
            case ("", "", "preflight_cmd"), ("execution", "", "preflight_cmd"):
                rule.preflightCmd = (val.isEmpty || val == "null") ? nil : val
            case ("", "", "preflight_timeout_sec"), ("execution", "", "preflight_timeout_sec"):
                rule.preflightTimeoutSeconds = max(1, Int(val) ?? rule.preflightTimeoutSeconds)
            case ("", "", "on_complete"):
                if val == "[]" {
                    sawOnComplete = true
                    parsedActions = []
                }
            case ("match", "", "type"): rule.matchTypes = parseArray(value)
            case ("match", "", "source"): rule.matchSources = parseArray(value)
            case ("match", "", "keywords_any"): rule.keywordsAny = parseArray(value)
            case ("match", "", "keywords_all"): rule.keywordsAll = parseArray(value)
            case ("match", "", "exclude_keywords"): rule.excludeKeywords = parseArray(value)
            case ("match", "", "title_equals"), ("match", "title", "equals"): rule.titleEquals = parseArray(value)
            case ("match", "", "title_any"), ("match", "", "title_contains"), ("match", "title", "any"), ("match", "title", "contains"):
                rule.titleAny = parseArray(value)
            case ("match", "", "title_all"), ("match", "title", "all"): rule.titleAll = parseArray(value)
            case ("match", "", "title_exclude"), ("match", "title", "exclude"): rule.titleExclude = parseArray(value)
            case ("match", "", "subtitle_equals"), ("match", "subtitle", "equals"): rule.subtitleEquals = parseArray(value)
            case ("match", "", "subtitle_any"), ("match", "", "subtitle_contains"), ("match", "subtitle", "any"), ("match", "subtitle", "contains"):
                rule.subtitleAny = parseArray(value)
            case ("match", "", "subtitle_all"), ("match", "subtitle", "all"): rule.subtitleAll = parseArray(value)
            case ("match", "", "subtitle_exclude"), ("match", "subtitle", "exclude"): rule.subtitleExclude = parseArray(value)
            case ("match", "", "body_any"), ("match", "", "body_contains"), ("match", "body", "any"), ("match", "body", "contains"):
                rule.bodyAny = parseArray(value)
            case ("match", "", "body_all"), ("match", "body", "all"): rule.bodyAll = parseArray(value)
            case ("match", "", "body_exclude"), ("match", "body", "exclude"): rule.bodyExclude = parseArray(value)
            case ("match", "", "cwd_prefix"), ("match", "cwd", "prefix"):
                rule.cwdPrefix = parseArray(value).map { expandTilde($0) }
            case ("funnel", "", "dedup_ttl"): rule.dedupTTLSeconds = parseDurationSeconds(val) ?? rule.dedupTTLSeconds
            case ("funnel", "", "debounce"): rule.debounceSeconds = parseDurationDouble(val) ?? rule.debounceSeconds
            case ("funnel", "", "max_wait"): rule.maxWaitSeconds = parseDurationDouble(val) ?? rule.maxWaitSeconds
            case ("funnel", "", "cooldown"): rule.cooldownSeconds = parseDurationSeconds(val) ?? rule.cooldownSeconds
            case ("funnel", "", "min_count"), ("funnel", "threshold", "min_count"):
                rule.minCount = max(1, Int(val) ?? rule.minCount)
            case ("funnel", "", "window"), ("funnel", "", "count_window"), ("funnel", "threshold", "window"):
                if let parsed = parseCountWindow(val) {
                    rule.countWindow = parsed
                }
            case ("funnel", "", "count_scope"), ("funnel", "threshold", "scope"):
                if let scope = CountScope(rawValue: val.lowercased()) {
                    rule.countScope = scope
                }
            case ("funnel", "", "count_reset_on_trigger"), ("funnel", "threshold", "reset_on_trigger"):
                rule.countResetOnTrigger = parseBool(val, default: rule.countResetOnTrigger)
            case ("funnel", "", "defer_on_focus"): rule.deferOnFocus = parseBool(val, default: rule.deferOnFocus)
            case ("funnel", "", "triage_enabled"), ("funnel", "triage", "enabled"):
                rule.triageEnabled = parseBool(val, default: rule.triageEnabled)
            case ("funnel", "", "triage_provider"), ("funnel", "triage", "provider"):
                rule.triageProviderOverride = (val.isEmpty || val == "null") ? nil : val
            case ("expect", "", "enabled"):
                expectEnabled = parseBool(val, default: true)
            case ("expect", "", "window"):
                let parts = val.split(separator: "-", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 {
                    expectStart = parts[0]
                    expectEnd = parts[1]
                }
            case ("expect", "", "window_start"), ("expect", "", "start"):
                expectStart = val
            case ("expect", "", "window_end"), ("expect", "", "end"):
                expectEnd = val
            case ("expect", "", "weekdays"):
                expectWeekdays = parseWeekdays(value)
            case ("expect", "", "suppress_on_match"):
                expectSuppressOnMatch = parseBool(val, default: true)
            case ("expect", "", "grace"), ("expect", "", "grace_seconds"):
                expectGraceSeconds = max(0, parseDurationSeconds(val) ?? 0)
            case ("session", "", "policy"): rule.sessionPolicy = SessionPolicy(rawValue: val) ?? rule.sessionPolicy
            case ("session", "", "ttl"): rule.sessionTTLSeconds = parseDurationSeconds(val) ?? rule.sessionTTLSeconds
            case ("execution", "", "autonomy"): rule.autonomy = AutonomyMode(rawValue: val) ?? rule.autonomy
            case ("execution", "", "driver"): rule.driver = val
            case ("execution", "", "model"): rule.model = (val.isEmpty || val == "null") ? nil : val
            case ("execution", "", "working_dir"):
                rule.workingDir = val.hasPrefix("$") || val == "auto" ? val : expandTilde(val)
            case ("execution", "", "worktree_on_phase2"): rule.worktreeOnPhase2 = parseBool(val, default: rule.worktreeOnPhase2)
            case ("execution", _, "phase1_max_time_sec"): rule.phase1MaxTimeSeconds = Int(val) ?? rule.phase1MaxTimeSeconds
            case ("execution", _, "phase1_max_cost_usd"): rule.phase1MaxCostUSD = Double(val) ?? rule.phase1MaxCostUSD
            case ("execution", _, "phase2_max_time_sec"): rule.phase2MaxTimeSeconds = Int(val) ?? rule.phase2MaxTimeSeconds
            case ("execution", _, "phase2_max_cost_usd"): rule.phase2MaxCostUSD = Double(val) ?? rule.phase2MaxCostUSD
            default: break
            }
        }

        flushAction()
        if sawOnComplete {
            rule.onComplete = parsedActions
        }
        if let start = expectStart, let end = expectEnd, !start.isEmpty, !end.isEmpty {
            let isEnabled = expectEnabled ?? true
            rule.expectWindow = ExpectWindowSpec(
                enabled: isEnabled,
                windowStart: start,
                windowEnd: end,
                weekdays: expectWeekdays,
                suppressOnMatch: expectSuppressOnMatch,
                graceSeconds: expectGraceSeconds
            )
        }

        let (p1, p2) = extractPhasePrompts(bodyLines.joined(separator: "\n"))
        rule.phase1Prompt = p1
        rule.phase2Prompt = p2
        return rule
    }

    private static func extractPhasePrompts(_ body: String) -> (String, String) {
        let lines = splitLines(body)
        var phase1: [String] = []
        var phase2: [String] = []
        var current = 1

        for line in lines {
            let lower = line.trimmingCharacters(in: .whitespaces).lowercased()
            if lower.hasPrefix("## phase 1") {
                current = 1
                continue
            }
            if lower.hasPrefix("## phase 2") {
                current = 2
                continue
            }
            if current == 1 {
                phase1.append(line)
            } else {
                phase2.append(line)
            }
        }

        let p1 = phase1.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let p2 = phase2.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (p1, p2)
    }

    /// Serializes this `ChimeRule` into canonical Markdown + YAML Frontmatter format (`chimes/*.md`).
    public func serializeToMarkdown() -> String {
        var lines: [String] = [
            "---",
            "id: \(yamlScalar(id))",
            "enabled: \(enabled)",
            "description: \(yamlQuote(description))",
            "",
            "match:",
            "  type: \(yamlArray(matchTypes))",
            "  source: \(yamlArray(matchSources))"
        ]
        if !titleEquals.isEmpty { lines.append("  title_equals: \(yamlArray(titleEquals))") }
        if !titleAny.isEmpty { lines.append("  title_any: \(yamlArray(titleAny))") }
        if !titleAll.isEmpty { lines.append("  title_all: \(yamlArray(titleAll))") }
        if !titleExclude.isEmpty { lines.append("  title_exclude: \(yamlArray(titleExclude))") }
        if !subtitleEquals.isEmpty { lines.append("  subtitle_equals: \(yamlArray(subtitleEquals))") }
        if !subtitleAny.isEmpty { lines.append("  subtitle_any: \(yamlArray(subtitleAny))") }
        if !subtitleAll.isEmpty { lines.append("  subtitle_all: \(yamlArray(subtitleAll))") }
        if !subtitleExclude.isEmpty { lines.append("  subtitle_exclude: \(yamlArray(subtitleExclude))") }
        if !bodyAny.isEmpty { lines.append("  body_any: \(yamlArray(bodyAny))") }
        if !bodyAll.isEmpty { lines.append("  body_all: \(yamlArray(bodyAll))") }
        if !bodyExclude.isEmpty { lines.append("  body_exclude: \(yamlArray(bodyExclude))") }
        if !cwdPrefix.isEmpty { lines.append("  cwd_prefix: \(yamlArray(cwdPrefix))") }
        lines.append("  keywords_any: \(yamlArray(keywordsAny))")
        if !keywordsAll.isEmpty { lines.append("  keywords_all: \(yamlArray(keywordsAll))") }
        lines.append("  exclude_keywords: \(yamlArray(excludeKeywords))")

        let windowLiteral: String
        switch countWindow {
        case .daily: windowLiteral = "daily"
        case .sliding(let sec):
            if sec % 3600 == 0 { windowLiteral = "\(sec / 3600)h" }
            else if sec % 60 == 0 { windowLiteral = "\(sec / 60)m" }
            else { windowLiteral = "\(sec)s" }
        }

        lines += [
            "",
            "funnel:",
            "  dedup_ttl: \(dedupTTLSeconds)s",
            "  debounce: \(formatDurationSeconds(debounceSeconds))",
            "  max_wait: \(formatDurationSeconds(maxWaitSeconds))",
            "  cooldown: \(cooldownSeconds)s"
        ]
        if minCount > 1 || countWindow != .daily || countScope != .rule || !countResetOnTrigger {
            lines.append("  min_count: \(minCount)")
            lines.append("  window: \(windowLiteral)")
            lines.append("  count_scope: \(countScope.rawValue)")
            lines.append("  count_reset_on_trigger: \(countResetOnTrigger)")
        }
        lines += [
            "  defer_on_focus: \(deferOnFocus)",
            "  triage:",
            "    enabled: \(triageEnabled)",
            "    provider: \(triageProviderOverride.map(yamlScalar) ?? "none")"
        ]

        if let exp = expectWindow {
            let wdNames: [String] = exp.weekdays.compactMap { wd in
                switch wd {
                case 1: return "mon"
                case 2: return "tue"
                case 3: return "wed"
                case 4: return "thu"
                case 5: return "fri"
                case 6: return "sat"
                case 7: return "sun"
                default: return nil
                }
            }
            lines += [
                "",
                "expect:",
                "  enabled: \(exp.enabled)",
                "  window: \(yamlQuote("\(exp.windowStart)-\(exp.windowEnd)"))",
                "  weekdays: \(yamlArray(wdNames))",
                "  suppress_on_match: \(exp.suppressOnMatch)",
                "  grace_seconds: \(exp.graceSeconds)"
            ]
        }

        lines += [
            "",
            "session:",
            "  policy: \(sessionPolicy.rawValue)",
            "  ttl: \(sessionTTLSeconds)s",
            "",
            "execution:",
            "  autonomy: \(autonomy.rawValue)",
            "  driver: \(yamlScalar(driver))",
            "  model: \(model.map(yamlScalar) ?? "null")",
            "  working_dir: \(yamlScalar(workingDir))",
            "  worktree_on_phase2: \(worktreeOnPhase2)"
        ]
        if let cmd = preflightCmd, !cmd.isEmpty {
            lines.append("  preflight_cmd: \(yamlQuote(cmd))")
            lines.append("  preflight_timeout_sec: \(preflightTimeoutSeconds)")
        }
        lines += [
            "  phase1_max_time_sec: \(phase1MaxTimeSeconds)",
            "  phase1_max_cost_usd: \(String(format: "%.2f", phase1MaxCostUSD))",
            "  phase2_max_time_sec: \(phase2MaxTimeSeconds)",
            "  phase2_max_cost_usd: \(String(format: "%.2f", phase2MaxCostUSD))"
        ]

        lines.append("")
        if onComplete.isEmpty {
            lines.append("on_complete: []")
        } else {
            lines.append("on_complete:")
            for act in onComplete {
                lines.append("  - type: \(act.type.rawValue)")
                if let w = act.whenCondition, !w.isEmpty { lines.append("    when: \(yamlQuote(w))") }
                if let p = act.preset, !p.isEmpty { lines.append("    preset: \(yamlScalar(p))") }
                if let u = act.url, !u.isEmpty { lines.append("    url: \(yamlQuote(u))") }
                if let ue = act.urlEnv, !ue.isEmpty { lines.append("    url_env: \(yamlScalar(ue))") }
                if let se = act.secretEnv, !se.isEmpty { lines.append("    secret_env: \(yamlScalar(se))") }
                if let te = act.tokenEnv, !te.isEmpty { lines.append("    token_env: \(yamlScalar(te))") }
                if let cid = act.chatID, !cid.isEmpty { lines.append("    chat_id: \(yamlQuote(cid))") }
                if let pa = act.path, !pa.isEmpty { lines.append("    path: \(yamlQuote(pa))") }
                if let na = act.name, !na.isEmpty { lines.append("    name: \(yamlQuote(na))") }
                if let cm = act.command, !cm.isEmpty { lines.append("    cmd: \(yamlQuote(cm))") }
                if let tp = act.template, !tp.isEmpty { lines.append("    template: \(yamlQuote(tp))") }
                if act.tts { lines.append("    tts: true") }
            }
        }

        lines.append("---")
        lines.append("")
        lines.append("## Phase 1")
        lines.append(phase1Prompt.isEmpty ? "请只读排查此信号并输出精炼结论。" : phase1Prompt)
        if !phase2Prompt.isEmpty {
            lines.append("")
            lines.append("## Phase 2")
            lines.append(phase2Prompt)
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    public func save(to fileURL: URL) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try serializeToMarkdown().write(to: fileURL, atomically: true, encoding: .utf8)
    }
}

private func formatDurationSeconds(_ val: Double) -> String {
    if val == val.rounded() {
        return "\(Int(val))s"
    }
    return "\(String(format: "%g", val))s"
}

private func yamlQuote(_ raw: String) -> String {
    let escaped = raw
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\t", with: "\\t")
    return "\"\(escaped)\""
}

private func yamlScalar(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "\"\"" }
    if trimmed.contains(":") || trimmed.contains("#") || trimmed.contains(" ") || trimmed.hasPrefix("$") {
        return yamlQuote(trimmed)
    }
    return trimmed
}

private func yamlArray(_ items: [String]) -> String {
    if items.isEmpty { return "[]" }
    return "[" + items.map(yamlQuote).joined(separator: ", ") + "]"
}

// MARK: - Lightweight YAML Parsing Helpers

private func splitLines(_ text: String) -> [String] {
    text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .components(separatedBy: "\n")
}

private func stripComment(_ line: String) -> String {
    var inSingle = false
    var inDouble = false
    for (idx, ch) in line.enumerated() {
        if ch == "'" && !inDouble {
            inSingle.toggle()
        } else if ch == "\"" && !inSingle {
            inDouble.toggle()
        } else if ch == "#" && !inSingle && !inDouble {
            let cut = line.index(line.startIndex, offsetBy: idx)
            return String(line[..<cut])
        }
    }
    return line
}

private func splitKeyValue(_ line: String) -> (String, String)? {
    guard let colon = line.firstIndex(of: ":") else { return nil }
    let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
    let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    guard !key.isEmpty else { return nil }
    return (key, value)
}

private func unquote(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
        let inner = String(trimmed.dropFirst().dropLast())
        var out = ""
        out.reserveCapacity(inner.count)
        var escaping = false
        for ch in inner {
            if escaping {
                switch ch {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                default:
                    out.append("\\")
                    out.append(ch)
                }
                escaping = false
            } else if ch == "\\" {
                escaping = true
            } else {
                out.append(ch)
            }
        }
        if escaping { out.append("\\") }
        return out
    }
    if trimmed.count >= 2, trimmed.hasPrefix("'"), trimmed.hasSuffix("'") {
        return String(trimmed.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
    }
    return trimmed
}

private func parseArray(_ raw: String) -> [String] {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
        let inner = String(trimmed.dropFirst().dropLast())
        return inner
            .split(separator: ",")
            .map { unquote(String($0)) }
            .filter { !$0.isEmpty }
    }
    let single = unquote(trimmed)
    return single.isEmpty || single == "null" ? [] : [single]
}

private func parseBool(_ value: String, default fallback: Bool) -> Bool {
    switch value.lowercased() {
    case "true", "yes", "1": return true
    case "false", "no", "0": return false
    default: return fallback
    }
}

private func parseDurationSeconds(_ value: String) -> Int? {
    guard let seconds = parseDurationDouble(value) else { return nil }
    return Int(seconds.rounded())
}

private func parseDurationDouble(_ value: String) -> Double? {
    let s = value.lowercased().trimmingCharacters(in: .whitespaces)
    if s.hasSuffix("ms"), let num = Double(s.dropLast(2)) { return num / 1000.0 }
    if s.hasSuffix("s"), let num = Double(s.dropLast(1)) { return num }
    if s.hasSuffix("m"), let num = Double(s.dropLast(1)) { return num * 60.0 }
    if s.hasSuffix("h"), let num = Double(s.dropLast(1)) { return num * 3600.0 }
    if s.hasSuffix("d"), let num = Double(s.dropLast(1)) { return num * 86400.0 }
    return Double(s)
}

private func parseCountWindow(_ value: String) -> CountWindow? {
    let s = value.lowercased().trimmingCharacters(in: .whitespaces)
    if s == "daily" || s == "today" || s == "day" {
        return .daily
    }
    if let sec = parseDurationSeconds(s), sec > 0 {
        return .sliding(seconds: sec)
    }
    return nil
}

private func parseWeekdays(_ raw: String) -> [Int] {
    let tokens = parseArray(raw)
    var result: [Int] = []
    for tok in tokens {
        let lower = tok.lowercased()
        switch lower {
        case "*", "all", "daily", "everyday":
            return []
        case "weekday", "weekdays", "workday", "workdays":
            result.append(contentsOf: [1, 2, 3, 4, 5])
        case "weekend", "weekends":
            result.append(contentsOf: [6, 7])
        case "mon", "monday", "1": result.append(1)
        case "tue", "tues", "tuesday", "2": result.append(2)
        case "wed", "wednesday", "3": result.append(3)
        case "thu", "thur", "thurs", "thursday", "4": result.append(4)
        case "fri", "friday", "5": result.append(5)
        case "sat", "saturday", "6": result.append(6)
        case "sun", "sunday", "7", "0": result.append(7)
        default: break
        }
    }
    return Array(Set(result)).sorted()
}

private func expandTilde(_ path: String) -> String {
    NSString(string: path).expandingTildeInPath
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
