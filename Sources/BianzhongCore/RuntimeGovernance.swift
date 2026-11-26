import Foundation

public enum GovernanceVerdict: Equatable, Sendable {
    case allowed
    case blockedDailyCost(current: Double, cap: Double)
    case blockedDailyRuns(current: Int, cap: Int)
    case circuitOpen(chimeID: String, failures: Int)
}

public struct GCReport: Codable, Sendable, Equatable {
    public let prunedEvents: Int
    public let removedRunDirs: Int
    public let removedWorktrees: Int
    public let preservedDirtyWorktrees: [String]

    enum CodingKeys: String, CodingKey {
        case prunedEvents = "pruned_events"
        case removedRunDirs = "removed_run_dirs"
        case removedWorktrees = "removed_worktrees"
        case preservedDirtyWorktrees = "preserved_dirty_worktrees"
    }
}

/// Enforces global daily cost/run caps, per-rule consecutive failure circuit breakers,
/// and retention GC while protecting dirty Git worktrees.
public final class RuntimeGovernance: @unchecked Sendable {
    private let lock = NSLock()
    private var circuitResetMs: [String: Int64] = [:]

    public init() {}

    public func resetCircuit(chimeID: String) {
        lock.lock()
        circuitResetMs[chimeID] = SQLiteStore.nowMs()
        lock.unlock()
    }

    public func checkAdmission(chimeID: String, config: AppConfig, store: SQLiteStore) -> GovernanceVerdict {
        if let usage = try? store.todayUsageSummary() {
            if config.dailyMaxCostUSD > 0 && usage.totalCostUSD >= config.dailyMaxCostUSD {
                return .blockedDailyCost(current: usage.totalCostUSD, cap: config.dailyMaxCostUSD)
            }
            if config.dailyMaxRuns > 0 && usage.runsCount >= config.dailyMaxRuns {
                return .blockedDailyRuns(current: usage.runsCount, cap: config.dailyMaxRuns)
            }
        }

        lock.lock()
        let sinceMs = circuitResetMs[chimeID] ?? 0
        lock.unlock()

        if let failures = try? store.consecutiveFailures(
            chimeID: chimeID,
            sinceMs: sinceMs,
            limit: config.circuitBreakerFailures
        ), failures >= config.circuitBreakerFailures {
            return .circuitOpen(chimeID: chimeID, failures: failures)
        }
        return .allowed
    }

    @discardableResult
    public func performGC(paths: BianzhongPaths, store: SQLiteStore, retentionDays: Int) -> GCReport {
        let safeDays = max(1, retentionDays)
        let cutoffDate = Date().addingTimeInterval(-TimeInterval(safeDays) * 86400)
        let cutoffMs = Int64(cutoffDate.timeIntervalSince1970 * 1000)

        let prunedEvents = (try? store.pruneExpiredRecords(olderThanMs: cutoffMs)) ?? 0
        let removedRunDirs = pruneDirectory(paths.runsDir, olderThan: cutoffDate)

        var removedWorktrees = 0
        var dirtyWorktrees: [String] = []
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(
            at: paths.worktreesDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for item in items {
                let mtime = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                guard mtime < cutoffDate else { continue }
                if isWorktreeDirty(at: item.path) {
                    dirtyWorktrees.append(item.path)
                } else if Self.detachAndRemoveWorktreeDir(at: item.path) {
                    removedWorktrees += 1
                }
            }
        }

        return GCReport(
            prunedEvents: prunedEvents,
            removedRunDirs: removedRunDirs,
            removedWorktrees: removedWorktrees,
            preservedDirtyWorktrees: dirtyWorktrees
        )
    }

    /// Cleanly detaches a Git worktree from its parent `.git/worktrees/<name>` metadata before deleting its folder.
    @discardableResult
    public static func detachAndRemoveWorktreeDir(at path: String) -> Bool {
        let fm = FileManager.default
        let gitCommonDir = resolveGitCommonDir(forWorktree: path)

        if let common = gitCommonDir {
            let rmProc = Process()
            rmProc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            rmProc.arguments = ["--git-dir=\(common)", "worktree", "remove", path]
            rmProc.standardOutput = Pipe()
            rmProc.standardError = Pipe()
            if (try? rmProc.run()) != nil {
                rmProc.waitUntilExit()
                if rmProc.terminationStatus == 0 && !fm.fileExists(atPath: path) {
                    return true
                }
            }
        }

        let removed = (try? fm.removeItem(atPath: path)) != nil
        if let common = gitCommonDir {
            let pruneProc = Process()
            pruneProc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            pruneProc.arguments = ["--git-dir=\(common)", "worktree", "prune"]
            pruneProc.standardOutput = Pipe()
            pruneProc.standardError = Pipe()
            if (try? pruneProc.run()) != nil {
                pruneProc.waitUntilExit()
            }
        }
        return removed
    }

    private static func resolveGitCommonDir(forWorktree path: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let raw = (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    private func pruneDirectory(_ dir: URL, olderThan cutoff: Date) -> Int {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var removed = 0
        for item in items {
            let mtime = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            if mtime < cutoff {
                if (try? fm.removeItem(at: item)) != nil {
                    removed += 1
                }
            }
        }
        return removed
    }

    private func isWorktreeDirty(at path: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", path, "status", "--porcelain"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return true }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return true }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
