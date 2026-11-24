import AppKit
import Foundation

public struct ActionContext: Sendable {
    public let event: EventEnvelope
    public let rule: ChimeRule
    public let approval: ApprovalRecord?
    public let phase: String
    public let summaryText: String
    public let sessionID: String?

    public init(
        event: EventEnvelope,
        rule: ChimeRule,
        approval: ApprovalRecord? = nil,
        phase: String,
        summaryText: String,
        sessionID: String? = nil
    ) {
        self.event = event
        self.rule = rule
        self.approval = approval
        self.phase = phase
        self.summaryText = summaryText
        self.sessionID = sessionID
    }
}

/// Evaluates lightweight boolean `when` expressions (supporting `||`, `&&`, `==`, `!=`, `>`, `>=`, `<`, `<=`)
/// against ambient context, risk level, approval kind, and run phase.
public enum ActionConditionEvaluator {
    public static func matches(_ expression: String?, context: ActionContext) -> Bool {
        guard let raw = expression?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return true
        }
        if raw.lowercased() == "always" { return true }

        let orClauses = raw.components(separatedBy: "||")
        return orClauses.contains { orClause in
            let andAtoms = orClause.components(separatedBy: "&&")
            return andAtoms.allSatisfy { evaluateAtom($0, context: context) }
        }
    }

    private static func evaluateAtom(_ rawAtom: String, context: ActionContext) -> Bool {
        let atom = rawAtom.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !atom.isEmpty else { return true }

        let operators = [">=", "<=", "!=", "==", ">", "<"]
        for op in operators {
            if let range = atom.range(of: op) {
                let lhs = String(atom[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let rhs = unquoteLiteral(String(atom[range.upperBound...]).trimmingCharacters(in: .whitespaces))
                return compare(field: lhs, op: op, target: rhs, context: context)
            }
        }
        return resolveBool(field: atom, context: context) ?? false
    }

    private static func compare(field: String, op: String, target: String, context: ActionContext) -> Bool {
        if let numVal = resolveDouble(field: field, context: context), let targetNum = Double(target) {
            switch op {
            case "==": return numVal == targetNum
            case "!=": return numVal != targetNum
            case ">": return numVal > targetNum
            case ">=": return numVal >= targetNum
            case "<": return numVal < targetNum
            case "<=": return numVal <= targetNum
            default: return false
            }
        }

        if let boolVal = resolveBool(field: field, context: context) {
            let targetBool = (target.lowercased() == "true" || target == "1")
            switch op {
            case "==": return boolVal == targetBool
            case "!=": return boolVal != targetBool
            default: return false
            }
        }

        let strVal = resolveString(field: field, context: context) ?? ""
        switch op {
        case "==": return strVal == target
        case "!=": return strVal != target
        default: return false
        }
    }

    private static func resolveBool(field: String, context: ActionContext) -> Bool? {
        switch field {
        case "screen_locked", "ambient.screen_locked":
            return context.event.ambientContext.screenLocked
        case "focus_active", "ambient.focus_active":
            return context.event.ambientContext.focusActive
        default:
            return nil
        }
    }

    private static func resolveDouble(field: String, context: ActionContext) -> Double? {
        switch field {
        case "idle_seconds", "ambient.idle_seconds":
            return context.event.ambientContext.idleSeconds
        default:
            return nil
        }
    }

    private static func resolveString(field: String, context: ActionContext) -> String? {
        switch field {
        case "risk_level", "risk":
            return context.approval?.riskLevel ?? (context.rule.worktreeOnPhase2 ? "medium" : "high")
        case "kind":
            return context.event.payload["kind"] ?? context.approval?.kind ?? "review"
        case "phase":
            return context.phase
        case "chime_id":
            return context.rule.id
        case "driver":
            return context.rule.driver
        default:
            return context.event.payload[field]
        }
    }

    private static func unquoteLiteral(_ s: String) -> String {
        if (s.hasPrefix("'") && s.hasSuffix("'")) || (s.hasPrefix("\"") && s.hasSuffix("\"")), s.count >= 2 {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
}

/// Executes declarative `on_complete` post-actions (`notify`, `webhook`, `shortcut`, `append_markdown`, `shell`, `clipboard`, `chime_sound`).
public final class ActionDispatcher: @unchecked Sendable {
    private let funnel: WakeupFunnel
    private let notifyHandler: @Sendable (ApprovalRecord) -> Void

    public init(funnel: WakeupFunnel, notifyHandler: @escaping @Sendable (ApprovalRecord) -> Void) {
        self.funnel = funnel
        self.notifyHandler = notifyHandler
    }

    @discardableResult
    public func dispatch(specs: [ActionSpec], context: ActionContext) async -> [String] {
        var executed: [String] = []
        for spec in specs {
            guard ActionConditionEvaluator.matches(spec.whenCondition, context: context) else {
                continue
            }
            if await executeOne(spec, context: context) {
                executed.append(spec.type.rawValue)
            }
        }
        return executed
    }

    private func executeOne(_ spec: ActionSpec, context: ActionContext) async -> Bool {
        let text = renderText(spec.template, context: context)
        let title = context.approval?.title ?? context.event.payload["title"] ?? context.rule.id

        switch spec.type {
        case .notify:
            if let approval = context.approval {
                notifyHandler(approval)
                return true
            }
            return false

        case .webhook:
            guard let urlString = resolveWebhookURL(spec: spec), let url = URL(string: urlString) else {
                return false
            }
            return await postWebhook(url: url, title: title, text: text, context: context)

        case .shortcut:
            guard let name = spec.name, !name.isEmpty else { return false }
            let specRun = SpawnSpec(
                executablePath: "/usr/bin/shortcuts",
                arguments: ["run", name],
                environment: ["BIANZHONG_DEPTH": "1"],
                stdinData: text.data(using: .utf8),
                workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path
            )
            let res = await AgentProcessRunner.run(spec: specRun, timeoutSeconds: 15)
            return res.exitCode == 0

        case .appendMarkdown:
            guard let pathTemplate = spec.path, !pathTemplate.isEmpty else { return false }
            return appendMarkdownNote(pathTemplate: pathTemplate, title: title, text: text, ruleID: context.rule.id)

        case .shell:
            guard let command = spec.command, !command.isEmpty else { return false }
            let specRun = SpawnSpec(
                executablePath: "/bin/zsh",
                arguments: ["-lc", command],
                environment: [
                    "BIANZHONG_DEPTH": "1",
                    "BIANZHONG_TITLE": title,
                    "BIANZHONG_SUMMARY": String(text.prefix(4000)),
                    "BIANZHONG_SESSION_ID": context.sessionID ?? ""
                ],
                stdinData: nil,
                workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path
            )
            let res = await AgentProcessRunner.run(spec: specRun, timeoutSeconds: 20)
            return res.exitCode == 0

        case .clipboard:
            let hash = "sha256:" + EventEnvelope.sha256Hex(text)
            funnel.registerEchoHash(hash, ttlSeconds: 30)
            await MainActor.run {
                let pb = NSPasteboard.general
                pb.clearContents()
                let item = NSPasteboardItem()
                item.setString(text, forType: .string)
                item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
                item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
                pb.writeObjects([item])
            }
            return true

        case .chimeSound:
            let soundsBase = "/System/Library/Sounds/"
            let rawName = (spec.name ?? "Glass").replacingOccurrences(of: ".aiff", with: "")
            let safeName = (rawName.isEmpty || rawName.contains("/") || rawName.contains("..") || rawName.contains("\0"))
                ? "Glass"
                : rawName
            let soundURL = URL(fileURLWithPath: "\(soundsBase)\(safeName).aiff").standardizedFileURL
            if soundURL.path.hasPrefix(soundsBase), FileManager.default.fileExists(atPath: soundURL.path) {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
                proc.arguments = [soundURL.path]
                proc.terminationHandler = { _ in }
                try? proc.run()
            }
            if spec.tts {
                let spoken = String(text.replacingOccurrences(of: "\n", with: " ").prefix(80))
                let sayProc = Process()
                sayProc.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                sayProc.arguments = [spoken]
                sayProc.terminationHandler = { _ in }
                try? sayProc.run()
            }
            return true
        }
    }

    private func resolveWebhookURL(spec: ActionSpec) -> String? {
        if let url = spec.url, !url.isEmpty { return url }
        if let envName = spec.urlEnv, !envName.isEmpty,
           let val = ProcessInfo.processInfo.environment[envName], !val.isEmpty {
            return val
        }
        return nil
    }

    private func postWebhook(url: URL, title: String, text: String, context: ActionContext) async -> Bool {
        var req = URLRequest(url: url, timeoutInterval: 5.0)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: String] = [
            "title": title,
            "body": text,
            "text": "\(title)\n\(text)",
            "chime_id": context.rule.id,
            "phase": context.phase,
            "correlation_key": context.event.correlationKey,
            "session_id": context.sessionID ?? ""
        ]
        guard let body = try? JSONEncoder().encode(payload) else { return false }
        req.httpBody = body
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        } catch {
            return false
        }
    }

    private func appendMarkdownNote(pathTemplate: String, title: String, text: String, ruleID: String) -> Bool {
        let now = Date()
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"

        let resolvedPath = NSString(
            string: pathTemplate
                .replacingOccurrences(of: "{{date}}", with: dateFmt.string(from: now))
                .replacingOccurrences(of: "{{rule}}", with: ruleID)
        ).expandingTildeInPath

        let url = URL(fileURLWithPath: resolvedPath)
        let parentDir = url.deletingLastPathComponent().path

        funnel.registerWriteLease(pathPrefix: parentDir, ttlSeconds: 5.0)
        defer { funnel.releaseWriteLease(pathPrefix: parentDir, graceSeconds: 1.5) }

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let entry = "### \(timeFmt.string(from: now)) · \(title) [\(ruleID)]\n\(text)\n\n"
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                handle.write(Data(entry.utf8))
            } else {
                let header = "# Bianzhong Daily Notes (\(dateFmt.string(from: now)))\n\n"
                try (header + entry).write(to: url, atomically: true, encoding: .utf8)
            }
            return true
        } catch {
            return false
        }
    }

    private func renderText(_ template: String?, context: ActionContext) -> String {
        guard let template, !template.isEmpty else {
            return context.summaryText
        }
        let title = context.approval?.title ?? context.event.payload["title"] ?? context.rule.id
        return template
            .replacingOccurrences(of: "{{title}}", with: title)
            .replacingOccurrences(of: "{{summary}}", with: context.summaryText)
            .replacingOccurrences(of: "{{rule}}", with: context.rule.id)
            .replacingOccurrences(of: "{{session_id}}", with: context.sessionID ?? "")
    }
}
