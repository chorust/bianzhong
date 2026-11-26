import Foundation
import Security

/// Manages local secrets (`chmod 0600` JSON outside `~/.config/bianzhong` so keys never leak into Git),
/// solving the macOS GUI `.app` limitation where `~/.zshrc` environment variables are not inherited.
public enum SecretStore {
    public static let webhookTokenKey = "BIANZHONG_WEBHOOK_TOKEN"
    private static let lock = NSLock()

    public static func loadAll(paths: BianzhongPaths = BianzhongPaths()) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return readRawUnlocked(from: paths.secretsFile)
    }

    /// Resolves `key` from local `secrets.json` first, falling back to process environment variables.
    public static func resolve(_ key: String, paths: BianzhongPaths = BianzhongPaths()) -> String? {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return nil }

        lock.lock()
        let stored = readRawUnlocked(from: paths.secretsFile)[trimmedKey]
        lock.unlock()

        if let stored, !stored.isEmpty {
            return stored
        }
        if let envVal = ProcessInfo.processInfo.environment[trimmedKey], !envVal.isEmpty {
            return envVal
        }
        return nil
    }

    public static func set(key: String, value: String, paths: BianzhongPaths = BianzhongPaths()) throws {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }
        var map = readRawUnlocked(from: paths.secretsFile)
        if value.isEmpty {
            map.removeValue(forKey: trimmedKey)
        } else {
            map[trimmedKey] = value
        }
        try writeRawUnlocked(map, to: paths.secretsFile)
    }

    public static func remove(key: String, paths: BianzhongPaths = BianzhongPaths()) throws {
        try set(key: key, value: "", paths: paths)
    }

    /// Returns the existing inbound webhook token or generates and persists a new 256-bit random hex token.
    @discardableResult
    public static func ensureWebhookToken(paths: BianzhongPaths = BianzhongPaths()) -> String {
        if let existing = resolve(webhookTokenKey, paths: paths), !existing.isEmpty {
            return existing
        }
        let fresh = generateRandomHex(byteCount: 24)
        try? set(key: webhookTokenKey, value: fresh, paths: paths)
        return fresh
    }

    @discardableResult
    public static func rotateWebhookToken(paths: BianzhongPaths = BianzhongPaths()) throws -> String {
        let fresh = generateRandomHex(byteCount: 24)
        try set(key: webhookTokenKey, value: fresh, paths: paths)
        return fresh
    }

    public static func maskedPreview(_ secret: String) -> String {
        guard secret.count > 8 else { return String(repeating: "•", count: max(4, secret.count)) }
        return "\(secret.prefix(4))••••\(secret.suffix(4))"
    }

    private static func generateRandomHex(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        if status == errSecSuccess {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func readRawUnlocked(from url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func writeRawUnlocked(_ dict: [String: String], to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(dict)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
