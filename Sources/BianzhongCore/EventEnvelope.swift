import AppKit
import CoreGraphics
import CryptoKit
import Foundation

/// Privacy classification enforced before persistence or model dispatch.
public enum PrivacyLevel: String, Codable, Sendable {
    case `public`
    case `internal`
    case sensitive
    case restricted
}

/// Causal lineage tracked across child agent subprocesses to prevent self-trigger loops.
public struct Causality: Codable, Sendable, Equatable {
    public let emitterPID: Int32
    public let parentRunID: String?
    public let depth: Int

    enum CodingKeys: String, CodingKey {
        case emitterPID = "emitter_pid"
        case parentRunID = "parent_run_id"
        case depth
    }

    public init(emitterPID: Int32 = ProcessInfo.processInfo.processIdentifier, parentRunID: String? = nil, depth: Int = 0) {
        self.emitterPID = emitterPID
        self.parentRunID = parentRunID
        self.depth = depth
    }

    public static func fromEnvironment() -> Causality {
        let env = ProcessInfo.processInfo.environment
        let depth = Int(env["BIANZHONG_DEPTH"] ?? "0") ?? 0
        let parentRunID = env["BIANZHONG_RUN_ID"]
        return Causality(
            emitterPID: ProcessInfo.processInfo.processIdentifier,
            parentRunID: parentRunID,
            depth: depth
        )
    }
}

/// Zero-TCC ambient desktop state captured at signal ingestion time.
public struct AmbientContext: Codable, Sendable, Equatable {
    public let frontmostBundleID: String?
    public let focusActive: Bool
    public let idleSeconds: Double
    public let screenLocked: Bool

    enum CodingKeys: String, CodingKey {
        case frontmostBundleID = "frontmost_bundle_id"
        case focusActive = "focus_active"
        case idleSeconds = "idle_seconds"
        case screenLocked = "screen_locked"
    }

    public init(
        frontmostBundleID: String? = nil,
        focusActive: Bool = false,
        idleSeconds: Double = 0,
        screenLocked: Bool = false
    ) {
        self.frontmostBundleID = frontmostBundleID
        self.focusActive = focusActive
        self.idleSeconds = idleSeconds
        self.screenLocked = screenLocked
    }

    /// Captures frontmost app, HID idle duration, and screen lock status without requesting TCC prompts.
    public static func captureCurrent(focusActive: Bool = false) -> AmbientContext {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let anyInput = CGEventType(rawValue: ~0)!
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)

        var locked = false
        if let dict = CGSessionCopyCurrentDictionary() as? [String: Any],
           let flag = dict["CGSSessionScreenIsLocked"] as? Bool {
            locked = flag
        }

        return AmbientContext(
            frontmostBundleID: bundleID,
            focusActive: focusActive,
            idleSeconds: max(0, idle),
            screenLocked: locked
        )
    }
}

/// Normalized local CloudEvents-aligned envelope carried across sensors, funnel, and drivers.
public struct EventEnvelope: Codable, Sendable, Equatable {
    public let specversion: String
    public let id: String
    public let source: String
    public let type: String
    public let ts: String
    public let correlationKey: String
    public let dedupKey: String
    public let privacyLevel: PrivacyLevel
    public let causality: Causality
    public var payload: [String: String]
    public let ambientContext: AmbientContext

    enum CodingKeys: String, CodingKey {
        case specversion
        case id
        case source
        case type
        case ts
        case correlationKey = "correlation_key"
        case dedupKey = "dedup_key"
        case privacyLevel = "privacy_level"
        case causality
        case payload
        case ambientContext = "ambient_context"
    }

    public init(
        specversion: String = "1.0",
        id: String = UUID().uuidString.lowercased(),
        source: String,
        type: String,
        ts: String = ISO8601DateFormatter.bianzhong.string(from: Date()),
        correlationKey: String,
        dedupKey: String? = nil,
        privacyLevel: PrivacyLevel = .internal,
        causality: Causality = .fromEnvironment(),
        payload: [String: String] = [:],
        ambientContext: AmbientContext = .init()
    ) {
        self.specversion = specversion
        self.id = id
        self.source = source
        self.type = type
        self.ts = ts
        self.correlationKey = correlationKey
        if let dedupKey {
            self.dedupKey = dedupKey
        } else {
            let sortedPayload = payload.sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "&")
            self.dedupKey = "sha256:" + EventEnvelope.sha256Hex("\(source)|\(type)|\(correlationKey)|\(sortedPayload)")
        }
        self.privacyLevel = privacyLevel
        self.causality = causality
        self.payload = payload
        self.ambientContext = ambientContext
    }

    public static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public var searchableText: String {
        let title = payload["title"] ?? ""
        let subtitle = payload["subtitle"] ?? ""
        let body = payload["body"] ?? ""
        let summary = payload["summary"] ?? ""
        return [title, subtitle, body, summary, correlationKey, type]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

public extension ISO8601DateFormatter {
    static let bianzhong: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()
}

/// Resolves config and runtime state paths with environment variable overrides for isolated testing.
public struct BianzhongPaths: Sendable {
    public let configDir: URL
    public let stateDir: URL

    public init(configDir: URL? = nil, stateDir: URL? = nil) {
        let env = ProcessInfo.processInfo.environment
        let fm = FileManager.default

        if let configDir {
            self.configDir = configDir
        } else if let override = env["BIANZHONG_CONFIG_DIR"], !override.isEmpty {
            self.configDir = URL(fileURLWithPath: NSString(string: override).expandingTildeInPath, isDirectory: true)
        } else {
            self.configDir = fm.homeDirectoryForCurrentUser
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent("bianzhong", isDirectory: true)
        }

        if let stateDir {
            self.stateDir = stateDir
        } else if let override = env["BIANZHONG_STATE_DIR"], !override.isEmpty {
            self.stateDir = URL(fileURLWithPath: NSString(string: override).expandingTildeInPath, isDirectory: true)
        } else {
            let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            self.stateDir = appSupport.appendingPathComponent("bianzhong", isDirectory: true)
        }
    }

    public var chimesDir: URL { configDir.appendingPathComponent("chimes", isDirectory: true) }
    public var configFile: URL { configDir.appendingPathComponent("config.yml") }
    public var agentsFile: URL { configDir.appendingPathComponent("AGENTS.md") }

    public var dbURL: URL { stateDir.appendingPathComponent("bianzhong.db") }
    public var socketURL: URL { stateDir.appendingPathComponent("ingest.sock") }
    public var runsDir: URL { stateDir.appendingPathComponent("runs", isDirectory: true) }
    public var sessionsDir: URL { stateDir.appendingPathComponent("sessions", isDirectory: true) }
    public var worktreesDir: URL { stateDir.appendingPathComponent("worktrees", isDirectory: true) }
    public var feishuCursorURL: URL { stateDir.appendingPathComponent("feishu_sensor_cursor.txt") }
    public var secretsFile: URL { stateDir.appendingPathComponent("secrets.json") }

    public func ensureDirectories() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: chimesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: runsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: worktreesDir, withIntermediateDirectories: true)
    }
}

/// Decodes binary plist notification records produced by macOS `usernoted`.
public struct DecodedNotificationPayload: Sendable, Equatable {
    public let title: String
    public let subtitle: String
    public let body: String
}

public enum NotificationPayloadDecoder {
    /// Extracts `req.titl`, `req.subt`, and `req.body` from a `usernoted` binary property list blob,
    /// supporting both flat dictionary records and `NSKeyedArchiver` (`$objects`) graphs.
    public static func decode(bplistData: Data) -> DecodedNotificationPayload? {
        guard let raw = try? PropertyListSerialization.propertyList(from: bplistData, options: [], format: nil),
              let dict = raw as? [String: Any] else {
            return nil
        }

        if (dict["$archiver"] as? String) == "NSKeyedArchiver",
           let objects = dict["$objects"] as? [Any],
           let top = dict["$top"] as? [String: Any],
           let rootRef = top["root"] {
            var visited: Set<Int> = []
            if let resolvedRoot = resolveArchiverObject(rootRef, objects: objects, depth: 0, visited: &visited) as? [String: Any] {
                return extractPayload(from: resolvedRoot)
            }
        }

        return extractPayload(from: dict)
    }

    private static func extractPayload(from root: [String: Any]) -> DecodedNotificationPayload? {
        let level1 = (root["req"] as? [String: Any])
            ?? (root["content"] as? [String: Any])
            ?? root
        let req = (level1["content"] as? [String: Any]) ?? level1

        let title = firstNonEmptyString(in: req, keys: ["titl", "title", "_title"], fallbackArgKeys: ["titl-loc-args", "title-loc-args"])
        let subtitle = firstNonEmptyString(in: req, keys: ["subt", "subtitle", "_subtitle"], fallbackArgKeys: ["subt-loc-args", "subtitle-loc-args"])
        let body = firstNonEmptyString(in: req, keys: ["body", "_body", "msg"], fallbackArgKeys: ["body-loc-args"])

        if title.isEmpty && subtitle.isEmpty && body.isEmpty {
            return nil
        }
        return DecodedNotificationPayload(title: title, subtitle: subtitle, body: body)
    }

    private static func firstNonEmptyString(
        in dict: [String: Any],
        keys: [String],
        fallbackArgKeys: [String]
    ) -> String {
        for key in keys {
            if let value = dict[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        for argKey in fallbackArgKeys {
            if let arr = dict[argKey] as? [Any] {
                let joined = arr.compactMap { $0 as? String }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                if !joined.isEmpty { return joined }
            }
        }
        return ""
    }

    private static func extractArchiverUID(_ value: Any) -> Int? {
        guard (CFCopyTypeIDDescription(CFGetTypeID(value as CFTypeRef)) as String?) == "CFKeyedArchiverUID" else {
            return nil
        }
        let desc = String(describing: value)
        guard let range = desc.range(of: "value = ") else { return nil }
        let suffix = desc[range.upperBound...]
        let digits = suffix.prefix { $0.isNumber }
        return Int(digits)
    }

    private static func resolveArchiverObject(
        _ value: Any,
        objects: [Any],
        depth: Int,
        visited: inout Set<Int>
    ) -> Any? {
        if depth > 16 { return nil }

        if let uid = extractArchiverUID(value) {
            guard uid > 0, uid < objects.count, !visited.contains(uid) else {
                return nil
            }
            visited.insert(uid)
            defer { visited.remove(uid) }
            return resolveArchiverObject(objects[uid], objects: objects, depth: depth + 1, visited: &visited)
        }

        if let str = value as? String {
            return str == "$null" ? nil : str
        }

        if let arr = value as? [Any] {
            return arr.compactMap { resolveArchiverObject($0, objects: objects, depth: depth + 1, visited: &visited) }
        }

        if let dict = value as? [String: Any] {
            if let nsString = dict["NS.string"] as? String {
                return nsString
            }
            if let keys = dict["NS.keys"] as? [Any], let vals = dict["NS.objects"] as? [Any] {
                var resolved: [String: Any] = [:]
                for idx in 0..<min(keys.count, vals.count) {
                    guard let k = resolveArchiverObject(keys[idx], objects: objects, depth: depth + 1, visited: &visited) as? String,
                          let v = resolveArchiverObject(vals[idx], objects: objects, depth: depth + 1, visited: &visited) else {
                        continue
                    }
                    resolved[k] = v
                }
                return resolved
            }

            var resolved: [String: Any] = [:]
            for (k, v) in dict where k != "$class" {
                if let rv = resolveArchiverObject(v, objects: objects, depth: depth + 1, visited: &visited) {
                    resolved[k] = rv
                }
            }
            return resolved
        }

        return value
    }
}
