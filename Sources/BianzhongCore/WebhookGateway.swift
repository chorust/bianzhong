import CryptoKit
import Darwin
import Foundation

public enum WebhookPreset: String, CaseIterable, Codable, Sendable, Identifiable {
    case raw
    case feishuBot = "feishu_bot"
    case slack
    case bark
    case discord
    case telegram

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .raw: return "通用 JSON (Raw)"
        case .feishuBot: return "飞书自定义机器人 (Feishu Bot)"
        case .slack: return "Slack Webhook"
        case .bark: return "Bark (iOS 推送)"
        case .discord: return "Discord Webhook"
        case .telegram: return "Telegram Bot"
        }
    }
}

public enum BianzhongURLAction: Equatable, Sendable {
    case emit(EventEnvelope, token: String?)
    case openConsole(section: String?, ruleID: String? = nil)
    case approve(id: String, comment: String?, token: String?)
    case reject(id: String, comment: String?, token: String?)

    public var isMutating: Bool {
        switch self {
        case .openConsole:
            return false
        case .emit, .approve, .reject:
            return true
        }
    }

    public var providedToken: String? {
        switch self {
        case .openConsole:
            return nil
        case .emit(_, let tok), .approve(_, _, let tok), .reject(_, _, let tok):
            return tok
        }
    }
}

/// Parses `bianzhong://` deep links from Raycast, Alfred, PopClip, Shortcuts, or browser actions.
public enum BianzhongURLRouter {
    public static func parse(_ url: URL) -> BianzhongURLAction? {
        guard url.scheme?.lowercased() == "bianzhong" else { return nil }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let host = (url.host ?? "").lowercased()
        let pathFirst = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let route = host.isEmpty ? pathFirst : host

        func query(_ name: String) -> String? {
            comps?.queryItems?.first(where: { $0.name.lowercased() == name.lowercased() })?.value
        }

        let tok = query("token")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nonEmptyTok = (tok?.isEmpty == false) ? tok : nil

        switch route {
        case "console", "settings", "preferences":
            return .openConsole(section: query("tab") ?? query("section"), ruleID: query("rule"))

        case "approve":
            guard let id = query("id"), !id.isEmpty else { return nil }
            return .approve(id: id, comment: query("note") ?? query("comment"), token: nonEmptyTok)

        case "reject", "dismiss":
            guard let id = query("id"), !id.isEmpty else { return nil }
            return .reject(id: id, comment: query("note") ?? query("comment"), token: nonEmptyTok)

        case "emit", "send", "trigger":
            let type = query("type") ?? "dev.bianzhong.url.emit"
            let source = query("source") ?? "bz://url/scheme"
            let title = query("title") ?? ""
            let subtitle = query("subtitle") ?? ""
            let body = query("body") ?? query("text") ?? ""
            let cwd = query("cwd") ?? ""
            let corr = query("correlation_key") ?? "\(type):\(title.isEmpty ? "url" : title)"
            let privacy = PrivacyLevel(rawValue: query("privacy") ?? "internal") ?? .internal

            var payload: [String: String] = [:]
            if !title.isEmpty { payload["title"] = title }
            if !subtitle.isEmpty { payload["subtitle"] = subtitle }
            if !body.isEmpty { payload["body"] = body }
            if !cwd.isEmpty { payload["cwd"] = cwd }
            let reserved = ["type", "source", "title", "subtitle", "body", "text", "cwd", "correlation_key", "privacy", "token"]
            for item in comps?.queryItems ?? [] {
                let k = item.name
                if !reserved.contains(k.lowercased()),
                   let v = item.value, !v.isEmpty {
                    payload[k] = v
                }
            }
            let env = EventEnvelope(
                source: source,
                type: type,
                correlationKey: corr,
                privacyLevel: privacy,
                payload: payload,
                ambientContext: .captureCurrent()
            )
            return .emit(env, token: nonEmptyTok)

        default:
            return nil
        }
    }
}

/// Cryptographic signing & outbound payload formatting for multi-platform webhooks.
public enum OutboundWebhookBuilder {
    public struct BuiltWebhookRequest: Sendable {
        public let body: Data
        public let headers: [String: String]
    }

    public static func hmacSHA256Hex(key: String, data: Data) -> String {
        let symKey = SymmetricKey(data: Data(key.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: symKey)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// Computes Feishu Custom Bot signature (`Base64(HMAC_SHA256(key: "\(timestamp)\n\(secret)", data: ""))`).
    public static func feishuBotSign(timestamp: Int64, secret: String) -> String {
        let stringToSign = "\(timestamp)\n\(secret)"
        let symKey = SymmetricKey(data: Data(stringToSign.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(), using: symKey)
        return Data(mac).base64EncodedString()
    }

    /// Generates a signed remote approval/rejection callback URL valid up to `ttlSeconds`.
    public static func signedApprovalURL(
        baseURL: String,
        approvalID: String,
        action: String,
        token: String,
        ttlSeconds: Int = 86400,
        nowUnix: Int64 = Int64(Date().timeIntervalSince1970)
    ) -> String? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty, !token.isEmpty else { return nil }
        let exp = nowUnix + Int64(ttlSeconds)
        let msg = "\(approvalID):\(action):\(exp)"
        let sig = hmacSHA256Hex(key: token, data: Data(msg.utf8))
        let encodedID = approvalID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? approvalID
        return "\(trimmed)/v1/approvals/\(encodedID)/\(action)?exp=\(exp)&sig=\(sig)"
    }

    public static func verifyApprovalSignature(
        approvalID: String,
        action: String,
        expString: String?,
        signature: String?,
        token: String,
        nowUnix: Int64 = Int64(Date().timeIntervalSince1970)
    ) -> Bool {
        guard !token.isEmpty,
              let expStr = expString, let exp = Int64(expStr), exp >= nowUnix,
              let sig = signature?.lowercased(), !sig.isEmpty else {
            return false
        }
        let msg = "\(approvalID):\(action):\(exp)"
        let expected = hmacSHA256Hex(key: token, data: Data(msg.utf8))
        return constantTimeEquals(sig, expected)
    }

    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        guard aBytes.count == bBytes.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<aBytes.count {
            diff |= aBytes[i] ^ bBytes[i]
        }
        return diff == 0
    }

    public static func build(
        preset: WebhookPreset,
        title: String,
        text: String,
        chimeID: String,
        phase: String,
        riskLevel: String,
        correlationKey: String,
        sessionID: String?,
        approvalID: String?,
        secret: String?,
        bearerToken: String?,
        chatID: String?,
        approveCallbackURL: String? = nil,
        rejectCallbackURL: String? = nil,
        timestampUnix: Int64 = Int64(Date().timeIntervalSince1970)
    ) throws -> BuiltWebhookRequest {
        var headers: [String: String] = ["Content-Type": "application/json; charset=utf-8"]
        if let bearerToken, !bearerToken.isEmpty {
            headers["Authorization"] = "Bearer \(bearerToken)"
        }

        let obj: [String: Any]
        switch preset {
        case .feishuBot:
            let headerTemplate: String
            switch riskLevel.lowercased() {
            case "high": headerTemplate = "red"
            case "medium": headerTemplate = "orange"
            default: headerTemplate = "blue"
            }
            var elements: [[String: Any]] = [
                [
                    "tag": "markdown",
                    "content": "**规则**: `\(chimeID)` · **阶段**: `\(phase)`\n\n\(text)"
                ]
            ]
            var actions: [[String: Any]] = []
            if let approveURL = approveCallbackURL, !approveURL.isEmpty {
                actions.append([
                    "tag": "button",
                    "text": ["tag": "plain_text", "content": "批准执行"],
                    "type": "primary",
                    "url": approveURL
                ])
            }
            if let rejectURL = rejectCallbackURL, !rejectURL.isEmpty {
                actions.append([
                    "tag": "button",
                    "text": ["tag": "plain_text", "content": "忽略"],
                    "type": "default",
                    "url": rejectURL
                ])
            }
            if !actions.isEmpty {
                elements.append([
                    "tag": "action",
                    "actions": actions
                ])
            }
            var root: [String: Any] = [
                "msg_type": "interactive",
                "card": [
                    "header": [
                        "title": ["tag": "plain_text", "content": "🔔 \(title)"],
                        "template": headerTemplate
                    ],
                    "elements": elements
                ]
            ]
            if let secret, !secret.isEmpty {
                root["timestamp"] = "\(timestampUnix)"
                root["sign"] = feishuBotSign(timestamp: timestampUnix, secret: secret)
            }
            obj = root

        case .slack:
            var blocks: [[String: Any]] = [
                [
                    "type": "section",
                    "text": [
                        "type": "mrkdwn",
                        "text": "*\(title)* (`\(chimeID)`)\n\(text)"
                    ]
                ]
            ]
            if let approveURL = approveCallbackURL {
                blocks.append([
                    "type": "context",
                    "elements": [["type": "mrkdwn", "text": "<\(approveURL)|远程批准执行>"]]
                ])
            }
            obj = [
                "text": "\(title)\n\(text)",
                "blocks": blocks
            ]

        case .bark:
            var root: [String: Any] = [
                "title": title,
                "body": text,
                "group": "Bianzhong"
            ]
            if let approveURL = approveCallbackURL {
                root["url"] = approveURL
            }
            obj = root

        case .discord:
            let colorInt: Int
            switch riskLevel.lowercased() {
            case "high": colorInt = 0xE5484D
            case "medium": colorInt = 0xF76B15
            default: colorInt = 0x3E63DD
            }
            var desc = text
            if let approveURL = approveCallbackURL {
                desc += "\n\n[远程批准执行](\(approveURL))"
            }
            obj = [
                "username": "Bianzhong",
                "embeds": [
                    [
                        "title": title,
                        "description": desc,
                        "color": colorInt,
                        "footer": ["text": "\(chimeID) • \(phase)"]
                    ]
                ]
            ]

        case .telegram:
            var msg = "*\(title)*\n\(text)"
            if let approveURL = approveCallbackURL {
                msg += "\n\n\(approveURL)"
            }
            obj = [
                "chat_id": chatID ?? "",
                "text": msg
            ]

        case .raw:
            var root: [String: String] = [
                "title": title,
                "body": text,
                "text": "\(title)\n\(text)",
                "chime_id": chimeID,
                "phase": phase,
                "risk_level": riskLevel,
                "correlation_key": correlationKey,
                "session_id": sessionID ?? "",
                "approval_id": approvalID ?? ""
            ]
            if let approveURL = approveCallbackURL {
                root["approve_url"] = approveURL
            }
            if let rejectURL = rejectCallbackURL {
                root["reject_url"] = rejectURL
            }
            obj = root
        }

        let body = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        if preset != .feishuBot, let secret, !secret.isEmpty {
            let sig = hmacSHA256Hex(key: secret, data: body)
            headers["X-Bianzhong-Signature"] = "sha256=\(sig)"
        }
        return BuiltWebhookRequest(body: body, headers: headers)
    }
}

/// Normalizes inbound third-party JSON webhooks into `EventEnvelope` records.
public enum InboundWebhookNormalizer {
    public enum NormalizationResult {
        case challengeResponse(Data)
        case event(EventEnvelope)
    }

    public static func normalizeEmit(body: Data) throws -> EventEnvelope {
        if let full = try? JSONDecoder().decode(EventEnvelope.self, from: body) {
            return full
        }
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw NSError(domain: "WebhookGateway", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON payload"])
        }
        let type = (obj["type"] as? String)?.nonEmpty ?? "dev.bianzhong.webhook.emit"
        let source = (obj["source"] as? String)?.nonEmpty ?? "bz://webhook/http"
        let title = (obj["title"] as? String) ?? ""
        let subtitle = (obj["subtitle"] as? String) ?? ""
        let text = (obj["body"] as? String) ?? (obj["text"] as? String) ?? (obj["message"] as? String) ?? ""
        let cwd = (obj["cwd"] as? String) ?? ""
        let corr = (obj["correlation_key"] as? String)?.nonEmpty ?? "\(type):\(title.isEmpty ? "http" : title)"
        let privacy = PrivacyLevel(rawValue: (obj["privacy_level"] as? String) ?? "internal") ?? .internal

        var payload: [String: String] = [:]
        if let nested = obj["payload"] as? [String: Any] {
            for (k, v) in nested {
                payload[k] = stringify(v)
            }
        }
        for (k, v) in obj where !["type", "source", "correlation_key", "privacy_level", "payload"].contains(k) {
            let s = stringify(v)
            if !s.isEmpty { payload[k] = s }
        }
        if !title.isEmpty { payload["title"] = title }
        if !subtitle.isEmpty { payload["subtitle"] = subtitle }
        if !text.isEmpty { payload["body"] = text }
        if !cwd.isEmpty { payload["cwd"] = cwd }

        return EventEnvelope(
            source: source,
            type: type,
            correlationKey: corr,
            privacyLevel: privacy,
            payload: payload,
            ambientContext: .captureCurrent()
        )
    }

    public static func normalizePreset(_ preset: String, headers: [String: String], body: Data) throws -> NormalizationResult {
        let obj = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let lower = preset.lowercased()

        // Feishu URL verification handshake
        if let challenge = obj["challenge"] as? String, !challenge.isEmpty {
            let reply = try JSONSerialization.data(withJSONObject: ["challenge": challenge])
            return .challengeResponse(reply)
        }

        switch lower {
        case "github":
            let ghEvent = headers["x-github-event"]?.lowercased() ?? "webhook"
            let repo = ((obj["repository"] as? [String: Any])?["full_name"] as? String) ?? "github"
            var title = "GitHub \(ghEvent): \(repo)"
            var detail = (obj["action"] as? String) ?? ""
            var eventType = "dev.bianzhong.github.\(ghEvent)"

            if let wf = obj["workflow_run"] as? [String: Any] {
                let name = (wf["name"] as? String) ?? "workflow"
                let conclusion = (wf["conclusion"] as? String) ?? (wf["status"] as? String) ?? ""
                let branch = (wf["head_branch"] as? String) ?? ""
                title = "[\(repo)] \(name) (\(conclusion))"
                detail = "branch=\(branch) url=\((wf["html_url"] as? String) ?? "")"
                if conclusion == "failure" {
                    eventType = "dev.bianzhong.ci.failed"
                }
            } else if let pr = obj["pull_request"] as? [String: Any] {
                let prTitle = (pr["title"] as? String) ?? ""
                title = "[\(repo)] PR: \(prTitle)"
                detail = (pr["body"] as? String) ?? detail
            } else if let issue = obj["issue"] as? [String: Any] {
                title = "[\(repo)] Issue: \((issue["title"] as? String) ?? "")"
                detail = (issue["body"] as? String) ?? detail
            }

            let env = EventEnvelope(
                source: "bz://webhook/github",
                type: eventType,
                correlationKey: "github:\(repo)",
                privacyLevel: .internal,
                payload: [
                    "title": title,
                    "subtitle": repo,
                    "body": detail,
                    "github_event": ghEvent
                ],
                ambientContext: .captureCurrent()
            )
            return .event(env)

        case "sentry", "grafana", "alertmanager":
            let title = (obj["title"] as? String)
                ?? (obj["ruleName"] as? String)
                ?? (obj["project_name"] as? String)
                ?? "\(preset.capitalized) Alert"
            let message = (obj["message"] as? String)
                ?? (obj["body"] as? String)
                ?? (obj["state"] as? String)
                ?? String(data: body.prefix(1024), encoding: .utf8)
                ?? ""
            let env = EventEnvelope(
                source: "bz://webhook/\(lower)",
                type: "dev.bianzhong.alert.\(lower)",
                correlationKey: "alert:\(lower):\(title)",
                privacyLevel: .internal,
                payload: [
                    "title": title,
                    "subtitle": preset.capitalized,
                    "body": message
                ],
                ambientContext: .captureCurrent()
            )
            return .event(env)

        case "feishu":
            let header = obj["header"] as? [String: Any]
            let evType = (header?["event_type"] as? String) ?? "message"
            let eventObj = (obj["event"] as? [String: Any]) ?? obj
            let title = (eventObj["title"] as? String) ?? "飞书 Webhook"
            let content = (eventObj["text"] as? String)
                ?? ((eventObj["message"] as? [String: Any])?["content"] as? String)
                ?? String(data: body.prefix(1024), encoding: .utf8)
                ?? ""
            let env = EventEnvelope(
                source: "bz://webhook/feishu",
                type: "dev.bianzhong.feishu.webhook",
                correlationKey: "feishu:webhook:\(evType)",
                privacyLevel: .sensitive,
                payload: [
                    "title": title,
                    "subtitle": evType,
                    "body": content
                ],
                ambientContext: .captureCurrent()
            )
            return .event(env)

        default:
            let title = (obj["title"] as? String)
                ?? (obj["subject"] as? String)
                ?? (obj["name"] as? String)
                ?? "Webhook (\(lower))"
            let message = (obj["body"] as? String)
                ?? (obj["text"] as? String)
                ?? (obj["message"] as? String)
                ?? (obj["description"] as? String)
                ?? String(data: body.prefix(1024), encoding: .utf8)
                ?? ""
            var payload: [String: String] = [
                "title": title,
                "subtitle": lower,
                "body": message
            ]
            for (k, v) in obj where payload[k] == nil {
                let s = stringify(v)
                if !s.isEmpty { payload[k] = String(s.prefix(512)) }
            }
            let env = EventEnvelope(
                source: "bz://webhook/\(lower)",
                type: "dev.bianzhong.webhook.\(lower)",
                correlationKey: "webhook:\(lower):\(title)",
                privacyLevel: .internal,
                payload: payload,
                ambientContext: .captureCurrent()
            )
            return .event(env)
        }
    }

    private static func stringify(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return ""
    }
}

public struct HTTPWebhookRequest: Sendable {
    public let method: String
    public let path: String
    public let queryItems: [String: String]
    public let headers: [String: String]
    public let body: Data
}

public struct HTTPWebhookResponse: Sendable {
    public let statusCode: Int
    public let contentType: String
    public let body: Data
    public let extraHeaders: [String: String]

    public init(statusCode: Int, contentType: String, body: Data, extraHeaders: [String: String] = [:]) {
        self.statusCode = statusCode
        self.contentType = contentType
        self.body = body
        self.extraHeaders = extraHeaders
    }

    public static func json(_ status: Int, _ dict: [String: Any], extraHeaders: [String: String] = [:]) -> HTTPWebhookResponse {
        let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data("{}".utf8)
        return HTTPWebhookResponse(statusCode: status, contentType: "application/json; charset=utf-8", body: data, extraHeaders: extraHeaders)
    }

    public static func html(_ status: Int, _ htmlString: String, extraHeaders: [String: String] = [:]) -> HTTPWebhookResponse {
        HTTPWebhookResponse(statusCode: status, contentType: "text/html; charset=utf-8", body: Data(htmlString.utf8), extraHeaders: extraHeaders)
    }
}

/// Embedded zero-dependency HTTP/1.1 Webhook Server built on POSIX sockets (`127.0.0.1` by default).
public final class WebhookServer: @unchecked Sendable {
    public let host: String
    public let requestedPort: UInt16
    public private(set) var boundPort: UInt16 = 0

    private let tokenProvider: @Sendable () -> String
    private let onEmit: @Sendable (EventEnvelope) -> (ok: Bool, disposition: String)
    private let onInspectApproval: @Sendable (_ id: String) -> (pending: Bool, title: String)?
    private let onResolveApproval: @Sendable (_ id: String, _ approve: Bool, _ comment: String?) -> Bool
    private let onPocketState: @Sendable () -> Data
    private let onPocketAction: @Sendable ([String: Any]) -> (ok: Bool, message: String)

    private let queue = DispatchQueue(label: "dev.bianzhong.webhook-http", qos: .userInitiated, attributes: .concurrent)
    private let connectionSemaphore = DispatchSemaphore(value: 16)
    private let lock = NSLock()
    private var serverFD: Int32 = -1
    private var running = false

    public init(
        host: String = "127.0.0.1",
        port: UInt16 = 17380,
        tokenProvider: @escaping @Sendable () -> String,
        onEmit: @escaping @Sendable (EventEnvelope) -> (ok: Bool, disposition: String),
        onInspectApproval: @escaping @Sendable (_ id: String) -> (pending: Bool, title: String)? = { _ in (true, "Bianzhong Approval") },
        onResolveApproval: @escaping @Sendable (_ id: String, _ approve: Bool, _ comment: String?) -> Bool,
        onPocketState: @escaping @Sendable () -> Data = { Data("{}".utf8) },
        onPocketAction: @escaping @Sendable ([String: Any]) -> (ok: Bool, message: String) = { _ in (false, "Unsupported") }
    ) {
        self.host = host
        self.requestedPort = port
        self.tokenProvider = tokenProvider
        self.onEmit = onEmit
        self.onInspectApproval = onInspectApproval
        self.onResolveApproval = onResolveApproval
        self.onPocketState = onPocketState
        self.onPocketAction = onPocketAction
    }

    deinit {
        stop()
    }

    public var isRunning: Bool {
        lock.withLock { running }
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        if running { return }

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "WebhookServer", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = requestedPort.bigEndian

        let targetHost = (host.isEmpty || host == "localhost") ? "127.0.0.1" : host
        guard inet_pton(AF_INET, targetHost, &addr.sin_addr) == 1 else {
            Darwin.close(fd)
            throw NSError(domain: "WebhookServer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid IPv4 bind address: \(host)"])
        }

        let bindRC = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRC == 0 else {
            let msg = String(cString: strerror(errno))
            Darwin.close(fd)
            throw NSError(domain: "WebhookServer", code: 3, userInfo: [NSLocalizedDescriptionKey: "Port \(requestedPort) bind failed: \(msg)"])
        }

        guard Darwin.listen(fd, 32) == 0 else {
            let msg = String(cString: strerror(errno))
            Darwin.close(fd)
            throw NSError(domain: "WebhookServer", code: 4, userInfo: [NSLocalizedDescriptionKey: "Listen failed: \(msg)"])
        }

        var actualAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actualAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.getsockname(fd, saPtr, &len)
            }
        }
        self.boundPort = UInt16(bigEndian: actualAddr.sin_port)
        self.serverFD = fd
        self.running = true

        queue.async { [weak self] in
            self?.acceptLoop(listenFD: fd)
        }
    }

    public func stop() {
        lock.lock()
        let wasRunning = running
        let fd = serverFD
        running = false
        serverFD = -1
        boundPort = 0
        lock.unlock()

        if wasRunning && fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }

    private func acceptLoop(listenFD: Int32) {
        while lock.withLock({ running }) {
            var clientAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    Darwin.accept(listenFD, saPtr, &addrLen)
                }
            }
            if clientFD < 0 {
                if errno == EINTR { continue }
                break
            }
            if connectionSemaphore.wait(timeout: .now() + 0.5) == .timedOut {
                writeHTTPResponse(fd: clientFD, response: .json(503, ["ok": false, "error": "Server busy"]))
                Darwin.close(clientFD)
                continue
            }
            let sem = connectionSemaphore
            queue.async { [weak self] in
                defer { sem.signal() }
                self?.handleClient(fd: clientFD)
            }
        }
    }

    private func handleClient(fd: Int32) {
        defer { Darwin.close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        guard let req = readHTTPRequest(fd: fd) else {
            writeHTTPResponse(fd: fd, response: .json(400, ["ok": false, "error": "Malformed HTTP request"]))
            return
        }
        let resp = route(req)
        writeHTTPResponse(fd: fd, response: resp)
    }

    private func route(_ req: HTTPWebhookRequest) -> HTTPWebhookResponse {
        if req.method == "GET" && (req.path == "/v1/health" || req.path == "/health") {
            return .json(200, ["ok": true, "service": "bianzhong", "port": Int(boundPort)])
        }

        // Static Mobile Pocket Console PWA shell (all data endpoints under /v1/pocket/* require Bearer header)
        if req.method == "GET" {
            let secHeaders = ["X-Frame-Options": "DENY", "X-Content-Type-Options": "nosniff"]
            switch req.path {
            case "/pocket", "/pocket/":
                return .html(200, PocketConsoleAssets.indexHTML, extraHeaders: secHeaders)
            case "/pocket/manifest.json":
                return HTTPWebhookResponse(statusCode: 200, contentType: "application/manifest+json; charset=utf-8", body: Data(PocketConsoleAssets.manifestJSON.utf8), extraHeaders: secHeaders)
            case "/pocket/sw.js":
                return HTTPWebhookResponse(statusCode: 200, contentType: "application/javascript; charset=utf-8", body: Data(PocketConsoleAssets.serviceWorkerJS.utf8), extraHeaders: secHeaders)
            case "/pocket/icon.svg":
                return HTTPWebhookResponse(statusCode: 200, contentType: "image/svg+xml; charset=utf-8", body: Data(PocketConsoleAssets.iconSVG.utf8), extraHeaders: secHeaders)
            default:
                break
            }
        }

        let secretToken = tokenProvider()
        let pathParts = req.path.split(separator: "/").map(String.init)

        // Pocket API routes enforce strict Header-only Bearer auth (rejecting query ?token= for CSRF defense) + no-store
        if req.path == "/v1/pocket/state" || req.path == "/v1/pocket/act" {
            let pocketHeaders = ["Cache-Control": "no-store", "X-Frame-Options": "DENY", "X-Content-Type-Options": "nosniff"]
            guard isHeaderBearerAuthorized(req: req, secretToken: secretToken) else {
                return .json(401, ["ok": false, "error": "Unauthorized (Bearer header required)"], extraHeaders: pocketHeaders)
            }
            if req.method == "GET" && req.path == "/v1/pocket/state" {
                return HTTPWebhookResponse(statusCode: 200, contentType: "application/json; charset=utf-8", body: onPocketState(), extraHeaders: pocketHeaders)
            }
            if req.method == "POST" && req.path == "/v1/pocket/act" {
                let obj = (try? JSONSerialization.jsonObject(with: req.body) as? [String: Any]) ?? [:]
                let out = onPocketAction(obj)
                return .json(out.ok ? 200 : 400, ["ok": out.ok, "message": out.message], extraHeaders: pocketHeaders)
            }
            return .json(405, ["ok": false, "error": "Method not allowed"], extraHeaders: pocketHeaders)
        }

        // Approval callback route: /v1/approvals/:id/approve|reject
        // Note: GET/HEAD never mutates state so IM link-preview unfurl bots cannot auto-trigger Phase 2!
        if pathParts.count == 4,
           pathParts[0] == "v1",
           pathParts[1] == "approvals",
           (pathParts[3] == "approve" || pathParts[3] == "reject") {
            let approvalID = pathParts[2].removingPercentEncoding ?? pathParts[2]
            let action = pathParts[3]
            let signedOK = OutboundWebhookBuilder.verifyApprovalSignature(
                approvalID: approvalID,
                action: action,
                expString: req.queryItems["exp"],
                signature: req.queryItems["sig"],
                token: secretToken
            )
            let tokenOK = isAuthorized(req: req, secretToken: secretToken)
            guard signedOK || tokenOK else {
                return .json(401, ["ok": false, "error": "Unauthorized"])
            }

            let safeID = htmlEscape(approvalID)
            if req.method == "HEAD" {
                return HTTPWebhookResponse(statusCode: 200, contentType: "text/html; charset=utf-8", body: Data())
            }
            if req.method == "GET" {
                guard let info = onInspectApproval(approvalID) else {
                    return .json(404, ["ok": false, "error": "Approval not found: \(approvalID)"])
                }
                let safeTitle = htmlEscape(info.title)
                if !info.pending {
                    return .html(200, "<!doctype html><html><meta charset='utf-8'><body style='font-family:-apple-system,sans-serif;padding:32px'><h2>ℹ️ Bianzhong：该审批单已处理</h2><p>标题：\(safeTitle)</p><p>单号：<code>\(safeID)</code></p></body></html>")
                }
                let verb = action == "approve" ? "批准执行" : "忽略此项"
                let encodedPathID = approvalID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? safeID
                var queryParts: [String] = []
                if let exp = req.queryItems["exp"] { queryParts.append("exp=\(urlQueryEscape(exp))") }
                if let sig = req.queryItems["sig"] { queryParts.append("sig=\(urlQueryEscape(sig))") }
                if let tok = req.queryItems["token"] { queryParts.append("token=\(urlQueryEscape(tok))") }
                let qs = queryParts.isEmpty ? "" : "?\(queryParts.joined(separator: "&"))"
                let actionAttr = htmlEscape("/v1/approvals/\(encodedPathID)/\(action)\(qs)")
                let btnBg = action == "approve" ? "#007AFF" : "#666666"
                let html = """
                <!doctype html><html><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>
                <body style='font-family:-apple-system,sans-serif;padding:32px;max-width:520px;margin:0 auto'>
                <h2>🔔 Bianzhong 远程审批确认</h2>
                <p><strong>\(safeTitle)</strong></p>
                <p style='color:#666;font-size:13px'>审批单号：<code>\(safeID)</code></p>
                <form method='POST' action='\(actionAttr)' style='margin-top:20px'>
                  <input type='text' name='comment' placeholder='可选审批备注...' style='width:100%;padding:8px;margin-bottom:12px;box-sizing:border-box;border:1px solid #ccc;border-radius:6px'>
                  <button type='submit' style='background:\(btnBg);color:#fff;border:none;padding:10px 20px;border-radius:6px;font-size:15px;cursor:pointer'>确认\(verb)</button>
                </form>
                </body></html>
                """
                return .html(200, html)
            }

            guard req.method == "POST" else {
                return .json(405, ["ok": false, "error": "Method not allowed"])
            }

            var comment = req.queryItems["comment"] ?? req.queryItems["note"]
            if comment == nil, !req.body.isEmpty {
                if (req.headers["content-type"] ?? "").lowercased().contains("application/x-www-form-urlencoded"),
                   let formStr = String(data: req.body, encoding: .utf8) {
                    comment = parseFormURLEncoded(formStr)["comment"]?.nonEmpty
                } else if let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] {
                    comment = (obj["comment"] as? String) ?? (obj["note"] as? String)
                }
            }

            let resolved = onResolveApproval(approvalID, action == "approve", comment)
            let acceptsHTML = (req.headers["accept"] ?? "").contains("text/html")
            guard resolved else {
                if acceptsHTML {
                    return .html(409, "<!doctype html><html><meta charset='utf-8'><body style='font-family:-apple-system,sans-serif;padding:32px'><h2>⚠️ 该审批单已被处理或不存在</h2><p>单号：<code>\(safeID)</code></p></body></html>")
                }
                return .json(409, ["ok": false, "error": "Approval already resolved or not found: \(approvalID)"])
            }

            if acceptsHTML {
                let verb = action == "approve" ? "已批准执行" : "已忽略"
                return .html(200, "<!doctype html><html><meta charset='utf-8'><body style='font-family:-apple-system,sans-serif;padding:32px'><h2>✅ Bianzhong：\(verb)</h2><p>审批单号：<code>\(safeID)</code></p></body></html>")
            }
            return .json(200, ["ok": true, "approval_id": approvalID, "action": action])
        }

        guard isAuthorized(req: req, secretToken: secretToken) else {
            return .json(401, ["ok": false, "error": "Unauthorized (missing or invalid token/signature)"])
        }

        guard req.method == "POST" else {
            return .json(405, ["ok": false, "error": "Method not allowed"])
        }

        if req.path == "/v1/emit" {
            do {
                let event = try InboundWebhookNormalizer.normalizeEmit(body: req.body)
                let out = onEmit(event)
                return .json(200, ["ok": out.ok, "event_id": event.id, "disposition": out.disposition])
            } catch {
                return .json(400, ["ok": false, "error": error.localizedDescription])
            }
        }

        if pathParts.count == 3 && pathParts[0] == "v1" && pathParts[1] == "hooks" {
            let preset = pathParts[2]
            do {
                switch try InboundWebhookNormalizer.normalizePreset(preset, headers: req.headers, body: req.body) {
                case .challengeResponse(let replyData):
                    return HTTPWebhookResponse(statusCode: 200, contentType: "application/json; charset=utf-8", body: replyData)
                case .event(let event):
                    let out = onEmit(event)
                    return .json(200, ["ok": out.ok, "event_id": event.id, "disposition": out.disposition])
                }
            } catch {
                return .json(400, ["ok": false, "error": error.localizedDescription])
            }
        }

        return .json(404, ["ok": false, "error": "Unknown route: \(req.path)"])
    }

    private func isHeaderBearerAuthorized(req: HTTPWebhookRequest, secretToken: String) -> Bool {
        guard !secretToken.isEmpty else { return false }
        if let auth = req.headers["authorization"] {
            let trimmed = auth.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("bearer ") {
                let candidate = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                if OutboundWebhookBuilder.constantTimeEquals(candidate, secretToken) {
                    return true
                }
            }
        }
        if let headerTok = req.headers["x-bianzhong-token"],
           OutboundWebhookBuilder.constantTimeEquals(headerTok, secretToken) {
            return true
        }
        return false
    }

    private func isAuthorized(req: HTTPWebhookRequest, secretToken: String) -> Bool {
        guard !secretToken.isEmpty else { return false }

        if let auth = req.headers["authorization"] {
            let trimmed = auth.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("bearer ") {
                let candidate = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                if OutboundWebhookBuilder.constantTimeEquals(candidate, secretToken) {
                    return true
                }
            }
        }
        if let headerTok = req.headers["x-bianzhong-token"],
           OutboundWebhookBuilder.constantTimeEquals(headerTok, secretToken) {
            return true
        }
        if let queryTok = req.queryItems["token"],
           OutboundWebhookBuilder.constantTimeEquals(queryTok, secretToken) {
            return true
        }
        if let sigHeader = req.headers["x-hub-signature-256"] ?? req.headers["x-bianzhong-signature"] {
            let cleanSig = sigHeader.lowercased().replacingOccurrences(of: "sha256=", with: "")
            let expected = OutboundWebhookBuilder.hmacSHA256Hex(key: secretToken, data: req.body)
            if OutboundWebhookBuilder.constantTimeEquals(cleanSig, expected) {
                return true
            }
        }
        // Feishu Open Platform Event Subscription Verification Token in JSON payload (`token` or `header.token`)
        if req.path.lowercased() == "/v1/hooks/feishu",
           !req.body.isEmpty,
           let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] {
            let bodyTok = (obj["token"] as? String) ?? ((obj["header"] as? [String: Any])?["token"] as? String)
            if let bodyTok, OutboundWebhookBuilder.constantTimeEquals(bodyTok, secretToken) {
                return true
            }
        }
        return false
    }

    private func readHTTPRequest(fd: Int32) -> HTTPWebhookRequest? {
        let maxHeaderBytes = 32 * 1024
        let maxBodyBytes = 1_048_576
        let separator = Data("\r\n\r\n".utf8)
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        var headerEndRange: Range<Data.Index>?

        while headerEndRange == nil {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(chunk, count: n)
                headerEndRange = buffer.range(of: separator)
                if buffer.count > maxHeaderBytes && headerEndRange == nil {
                    return nil
                }
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }

        guard let sepRange = headerEndRange,
              let headerText = String(data: buffer[..<sepRange.lowerBound], encoding: .utf8) else {
            return nil
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let rawTarget = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[k] = v
        }

        let contentLength = max(0, Int(headers["content-length"] ?? "0") ?? 0)
        guard contentLength <= maxBodyBytes else { return nil }

        if (headers["expect"] ?? "").lowercased().contains("100-continue") {
            let cont = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)
            _ = cont.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.write(fd, base, raw.count)
            }
        }

        var body = Data(buffer[sepRange.upperBound...])
        while body.count < contentLength {
            let n = Darwin.read(fd, &chunk, min(chunk.count, contentLength - body.count))
            if n > 0 {
                body.append(chunk, count: n)
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        guard body.count >= contentLength else {
            return nil
        }
        if body.count > contentLength {
            body = body.prefix(contentLength)
        }

        let urlComps = URLComponents(string: "http://localhost\(rawTarget.hasPrefix("/") ? rawTarget : "/" + rawTarget)")
        let cleanPath = urlComps?.path ?? rawTarget
        var queryMap: [String: String] = [:]
        for item in urlComps?.queryItems ?? [] {
            if let val = item.value {
                queryMap[item.name] = val
            }
        }

        return HTTPWebhookRequest(
            method: method,
            path: cleanPath,
            queryItems: queryMap,
            headers: headers,
            body: body
        )
    }

    private func writeHTTPResponse(fd: Int32, response: HTTPWebhookResponse) {
        let reason: String
        switch response.statusCode {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 409: reason = "Conflict"
        case 503: reason = "Service Unavailable"
        default: reason = "Server Error"
        }

        var headLines = [
            "HTTP/1.1 \(response.statusCode) \(reason)",
            "Content-Type: \(response.contentType)",
            "Content-Length: \(response.body.count)",
            "Connection: close"
        ]
        for (hk, hv) in response.extraHeaders.sorted(by: { $0.key < $1.key }) {
            headLines.append("\(hk): \(hv)")
        }
        headLines.append("")
        headLines.append("")
        let head = headLines.joined(separator: "\r\n")

        var packet = Data(head.utf8)
        packet.append(response.body)
        _ = packet.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }
}

private func htmlEscape(_ raw: String) -> String {
    raw
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}

private func urlQueryEscape(_ raw: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&+=?")
    return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
}

private func parseFormURLEncoded(_ raw: String) -> [String: String] {
    var out: [String: String] = [:]
    for pair in raw.split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1)
        guard !kv.isEmpty else { continue }
        let key = String(kv[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(kv[0])
        let val = kv.count > 1
            ? (String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(kv[1]))
            : ""
        out[key] = val
    }
    return out
}

private extension String {
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
