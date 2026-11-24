import Foundation
import SQLite3
import Testing
@testable import BianzhongCore

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ initial: Value) {
        self.value = initial
    }

    func withValue<T>(_ body: (inout Value) -> T) -> T {
        lock.withLock {
            body(&value)
        }
    }

    func get() -> Value {
        lock.withLock { value }
    }
}

private func makeTempDir(prefix: String) throws -> URL {
    let dir = URL(fileURLWithPath: "/tmp")
        .appendingPathComponent("\(prefix)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite("BianzhongCore M0 Verification")
struct BianzhongCoreTests {

    @Test("1. Restricted privacy events drop at L0.1 with zero SQLite rows")
    func restrictedPrivacyDropsBeforeSQLite() throws {
        let dir = try makeTempDir(prefix: "bz-t1")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try SQLiteStore(dbURL: dir.appendingPathComponent("bianzhong.db"))
        let rule = ChimeRule(id: "catch-all", enabled: true)
        let funnel = WakeupFunnel(store: store, rules: [rule])

        let secretEvent = EventEnvelope(
            source: "bz://sensor/pasteboard",
            type: "dev.bianzhong.clipboard.changed",
            correlationKey: "clipboard",
            privacyLevel: .restricted,
            payload: ["body": "1password-super-secret-password"]
        )

        let dispatched = LockedBox(false)
        let disposition = funnel.ingest(secretEvent) { _, _ in
            dispatched.withValue { $0 = true }
        }

        #expect(disposition == .dropped(stage: "dropped_acl", reason: "restricted_privacy_level"))
        #expect(dispatched.get() == false)
        #expect(try store.eventCount() == 0)
        #expect(throws: SQLiteStoreError.restrictedEventRejected) {
            try store.recordEvent(secretEvent, funnelStage: "test")
        }
    }

    @Test("2. Anti-loop blocks causal depth >= 1, active write leases, and echo hashes")
    func antiLoopBlocksAllEchoPaths() throws {
        let dir = try makeTempDir(prefix: "bz-t2")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try SQLiteStore(dbURL: dir.appendingPathComponent("bianzhong.db"))
        let rule = ChimeRule(id: "fs-watch", enabled: true, debounceSeconds: 0)
        let funnel = WakeupFunnel(store: store, rules: [rule], maxCausalDepth: 1)

        // (a) Causal depth >= 1
        let childEvent = EventEnvelope(
            source: "bz://cli/emit",
            type: "dev.bianzhong.fs.modified",
            correlationKey: "repo:app",
            causality: Causality(emitterPID: 999, parentRunID: "run-1", depth: 1),
            payload: ["path": "/tmp/app/a.swift"]
        )
        let d1 = funnel.ingest(childEvent) { _, _ in }
        #expect(d1 == .dropped(stage: "dropped_loop", reason: "causal_depth_exceeded:1"))

        // (b) Active write-path lease
        funnel.registerWriteLease(pathPrefix: "/Users/test/repo-x", ttlSeconds: 10)
        let fsEvent = EventEnvelope(
            source: "bz://sensor/fsevents",
            type: "dev.bianzhong.fs.modified",
            correlationKey: "repo-x",
            causality: Causality(emitterPID: 100, parentRunID: nil, depth: 0),
            payload: ["path": "/Users/test/repo-x/src/main.swift"]
        )
        let d2 = funnel.ingest(fsEvent) { _, _ in }
        #expect(d2 == .dropped(stage: "dropped_loop", reason: "active_write_lease:/Users/test/repo-x"))

        // (c) Echo hash suppression
        let echoText = "问题已在 token.ts 修复完成"
        let echoHash = "sha256:" + EventEnvelope.sha256Hex(echoText)
        funnel.registerEchoHash(echoHash, ttlSeconds: 30)
        let pbEvent = EventEnvelope(
            source: "bz://sensor/pasteboard",
            type: "dev.bianzhong.clipboard.changed",
            correlationKey: "pb",
            causality: Causality(emitterPID: 100, parentRunID: nil, depth: 0),
            payload: ["body": echoText, "echo_hash": echoHash]
        )
        let d3 = funnel.ingest(pbEvent) { _, _ in }
        #expect(d3 == .dropped(stage: "dropped_loop", reason: "echo_hash_matched"))
    }

    @Test("3. Chime Markdown + YAML frontmatter parser extracts match, funnel, execution, and prompts")
    func chimeParserParsesFullPlaybook() {
        let md = """
        ---
        id: custom-feishu
        enabled: true
        description: 飞书测试规则

        match:
          type: ["dev.bianzhong.feishu.notification"]
          source: ["bz://sensor/feishu"]
          keywords_any: ["500", "报错"]
          exclude_keywords: ["收到"]

        funnel:
          dedup_ttl: 300s
          debounce: 8s
          max_wait: 30s
          cooldown: 15m
          defer_on_focus: true
          triage:
            enabled: true
            provider: decision_api

        session:
          policy: threaded
          ttl: 12h

        execution:
          autonomy: draft_approve
          driver: codex
          model: gpt-5-mini
          working_dir: /tmp/demo-repo
          worktree_on_phase2: true
          budget:
            phase1_max_time_sec: 120
            phase1_max_cost_usd: 0.20
            phase2_max_time_sec: 480
            phase2_max_cost_usd: 0.80
        ---

        ## Phase 1
        只读检查问题

        ## Phase 2
        根据意见 {{approval.user_comment}} 修复
        """

        let rule = ChimeRule.parse(markdown: md, defaultID: "fallback")
        #expect(rule.id == "custom-feishu")
        #expect(rule.enabled == true)
        #expect(rule.matchTypes == ["dev.bianzhong.feishu.notification"])
        #expect(rule.matchSources == ["bz://sensor/feishu"])
        #expect(rule.keywordsAny == ["500", "报错"])
        #expect(rule.excludeKeywords == ["收到"])
        #expect(rule.dedupTTLSeconds == 300)
        #expect(rule.debounceSeconds == 8.0)
        #expect(rule.maxWaitSeconds == 30.0)
        #expect(rule.cooldownSeconds == 900)
        #expect(rule.triageEnabled == true)
        #expect(rule.triageProviderOverride == "decision_api")
        #expect(rule.sessionPolicy == .threaded)
        #expect(rule.sessionTTLSeconds == 43200)
        #expect(rule.driver == "codex")
        #expect(rule.model == "gpt-5-mini")
        #expect(rule.workingDir == "/tmp/demo-repo")
        #expect(rule.worktreeOnPhase2 == true)
        #expect(rule.phase1MaxTimeSeconds == 120)
        #expect(rule.phase1MaxCostUSD == 0.20)
        #expect(rule.phase1Prompt == "只读检查问题")
        #expect(rule.phase2Prompt == "根据意见 {{approval.user_comment}} 修复")

        // Verify nested `funnel.triage.enabled: false` does not clobber top-level `enabled: true`
        let parsedStarter = ChimeRule.parse(markdown: DefaultTemplates.testFailureChimeMD, defaultID: "local-test-failure")
        #expect(parsedStarter.enabled == true)
        #expect(parsedStarter.triageEnabled == false)
    }

    @Test("4. Burst of 4 Feishu messages coalesces into 1 batch and TTL dedup suppresses duplicate")
    func debounceCoalescesBurstAndDedupSuppressesRepeat() async throws {
        let dir = try makeTempDir(prefix: "bz-t4")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try SQLiteStore(dbURL: dir.appendingPathComponent("bianzhong.db"))
        let rule = ChimeRule(
            id: "feishu-burst",
            enabled: true,
            matchTypes: ["dev.bianzhong.feishu.notification"],
            dedupTTLSeconds: 120,
            debounceSeconds: 0.15,
            maxWaitSeconds: 0.5,
            cooldownSeconds: 60
        )
        let funnel = WakeupFunnel(store: store, rules: [rule])

        let flushedEvents = LockedBox<[EventEnvelope]>([])
        let parts = ["在吗", "订单接口 500 了", "日志报 NPE", "看下是不是刚合的 PR"]

        for (idx, text) in parts.enumerated() {
            let ev = EventEnvelope(
                source: "bz://sensor/feishu",
                type: "dev.bianzhong.feishu.notification",
                correlationKey: "feishu:chat:支付研发群",
                dedupKey: "sha256:msg-\(idx)",
                causality: Causality(emitterPID: 101, parentRunID: nil, depth: 0),
                payload: ["title": "支付研发群", "subtitle": "张三", "body": text]
            )
            let d = funnel.ingest(ev) { merged, _ in
                flushedEvents.withValue { $0.append(merged) }
            }
            #expect(d == .coalescing(chimeID: "feishu-burst", correlationKey: "feishu:chat:支付研发群"))
        }

        // Duplicate dedup_key within TTL must be rejected before entering debounce
        let duplicateEv = EventEnvelope(
            source: "bz://sensor/feishu",
            type: "dev.bianzhong.feishu.notification",
            correlationKey: "feishu:chat:支付研发群",
            dedupKey: "sha256:msg-0",
            causality: Causality(emitterPID: 101, parentRunID: nil, depth: 0),
            payload: ["title": "支付研发群", "subtitle": "张三", "body": "在吗"]
        )
        let dupDisp = funnel.ingest(duplicateEv) { _, _ in }
        #expect(dupDisp == .dropped(stage: "dropped_dedup", reason: "dedup_ttl"))

        try await Task.sleep(for: .milliseconds(350))

        let snapshot = flushedEvents.get()
        let count = snapshot.count
        let mergedBody = snapshot.first?.payload["body"] ?? ""
        let coalescedCount = snapshot.first?.payload["coalesced_count"] ?? ""

        #expect(count == 1)
        #expect(coalescedCount == "4")
        for part in parts {
            #expect(mergedBody.contains(part))
        }
    }

    @Test("5. OmpDriver and CodexDriver build verified CLI args and parse JSONL session streams")
    func agentDriversBuildExpectedArgsAndParseJSONL() {
        let omp = OmpDriver(executablePath: "/usr/local/bin/omp")
        let p1Req = AgentInvocationRequest(
            runID: "run-1",
            correlationKey: "repo:app",
            workingDirectory: "/tmp/repo",
            promptText: "investigate bug",
            eventFilePath: "/tmp/event.json",
            sessionDir: "/tmp/sessions/omp",
            permissionProfile: .readOnly,
            maxTimeSeconds: 180,
            maxCostUSD: 0.25
        )
        let p1Spec = omp.buildSpawnSpec(request: p1Req)
        #expect(p1Spec.arguments.contains("--mode=json"))
        #expect(p1Spec.arguments.contains("--tools=read,grep,glob"))
        #expect(p1Spec.arguments.contains("--no-extensions"))
        #expect(!p1Spec.arguments.contains("investigate bug"))
        #expect(p1Spec.promptFileText == "investigate bug")
        #expect(p1Spec.environment["BIANZHONG_DEPTH"] == "1")

        let ompSessionEv = omp.parseStdoutLine(#"{"type":"session","version":3,"id":"omp-abc-123"}"#)
        #expect(ompSessionEv == [.sessionStarted(externalSessionID: "omp-abc-123")])

        let p2Req = AgentInvocationRequest(
            runID: "run-2",
            correlationKey: "repo:app",
            workingDirectory: "/tmp/worktree-1",
            promptText: "apply fix",
            eventFilePath: "/tmp/event.json",
            sessionDir: "/tmp/sessions/omp",
            permissionProfile: .workspaceRW,
            resumeSessionID: "omp-abc-123",
            worktreeRequested: true
        )
        let p2Spec = omp.buildSpawnSpec(request: p2Req)
        #expect(p2Spec.arguments.contains("-r"))
        #expect(p2Spec.arguments.contains("omp-abc-123"))
        #expect(p2Spec.arguments.contains("--auto-approve"))

        let codex = CodexDriver(executablePath: "/usr/local/bin/codex")
        let c1Spec = codex.buildSpawnSpec(request: p1Req)
        #expect(c1Spec.arguments.prefix(2) == ["exec", "--json"])
        #expect(c1Spec.arguments.contains("read-only"))
        #expect(c1Spec.arguments.last == "-")

        let cSessionEv = codex.parseStdoutLine(#"{"type":"thread.started","thread_id":"019d-codex-xyz"}"#)
        #expect(cSessionEv == [.sessionStarted(externalSessionID: "019d-codex-xyz")])

        let c2Req = AgentInvocationRequest(
            runID: "run-3",
            correlationKey: "repo:app",
            workingDirectory: "/tmp/repo",
            promptText: "fix in worktree",
            eventFilePath: "/tmp/event.json",
            sessionDir: "/tmp/sessions/codex",
            permissionProfile: .workspaceRW,
            resumeSessionID: "019d-codex-xyz",
            worktreeRequested: true
        )
        let c2Spec = codex.buildSpawnSpec(request: c2Req)
        #expect(Array(c2Spec.arguments.prefix(4)) == ["exec", "fork", "019d-codex-xyz", "--worktree"])
        #expect(c2Spec.arguments.contains("sandbox_mode=\"workspace-write\""))
    }

    @Test("6. SocketBus + SQLiteStore end-to-end UDS emit and status roundtrip")
    func socketBusEndToEndRoundtrip() throws {
        let shortID = String(UUID().uuidString.prefix(8))
        let stateDir = URL(fileURLWithPath: "/tmp/bz-s-\(shortID)", isDirectory: true)
        let cfgDir = URL(fileURLWithPath: "/tmp/bz-c-\(shortID)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: stateDir)
            try? FileManager.default.removeItem(at: cfgDir)
        }

        let paths = BianzhongPaths(configDir: cfgDir, stateDir: stateDir)
        try DefaultTemplates.installDefaultsIfMissing(paths: paths)
        let orch = try Orchestrator(paths: paths)
        try orch.start()
        defer { orch.stop() }

        let env = EventEnvelope(
            source: "bz://sensor/feishu",
            type: "dev.bianzhong.feishu.notification",
            correlationKey: "feishu:chat:日常水群",
            causality: Causality(emitterPID: 42, parentRunID: nil, depth: 0),
            payload: ["title": "日常水群", "subtitle": "李四", "body": "收到，辛苦"]
        )
        let emitResp = try SocketClient.send(request: BusRequest(action: "emit", event: env), socketURL: paths.socketURL)
        #expect(emitResp.ok == true)
        #expect(emitResp.disposition == "dropped_rule:no_chime_matched")

        let statusResp = try SocketClient.send(request: BusRequest(action: "status"), socketURL: paths.socketURL)
        #expect(statusResp.ok == true)
        #expect(statusResp.status?.loadedRules == 3)
        #expect(statusResp.status?.eventsCount == 1)
    }

    @Test("7. NotificationPayloadDecoder decodes usernoted bplist blobs")
    func binaryPlistNotificationDecoder() throws {
        let dict: [String: Any] = [
            "req": [
                "titl": "支付研发群",
                "subt": "张三",
                "body": "@你 退款接口报 500"
            ]
        ]
        let bplist = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
        let decoded = NotificationPayloadDecoder.decode(bplistData: bplist)

        #expect(decoded?.title == "支付研发群")
        #expect(decoded?.subtitle == "张三")
        #expect(decoded?.body == "@你 退款接口报 500")
    }

    @Test("8. Governance enforces daily cost/run caps, circuit breaker reset, and dirty-safe GC")
    func governanceCapsCircuitAndDirtySafeGC() throws {
        let dir = try makeTempDir(prefix: "bz-t8")
        defer { try? FileManager.default.removeItem(at: dir) }

        let paths = BianzhongPaths(configDir: dir.appendingPathComponent("cfg"), stateDir: dir.appendingPathComponent("state"))
        try paths.ensureDirectories()
        let store = try SQLiteStore(dbURL: paths.dbURL)
        let gov = RuntimeGovernance()
        var cfg = AppConfig(dailyMaxCostUSD: 1.0, dailyMaxRuns: 5, circuitBreakerFailures: 2, retentionDays: 7)

        let ev = EventEnvelope(source: "bz://test", type: "dev.bianzhong.ci.failed", correlationKey: "repo:app")
        try store.recordEvent(ev, funnelStage: "dispatched", matchedChimeID: "r1")

        // Insert 2 failed runs -> trips circuit breaker for r1
        for i in 1...2 {
            let rid = "run-fail-\(i)"
            try store.insertRun(id: rid, eventID: ev.id, sessionID: nil, chimeID: "r1", phase: "draft", driver: "omp", status: "running")
            try store.updateRunStatus(id: rid, status: "failed", exitCode: 1, costUSD: 0.2)
        }
        #expect(gov.checkAdmission(chimeID: "r1", config: cfg, store: store) == .circuitOpen(chimeID: "r1", failures: 2))

        // Manual circuit reset clears open state immediately
        gov.resetCircuit(chimeID: "r1")
        #expect(gov.checkAdmission(chimeID: "r1", config: cfg, store: store) == .allowed)

        // Daily cost cap blocks when today's spend reaches cap
        cfg.dailyMaxCostUSD = 0.35
        #expect(gov.checkAdmission(chimeID: "r1", config: cfg, store: store) == .blockedDailyCost(current: 0.4, cap: 0.35))

        // Dirty worktree GC test: create an old clean run dir and an old dirty git worktree
        let oldDate = Date().addingTimeInterval(-10 * 86400)
        let oldRunDir = paths.runsDir.appendingPathComponent("old-run", isDirectory: true)
        try FileManager.default.createDirectory(at: oldRunDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldRunDir.path)

        let dirtyWT = paths.worktreesDir.appendingPathComponent("dirty-wt", isDirectory: true)
        try FileManager.default.createDirectory(at: dirtyWT, withIntermediateDirectories: true)
        let initProc = Process()
        initProc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        initProc.arguments = ["-C", dirtyWT.path, "init", "-q"]
        try initProc.run()
        initProc.waitUntilExit()
        try "uncommitted change".write(to: dirtyWT.appendingPathComponent("dirty.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: dirtyWT.path)

        let report = gov.performGC(paths: paths, store: store, retentionDays: 7)
        #expect(report.removedRunDirs == 1)
        #expect(!FileManager.default.fileExists(atPath: oldRunDir.path))
        #expect(report.preservedDirtyWorktrees.count == 1)
        #expect(report.preservedDirtyWorktrees.contains { $0.hasSuffix("/dirty-wt") })
        #expect(FileManager.default.fileExists(atPath: dirtyWT.path))
    }

    @Test("9. Correlated 20m timeline and preflight_cmd / on_complete Chime parsing")
    func correlatedTimelineAndExtendedChimeParsing() throws {
        let dir = try makeTempDir(prefix: "bz-t9")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try SQLiteStore(dbURL: dir.appendingPathComponent("bianzhong.db"))
        let priorEv = EventEnvelope(
            source: "bz://sensor/shell/zsh",
            type: "dev.bianzhong.shell.command_failed",
            correlationKey: "shell:/tmp/repo",
            payload: ["title": "swift test 失败", "body": "Exit: 1"]
        )
        let currentEv = EventEnvelope(
            source: "bz://sensor/feishu",
            type: "dev.bianzhong.feishu.notification",
            correlationKey: "feishu:chat:研发群",
            payload: ["title": "研发群", "body": "构建挂了吗？"]
        )
        try store.recordEvent(priorEv, funnelStage: "dispatched", matchedChimeID: "shell")
        try store.recordEvent(currentEv, funnelStage: "dispatched", matchedChimeID: "feishu")

        let timeline = try store.recentTimeline(withinSeconds: 1200, excludingEventID: currentEv.id, limit: 10)
        #expect(timeline.count == 1)
        #expect(timeline.first?.id == priorEv.id)
        #expect(timeline.first?.summary.contains("swift test 失败") == true)

        let md = """
        ---
        id: multi-action-rule
        enabled: true
        match:
          type: ["dev.bianzhong.feishu.notification"]
        execution:
          driver: none
          working_dir: $payload.cwd
          preflight_cmd: "git status -s"
          preflight_timeout_sec: 15
        on_complete:
          - type: notify
          - type: webhook
            url_env: BARK_URL
            when: "screen_locked == true || idle_seconds > 600"
          - type: append_markdown
            path: "~/Notes/{{date}}.md"
          - type: chime_sound
            name: Glass
            tts: true
        ---
        ## Phase 1
        direct
        """
        let parsed = ChimeRule.parse(markdown: md, defaultID: "fallback")
        #expect(parsed.driver == "none")
        #expect(parsed.workingDir == "$payload.cwd")
        #expect(parsed.preflightCmd == "git status -s")
        #expect(parsed.preflightTimeoutSeconds == 15)
        #expect(parsed.onComplete.count == 4)
        #expect(parsed.onComplete[1].type == .webhook)
        #expect(parsed.onComplete[1].urlEnv == "BARK_URL")
        #expect(parsed.onComplete[1].whenCondition == "screen_locked == true || idle_seconds > 600")
        #expect(parsed.onComplete[3].tts == true)
    }

    @Test("10. ActionConditionEvaluator and ActionDispatcher append_markdown with write lease")
    func actionConditionsAndAppendMarkdown() async throws {
        let dir = try makeTempDir(prefix: "bz-t10")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try SQLiteStore(dbURL: dir.appendingPathComponent("bianzhong.db"))
        let notesFile = dir.appendingPathComponent("notes/daily-{{date}}.md")
        let rule = ChimeRule(
            id: "notes-rule",
            matchTypes: ["dev.bianzhong.fs.modified"],
            debounceSeconds: 0,
            onComplete: [
                ActionSpec(type: .webhook, whenCondition: "screen_locked == true || idle_seconds > 600", url: "http://127.0.0.1:9/unused"),
                ActionSpec(type: .appendMarkdown, whenCondition: "phase == 'draft' && risk_level == 'medium'", path: notesFile.path)
            ]
        )
        let funnel = WakeupFunnel(store: store, rules: [rule])
        let dispatcher = ActionDispatcher(funnel: funnel, notifyHandler: { _ in })

        let lockedEv = EventEnvelope(
            source: "bz://test",
            type: "dev.bianzhong.test",
            correlationKey: "k1",
            payload: ["title": "CI 修复草案", "kind": "review"],
            ambientContext: AmbientContext(frontmostBundleID: nil, focusActive: false, idleSeconds: 45, screenLocked: true)
        )
        let ctxLocked = ActionContext(event: lockedEv, rule: rule, approval: nil, phase: "draft", summaryText: "已定位 token.ts 空指针")
        #expect(ActionConditionEvaluator.matches("screen_locked == true || idle_seconds > 600", context: ctxLocked) == true)
        #expect(ActionConditionEvaluator.matches("idle_seconds > 600", context: ctxLocked) == false)
        #expect(ActionConditionEvaluator.matches("kind == 'todo'", context: ctxLocked) == false)

        let executed = await dispatcher.dispatch(specs: [rule.onComplete[1]], context: ctxLocked)
        #expect(executed == ["append_markdown"])

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        let actualPath = notesFile.path.replacingOccurrences(of: "{{date}}", with: dateFmt.string(from: Date()))
        let written = try String(contentsOfFile: actualPath, encoding: .utf8)
        #expect(written.contains("CI 修复草案"))
        #expect(written.contains("已定位 token.ts 空指针"))

        // Confirm write lease on notes directory prevents FSEvents self-loop right after writing
        let echoFS = EventEnvelope(
            source: "bz://sensor/fsevents",
            type: "dev.bianzhong.fs.modified",
            correlationKey: "notes",
            causality: Causality(emitterPID: 10, parentRunID: nil, depth: 0),
            payload: ["path": actualPath]
        )
        #expect(funnel.ingest(echoFS) { _, _ in } == .dropped(stage: "dropped_loop", reason: "active_write_lease:\(URL(fileURLWithPath: actualPath).deletingLastPathComponent().path)"))
    }

    @Test("11. RuleSimulator replays historical events cleanly without mutating production DB")
    func ruleSimulatorDryReplay() async throws {
        let dir = try makeTempDir(prefix: "bz-t11")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try SQLiteStore(dbURL: dir.appendingPathComponent("bianzhong.db"))
        let ev1 = EventEnvelope(
            source: "bz://sensor/feishu",
            type: "dev.bianzhong.feishu.notification",
            correlationKey: "feishu:chat:支付研发群",
            causality: Causality(emitterPID: 1, parentRunID: nil, depth: 0),
            payload: ["title": "支付研发群", "body": "@你 订单接口报 500"]
        )
        let ev2 = EventEnvelope(
            source: "bz://sensor/feishu",
            type: "dev.bianzhong.feishu.notification",
            correlationKey: "feishu:chat:闲聊",
            causality: Causality(emitterPID: 1, parentRunID: nil, depth: 0),
            payload: ["title": "闲聊", "body": "收到，辛苦啦"]
        )
        try store.recordEvent(ev1, funnelStage: "dispatched", matchedChimeID: "feishu-oncall-triage")
        try store.recordEvent(ev2, funnelStage: "dropped_rule", dropReason: "no_chime_matched")

        let history = try store.listRecentEvents(limit: 10)
        #expect(history.count == 2)

        let feishuRule = ChimeRule.parse(markdown: DefaultTemplates.feishuChimeMD, defaultID: "feishu-oncall-triage")
        let summary = await RuleSimulator.simulate(events: history, rules: [feishuRule], config: AppConfig(), runL1: false)

        #expect(summary.totalEvents == 2)
        #expect(summary.wouldWakeAgent == 1)
        #expect(summary.droppedL0 == 1)
        #expect(try store.listPendingApprovals().isEmpty)
    }

    @Test("12. Wake Digest consolidates deferred items into a single pending summary card")
    func wakeDigestConsolidatesDeferredItems() throws {
        let dir = try makeTempDir(prefix: "bz-t12")
        defer { try? FileManager.default.removeItem(at: dir) }

        let paths = BianzhongPaths(configDir: dir.appendingPathComponent("cfg"), stateDir: dir.appendingPathComponent("state"))
        try paths.ensureDirectories()
        let orch = try Orchestrator(paths: paths)

        for i in 1...2 {
            let ev = EventEnvelope(
                source: "bz://sensor/feishu",
                type: "dev.bianzhong.feishu.notification",
                correlationKey: "feishu:chat:group-\(i)",
                payload: ["title": "群 \(i)", "body": "普通同步消息 \(i)"]
            )
            try orch.store.recordEvent(ev, funnelStage: "dispatched", matchedChimeID: "c1")
            let rid = "run-d-\(i)"
            try orch.store.insertRun(id: rid, eventID: ev.id, sessionID: nil, chimeID: "c1", phase: "notify", driver: "triage", status: "succeeded")
            try orch.store.insertApproval(ApprovalRecord(
                id: "apr-d-\(i)",
                runID: rid,
                eventID: ev.id,
                sessionID: nil,
                chimeID: "c1",
                kind: "digest",
                riskLevel: "low",
                title: "群 \(i)",
                provenanceSummary: "bz://sensor/feishu • c1",
                proposedAction: "普通同步消息 \(i)",
                targetRepo: nil,
                externalSessionID: nil,
                status: "deferred",
                userComment: nil,
                createdAt: SQLiteStore.nowMs(),
                resolvedAt: nil
            ))
        }

        #expect(orch.deferredDigestCount() == 2)
        #expect(orch.pendingApprovals().isEmpty)

        let merged = orch.flushWakeDigest()
        #expect(merged != nil)
        #expect(merged?.title == "晨钟摘要（2 条待阅信号）")
        #expect(merged?.proposedAction.contains("普通同步消息 1") == true)
        #expect(merged?.proposedAction.contains("普通同步消息 2") == true)
        #expect(orch.deferredDigestCount() == 0)
        #expect(orch.pendingApprovals().count == 1)
    }

    @Test("13. Negative-feedback RuleTuner and zsh ShellHook generation")
    func ruleTunerAndShellHook() throws {
        let dir = try makeTempDir(prefix: "bz-t13")
        defer { try? FileManager.default.removeItem(at: dir) }

        let paths = BianzhongPaths(configDir: dir.appendingPathComponent("cfg"), stateDir: dir.appendingPathComponent("state"))
        try DefaultTemplates.installDefaultsIfMissing(paths: paths)
        let store = try SQLiteStore(dbURL: paths.dbURL)

        let ev = EventEnvelope(
            source: "bz://sensor/feishu",
            type: "dev.bianzhong.feishu.notification",
            correlationKey: "feishu:chat:闲聊",
            payload: ["title": "研发群", "body": "周五下午茶报一下口味"]
        )
        try store.recordEvent(ev, funnelStage: "dispatched", matchedChimeID: "feishu-oncall-triage")
        try store.insertRun(id: "run-rej", eventID: ev.id, sessionID: nil, chimeID: "feishu-oncall-triage", phase: "draft", driver: "omp", status: "waiting_approval")
        try store.insertApproval(ApprovalRecord(
            id: "apr-rej",
            runID: "run-rej",
            eventID: ev.id,
            sessionID: nil,
            chimeID: "feishu-oncall-triage",
            kind: "question",
            riskLevel: "low",
            title: "研发群",
            provenanceSummary: "bz://sensor/feishu • feishu-oncall-triage",
            proposedAction: "草稿",
            targetRepo: nil,
            externalSessionID: nil,
            status: "rejected",
            userComment: "下午茶闲聊别触发",
            createdAt: SQLiteStore.nowMs(),
            resolvedAt: SQLiteStore.nowMs()
        ))

        let tune = try RuleTuner.prepareTuneSession(paths: paths, store: store, chimeID: "feishu-oncall-triage")
        #expect(tune.sampleCount == 1)
        let sampleText = try String(contentsOf: tune.contextFile, encoding: .utf8)
        #expect(sampleText.contains("周五下午茶报一下口味"))
        #expect(sampleText.contains("下午茶闲聊别触发"))

        let hook = ShellHook.zshScript(bzExecutablePath: "/usr/local/bin/bz")
        #expect(hook.contains("BIANZHONG_DEPTH"))
        #expect(hook.contains("exit_code == 130"))
        #expect(hook.contains("--cwd \"$PWD\""))
        #expect(hook.contains("&!"))
    }

    @Test("14. AgentProcessRunner avoids pipe deadlock, survives early SIGPIPE, and passes @file 0600 prompts")
    func agentProcessRunnerPipeAndPromptFileSafety() async {
        // (a) >128 KB bidirectional pipe I/O must complete without deadlock
        let largePayload = String(repeating: "A", count: 160_000)
        let catSpec = SpawnSpec(
            executablePath: "/bin/cat",
            arguments: [],
            stdinData: Data(largePayload.utf8),
            workingDirectory: "/tmp"
        )
        let catRes = await AgentProcessRunner.run(spec: catSpec, timeoutSeconds: 5)
        #expect(catRes.timedOut == false)
        #expect(catRes.exitCode == 0)
        #expect(catRes.stdout.utf8.count == 160_000)

        // (b) Early child exit before stdin drains must not crash via SIGPIPE
        let earlyExitSpec = SpawnSpec(
            executablePath: "/usr/bin/true",
            arguments: [],
            stdinData: Data(repeating: 0x42, count: 200_000),
            workingDirectory: "/tmp"
        )
        let earlyRes = await AgentProcessRunner.run(spec: earlyExitSpec, timeoutSeconds: 5)
        #expect(earlyRes.timedOut == false)
        #expect(earlyRes.exitCode == 0)

        // (c) @file prompt materialization uses 0600 perms and auto-cleans temp file
        let script = """
        arg="$1"; p="${arg#@}"; stat -f "%Lp" "$p"; cat "$p"; echo ""; echo "$p"
        """
        let promptSpec = SpawnSpec(
            executablePath: "/bin/zsh",
            arguments: ["-c", script, "inline"],
            promptFileText: "secret-feishu-payload",
            workingDirectory: "/tmp"
        )
        let promptRes = await AgentProcessRunner.run(spec: promptSpec, timeoutSeconds: 5)
        #expect(promptRes.exitCode == 0)
        let lines = promptRes.stdout.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0] == "600")
        #expect(lines[1] == "secret-feishu-payload")
        if lines.count == 3 {
            #expect(!FileManager.default.fileExists(atPath: lines[2]))
        }
    }

    @Test("15. FeishuSensorRunner keeps cursor unadvanced when daemon offline and replays on recovery")
    func feishuSensorPreservesCursorAcrossDaemonOutage() throws {
        let shortID = String(UUID().uuidString.prefix(8))
        let stateDir = URL(fileURLWithPath: "/tmp/bz-s15-\(shortID)", isDirectory: true)
        let cfgDir = URL(fileURLWithPath: "/tmp/bz-c15-\(shortID)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: stateDir)
            try? FileManager.default.removeItem(at: cfgDir)
        }

        let paths = BianzhongPaths(configDir: cfgDir, stateDir: stateDir)
        try paths.ensureDirectories()

        // Create a mock usernoted SQLite fixture with 2 Feishu notifications
        let dbURL = stateDir.appendingPathComponent("usernoted.db")
        var db: OpaquePointer?
        #expect(sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }

        let ddl = """
        CREATE TABLE app (app_id INTEGER PRIMARY KEY, identifier TEXT NOT NULL);
        CREATE TABLE record (rec_id INTEGER PRIMARY KEY, app_id INTEGER NOT NULL, data BLOB, delivered_date REAL);
        INSERT INTO app (app_id, identifier) VALUES (1, 'com.electron.lark');
        """
        #expect(sqlite3_exec(db, ddl, nil, nil, nil) == SQLITE_OK)

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (recID, body) in [(1 as Int64, "消息一"), (2 as Int64, "消息二")] {
            let plist: [String: Any] = ["req": ["titl": "研发群", "subt": "张三", "body": body]]
            let blob = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            var stmt: OpaquePointer?
            #expect(sqlite3_prepare_v2(db, "INSERT INTO record (rec_id, app_id, data, delivered_date) VALUES (?, 1, ?, 0);", -1, &stmt, nil) == SQLITE_OK)
            sqlite3_bind_int64(stmt, 1, recID)
            _ = blob.withUnsafeBytes { raw in
                sqlite3_bind_blob(stmt, 2, raw.baseAddress, Int32(raw.count), transient)
            }
            #expect(sqlite3_step(stmt) == SQLITE_DONE)
            sqlite3_finalize(stmt)
        }

        let sensor = FeishuSensorRunner(
            dbURL: dbURL,
            cursorURL: paths.feishuCursorURL,
            socketURL: paths.socketURL,
            skipExistingOnFirstRun: false
        )

        // Daemon is offline: pollOnce must throw and MUST NOT advance cursor
        #expect(throws: (any Error).self) {
            try sensor.pollOnce(dryRun: false)
        }
        #expect(sensor.currentCursor() == 0)
        #expect(!FileManager.default.fileExists(atPath: paths.feishuCursorURL.path))

        // Start Orchestrator daemon and retry: both queued records must be delivered once
        let orch = try Orchestrator(paths: paths)
        try orch.start()
        defer { orch.stop() }

        let delivered = try sensor.pollOnce(dryRun: false)
        #expect(delivered == 2)
        #expect(sensor.currentCursor() == 2)
        #expect(try orch.store.eventCount() == 2)
        #expect(try sensor.pollOnce(dryRun: false) == 0)
    }

    @Test("16. Phase 2 tracks token/cost usage, updates forked session ID, and dispatches Phase 2 actions")
    func phase2AccountingSessionUpdateAndActions() async throws {
        struct MockTwoPhaseDriver: AgentDriver {
            let id: String
            func buildSpawnSpec(request: AgentInvocationRequest) -> SpawnSpec {
                let script: String
                if request.permissionProfile == .readOnly {
                    script = """
                    printf '%s\n' '{"type":"session","version":3,"id":"ses-phase1"}'
                    printf '%s\n' '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Phase 1 根因分析完成"}],"usage":{"input":100,"output":40,"cacheRead":10,"cost":{"total":0.15}}}}'
                    """
                } else {
                    script = """
                    printf '%s\n' '{"type":"session","version":3,"id":"ses-phase2-forked"}'
                    printf '%s\n' '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Phase 2 修复并测试通过"}],"usage":{"input":200,"output":80,"cacheRead":20,"cost":{"total":0.60}}}}'
                    """
                }
                return SpawnSpec(executablePath: "/bin/zsh", arguments: ["-c", script], workingDirectory: request.workingDirectory)
            }
            func parseStdoutLine(_ line: String) -> [NormalizedAgentEvent] {
                OmpDriver().parseStdoutLine(line)
            }
            func isSuccessExit(exitCode: Int32, lastEvents: [NormalizedAgentEvent]) -> Bool { exitCode == 0 }
            func buildTakeoverCommand(sessionID: String, sessionDir: String, workingDirectory: String) -> String {
                "mock resume \(sessionID) in \(workingDirectory)"
            }
        }

        let shortID = String(UUID().uuidString.prefix(8))
        let driverID = "mock-p2-\(shortID)"
        AgentDriverRegistry.register(MockTwoPhaseDriver(id: driverID))
        defer { AgentDriverRegistry.unregister(id: driverID) }

        let stateDir = URL(fileURLWithPath: "/tmp/bz-s16-\(shortID)", isDirectory: true)
        let cfgDir = URL(fileURLWithPath: "/tmp/bz-c16-\(shortID)", isDirectory: true)
        let workDir = URL(fileURLWithPath: "/tmp/bz-w16-\(shortID)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: stateDir)
            try? FileManager.default.removeItem(at: cfgDir)
            try? FileManager.default.removeItem(at: workDir)
        }
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let executedNote = stateDir.appendingPathComponent("notes/phase2-exec.md").path
        let nonExecNote = stateDir.appendingPathComponent("notes/non-exec.md").path

        let paths = BianzhongPaths(configDir: cfgDir, stateDir: stateDir)
        try paths.ensureDirectories()
        let ruleMD = """
        ---
        id: mock-p2-rule
        enabled: true
        match:
          type: ["dev.bianzhong.ci.failed"]
        funnel:
          debounce: 0s
          triage:
            enabled: false
            provider: none
        session:
          policy: threaded
          ttl: 1h
        execution:
          autonomy: draft_approve
          driver: \(driverID)
          working_dir: \(workDir.path)
          worktree_on_phase2: false
        on_complete:
          - type: notify
          - type: append_markdown
            path: \(executedNote)
            when: "phase == 'execute'"
          - type: append_markdown
            path: \(nonExecNote)
            when: "phase != 'execute'"
        ---
        ## Phase 1
        readonly

        ## Phase 2
        fix {{approval.user_comment}}
        """
        try ruleMD.write(to: paths.chimesDir.appendingPathComponent("mock-p2-rule.md"), atomically: true, encoding: .utf8)

        let notifiedApprovals = LockedBox<[ApprovalRecord]>([])
        let callbacks = OrchestratorCallbacks(
            onApprovalUpdated: {},
            onNotifyApproval: { rec in
                notifiedApprovals.withValue { $0.append(rec) }
            }
        )
        let orch = try Orchestrator(paths: paths, callbacks: callbacks)

        let ev = EventEnvelope(
            source: "bz://test",
            type: "dev.bianzhong.ci.failed",
            correlationKey: "ci:repo",
            payload: ["title": "CI 构建失败", "body": "unit test failed"]
        )
        _ = orch.handleBusRequest(BusRequest(action: "emit", event: ev))

        // Wait for Phase 1 approval item
        for _ in 0..<60 {
            if !orch.pendingApprovals().isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let p1Approval = try #require(orch.pendingApprovals().first)
        #expect(p1Approval.externalSessionID == "ses-phase1")
        #expect(notifiedApprovals.get().contains { $0.id == p1Approval.id })

        // Approve and wait for Phase 2 run completion
        orch.approve(id: p1Approval.id, comment: "LGTM")
        for _ in 0..<80 {
            let runs = orch.recentRuns()
            if runs.contains(where: { $0.phase == "execute" && $0.status == "succeeded" }) {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        // Small yield to let post-run DB/actions settle
        try await Task.sleep(for: .milliseconds(100))

        let p2Run = try #require(orch.recentRuns().first(where: { $0.phase == "execute" }))
        #expect(p2Run.status == "succeeded")
        #expect(abs(p2Run.costUSD - 0.60) < 0.0001)

        // Governance must see combined Phase 1 ($0.15) + Phase 2 ($0.60) = $0.75
        let usage = try orch.store.todayUsageSummary()
        #expect(abs(usage.totalCostUSD - 0.75) < 0.0001)
        let strictCapCfg = AppConfig(dailyMaxCostUSD: 0.70, dailyMaxRuns: 10, circuitBreakerFailures: 3, retentionDays: 7)
        let verdict = orch.governance.checkAdmission(chimeID: "mock-p2-rule", config: strictCapCfg, store: orch.store)
        #expect(verdict == .blockedDailyCost(current: usage.totalCostUSD, cap: 0.70))

        // Takeover command and active session must both reflect the forked Phase 2 session ID
        #expect(orch.takeoverCommand(for: p1Approval.id)?.contains("ses-phase2-forked") == true)
        let activeSes = try orch.store.findActiveSession(correlationKey: "ci:repo", driver: driverID)
        #expect(activeSes?.externalSessionID == "ses-phase2-forked")

        // Phase 2 completion notified + dispatched `phase == 'execute'` action without running `phase != 'execute'`
        let notified = notifiedApprovals.get()
        #expect(notified.count == 2)
        #expect(notified.last?.kind == "notify")
        #expect(FileManager.default.fileExists(atPath: executedNote))
        #expect(FileManager.default.fileExists(atPath: nonExecNote))
        let nonExecText = try String(contentsOfFile: nonExecNote, encoding: .utf8)
        #expect(!nonExecText.contains("Phase 2 修复并测试通过"))
    }

    @Test("17. SocketBus rejects duplicate live instance without unlinking active socket")
    func socketBusRejectsDuplicateLiveDaemon() throws {
        let shortID = String(UUID().uuidString.prefix(8))
        let sockURL = URL(fileURLWithPath: "/tmp/bz-s17-\(shortID).sock")
        defer { try? FileManager.default.removeItem(at: sockURL) }

        let bus1 = SocketBus(socketURL: sockURL) { req in
            BusResponse(ok: true, message: "primary:\(req.action)")
        }
        try bus1.start()
        defer { bus1.stop() }

        do {
            let bus2: SocketBus? = SocketBus(socketURL: sockURL) { _ in BusResponse(ok: true) }
            #expect(throws: SocketClientError.daemonAlreadyRunning(sockURL.path)) {
                try bus2?.start()
            }
            _ = bus2 // released at end of do scope, triggering bus2.deinit
        }

        // Socket file and primary listener must still be intact after bus2 failed and deallocated
        #expect(FileManager.default.fileExists(atPath: sockURL.path))
        let resp = try SocketClient.send(request: BusRequest(action: "status"), socketURL: sockURL)
        #expect(resp.ok == true)
        #expect(resp.message == "primary:status")
    }

    @Test("18. Canonical write-lease boundary, timed pause expiry, rolling_daily rotation, and NSKeyedArchiver bplist")
    func leaseBoundaryTimedPauseRollingDailyAndKeyedArchiver() async throws {
        let dir = try makeTempDir(prefix: "bz-t18")
        defer { try? FileManager.default.removeItem(at: dir) }

        let paths = BianzhongPaths(configDir: dir.appendingPathComponent("cfg"), stateDir: dir.appendingPathComponent("state"))
        try paths.ensureDirectories()
        let orch = try Orchestrator(paths: paths)

        // (a) Write lease respects path-segment boundary and canonicalizes /tmp vs /private/tmp
        let repoLease = "/tmp/bz-t18-lease-\(UUID().uuidString.prefix(6))/repo"
        orch.funnel.registerWriteLease(pathPrefix: repoLease, ttlSeconds: 10)

        let siblingPath = "/private" + repoLease + "-other/a.swift"
        let siblingEv = EventEnvelope(source: "bz://sensor/fsevents", type: "dev.bianzhong.fs.modified", correlationKey: "s", payload: ["path": siblingPath])
        #expect(orch.funnel.ingest(siblingEv) { _, _ in } == .dropped(stage: "dropped_rule", reason: "no_chime_matched"))

        let nestedPath = "/private" + repoLease + "/src/b.swift"
        let nestedEv = EventEnvelope(source: "bz://sensor/fsevents", type: "dev.bianzhong.fs.modified", correlationKey: "n", payload: ["path": nestedPath])
        #expect(orch.funnel.ingest(nestedEv) { _, _ in } == .dropped(stage: "dropped_loop", reason: "active_write_lease:\(repoLease)"))

        // (b) Timed pause auto-resumes after duration
        orch.pause(forSeconds: 0.2)
        #expect(orch.isPaused() == true)
        let pausedResp = orch.handleBusRequest(BusRequest(action: "emit", event: siblingEv))
        #expect(pausedResp.disposition == "paused")

        try await Task.sleep(for: .milliseconds(350))
        #expect(orch.isPaused() == false)
        let resumedResp = orch.handleBusRequest(BusRequest(action: "emit", event: siblingEv))
        #expect(resumedResp.disposition != "paused")

        // (c) rolling_daily rotates across midnight even if TTL has not expired
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let yesterdayNoon = cal.date(byAdding: .hour, value: -12, to: todayStart)!
        let yesterdayMs = Int64(yesterdayNoon.timeIntervalSince1970 * 1000)

        try orch.store.upsertSession(
            id: "ses-yesterday",
            correlationKey: "chat:daily",
            driver: "omp",
            policy: .rollingDaily,
            externalSessionID: "ext-yesterday",
            cwd: "/tmp",
            ttlSeconds: 7 * 86400,
            createdAtMs: yesterdayMs
        )
        #expect(try orch.store.findActiveSession(correlationKey: "chat:daily", driver: "omp", policy: .threaded) != nil)
        #expect(try orch.store.findActiveSession(correlationKey: "chat:daily", driver: "omp", policy: .rollingDaily) == nil)

        try orch.store.upsertSession(
            id: "ses-today",
            correlationKey: "chat:daily",
            driver: "omp",
            policy: .rollingDaily,
            externalSessionID: "ext-today",
            cwd: "/tmp",
            ttlSeconds: 7 * 86400
        )
        let activeToday = try orch.store.findActiveSession(correlationKey: "chat:daily", driver: "omp", policy: .rollingDaily)
        #expect(activeToday?.externalSessionID == "ext-today")

        // (d) NSKeyedArchiver notification bplist decoding
        let archivedDict: NSDictionary = [
            "req": [
                "titl": "线上告警群",
                "subt": "Bot",
                "body": "P0 异常"
            ]
        ]
        let archivedData = try NSKeyedArchiver.archivedData(withRootObject: archivedDict, requiringSecureCoding: false)
        let decoded = NotificationPayloadDecoder.decode(bplistData: archivedData)
        #expect(decoded?.title == "线上告警群")
        #expect(decoded?.subtitle == "Bot")
        #expect(decoded?.body == "P0 异常")
    }
}
