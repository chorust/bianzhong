import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct ApprovalRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let runID: String
    public let eventID: String
    public let sessionID: String?
    public let chimeID: String
    public let kind: String
    public let riskLevel: String
    public let title: String
    public let provenanceSummary: String
    public let proposedAction: String
    public let targetRepo: String?
    public let externalSessionID: String?
    public let status: String
    public let userComment: String?
    public let createdAt: Int64
    public let resolvedAt: Int64?
}

public struct RunRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let eventID: String
    public let sessionID: String?
    public let chimeID: String
    public let phase: String
    public let driver: String
    public let status: String
    public let costUSD: Double
    public let startedAt: Int64
    public let finishedAt: Int64?
    public let outputSummary: String?
}

public struct TimelineEntry: Codable, Sendable, Equatable {
    public let id: String
    public let ts: String
    public let source: String
    public let type: String
    public let correlationKey: String
    public let summary: String
}

public struct RejectedSample: Codable, Sendable, Equatable {
    public let approvalID: String
    public let chimeID: String
    public let title: String
    public let provenance: String
    public let payloadSummary: String
    public let userComment: String?
    public let createdAt: Int64
}

public enum SQLiteStoreError: Error, LocalizedError, Equatable {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case restrictedEventRejected

    public var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "SQLite open failed: \(msg)"
        case .prepareFailed(let msg): return "SQLite prepare failed: \(msg)"
        case .stepFailed(let msg): return "SQLite step failed: \(msg)"
        case .restrictedEventRejected: return "Restricted privacy events must never be persisted to SQLite"
        }
    }
}

/// Thread-safe embedded SQLite WAL state store (`events`, `sessions`, `runs`, `approvals`).
public final class SQLiteStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()

    public init(dbURL: URL) throws {
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(dbURL.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let opened = handle else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw SQLiteStoreError.openFailed(msg)
        }
        self.db = opened
        try initializeSchema()
    }

    deinit {
        lock.lock()
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
        lock.unlock()
    }

    private func initializeSchema() throws {
        let pragmas = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        PRAGMA foreign_keys=ON;
        PRAGMA busy_timeout=5000;
        """
        try execute(pragmas)

        let ddl = """
        CREATE TABLE IF NOT EXISTS events (
            id                TEXT PRIMARY KEY,
            source            TEXT NOT NULL,
            type              TEXT NOT NULL,
            ts                TEXT NOT NULL,
            received_at       INTEGER NOT NULL,
            correlation_key   TEXT NOT NULL,
            dedup_key         TEXT NOT NULL,
            privacy_level     TEXT NOT NULL CHECK (privacy_level IN ('public','internal','sensitive')),
            causality_depth   INTEGER NOT NULL DEFAULT 0,
            parent_run_id     TEXT,
            payload_summary   TEXT,
            ambient_json      TEXT,
            funnel_stage      TEXT NOT NULL,
            matched_chime_id  TEXT,
            drop_reason       TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_events_dedup ON events(matched_chime_id, dedup_key, received_at DESC);
        CREATE INDEX IF NOT EXISTS idx_events_corr  ON events(correlation_key, received_at DESC);

        CREATE TABLE IF NOT EXISTS sessions (
            id                  TEXT PRIMARY KEY,
            correlation_key     TEXT NOT NULL,
            driver              TEXT NOT NULL,
            policy              TEXT NOT NULL CHECK (policy IN ('ephemeral','threaded','rolling_daily')),
            external_session_id TEXT NOT NULL,
            cwd                 TEXT NOT NULL,
            worktree_path       TEXT,
            turn_count          INTEGER NOT NULL DEFAULT 1,
            status              TEXT NOT NULL CHECK (status IN ('active','expired','handed_over','closed')),
            last_used_at        INTEGER NOT NULL,
            expires_at          INTEGER,
            created_at          INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_sessions_lookup ON sessions(correlation_key, driver, status);

        CREATE TABLE IF NOT EXISTS runs (
            id                  TEXT PRIMARY KEY,
            event_id            TEXT NOT NULL REFERENCES events(id),
            session_id          TEXT REFERENCES sessions(id),
            chime_id            TEXT NOT NULL,
            phase               TEXT NOT NULL CHECK (phase IN ('triage','draft','execute','notify')),
            driver              TEXT NOT NULL,
            pid                 INTEGER,
            pgid                INTEGER,
            proc_start_time_ns  INTEGER,
            status              TEXT NOT NULL CHECK (status IN (
                                    'queued','running','waiting_approval',
                                    'succeeded','failed','timeout','budget_exceeded','aborted_orphan','cancelled'
                                )),
            exit_code           INTEGER,
            input_tokens        INTEGER NOT NULL DEFAULT 0,
            output_tokens       INTEGER NOT NULL DEFAULT 0,
            cached_tokens       INTEGER NOT NULL DEFAULT 0,
            cost_usd            REAL NOT NULL DEFAULT 0.0,
            started_at          INTEGER NOT NULL,
            finished_at         INTEGER,
            output_summary      TEXT,
            error_message       TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_runs_status_time ON runs(status, started_at DESC);

        CREATE TABLE IF NOT EXISTS approvals (
            id                       TEXT PRIMARY KEY,
            run_id                   TEXT NOT NULL REFERENCES runs(id),
            event_id                 TEXT NOT NULL REFERENCES events(id),
            session_id               TEXT REFERENCES sessions(id),
            chime_id                 TEXT NOT NULL,
            kind                     TEXT NOT NULL CHECK (kind IN ('review','question','notify','digest')),
            risk_level               TEXT NOT NULL CHECK (risk_level IN ('low','medium','high')),
            title                    TEXT NOT NULL,
            provenance_summary       TEXT NOT NULL,
            proposed_action          TEXT NOT NULL,
            diff_preview             TEXT,
            target_repo              TEXT,
            base_head_sha            TEXT,
            target_files_sha256_json TEXT,
            external_session_id      TEXT,
            status                   TEXT NOT NULL CHECK (status IN ('pending','approved','edited','rejected','taken_over','expired','deferred')),
            user_comment             TEXT,
            created_at               INTEGER NOT NULL,
            resolved_at              INTEGER
        );
        CREATE INDEX IF NOT EXISTS idx_approvals_inbox ON approvals(status, kind, created_at DESC);
        """
        try execute(ddl)
    }

    private func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw SQLiteStoreError.openFailed("Database closed") }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(errMsg)
            throw SQLiteStoreError.stepFailed(msg)
        }
    }

    public static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    public func recordEvent(
        _ event: EventEnvelope,
        funnelStage: String,
        matchedChimeID: String? = nil,
        dropReason: String? = nil
    ) throws {
        if event.privacyLevel == .restricted {
            throw SQLiteStoreError.restrictedEventRejected
        }

        let payloadData = try? JSONEncoder().encode(event.payload)
        let payloadSummary = payloadData.flatMap { String(data: $0, encoding: .utf8) }.map { String($0.prefix(4096)) }
        let ambientData = try? JSONEncoder().encode(event.ambientContext)
        let ambientJSON = ambientData.flatMap { String(data: $0, encoding: .utf8) }

        let sql = """
        INSERT OR REPLACE INTO events (
            id, source, type, ts, received_at, correlation_key, dedup_key,
            privacy_level, causality_depth, parent_run_id, payload_summary,
            ambient_json, funnel_stage, matched_chime_id, drop_reason
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        try runStatement(sql) { stmt in
            self.bindText(stmt, 1, event.id)
            self.bindText(stmt, 2, event.source)
            self.bindText(stmt, 3, event.type)
            self.bindText(stmt, 4, event.ts)
            sqlite3_bind_int64(stmt, 5, Self.nowMs())
            self.bindText(stmt, 6, event.correlationKey)
            self.bindText(stmt, 7, event.dedupKey)
            self.bindText(stmt, 8, event.privacyLevel.rawValue)
            sqlite3_bind_int(stmt, 9, Int32(event.causality.depth))
            self.bindOptionalText(stmt, 10, event.causality.parentRunID)
            self.bindOptionalText(stmt, 11, payloadSummary)
            self.bindOptionalText(stmt, 12, ambientJSON)
            self.bindText(stmt, 13, funnelStage)
            self.bindOptionalText(stmt, 14, matchedChimeID)
            self.bindOptionalText(stmt, 15, dropReason)
        }
    }

    public func eventCount() throws -> Int {
        try queryScalarInt("SELECT COUNT(*) FROM events;")
    }

    public func hasRecentDedup(chimeID: String, dedupKey: String, withinSeconds: Int) throws -> Bool {
        let cutoff = Self.nowMs() - Int64(withinSeconds) * 1000
        let sql = """
        SELECT COUNT(*) FROM events
        WHERE matched_chime_id = ? AND dedup_key = ? AND received_at >= ?
          AND funnel_stage IN ('dispatched', 'coalesced', 'l1_digest', 'l1_notified');
        """
        let count = try queryScalarInt(sql) { stmt in
            self.bindText(stmt, 1, chimeID)
            self.bindText(stmt, 2, dedupKey)
            sqlite3_bind_int64(stmt, 3, cutoff)
        }
        return count > 0
    }

    public func upsertSession(
        id: String,
        correlationKey: String,
        driver: String,
        policy: SessionPolicy,
        externalSessionID: String,
        cwd: String,
        worktreePath: String? = nil,
        ttlSeconds: Int,
        createdAtMs: Int64? = nil
    ) throws {
        let now = Self.nowMs()
        let effectiveCreatedAt = createdAtMs ?? now
        let expiresAt = now + Int64(ttlSeconds) * 1000
        let sql = """
        INSERT INTO sessions (
            id, correlation_key, driver, policy, external_session_id, cwd, worktree_path,
            turn_count, status, last_used_at, expires_at, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, 1, 'active', ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            external_session_id = excluded.external_session_id,
            worktree_path = COALESCE(excluded.worktree_path, sessions.worktree_path),
            turn_count = sessions.turn_count + 1,
            last_used_at = excluded.last_used_at,
            expires_at = excluded.expires_at,
            status = 'active';
        """
        try runStatement(sql) { stmt in
            self.bindText(stmt, 1, id)
            self.bindText(stmt, 2, correlationKey)
            self.bindText(stmt, 3, driver)
            self.bindText(stmt, 4, policy.rawValue)
            self.bindText(stmt, 5, externalSessionID)
            self.bindText(stmt, 6, cwd)
            self.bindOptionalText(stmt, 7, worktreePath)
            sqlite3_bind_int64(stmt, 8, effectiveCreatedAt)
            sqlite3_bind_int64(stmt, 9, expiresAt)
            sqlite3_bind_int64(stmt, 10, effectiveCreatedAt)
        }
    }

    public func findActiveSession(
        correlationKey: String,
        driver: String,
        policy: SessionPolicy = .threaded,
        nowMs: Int64? = nil
    ) throws -> (id: String, externalSessionID: String, cwd: String)? {
        if policy == .ephemeral {
            return nil
        }

        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw SQLiteStoreError.openFailed("Database closed") }

        let now = nowMs ?? Self.nowMs()
        let minCreatedAtMs: Int64
        if policy == .rollingDaily {
            let refDate = Date(timeIntervalSince1970: Double(now) / 1000.0)
            minCreatedAtMs = Int64(Calendar.current.startOfDay(for: refDate).timeIntervalSince1970 * 1000)
        } else {
            minCreatedAtMs = 0
        }

        let sql = """
        SELECT id, external_session_id, cwd FROM sessions
        WHERE correlation_key = ? AND driver = ? AND status = 'active'
          AND (expires_at IS NULL OR expires_at > ?)
          AND created_at >= ?
        ORDER BY last_used_at DESC LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, correlationKey)
        bindText(stmt, 2, driver)
        sqlite3_bind_int64(stmt, 3, now)
        sqlite3_bind_int64(stmt, 4, minCreatedAtMs)

        if sqlite3_step(stmt) == SQLITE_ROW {
            let id = columnText(stmt, 0) ?? ""
            let extID = columnText(stmt, 1) ?? ""
            let cwd = columnText(stmt, 2) ?? "."
            return (id, extID, cwd)
        }
        return nil
    }

    public func updateSessionAfterPhase2(
        id: String,
        externalSessionID: String,
        cwd: String,
        worktreePath: String?
    ) throws {
        let sql = """
        UPDATE sessions SET
            external_session_id = ?,
            cwd = ?,
            worktree_path = COALESCE(?, worktree_path),
            turn_count = turn_count + 1,
            last_used_at = ?
        WHERE id = ?;
        """
        try runStatement(sql) { stmt in
            self.bindText(stmt, 1, externalSessionID)
            self.bindText(stmt, 2, cwd)
            self.bindOptionalText(stmt, 3, worktreePath)
            sqlite3_bind_int64(stmt, 4, Self.nowMs())
            self.bindText(stmt, 5, id)
        }
    }

    public func updateApprovalAfterPhase2(
        id: String,
        externalSessionID: String,
        targetRepo: String?
    ) throws {
        let sql = """
        UPDATE approvals SET
            external_session_id = ?,
            target_repo = COALESCE(?, target_repo)
        WHERE id = ?;
        """
        try runStatement(sql) { stmt in
            self.bindText(stmt, 1, externalSessionID)
            self.bindOptionalText(stmt, 2, targetRepo)
            self.bindText(stmt, 3, id)
        }
    }

    public func markSessionHandedOver(id: String) throws {
        try runStatement("UPDATE sessions SET status = 'handed_over', last_used_at = ? WHERE id = ?;") { stmt in
            sqlite3_bind_int64(stmt, 1, Self.nowMs())
            self.bindText(stmt, 2, id)
        }
    }

    public func insertRun(
        id: String,
        eventID: String,
        sessionID: String?,
        chimeID: String,
        phase: String,
        driver: String,
        pid: Int32? = nil,
        pgid: Int32? = nil,
        status: String = "running"
    ) throws {
        let sql = """
        INSERT INTO runs (
            id, event_id, session_id, chime_id, phase, driver, pid, pgid, status, started_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        try runStatement(sql) { stmt in
            self.bindText(stmt, 1, id)
            self.bindText(stmt, 2, eventID)
            self.bindOptionalText(stmt, 3, sessionID)
            self.bindText(stmt, 4, chimeID)
            self.bindText(stmt, 5, phase)
            self.bindText(stmt, 6, driver)
            if let pid { sqlite3_bind_int(stmt, 7, pid) } else { sqlite3_bind_null(stmt, 7) }
            if let pgid { sqlite3_bind_int(stmt, 8, pgid) } else { sqlite3_bind_null(stmt, 8) }
            self.bindText(stmt, 9, status)
            sqlite3_bind_int64(stmt, 10, Self.nowMs())
        }
    }

    public func updateRunStatus(
        id: String,
        sessionID: String? = nil,
        status: String,
        exitCode: Int32? = nil,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cachedTokens: Int = 0,
        costUSD: Double = 0,
        outputSummary: String? = nil,
        errorMessage: String? = nil
    ) throws {
        let sql = """
        UPDATE runs SET
            session_id = COALESCE(?, session_id),
            status = ?,
            exit_code = ?,
            input_tokens = ?,
            output_tokens = ?,
            cached_tokens = ?,
            cost_usd = ?,
            finished_at = ?,
            output_summary = COALESCE(?, output_summary),
            error_message = COALESCE(?, error_message)
        WHERE id = ?;
        """
        try runStatement(sql) { stmt in
            self.bindOptionalText(stmt, 1, sessionID)
            self.bindText(stmt, 2, status)
            if let exitCode { sqlite3_bind_int(stmt, 3, exitCode) } else { sqlite3_bind_null(stmt, 3) }
            sqlite3_bind_int(stmt, 4, Int32(inputTokens))
            sqlite3_bind_int(stmt, 5, Int32(outputTokens))
            sqlite3_bind_int(stmt, 6, Int32(cachedTokens))
            sqlite3_bind_double(stmt, 7, costUSD)
            sqlite3_bind_int64(stmt, 8, Self.nowMs())
            self.bindOptionalText(stmt, 9, outputSummary)
            self.bindOptionalText(stmt, 10, errorMessage)
            self.bindText(stmt, 11, id)
        }
    }

    public func insertApproval(_ record: ApprovalRecord) throws {
        let sql = """
        INSERT INTO approvals (
            id, run_id, event_id, session_id, chime_id, kind, risk_level,
            title, provenance_summary, proposed_action, target_repo,
            external_session_id, status, user_comment, created_at, resolved_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        try runStatement(sql) { stmt in
            self.bindText(stmt, 1, record.id)
            self.bindText(stmt, 2, record.runID)
            self.bindText(stmt, 3, record.eventID)
            self.bindOptionalText(stmt, 4, record.sessionID)
            self.bindText(stmt, 5, record.chimeID)
            self.bindText(stmt, 6, record.kind)
            self.bindText(stmt, 7, record.riskLevel)
            self.bindText(stmt, 8, record.title)
            self.bindText(stmt, 9, record.provenanceSummary)
            self.bindText(stmt, 10, record.proposedAction)
            self.bindOptionalText(stmt, 11, record.targetRepo)
            self.bindOptionalText(stmt, 12, record.externalSessionID)
            self.bindText(stmt, 13, record.status)
            self.bindOptionalText(stmt, 14, record.userComment)
            sqlite3_bind_int64(stmt, 15, record.createdAt)
            if let resolvedAt = record.resolvedAt {
                sqlite3_bind_int64(stmt, 16, resolvedAt)
            } else {
                sqlite3_bind_null(stmt, 16)
            }
        }
    }

    public func listPendingApprovals(limit: Int = 50) throws -> [ApprovalRecord] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw SQLiteStoreError.openFailed("Database closed") }

        let sql = """
        SELECT id, run_id, event_id, session_id, chime_id, kind, risk_level,
               title, provenance_summary, proposed_action, target_repo,
               external_session_id, status, user_comment, created_at, resolved_at
        FROM approvals WHERE status = 'pending'
        ORDER BY created_at DESC LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var items: [ApprovalRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            items.append(readApprovalRow(stmt))
        }
        return items
    }

    public func getApproval(id: String) throws -> ApprovalRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw SQLiteStoreError.openFailed("Database closed") }

        let sql = """
        SELECT id, run_id, event_id, session_id, chime_id, kind, risk_level,
               title, provenance_summary, proposed_action, target_repo,
               external_session_id, status, user_comment, created_at, resolved_at
        FROM approvals WHERE id = ? LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, id)

        if sqlite3_step(stmt) == SQLITE_ROW {
            return readApprovalRow(stmt)
        }
        return nil
    }

    public func resolveApproval(id: String, status: String, comment: String?) throws {
        let sql = "UPDATE approvals SET status = ?, user_comment = COALESCE(?, user_comment), resolved_at = ? WHERE id = ?;"
        try runStatement(sql) { stmt in
            self.bindText(stmt, 1, status)
            self.bindOptionalText(stmt, 2, comment)
            sqlite3_bind_int64(stmt, 3, Self.nowMs())
            self.bindText(stmt, 4, id)
        }
    }

    public func listRecentRuns(limit: Int = 20) throws -> [RunRecord] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw SQLiteStoreError.openFailed("Database closed") }

        let sql = """
        SELECT id, event_id, session_id, chime_id, phase, driver, status, cost_usd, started_at, finished_at, output_summary
        FROM runs ORDER BY started_at DESC LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var rows: [RunRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(
                RunRecord(
                    id: columnText(stmt, 0) ?? "",
                    eventID: columnText(stmt, 1) ?? "",
                    sessionID: columnText(stmt, 2),
                    chimeID: columnText(stmt, 3) ?? "",
                    phase: columnText(stmt, 4) ?? "",
                    driver: columnText(stmt, 5) ?? "",
                    status: columnText(stmt, 6) ?? "",
                    costUSD: sqlite3_column_double(stmt, 7),
                    startedAt: sqlite3_column_int64(stmt, 8),
                    finishedAt: sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 9),
                    outputSummary: columnText(stmt, 10)
                )
            )
        }
        return rows
    }

    public func countsSummary() throws -> (events: Int, pendingApprovals: Int, runs: Int) {
        let e = try queryScalarInt("SELECT COUNT(*) FROM events;")
        let a = try queryScalarInt("SELECT COUNT(*) FROM approvals WHERE status = 'pending';")
        let r = try queryScalarInt("SELECT COUNT(*) FROM runs;")
        return (e, a, r)
    }

    public func listRecentEvents(limit: Int = 50) throws -> [EventEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw SQLiteStoreError.openFailed("Database closed") }

        let sql = """
        SELECT id, source, type, ts, correlation_key, dedup_key, privacy_level,
               causality_depth, parent_run_id, payload_summary, ambient_json
        FROM events
        ORDER BY received_at DESC LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var events: [EventEnvelope] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = columnText(stmt, 0) ?? ""
            let source = columnText(stmt, 1) ?? ""
            let type = columnText(stmt, 2) ?? ""
            let ts = columnText(stmt, 3) ?? ""
            let corr = columnText(stmt, 4) ?? ""
            let dedup = columnText(stmt, 5) ?? ""
            let privacy = PrivacyLevel(rawValue: columnText(stmt, 6) ?? "internal") ?? .internal
            let depth = Int(sqlite3_column_int(stmt, 7))
            let parentRunID = columnText(stmt, 8)
            let payloadText = columnText(stmt, 9) ?? "{}"
            let ambientText = columnText(stmt, 10) ?? "{}"

            let payload = (try? JSONDecoder().decode([String: String].self, from: Data(payloadText.utf8))) ?? [:]
            let ambient = (try? JSONDecoder().decode(AmbientContext.self, from: Data(ambientText.utf8))) ?? AmbientContext()

            events.append(
                EventEnvelope(
                    id: id,
                    source: source,
                    type: type,
                    ts: ts,
                    correlationKey: corr,
                    dedupKey: dedup,
                    privacyLevel: privacy,
                    causality: Causality(emitterPID: 0, parentRunID: parentRunID, depth: depth),
                    payload: payload,
                    ambientContext: ambient
                )
            )
        }
        return events.reversed()
    }

    public func recentTimeline(withinSeconds: Int = 1200, excludingEventID: String, limit: Int = 10) throws -> [TimelineEntry] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw SQLiteStoreError.openFailed("Database closed") }

        let cutoff = Self.nowMs() - Int64(withinSeconds) * 1000
        let sql = """
        SELECT id, ts, source, type, correlation_key, payload_summary
        FROM events
        WHERE received_at >= ? AND id != ?
        ORDER BY received_at DESC LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cutoff)
        bindText(stmt, 2, excludingEventID)
        sqlite3_bind_int(stmt, 3, Int32(limit))

        var entries: [TimelineEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let payloadRaw = columnText(stmt, 5) ?? "{}"
            let payload = (try? JSONDecoder().decode([String: String].self, from: Data(payloadRaw.utf8))) ?? [:]
            let title = payload["title"] ?? ""
            let body = payload["body"] ?? payload["summary"] ?? payload["command"] ?? payload["path"] ?? ""
            let compact = [title, body].filter { !$0.isEmpty }.joined(separator: " | ")
            entries.append(
                TimelineEntry(
                    id: columnText(stmt, 0) ?? "",
                    ts: columnText(stmt, 1) ?? "",
                    source: columnText(stmt, 2) ?? "",
                    type: columnText(stmt, 3) ?? "",
                    correlationKey: columnText(stmt, 4) ?? "",
                    summary: String(compact.prefix(200))
                )
            )
        }
        return entries.reversed()
    }

    public func todayUsageSummary() throws -> (runsCount: Int, totalCostUSD: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw SQLiteStoreError.openFailed("Database closed") }

        let startOfDayMs = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000)
        let sql = """
        SELECT COUNT(*), COALESCE(SUM(cost_usd), 0.0)
        FROM runs
        WHERE started_at >= ? AND phase IN ('draft', 'execute');
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, startOfDayMs)

        if sqlite3_step(stmt) == SQLITE_ROW {
            return (runsCount: Int(sqlite3_column_int64(stmt, 0)), totalCostUSD: sqlite3_column_double(stmt, 1))
        }
        return (runsCount: 0, totalCostUSD: 0.0)
    }

    public func consecutiveFailures(chimeID: String, sinceMs: Int64 = 0, limit: Int = 5) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw SQLiteStoreError.openFailed("Database closed") }

        let sql = """
        SELECT status FROM runs
        WHERE chime_id = ? AND started_at >= ? AND phase IN ('draft', 'execute')
          AND status NOT IN ('queued', 'running')
        ORDER BY started_at DESC LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, chimeID)
        sqlite3_bind_int64(stmt, 2, sinceMs)
        sqlite3_bind_int(stmt, 3, Int32(limit))

        var count = 0
        let failureStatuses: Set<String> = ["failed", "timeout", "budget_exceeded", "aborted_orphan"]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let status = columnText(stmt, 0) ?? ""
            if failureStatuses.contains(status) {
                count += 1
            } else {
                break
            }
        }
        return count
    }

    public func listDeferredDigests(limit: Int = 100) throws -> [ApprovalRecord] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw SQLiteStoreError.openFailed("Database closed") }

        let sql = """
        SELECT id, run_id, event_id, session_id, chime_id, kind, risk_level,
               title, provenance_summary, proposed_action, target_repo,
               external_session_id, status, user_comment, created_at, resolved_at
        FROM approvals WHERE status = 'deferred' AND kind = 'digest'
        ORDER BY created_at ASC LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var items: [ApprovalRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            items.append(readApprovalRow(stmt))
        }
        return items
    }

    public func markApprovalsStatus(ids: [String], status: String) throws {
        guard !ids.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw SQLiteStoreError.openFailed("Database closed") }

        guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
            throw SQLiteStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }

        let sql = "UPDATE approvals SET status = ?, resolved_at = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let err = String(cString: sqlite3_errmsg(db))
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            throw SQLiteStoreError.prepareFailed(err)
        }
        defer { sqlite3_finalize(stmt) }

        let now = Self.nowMs()
        do {
            for id in ids {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bindText(stmt, 1, status)
                sqlite3_bind_int64(stmt, 2, now)
                bindText(stmt, 3, id)
                let rc = sqlite3_step(stmt)
                guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
                    throw SQLiteStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
                }
            }
            guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                throw SQLiteStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
        } catch {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    public func listRejectedSamples(chimeID: String? = nil, limit: Int = 15) throws -> [RejectedSample] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw SQLiteStoreError.openFailed("Database closed") }

        let sql = """
        SELECT a.id, a.chime_id, a.title, a.provenance_summary, COALESCE(e.payload_summary, ''), a.user_comment, a.created_at
        FROM approvals a
        LEFT JOIN events e ON a.event_id = e.id
        WHERE a.status = 'rejected' AND (? IS NULL OR a.chime_id = ?)
        ORDER BY a.created_at DESC LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bindOptionalText(stmt, 1, chimeID)
        bindOptionalText(stmt, 2, chimeID)
        sqlite3_bind_int(stmt, 3, Int32(limit))

        var samples: [RejectedSample] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            samples.append(
                RejectedSample(
                    approvalID: columnText(stmt, 0) ?? "",
                    chimeID: columnText(stmt, 1) ?? "",
                    title: columnText(stmt, 2) ?? "",
                    provenance: columnText(stmt, 3) ?? "",
                    payloadSummary: columnText(stmt, 4) ?? "",
                    userComment: columnText(stmt, 5),
                    createdAt: sqlite3_column_int64(stmt, 6)
                )
            )
        }
        return samples
    }

    public func pruneExpiredRecords(olderThanMs: Int64) throws -> Int {
        try runStatement("DELETE FROM approvals WHERE status != 'pending' AND status != 'deferred' AND created_at < ?;") { stmt in
            sqlite3_bind_int64(stmt, 1, olderThanMs)
        }
        try runStatement("DELETE FROM runs WHERE started_at < ? AND id NOT IN (SELECT run_id FROM approvals);") { stmt in
            sqlite3_bind_int64(stmt, 1, olderThanMs)
        }
        let before = try queryScalarInt("SELECT COUNT(*) FROM events;")
        try runStatement("DELETE FROM events WHERE received_at < ? AND id NOT IN (SELECT event_id FROM runs) AND id NOT IN (SELECT event_id FROM approvals);") { stmt in
            sqlite3_bind_int64(stmt, 1, olderThanMs)
        }
        let after = try queryScalarInt("SELECT COUNT(*) FROM events;")
        return max(0, before - after)
    }

    // MARK: - SQLite C Helpers

    private func runStatement(_ sql: String, bind: (OpaquePointer?) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw SQLiteStoreError.openFailed("Database closed") }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)

        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw SQLiteStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func queryScalarInt(_ sql: String, bind: ((OpaquePointer?) -> Void)? = nil) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw SQLiteStoreError.openFailed("Database closed") }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bind?(stmt)

        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return 0
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
    }

    private func readApprovalRow(_ stmt: OpaquePointer?) -> ApprovalRecord {
        ApprovalRecord(
            id: columnText(stmt, 0) ?? "",
            runID: columnText(stmt, 1) ?? "",
            eventID: columnText(stmt, 2) ?? "",
            sessionID: columnText(stmt, 3),
            chimeID: columnText(stmt, 4) ?? "",
            kind: columnText(stmt, 5) ?? "review",
            riskLevel: columnText(stmt, 6) ?? "medium",
            title: columnText(stmt, 7) ?? "",
            provenanceSummary: columnText(stmt, 8) ?? "",
            proposedAction: columnText(stmt, 9) ?? "",
            targetRepo: columnText(stmt, 10),
            externalSessionID: columnText(stmt, 11),
            status: columnText(stmt, 12) ?? "pending",
            userComment: columnText(stmt, 13),
            createdAt: sqlite3_column_int64(stmt, 14),
            resolvedAt: sqlite3_column_type(stmt, 15) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 15)
        )
    }
}
