import Foundation
import SQLite3

/// Standalone read-only sensor querying macOS `usernoted` SQLite (`com.electron.lark` only).
/// Full Disk Access is isolated strictly at runtime to `bz-feishu-sensor` so core Bianzhong & agents stay Zero-TCC.
public final class FeishuSensorRunner: @unchecked Sendable {
    public let dbURL: URL
    public let cursorURL: URL
    public let socketURL: URL
    public let bundleFilter: String
    public let skipExistingOnFirstRun: Bool

    private var lastRecID: Int64
    private let lock = NSLock()

    public init(
        dbURL: URL,
        cursorURL: URL,
        socketURL: URL,
        bundleFilter: String = "com.electron.lark",
        skipExistingOnFirstRun: Bool = true
    ) {
        self.dbURL = dbURL
        self.cursorURL = cursorURL
        self.socketURL = socketURL
        self.bundleFilter = bundleFilter
        self.skipExistingOnFirstRun = skipExistingOnFirstRun
        self.lastRecID = Self.loadCursor(from: cursorURL)
    }

    public func currentCursor() -> Int64 {
        lock.withLock { lastRecID }
    }

    private static func loadCursor(from url: URL) -> Int64 {
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
              let val = Int64(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return 0
        }
        return val
    }

    private func saveCursor(_ recID: Int64) {
        try? FileManager.default.createDirectory(at: cursorURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "\(recID)\n".write(to: cursorURL, atomically: true, encoding: .utf8)
    }

    /// Reads new `com.electron.lark` records since `lastRecID` and returns emitted count.
    /// Cursor advances strictly up to the last record acknowledged by the daemon (`resp.ok == true`),
    /// so offline/restart windows never silently drop notifications.
    @discardableResult
    public func pollOnce(dryRun: Bool = false) throws -> Int {
        lock.lock()
        defer { lock.unlock() }

        var db: OpaquePointer?
        let rc = sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let handle = db else {
            let err = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(rc)"
            sqlite3_close(db)
            if rc == SQLITE_CANTOPEN || rc == SQLITE_PERM {
                fputs("""
                [bz-feishu-sensor] Unable to open \(dbURL.path): \(err)
                Grant Full Disk Access ONLY to dist/BianzhongFeishuSensor.app in:
                  System Settings -> Privacy & Security -> Full Disk Access
                """, stderr)
            }
            throw NSError(domain: "FeishuSensor", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: err])
        }
        defer { sqlite3_close(handle) }

        if lastRecID == 0 && !dryRun && skipExistingOnFirstRun {
            if let maxID = queryMaxRecID(db: handle), maxID > 0 {
                lastRecID = maxID
                saveCursor(maxID)
                return 0
            }
        }

        let sql = """
        SELECT r.rec_id, r.data, r.delivered_date
        FROM record r
        JOIN app a ON r.app_id = a.app_id
        WHERE a.identifier = ? AND r.rec_id > ?
        ORDER BY r.rec_id ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            let err = String(cString: sqlite3_errmsg(handle))
            throw NSError(domain: "FeishuSensor", code: 2, userInfo: [NSLocalizedDescriptionKey: err])
        }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, bundleFilter, -1, transient)
        sqlite3_bind_int64(stmt, 2, lastRecID)

        var emitted = 0
        var committedRecID = lastRecID
        var deliveryError: Error?

        while sqlite3_step(stmt) == SQLITE_ROW {
            let recID = sqlite3_column_int64(stmt, 0)
            let blobPtr = sqlite3_column_blob(stmt, 1)
            let blobLen = Int(sqlite3_column_bytes(stmt, 1))

            guard let blobPtr, blobLen > 0 else {
                committedRecID = max(committedRecID, recID)
                continue
            }
            let data = Data(bytes: blobPtr, count: blobLen)
            guard let decoded = NotificationPayloadDecoder.decode(bplistData: data) else {
                committedRecID = max(committedRecID, recID)
                continue
            }

            let chatTitle = decoded.title.isEmpty ? "飞书通知" : decoded.title
            let event = EventEnvelope(
                source: "bz://sensor/feishu",
                type: "dev.bianzhong.feishu.notification",
                correlationKey: "feishu:chat:\(chatTitle)",
                privacyLevel: .sensitive,
                payload: [
                    "rec_id": "\(recID)",
                    "title": chatTitle,
                    "subtitle": decoded.subtitle,
                    "body": decoded.body
                ],
                ambientContext: .captureCurrent()
            )

            if dryRun {
                if let json = try? JSONEncoder().encode(event), let str = String(data: json, encoding: .utf8) {
                    print(str)
                }
                committedRecID = max(committedRecID, recID)
                emitted += 1
            } else {
                do {
                    let resp = try SocketClient.send(request: BusRequest(action: "emit", event: event), socketURL: socketURL)
                    guard resp.ok else {
                        deliveryError = NSError(
                            domain: "FeishuSensor",
                            code: 3,
                            userInfo: [NSLocalizedDescriptionKey: resp.message.isEmpty ? "Daemon rejected event" : resp.message]
                        )
                        break
                    }
                    committedRecID = max(committedRecID, recID)
                    emitted += 1
                } catch {
                    deliveryError = error
                    break
                }
            }
        }

        if committedRecID > lastRecID {
            lastRecID = committedRecID
            saveCursor(committedRecID)
        }

        if let deliveryError {
            throw deliveryError
        }
        return emitted
    }

    private func queryMaxRecID(db: OpaquePointer?) -> Int64? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(rec_id), 0) FROM record;", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : nil
    }
}
