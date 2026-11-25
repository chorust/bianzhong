import CoreServices
import Darwin
import Foundation
import SQLite3

public enum FeishuSensorStatus: String, Codable, Sendable, Equatable {
    case disabled = "disabled"
    case watching = "watching"
    case needsFullDiskAccess = "needs_fda"
    case unavailable = "unavailable"
}

public enum FeishuSensorError: Error, LocalizedError {
    case permissionDenied(String)
    case openFailed(Int32, String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let msg):
            return "Full Disk Access required to read Notification Center database: \(msg)"
        case .openFailed(_, let msg):
            return "Failed to open Notification Center database: \(msg)"
        }
    }
}

/// Read-only sensor querying macOS `usernoted` SQLite (`com.electron.lark` only).
/// Embedded directly inside `Bianzhong.app` (single-app mode) with optional direct `eventSink`
/// or Unix socket delivery.
public final class FeishuSensorRunner: @unchecked Sendable {
    public let dbURL: URL
    public let cursorURL: URL
    public let socketURL: URL?
    public let bundleFilter: String
    public let skipExistingOnFirstRun: Bool
    public let quietPermissionErrors: Bool
    private let eventSink: (@Sendable (EventEnvelope) -> Bool)?

    private var lastRecID: Int64
    private let lock = NSLock()

    public init(
        dbURL: URL,
        cursorURL: URL,
        socketURL: URL? = nil,
        bundleFilter: String = "com.electron.lark",
        skipExistingOnFirstRun: Bool = true,
        quietPermissionErrors: Bool = false,
        eventSink: (@Sendable (EventEnvelope) -> Bool)? = nil
    ) {
        self.dbURL = dbURL
        self.cursorURL = cursorURL
        self.socketURL = socketURL
        self.bundleFilter = bundleFilter
        self.skipExistingOnFirstRun = skipExistingOnFirstRun
        self.quietPermissionErrors = quietPermissionErrors
        self.eventSink = eventSink
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
    /// Cursor advances strictly up to the last record acknowledged by the daemon or in-process sink,
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
                if !quietPermissionErrors {
                    fputs("""
                    [feishu-sensor] Unable to open \(dbURL.path): \(err)
                    Grant Full Disk Access to /Applications/Bianzhong.app in:
                      System Settings -> Privacy & Security -> Full Disk Access
                    """, stderr)
                }
                throw FeishuSensorError.permissionDenied(err)
            }
            throw FeishuSensorError.openFailed(rc, err)
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
            } else if let eventSink {
                if eventSink(event) {
                    committedRecID = max(committedRecID, recID)
                    emitted += 1
                } else {
                    deliveryError = NSError(
                        domain: "FeishuSensor",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "In-process event sink rejected event"]
                    )
                    break
                }
            } else if let socketURL {
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
            } else {
                deliveryError = NSError(
                    domain: "FeishuSensor",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "No socketURL or eventSink configured"]
                )
                break
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

private final class WeakMonitorBox: @unchecked Sendable {
    weak var monitor: FeishuSensorMonitor?
    init(_ monitor: FeishuSensorMonitor) {
        self.monitor = monitor
    }
}

private final class StreamHolder: @unchecked Sendable {
    var stream: FSEventStreamRef?
}

/// Manages background `FSEvents` + periodic polling for in-process Feishu notification capture
/// inside `Bianzhong.app`, surfacing Full Disk Access onboarding status gracefully.
public final class FeishuSensorMonitor: @unchecked Sendable {
    public let dbURL: URL
    public let runner: FeishuSensorRunner
    private let onStatusChange: @Sendable (FeishuSensorStatus) -> Void

    private let monitorQueue = DispatchQueue(label: "dev.bianzhong.feishu-monitor", qos: .utility)
    private let lock = NSLock()
    private let streamHolder = StreamHolder()
    private var timer: DispatchSourceTimer?
    private var running = false
    private var status: FeishuSensorStatus = .disabled

    public static func defaultUsernotedDBURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")
    }

    public init(
        dbURL: URL = FeishuSensorMonitor.defaultUsernotedDBURL(),
        cursorURL: URL,
        skipExistingOnFirstRun: Bool = true,
        eventSink: @escaping @Sendable (EventEnvelope) -> Bool,
        onStatusChange: @escaping @Sendable (FeishuSensorStatus) -> Void = { _ in }
    ) {
        self.dbURL = dbURL
        self.runner = FeishuSensorRunner(
            dbURL: dbURL,
            cursorURL: cursorURL,
            socketURL: nil,
            bundleFilter: "com.electron.lark",
            skipExistingOnFirstRun: skipExistingOnFirstRun,
            quietPermissionErrors: true,
            eventSink: eventSink
        )
        self.onStatusChange = onStatusChange
    }

    deinit {
        teardown(notify: false)
    }

    public func currentStatus() -> FeishuSensorStatus {
        lock.withLock { status }
    }

    public func start() {
        lock.lock()
        guard !running else {
            lock.unlock()
            return
        }
        running = true
        let retryTimer = DispatchSource.makeTimerSource(queue: monitorQueue)
        retryTimer.schedule(deadline: .now() + 10.0, repeating: 10.0)
        retryTimer.setEventHandler { [weak self] in
            self?.checkAndPoll()
        }
        timer = retryTimer
        lock.unlock()

        retryTimer.resume()
        monitorQueue.async { [weak self] in
            self?.checkAndPoll()
        }
    }

    public func retryNow() {
        monitorQueue.async { [weak self] in
            self?.checkAndPoll()
        }
    }

    public func stop() {
        teardown(notify: true)
    }

    private func teardown(notify: Bool) {
        lock.lock()
        let wasRunning = running
        running = false
        let activeTimer = timer
        timer = nil
        let previousStatus = status
        status = .disabled
        lock.unlock()

        activeTimer?.cancel()
        let holder = streamHolder
        monitorQueue.async {
            if let activeStream = holder.stream {
                holder.stream = nil
                FSEventStreamStop(activeStream)
                FSEventStreamInvalidate(activeStream)
                FSEventStreamRelease(activeStream)
            }
        }
        if notify && (wasRunning || previousStatus != .disabled) {
            onStatusChange(.disabled)
        }
    }

    private func checkAndPoll() {
        guard lock.withLock({ running }) else { return }
        do {
            _ = try runner.pollOnce(dryRun: false)
            updateStatus(.watching)
            ensureFSEventStream()
        } catch FeishuSensorError.permissionDenied {
            if isLikelyMissingFDA() {
                updateStatus(.needsFullDiskAccess)
            } else {
                updateStatus(.unavailable)
            }
        } catch {
            updateStatus(.unavailable)
        }
    }

    private func isLikelyMissingFDA() -> Bool {
        var st = stat()
        if Darwin.lstat(dbURL.path, &st) != 0 {
            if errno == EACCES || errno == EPERM {
                return true
            }
        }
        return dbURL.path.contains("group.com.apple.usernoted")
    }

    private func ensureFSEventStream() {
        guard lock.withLock({ running }) else { return }
        guard streamHolder.stream == nil else { return }

        let watchDir = dbURL.deletingLastPathComponent().path as CFString
        let pathsToWatch = [watchDir] as CFArray
        let boxPtr = Unmanaged.passRetained(WeakMonitorBox(self)).toOpaque()
        var context = FSEventStreamContext(
            version: 0,
            info: boxPtr,
            retain: nil,
            release: { ptr in
                guard let ptr else { return }
                Unmanaged<WeakMonitorBox>.fromOpaque(ptr).release()
            },
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let box = Unmanaged<WeakMonitorBox>.fromOpaque(info).takeUnretainedValue()
            box.monitor?.checkAndPoll()
        }

        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.4,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ) else {
            Unmanaged<WeakMonitorBox>.fromOpaque(boxPtr).release()
            return
        }

        guard lock.withLock({ running }) else {
            FSEventStreamInvalidate(newStream)
            FSEventStreamRelease(newStream)
            return
        }

        FSEventStreamSetDispatchQueue(newStream, monitorQueue)
        FSEventStreamStart(newStream)
        streamHolder.stream = newStream
    }

    private func updateStatus(_ next: FeishuSensorStatus) {
        let changed: Bool = lock.withLock {
            guard running else { return false }
            if status == next { return false }
            status = next
            return true
        }
        if changed {
            onStatusChange(next)
        }
    }
}
