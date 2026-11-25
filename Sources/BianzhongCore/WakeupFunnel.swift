import Foundation

public enum FunnelDisposition: Equatable, Sendable {
    case dropped(stage: String, reason: String)
    case coalescing(chimeID: String, correlationKey: String)
    case ready(event: EventEnvelope, rule: ChimeRule)
}

private struct DebounceBucket {
    var events: [EventEnvelope]
    let rule: ChimeRule
    let firstReceivedAt: Date
    var workItem: DispatchWorkItem?
}

private struct WriteLease {
    let rawPrefix: String
    let canonicalPrefix: String
    var expiry: Date
}

/// Evaluates expected signal time windows (`expect:`) for missed-signal watchdogs.
public enum ExpectWindowEvaluator {
    public struct ResolvedWindow: Sendable, Equatable {
        public let periodKey: String
        public let start: Date
        public let end: Date
        public let deadline: Date
    }

    public static func parseClock(_ hhmm: String) -> (hour: Int, minute: Int)? {
        let parts = hhmm.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]), (0...23).contains(h),
              let m = Int(parts[1]), (0...59).contains(m) else {
            return nil
        }
        return (h, m)
    }

    public static func isoWeekday(for date: Date, calendar: Calendar = .current) -> Int {
        let wd = calendar.component(.weekday, from: date) // 1 = Sun, 2 = Mon ... 7 = Sat
        return wd == 1 ? 7 : wd - 1
    }

    public static func periodKey(for date: Date, calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    /// Resolves the active window anchored to `baseDay` (handles overnight windows where `end <= start`).
    public static func windowForDay(_ baseDay: Date, spec: ExpectWindowSpec, calendar: Calendar = .current) -> ResolvedWindow? {
        guard spec.enabled,
              let startClock = parseClock(spec.windowStart),
              let endClock = parseClock(spec.windowEnd) else {
            return nil
        }
        if !spec.weekdays.isEmpty {
            let wd = isoWeekday(for: baseDay, calendar: calendar)
            if !spec.weekdays.contains(wd) {
                return nil
            }
        }
        let dayStart = calendar.startOfDay(for: baseDay)
        guard let start = calendar.date(bySettingHour: startClock.hour, minute: startClock.minute, second: 0, of: dayStart),
              var end = calendar.date(bySettingHour: endClock.hour, minute: endClock.minute, second: 0, of: dayStart) else {
            return nil
        }
        if end <= start {
            end = calendar.date(byAdding: .day, value: 1, to: end) ?? end.addingTimeInterval(86400)
        }
        let deadline = end.addingTimeInterval(TimeInterval(spec.graceSeconds))
        return ResolvedWindow(
            periodKey: periodKey(for: dayStart, calendar: calendar),
            start: start,
            end: end,
            deadline: deadline
        )
    }

    /// Returns the `periodKey` if `now` falls inside an active expectation window `[start, deadline]`.
    public static func activePeriodKey(for spec: ExpectWindowSpec, at now: Date, calendar: Calendar = .current) -> String? {
        let today = calendar.startOfDay(for: now)
        if let w = windowForDay(today, spec: spec, calendar: calendar), now >= w.start && now <= w.deadline {
            return w.periodKey
        }
        // Check yesterday for overnight windows (e.g. 23:30–00:30)
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
           let w = windowForDay(yesterday, spec: spec, calendar: calendar),
           now >= w.start && now <= w.deadline {
            return w.periodKey
        }
        return nil
    }

    /// Returns the most recent overdue `ResolvedWindow` if `now > deadline` for today (or an overnight window that ended today).
    public static func missedWindow(for spec: ExpectWindowSpec, at now: Date, calendar: Calendar = .current) -> ResolvedWindow? {
        let today = calendar.startOfDay(for: now)
        if let w = windowForDay(today, spec: spec, calendar: calendar), now > w.deadline {
            return w
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
           let w = windowForDay(yesterday, spec: spec, calendar: calendar),
           calendar.isDate(w.deadline, inSameDayAs: today),
           now > w.deadline {
            return w
        }
        return nil
    }

    /// Returns the most recent overdue window's `periodKey` if `now > deadline` for today (or an overnight window that ended today).
    public static func missedPeriodKey(for spec: ExpectWindowSpec, at now: Date, calendar: Calendar = .current) -> String? {
        missedWindow(for: spec, at: now, calendar: calendar)?.periodKey
    }
}

/// Deterministic L0 wakeup funnel implementing privacy ACL, 4-layer loop guard,
/// per-field & AND rule matching, TTL dedup, cumulative window thresholds,
/// expect-window satisfaction, trailing debounce coalescing, and cooldown locks.
public final class WakeupFunnel: @unchecked Sendable {
    private let store: SQLiteStore
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.bianzhong.funnel", qos: .userInitiated)

    private var rules: [ChimeRule]
    private var maxCausalDepth: Int
    private let selfSourcePrefixes: [String]

    private var writeLeases: [String: WriteLease] = [:]
    private var echoHashes: [String: Date] = [:]
    private var recentDedups: [String: Date] = [:]
    private var cooldowns: [String: Date] = [:]
    private var debounceBuckets: [String: DebounceBucket] = [:]

    public init(
        store: SQLiteStore,
        rules: [ChimeRule] = [],
        maxCausalDepth: Int = 1,
        selfSourcePrefixes: [String] = ["bz://app/", "dev.bianzhong.self"]
    ) {
        self.store = store
        self.rules = rules
        self.maxCausalDepth = maxCausalDepth
        self.selfSourcePrefixes = selfSourcePrefixes
    }

    public func updateRules(_ newRules: [ChimeRule]) {
        lock.lock()
        self.rules = newRules
        lock.unlock()
    }

    public func updateMaxCausalDepth(_ newDepth: Int) {
        lock.lock()
        self.maxCausalDepth = max(1, newDepth)
        lock.unlock()
    }

    public func currentRules() -> [ChimeRule] {
        lock.lock()
        defer { lock.unlock() }
        return rules
    }

    public static func canonicalPath(_ rawPath: String) -> String {
        let expanded = NSString(string: rawPath).expandingTildeInPath
        guard !expanded.isEmpty else { return "" }

        let fm = FileManager.default
        var probeURL = URL(fileURLWithPath: expanded).standardizedFileURL
        var trailingComponents: [String] = []

        while !fm.fileExists(atPath: probeURL.path) {
            let last = probeURL.lastPathComponent
            let parent = probeURL.deletingLastPathComponent()
            if parent.path == probeURL.path || last.isEmpty {
                break
            }
            trailingComponents.append(last)
            probeURL = parent
        }

        var resolved = probeURL.resolvingSymlinksInPath().standardizedFileURL
        for component in trailingComponents.reversed() {
            resolved.appendPathComponent(component)
        }
        var path = resolved.path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    /// Registers an active write path prefix so agent file edits do not re-trigger FSEvents.
    public func registerWriteLease(pathPrefix: String, ttlSeconds: TimeInterval = 30.0) {
        let canonical = Self.canonicalPath(pathPrefix)
        guard !canonical.isEmpty else { return }
        lock.lock()
        writeLeases[canonical] = WriteLease(
            rawPrefix: pathPrefix,
            canonicalPrefix: canonical,
            expiry: Date().addingTimeInterval(ttlSeconds)
        )
        lock.unlock()
    }

    /// Releases a write lease after an optional grace period to drain trailing OS FSEvents.
    public func releaseWriteLease(pathPrefix: String, graceSeconds: TimeInterval = 1.5) {
        let canonical = Self.canonicalPath(pathPrefix)
        guard !canonical.isEmpty else { return }
        lock.lock()
        let raw = writeLeases[canonical]?.rawPrefix ?? pathPrefix
        writeLeases[canonical] = WriteLease(
            rawPrefix: raw,
            canonicalPrefix: canonical,
            expiry: Date().addingTimeInterval(graceSeconds)
        )
        lock.unlock()
    }

    /// Registers a content hash so notifications or clipboard writes from Bianzhong are ignored on echo.
    public func registerEchoHash(_ hash: String, ttlSeconds: TimeInterval = 60.0) {
        lock.lock()
        echoHashes[hash] = Date().addingTimeInterval(ttlSeconds)
        lock.unlock()
    }

    /// Evaluates an incoming event through L0.1–L0.6 and invokes `onReady` when a coalesced event flushes.
    @discardableResult
    public func ingest(
        _ event: EventEnvelope,
        now: Date = Date(),
        onReady: @escaping @Sendable (EventEnvelope, ChimeRule) -> Void
    ) -> FunnelDisposition {
        // L0.1: Restricted privacy hard gate (never write to SQLite or models)
        if event.privacyLevel == .restricted {
            return .dropped(stage: "dropped_acl", reason: "restricted_privacy_level")
        }

        // L0.2: Four-layer anti-loop suppression
        if let loopReason = checkLoopViolation(event) {
            try? store.recordEvent(event, funnelStage: "dropped_loop", dropReason: loopReason)
            return .dropped(stage: "dropped_loop", reason: loopReason)
        }

        // L0.2b: Record satisfaction for any active expect-window watchdog rules whose match criteria pass
        let satisfiedExpectIDs = recordExpectWindowMatchesIfNeeded(for: event, now: now)

        // L0.3: Deterministic rule match (skips suppressOnMatch expect-only watchdogs)
        guard let matchedRule = matchFirstRule(for: event) else {
            if !satisfiedExpectIDs.isEmpty {
                let firstID = satisfiedExpectIDs[0]
                let reason = "window_satisfied:\(satisfiedExpectIDs.joined(separator: ","))"
                try? store.recordEvent(event, funnelStage: "expect_satisfied", matchedChimeID: firstID, dropReason: reason)
                return .dropped(stage: "expect_satisfied", reason: reason)
            }
            try? store.recordEvent(event, funnelStage: "dropped_rule", dropReason: "no_chime_matched")
            return .dropped(stage: "dropped_rule", reason: "no_chime_matched")
        }

        // L0.4: TTL content deduplication
        if isDuplicate(event, chimeID: matchedRule.id, ttlSeconds: matchedRule.dedupTTLSeconds) {
            try? store.recordEvent(event, funnelStage: "dropped_dedup", matchedChimeID: matchedRule.id, dropReason: "dedup_ttl")
            return .dropped(stage: "dropped_dedup", reason: "dedup_ttl")
        }

        // L0.6 (pre-check): Cooldown lock per (chimeID, correlationKey)
        let corrKey = "\(matchedRule.id)|\(event.correlationKey)"
        if isInCooldown(corrKey) {
            try? store.recordEvent(event, funnelStage: "dropped_cooldown", matchedChimeID: matchedRule.id, dropReason: "cooldown_active")
            return .dropped(stage: "dropped_cooldown", reason: "cooldown_active")
        }

        // L0.4b: Atomic cumulative hit threshold within time window (e.g. min_count: 2 + window: daily)
        var effectiveEvent = event
        if matchedRule.minCount > 1 {
            let nowMs = Int64(now.timeIntervalSince1970 * 1000)
            let windowStartMs = computeWindowStartMs(for: matchedRule.countWindow, now: now)
            let scopeKey = matchedRule.countScope == .correlation ? event.correlationKey : "__rule__"
            let outcome = (try? store.recordRuleHitAndCheckThreshold(
                chimeID: matchedRule.id,
                scopeKey: scopeKey,
                eventID: event.id,
                windowStartMs: windowStartMs,
                minCount: matchedRule.minCount,
                resetOnTrigger: matchedRule.countResetOnTrigger,
                nowMs: nowMs
            )) ?? (count: 1, triggered: matchedRule.minCount <= 1)
            if !outcome.triggered {
                let reason = "threshold:\(outcome.count)/\(matchedRule.minCount)"
                try? store.recordEvent(event, funnelStage: "dropped_threshold", matchedChimeID: matchedRule.id, dropReason: reason)
                return .dropped(stage: "dropped_threshold", reason: reason)
            }
            effectiveEvent.payload["window_hit_count"] = "\(outcome.count)"
        }

        // L0.5: Trailing debounce & time-window coalescing
        if matchedRule.debounceSeconds <= 0 {
            markDispatched(effectiveEvent, rule: matchedRule, corrKey: corrKey)
            onReady(effectiveEvent, matchedRule)
            return .ready(event: effectiveEvent, rule: matchedRule)
        }

        enqueueDebounce(effectiveEvent, rule: matchedRule, bucketKey: corrKey, onReady: onReady)
        try? store.recordEvent(effectiveEvent, funnelStage: "coalesced", matchedChimeID: matchedRule.id)
        return .coalescing(chimeID: matchedRule.id, correlationKey: effectiveEvent.correlationKey)
    }

    private func computeWindowStartMs(for window: CountWindow, now: Date) -> Int64 {
        switch window {
        case .daily:
            return Int64(Calendar.current.startOfDay(for: now).timeIntervalSince1970 * 1000)
        case .sliding(let seconds):
            return Int64((now.timeIntervalSince1970 - Double(seconds)) * 1000)
        }
    }

    /// Records satisfaction for active `expect` windows safely even while daemon dispatch is paused.
    @discardableResult
    public func recordExpectWindowMatchesWhilePaused(_ event: EventEnvelope, now: Date = Date()) -> [String] {
        guard event.privacyLevel != .restricted else { return [] }
        guard checkLoopViolation(event) == nil else { return [] }
        return recordExpectWindowMatchesIfNeeded(for: event, now: now)
    }

    private func recordExpectWindowMatchesIfNeeded(for event: EventEnvelope, now: Date) -> [String] {
        let snapshot = currentRules()
        var satisfied: [String] = []
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        for rule in snapshot where rule.enabled {
            guard let spec = rule.expectWindow, spec.enabled else { continue }
            guard matchesRule(event, rule: rule) else { continue }
            if let periodKey = ExpectWindowEvaluator.activePeriodKey(for: spec, at: now) {
                try? store.markExpectWindow(
                    chimeID: rule.id,
                    periodKey: periodKey,
                    status: "satisfied",
                    matchedEventID: event.id,
                    nowMs: nowMs
                )
                satisfied.append(rule.id)
            }
        }
        return satisfied
    }

    private func checkLoopViolation(_ event: EventEnvelope) -> String? {
        if selfSourcePrefixes.contains(where: { event.source.hasPrefix($0) || event.type.hasPrefix($0) }) {
            return "self_source_excluded"
        }

        lock.lock()
        defer { lock.unlock() }
        let now = Date()

        if event.causality.depth >= maxCausalDepth {
            return "causal_depth_exceeded:\(event.causality.depth)"
        }

        echoHashes = echoHashes.filter { $0.value > now }
        if echoHashes[event.dedupKey] != nil {
            return "echo_hash_matched"
        }
        if let bodyHash = event.payload["echo_hash"], echoHashes[bodyHash] != nil {
            return "echo_hash_matched"
        }

        writeLeases = writeLeases.filter { $0.value.expiry > now }
        if let candidatePath = event.payload["path"] ?? event.payload["root"], !candidatePath.isEmpty {
            let candidateCanonical = Self.canonicalPath(candidatePath)
            for lease in writeLeases.values where lease.expiry > now {
                if candidateCanonical == lease.canonicalPrefix
                    || lease.canonicalPrefix == "/"
                    || candidateCanonical.hasPrefix(lease.canonicalPrefix + "/") {
                    return "active_write_lease:\(lease.rawPrefix)"
                }
            }
        }
        return nil
    }

    public func matchesRule(_ event: EventEnvelope, rule: ChimeRule) -> Bool {
        let haystack = event.searchableText.lowercased()
        let title = (event.payload["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let subtitle = (event.payload["subtitle"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let body = (event.payload["body"] ?? event.payload["summary"] ?? "").lowercased()

        if !rule.matchTypes.isEmpty && !rule.matchTypes.contains(where: { wildcardMatch(pattern: $0, value: event.type) }) {
            return false
        }
        if !rule.matchSources.isEmpty && !rule.matchSources.contains(where: { wildcardMatch(pattern: $0, value: event.source) }) {
            return false
        }

        // Combined text filters (AND across fields)
        if !rule.excludeKeywords.isEmpty && rule.excludeKeywords.contains(where: { haystack.contains($0.lowercased()) }) {
            return false
        }
        if !rule.keywordsAny.isEmpty && !rule.keywordsAny.contains(where: { haystack.contains($0.lowercased()) }) {
            return false
        }
        if !rule.keywordsAll.isEmpty && !rule.keywordsAll.allSatisfy({ haystack.contains($0.lowercased()) }) {
            return false
        }

        // Title per-field filters
        if !rule.titleEquals.isEmpty && !rule.titleEquals.contains(where: { title == $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }) {
            return false
        }
        if !rule.titleAny.isEmpty && !rule.titleAny.contains(where: { title.contains($0.lowercased()) }) {
            return false
        }
        if !rule.titleAll.isEmpty && !rule.titleAll.allSatisfy({ title.contains($0.lowercased()) }) {
            return false
        }
        if !rule.titleExclude.isEmpty && rule.titleExclude.contains(where: { title.contains($0.lowercased()) }) {
            return false
        }

        // Subtitle (sender) per-field filters
        if !rule.subtitleEquals.isEmpty && !rule.subtitleEquals.contains(where: { subtitle == $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }) {
            return false
        }
        if !rule.subtitleAny.isEmpty && !rule.subtitleAny.contains(where: { subtitle.contains($0.lowercased()) }) {
            return false
        }
        if !rule.subtitleAll.isEmpty && !rule.subtitleAll.allSatisfy({ subtitle.contains($0.lowercased()) }) {
            return false
        }
        if !rule.subtitleExclude.isEmpty && rule.subtitleExclude.contains(where: { subtitle.contains($0.lowercased()) }) {
            return false
        }

        // Body per-field filters
        if !rule.bodyAny.isEmpty && !rule.bodyAny.contains(where: { body.contains($0.lowercased()) }) {
            return false
        }
        if !rule.bodyAll.isEmpty && !rule.bodyAll.allSatisfy({ body.contains($0.lowercased()) }) {
            return false
        }
        if !rule.bodyExclude.isEmpty && rule.bodyExclude.contains(where: { body.contains($0.lowercased()) }) {
            return false
        }

        // Working directory prefix filter
        if !rule.cwdPrefix.isEmpty {
            let rawCwd = event.payload["cwd"] ?? event.payload["root"] ?? ""
            guard !rawCwd.isEmpty else { return false }
            let canonicalCwd = Self.canonicalPath(rawCwd)
            let matchedCwd = rule.cwdPrefix.contains { prefix in
                let canonicalPrefix = Self.canonicalPath(prefix)
                return canonicalCwd == canonicalPrefix || canonicalCwd.hasPrefix(canonicalPrefix + "/")
            }
            if !matchedCwd { return false }
        }

        return true
    }

    private func matchFirstRule(for event: EventEnvelope) -> ChimeRule? {
        let snapshot = currentRules()
        for rule in snapshot where rule.enabled {
            if let expect = rule.expectWindow, expect.enabled, expect.suppressOnMatch {
                continue
            }
            if matchesRule(event, rule: rule) {
                return rule
            }
        }
        return nil
    }

    private func isDuplicate(_ event: EventEnvelope, chimeID: String, ttlSeconds: Int) -> Bool {
        guard ttlSeconds > 0 else { return false }
        let key = "\(chimeID)|\(event.dedupKey)"
        let now = Date()

        lock.lock()
        recentDedups = recentDedups.filter { $0.value > now }
        let memHit = recentDedups[key] != nil
        if !memHit {
            recentDedups[key] = now.addingTimeInterval(TimeInterval(ttlSeconds))
        }
        lock.unlock()

        if memHit { return true }
        return (try? store.hasRecentDedup(chimeID: chimeID, dedupKey: event.dedupKey, withinSeconds: ttlSeconds)) ?? false
    }

    private func isInCooldown(_ corrKey: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        cooldowns = cooldowns.filter { $0.value > now }
        return cooldowns[corrKey] != nil
    }

    private func markDispatched(_ event: EventEnvelope, rule: ChimeRule, corrKey: String) {
        lock.lock()
        if rule.cooldownSeconds > 0 {
            cooldowns[corrKey] = Date().addingTimeInterval(TimeInterval(rule.cooldownSeconds))
        }
        lock.unlock()
        try? store.recordEvent(event, funnelStage: "dispatched", matchedChimeID: rule.id)
    }

    private func enqueueDebounce(
        _ event: EventEnvelope,
        rule: ChimeRule,
        bucketKey: String,
        onReady: @escaping @Sendable (EventEnvelope, ChimeRule) -> Void
    ) {
        lock.lock()
        var bucket = debounceBuckets[bucketKey] ?? DebounceBucket(
            events: [],
            rule: rule,
            firstReceivedAt: Date(),
            workItem: nil
        )
        bucket.workItem?.cancel()
        bucket.events.append(event)

        let elapsed = Date().timeIntervalSince(bucket.firstReceivedAt)
        let remainingMax = max(0, rule.maxWaitSeconds - elapsed)
        let delay = min(rule.debounceSeconds, remainingMax)

        let item = DispatchWorkItem { [weak self] in
            self?.flushBucket(key: bucketKey, onReady: onReady)
        }
        bucket.workItem = item
        debounceBuckets[bucketKey] = bucket
        lock.unlock()

        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func flushBucket(key: String, onReady: @escaping @Sendable (EventEnvelope, ChimeRule) -> Void) {
        lock.lock()
        guard let bucket = debounceBuckets.removeValue(forKey: key), !bucket.events.isEmpty else {
            lock.unlock()
            return
        }
        lock.unlock()

        let merged = mergeCoalescedEvents(bucket.events)
        markDispatched(merged, rule: bucket.rule, corrKey: key)
        onReady(merged, bucket.rule)
    }

    private func mergeCoalescedEvents(_ events: [EventEnvelope]) -> EventEnvelope {
        guard events.count > 1, var latest = events.last else {
            var single = events[0]
            single.payload["coalesced_count"] = "1"
            return single
        }

        let bodies = events.compactMap { ev -> String? in
            let sender = ev.payload["subtitle"] ?? ""
            let body = ev.payload["body"] ?? ev.payload["summary"] ?? ""
            if sender.isEmpty && body.isEmpty { return nil }
            return sender.isEmpty ? body : "\(sender): \(body)"
        }
        if !bodies.isEmpty {
            latest.payload["body"] = bodies.joined(separator: "\n")
        }

        let paths = Array(Set(events.compactMap { $0.payload["path"] }.filter { !$0.isEmpty })).sorted()
        if !paths.isEmpty {
            latest.payload["paths"] = paths.joined(separator: ",")
        }
        latest.payload["coalesced_count"] = "\(events.count)"
        return latest
    }

    private func wildcardMatch(pattern: String, value: String) -> Bool {
        if pattern == "*" { return true }
        if pattern.hasSuffix("*") {
            return value.hasPrefix(String(pattern.dropLast()))
        }
        return pattern == value
    }
}
