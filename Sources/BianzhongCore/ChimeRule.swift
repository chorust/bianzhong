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
    public var url: String?
    public var urlEnv: String?
    public var path: String?
    public var name: String?
    public var command: String?
    public var template: String?
    public var tts: Bool

    enum CodingKeys: String, CodingKey {
        case type
        case whenCondition = "when"
        case url
        case urlEnv = "url_env"
        case path
        case name
        case command = "cmd"
        case template
        case tts
    }

    public init(
        type: ActionType,
        whenCondition: String? = nil,
        url: String? = nil,
        urlEnv: String? = nil,
        path: String? = nil,
        name: String? = nil,
        command: String? = nil,
        template: String? = nil,
        tts: Bool = false
    ) {
        self.type = type
        self.whenCondition = whenCondition
        self.url = url
        self.urlEnv = urlEnv
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

        for rawLine in yaml.components(separatedBy: .newlines) {
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
        case "max_concurrent_runs": config.maxConcurrentRuns = max(1, Int(val) ?? config.maxConcurrentRuns)
        case "max_causal_depth": config.maxCausalDepth = max(1, Int(val) ?? config.maxCausalDepth)
        case "daily_max_cost_usd": config.dailyMaxCostUSD = max(0, Double(val) ?? config.dailyMaxCostUSD)
        case "daily_max_runs": config.dailyMaxRuns = max(1, Int(val) ?? config.dailyMaxRuns)
        case "circuit_breaker_failures": config.circuitBreakerFailures = max(1, Int(val) ?? config.circuitBreakerFailures)
        case "retention_days": config.retentionDays = max(1, Int(val) ?? config.retentionDays)
        default: break
        }
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
public struct ChimeRule: Sendable, Equatable {
    public var id: String
    public var enabled: Bool
    public var description: String
    public var matchTypes: [String]
    public var matchSources: [String]
    public var keywordsAny: [String]
    public var excludeKeywords: [String]
    public var dedupTTLSeconds: Int
    public var debounceSeconds: Double
    public var maxWaitSeconds: Double
    public var cooldownSeconds: Int
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
        enabled: Bool = true,
        description: String = "",
        matchTypes: [String] = [],
        matchSources: [String] = [],
        keywordsAny: [String] = [],
        excludeKeywords: [String] = [],
        dedupTTLSeconds: Int = 300,
        debounceSeconds: Double = 5.0,
        maxWaitSeconds: Double = 30.0,
        cooldownSeconds: Int = 900,
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
        self.enabled = enabled
        self.description = description
        self.matchTypes = matchTypes
        self.matchSources = matchSources
        self.keywordsAny = keywordsAny
        self.excludeKeywords = excludeKeywords
        self.dedupTTLSeconds = dedupTTLSeconds
        self.debounceSeconds = debounceSeconds
        self.maxWaitSeconds = maxWaitSeconds
        self.cooldownSeconds = cooldownSeconds
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
                return parse(markdown: content, defaultID: fallbackID)
            }
    }

    /// Parses YAML frontmatter (`--- ... ---`) plus `## Phase 1` and `## Phase 2` Markdown bodies.
    public static func parse(markdown: String, defaultID: String) -> ChimeRule {
        let lines = markdown.components(separatedBy: .newlines)
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
        var section = ""
        var subSection = ""
        var subIndent = Int.max
        var sawOnComplete = false
        var parsedActions: [ActionSpec] = []
        var currentAction: ActionSpec?

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
            case "url": currentAction?.url = (val.isEmpty || val == "null") ? nil : val
            case "url_env": currentAction?.urlEnv = (val.isEmpty || val == "null") ? nil : val
            case "path": currentAction?.path = (val.isEmpty || val == "null") ? nil : expandTilde(val)
            case "name": currentAction?.name = (val.isEmpty || val == "null") ? nil : val
            case "cmd", "command": currentAction?.command = (val.isEmpty || val == "null") ? nil : val
            case "template": currentAction?.template = (val.isEmpty || val == "null") ? nil : val
            case "tts": currentAction?.tts = parseBool(val, default: false)
            default: break
            }
        }

        for rawLine in frontmatterLines {
            let clean = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if clean.isEmpty { continue }
            let indent = rawLine.prefix { $0 == " " }.count

            if indent == 0 {
                flushAction()
                subSection = ""
                subIndent = Int.max
                if clean.hasSuffix(":") {
                    section = String(clean.dropLast()).trimmingCharacters(in: .whitespaces)
                    if section == "on_complete" {
                        sawOnComplete = true
                    }
                    continue
                }
                section = ""
            } else if section == "on_complete" {
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
                if indent <= subIndent {
                    subSection = ""
                    subIndent = Int.max
                }
                if clean.hasSuffix(":") {
                    subSection = String(clean.dropLast()).trimmingCharacters(in: .whitespaces)
                    subIndent = indent
                    continue
                }
            }

            guard let (key, value) = splitKeyValue(clean) else { continue }
            let val = unquote(value)

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
            case ("match", "", "exclude_keywords"): rule.excludeKeywords = parseArray(value)
            case ("funnel", "", "dedup_ttl"): rule.dedupTTLSeconds = parseDurationSeconds(val) ?? rule.dedupTTLSeconds
            case ("funnel", "", "debounce"): rule.debounceSeconds = parseDurationDouble(val) ?? rule.debounceSeconds
            case ("funnel", "", "max_wait"): rule.maxWaitSeconds = parseDurationDouble(val) ?? rule.maxWaitSeconds
            case ("funnel", "", "cooldown"): rule.cooldownSeconds = parseDurationSeconds(val) ?? rule.cooldownSeconds
            case ("funnel", "", "defer_on_focus"): rule.deferOnFocus = parseBool(val, default: rule.deferOnFocus)
            case ("funnel", "", "triage_enabled"), ("funnel", "triage", "enabled"):
                rule.triageEnabled = parseBool(val, default: rule.triageEnabled)
            case ("funnel", "", "triage_provider"), ("funnel", "triage", "provider"):
                rule.triageProviderOverride = (val.isEmpty || val == "null") ? nil : val
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

        let (p1, p2) = extractPhasePrompts(bodyLines.joined(separator: "\n"))
        rule.phase1Prompt = p1
        rule.phase2Prompt = p2
        return rule
    }

    private static func extractPhasePrompts(_ body: String) -> (String, String) {
        let lines = body.components(separatedBy: .newlines)
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
}

// MARK: - Lightweight YAML Parsing Helpers

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
    if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
        if trimmed.count >= 2 {
            return String(trimmed.dropFirst().dropLast())
        }
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
    return Double(s)
}

private func expandTilde(_ path: String) -> String {
    NSString(string: path).expandingTildeInPath
}
