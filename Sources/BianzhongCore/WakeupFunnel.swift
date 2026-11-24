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

/// Deterministic L0 wakeup funnel implementing privacy ACL, 4-layer loop guard,
/// rule matching, TTL dedup, trailing debounce coalescing, and cooldown locks.
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

        // L0.3: Deterministic rule match
        guard let matchedRule = matchFirstRule(for: event) else {
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

        // L0.5: Trailing debounce & time-window coalescing
        if matchedRule.debounceSeconds <= 0 {
            markDispatched(event, rule: matchedRule, corrKey: corrKey)
            onReady(event, matchedRule)
            return .ready(event: event, rule: matchedRule)
        }

        enqueueDebounce(event, rule: matchedRule, bucketKey: corrKey, onReady: onReady)
        try? store.recordEvent(event, funnelStage: "coalesced", matchedChimeID: matchedRule.id)
        return .coalescing(chimeID: matchedRule.id, correlationKey: event.correlationKey)
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

    private func matchFirstRule(for event: EventEnvelope) -> ChimeRule? {
        let snapshot = currentRules()
        let haystack = event.searchableText.lowercased()

        for rule in snapshot where rule.enabled {
            if !rule.matchTypes.isEmpty && !rule.matchTypes.contains(where: { wildcardMatch(pattern: $0, value: event.type) }) {
                continue
            }
            if !rule.matchSources.isEmpty && !rule.matchSources.contains(where: { wildcardMatch(pattern: $0, value: event.source) }) {
                continue
            }
            if !rule.excludeKeywords.isEmpty && rule.excludeKeywords.contains(where: { haystack.contains($0.lowercased()) }) {
                continue
            }
            if !rule.keywordsAny.isEmpty && !rule.keywordsAny.contains(where: { haystack.contains($0.lowercased()) }) {
                continue
            }
            return rule
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
