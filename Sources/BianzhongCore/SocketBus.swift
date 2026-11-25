import Darwin
import Foundation

public struct BusRequest: Codable, Sendable {
    public let action: String
    public let event: EventEnvelope?
    public let approvalID: String?
    public let comment: String?
    public let chimeID: String?
    public let durationSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case action
        case event
        case approvalID = "approval_id"
        case comment
        case chimeID = "chime_id"
        case durationSeconds = "duration_seconds"
    }

    public init(
        action: String,
        event: EventEnvelope? = nil,
        approvalID: String? = nil,
        comment: String? = nil,
        chimeID: String? = nil,
        durationSeconds: Int? = nil
    ) {
        self.action = action
        self.event = event
        self.approvalID = approvalID
        self.comment = comment
        self.chimeID = chimeID
        self.durationSeconds = durationSeconds
    }
}

public struct BusStatusSummary: Codable, Sendable {
    public let daemonPID: Int32
    public let loadedRules: Int
    public let eventsCount: Int
    public let pendingApprovalsCount: Int
    public let runsCount: Int
    public let paused: Bool
    public let feishuSensor: String?

    enum CodingKeys: String, CodingKey {
        case daemonPID = "daemon_pid"
        case loadedRules = "loaded_rules"
        case eventsCount = "events_count"
        case pendingApprovalsCount = "pending_approvals_count"
        case runsCount = "runs_count"
        case paused
        case feishuSensor = "feishu_sensor"
    }

    public init(
        daemonPID: Int32,
        loadedRules: Int,
        eventsCount: Int,
        pendingApprovalsCount: Int,
        runsCount: Int,
        paused: Bool,
        feishuSensor: String? = nil
    ) {
        self.daemonPID = daemonPID
        self.loadedRules = loadedRules
        self.eventsCount = eventsCount
        self.pendingApprovalsCount = pendingApprovalsCount
        self.runsCount = runsCount
        self.paused = paused
        self.feishuSensor = feishuSensor
    }
}

public struct BusResponse: Codable, Sendable {
    public let ok: Bool
    public let message: String
    public let disposition: String?
    public let status: BusStatusSummary?
    public let approvals: [ApprovalRecord]?
    public let runs: [RunRecord]?
    public let takeoverCommand: String?
    public let gcReport: GCReport?
    public let digestApproval: ApprovalRecord?

    enum CodingKeys: String, CodingKey {
        case ok
        case message
        case disposition
        case status
        case approvals
        case runs
        case takeoverCommand = "takeover_command"
        case gcReport = "gc_report"
        case digestApproval = "digest_approval"
    }

    public init(
        ok: Bool,
        message: String = "",
        disposition: String? = nil,
        status: BusStatusSummary? = nil,
        approvals: [ApprovalRecord]? = nil,
        runs: [RunRecord]? = nil,
        takeoverCommand: String? = nil,
        gcReport: GCReport? = nil,
        digestApproval: ApprovalRecord? = nil
    ) {
        self.ok = ok
        self.message = message
        self.disposition = disposition
        self.status = status
        self.approvals = approvals
        self.runs = runs
        self.takeoverCommand = takeoverCommand
        self.gcReport = gcReport
        self.digestApproval = digestApproval
    }
}

public enum SocketClientError: Error, LocalizedError, Equatable {
    case socketPathTooLong
    case connectFailed(String)
    case invalidResponse
    case payloadTooLarge
    case daemonAlreadyRunning(String)

    public var errorDescription: String? {
        switch self {
        case .socketPathTooLong: return "Unix socket path exceeds 104-byte sun_path limit"
        case .connectFailed(let msg): return "Failed to connect to Bianzhong daemon: \(msg)"
        case .invalidResponse: return "Invalid JSON response from daemon"
        case .payloadTooLarge: return "Socket message exceeds size limit"
        case .daemonAlreadyRunning(let path): return "Another Bianzhong daemon is already listening on \(path)"
        }
    }
}

private let maxSocketRequestBytes = 1_048_576
private let maxSocketResponseBytes = 4 * 1_048_576

private func makeUnixAddress(path: String) throws -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8CString)
    let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
    guard pathBytes.count <= maxLen else {
        throw SocketClientError.socketPathTooLong
    }

    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { cPtr in
            for (i, byte) in pathBytes.enumerated() {
                cPtr[i] = byte
            }
        }
    }
    return addr
}

private func configureSocket(fd: Int32, timeoutSeconds: Int) {
    var noSigPipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    if timeoutSeconds > 0 {
        var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }
}

/// Short-lived Unix Domain Socket client for `bz` CLI and thin sensors.
public enum SocketClient {
    public static func send(request: BusRequest, socketURL: URL) throws -> BusResponse {
        var addr = try makeUnixAddress(path: socketURL.path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketClientError.connectFailed(String(cString: strerror(errno)))
        }
        defer { close(fd) }
        configureSocket(fd: fd, timeoutSeconds: 10)

        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.connect(fd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            throw SocketClientError.connectFailed(String(cString: strerror(errno)))
        }

        var payload = try JSONEncoder().encode(request)
        payload.append(0x0a)
        guard payload.count <= maxSocketRequestBytes else {
            throw SocketClientError.payloadTooLarge
        }

        let wrote = payload.withUnsafeBytes { raw in
            writeAll(fd: fd, buffer: raw.baseAddress!, length: raw.count)
        }
        guard wrote else {
            throw SocketClientError.connectFailed("Write to daemon socket failed")
        }
        shutdown(fd, SHUT_WR)

        var responseData = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n > 0 {
                if responseData.count + n > maxSocketResponseBytes {
                    throw SocketClientError.payloadTooLarge
                }
                responseData.append(buf, count: n)
                if buf[..<n].contains(0x0a) { break }
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }

        let trimmed = String(data: responseData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let jsonData = trimmed.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(BusResponse.self, from: jsonData) else {
            throw SocketClientError.invalidResponse
        }
        return decoded
    }
}

/// NDJSON Unix Domain Socket server (`chmod 0600`) receiving events and CLI control commands.
public final class SocketBus: @unchecked Sendable {
    private let socketURL: URL
    private let handler: @Sendable (BusRequest) -> BusResponse
    private let queue = DispatchQueue(label: "dev.bianzhong.socketbus", qos: .userInitiated, attributes: .concurrent)
    private let stateLock = NSLock()
    private var serverFD: Int32 = -1
    private var running = false
    private var ownsSocketFile = false

    public init(socketURL: URL, handler: @escaping @Sendable (BusRequest) -> BusResponse) {
        self.socketURL = socketURL
        self.handler = handler
    }

    deinit {
        stop()
    }

    public func start() throws {
        var addr = try makeUnixAddress(path: socketURL.path)
        let dir = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: socketURL.path) {
            if isSocketLive(addr: addr) {
                throw SocketClientError.daemonAlreadyRunning(socketURL.path)
            }
            unlink(socketURL.path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketClientError.connectFailed(String(cString: strerror(errno)))
        }
        configureSocket(fd: fd, timeoutSeconds: 0)

        let bindRC = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindRC == 0 else {
            let msg = String(cString: strerror(errno))
            close(fd)
            throw SocketClientError.connectFailed(msg)
        }

        chmod(socketURL.path, 0o600)
        guard Darwin.listen(fd, 32) == 0 else {
            let msg = String(cString: strerror(errno))
            close(fd)
            unlink(socketURL.path)
            throw SocketClientError.connectFailed(msg)
        }

        stateLock.withLock {
            self.serverFD = fd
            self.running = true
            self.ownsSocketFile = true
        }

        queue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    public func stop() {
        let (fdToClose, shouldUnlink): (Int32, Bool) = stateLock.withLock {
            let fd = serverFD
            let owned = ownsSocketFile
            running = false
            serverFD = -1
            ownsSocketFile = false
            return (fd, owned)
        }

        if fdToClose >= 0 {
            Darwin.shutdown(fdToClose, SHUT_RDWR)
            close(fdToClose)
        }
        if shouldUnlink {
            unlink(socketURL.path)
        }
    }

    private func isSocketLive(addr: sockaddr_un) -> Bool {
        var addrCopy = addr
        let probeFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probeFD >= 0 else { return false }
        defer { close(probeFD) }
        configureSocket(fd: probeFD, timeoutSeconds: 1)
        let rc = withUnsafePointer(to: &addrCopy) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.connect(probeFD, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return rc == 0
    }

    private func acceptLoop() {
        while true {
            let activeFD: Int32 = stateLock.withLock {
                running ? serverFD : -1
            }
            guard activeFD >= 0 else { break }

            let clientFD = Darwin.accept(activeFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                break
            }
            queue.async { [weak self] in
                self?.handleClient(clientFD)
            }
        }
    }

    private func handleClient(_ clientFD: Int32) {
        defer { close(clientFD) }
        configureSocket(fd: clientFD, timeoutSeconds: 5)

        var input = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        var exceededLimit = false

        while true {
            let n = Darwin.read(clientFD, &buf, buf.count)
            if n > 0 {
                if input.count + n > maxSocketRequestBytes {
                    exceededLimit = true
                    break
                }
                input.append(buf, count: n)
                if buf[..<n].contains(0x0a) { break }
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }

        let response: BusResponse
        if exceededLimit {
            response = BusResponse(ok: false, message: "Request exceeds 1 MiB limit")
        } else {
            let line = String(data: input, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let jsonData = line.data(using: .utf8),
               let request = try? JSONDecoder().decode(BusRequest.self, from: jsonData) {
                response = handler(request)
            } else {
                response = BusResponse(ok: false, message: "Malformed NDJSON request")
            }
        }

        if var outData = try? JSONEncoder().encode(response) {
            outData.append(0x0a)
            _ = outData.withUnsafeBytes { raw in
                writeAll(fd: clientFD, buffer: raw.baseAddress!, length: raw.count)
            }
        }
    }
}

private func writeAll(fd: Int32, buffer: UnsafeRawPointer, length: Int) -> Bool {
    var written = 0
    while written < length {
        let n = Darwin.write(fd, buffer.advanced(by: written), length - written)
        if n <= 0 {
            if errno == EINTR { continue }
            return false
        }
        written += n
    }
    return true
}
