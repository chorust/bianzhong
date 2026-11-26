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

    @Test("19. Single-app in-process Feishu monitor, bz symlink automation, and idempotent .zshrc hook")
    func singleAppSensorAndCLIIntegration() async throws {
        let shortID = String(UUID().uuidString.prefix(8))
        let dir = URL(fileURLWithPath: "/tmp/bz-t19-\(shortID)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let binDir = dir.appendingPathComponent("bin", isDirectory: true)
        let srcDir = dir.appendingPathComponent("src", isDirectory: true)
        let cfgDir = dir.appendingPathComponent("cfg", isDirectory: true)
        let stateDir = dir.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)

        // (a) Mock executable bz inside bundle + symlink lifecycle
        let fakeBZ = srcDir.appendingPathComponent("bz")
        try "#!/bin/zsh\necho ok\n".write(to: fakeBZ, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBZ.path)

        let linked = CLIIntegration.ensureCLISymlinks(
            sourceBZPath: fakeBZ.path,
            homeDir: dir,
            candidateDirs: [binDir],
            force: false
        )
        #expect(linked == [binDir.appendingPathComponent("bz").path])
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: binDir.appendingPathComponent("bz").path)
        #expect(URL(fileURLWithPath: dest).resolvingSymlinksInPath().path == fakeBZ.resolvingSymlinksInPath().path)

        // (b) Custom non-symlink bz binary is preserved when force == false, replaced when force == true
        let customBZ = dir.appendingPathComponent("custom-bin/bz")
        try FileManager.default.createDirectory(at: customBZ.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "custom".write(to: customBZ, atomically: true, encoding: .utf8)
        let skipped = CLIIntegration.ensureCLISymlinks(
            sourceBZPath: fakeBZ.path,
            homeDir: dir,
            candidateDirs: [customBZ.deletingLastPathComponent()],
            force: false
        )
        #expect(skipped.isEmpty)
        let forced = CLIIntegration.ensureCLISymlinks(
            sourceBZPath: fakeBZ.path,
            homeDir: dir,
            candidateDirs: [customBZ.deletingLastPathComponent()],
            force: true
        )
        #expect(forced == [customBZ.path])

        // (c) Idempotent .zshrc block add & clean removal preserving existing lines
        let zshrc = dir.appendingPathComponent(".zshrc")
        try "export FOO=bar\nalias ll='ls -la'\n".write(to: zshrc, atomically: true, encoding: .utf8)
        try CLIIntegration.setZshHook(enabled: true, zshrcURL: zshrc)
        try CLIIntegration.setZshHook(enabled: true, zshrcURL: zshrc)
        #expect(CLIIntegration.isZshHookInstalled(zshrcURL: zshrc) == true)
        let withHook = try String(contentsOf: zshrc, encoding: .utf8)
        #expect(withHook.components(separatedBy: CLIIntegration.blockStartMarker).count == 2)
        #expect(withHook.contains("export FOO=bar"))

        try CLIIntegration.setZshHook(enabled: false, zshrcURL: zshrc)
        #expect(CLIIntegration.isZshHookInstalled(zshrcURL: zshrc) == false)
        let withoutHook = try String(contentsOf: zshrc, encoding: .utf8)
        #expect(withoutHook.contains("export FOO=bar"))
        #expect(!withoutHook.contains("bz shell-hook zsh"))

        // (d) In-process Orchestrator built-in Feishu monitor ingests usernoted fixture without separate app
        let paths = BianzhongPaths(configDir: cfgDir, stateDir: stateDir)
        try paths.ensureDirectories()
        let dbURL = stateDir.appendingPathComponent("usernoted-inproc.db")
        var db: OpaquePointer?
        #expect(sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let ddl = """
        CREATE TABLE app (app_id INTEGER PRIMARY KEY, identifier TEXT NOT NULL);
        CREATE TABLE record (rec_id INTEGER PRIMARY KEY, app_id INTEGER NOT NULL, data BLOB, delivered_date REAL);
        INSERT INTO app (app_id, identifier) VALUES (1, 'com.electron.lark');
        """
        #expect(sqlite3_exec(db, ddl, nil, nil, nil) == SQLITE_OK)
        let plist: [String: Any] = ["req": ["titl": "系统告警", "subt": "Bot", "body": "接口 500"]]
        let blob = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "INSERT INTO record (rec_id, app_id, data, delivered_date) VALUES (1, 1, ?, 0);", -1, &stmt, nil) == SQLITE_OK)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = blob.withUnsafeBytes { raw in
            sqlite3_bind_blob(stmt, 1, raw.baseAddress, Int32(raw.count), transient)
        }
        #expect(sqlite3_step(stmt) == SQLITE_DONE)
        sqlite3_finalize(stmt)

        let orch = try Orchestrator(paths: paths)
        try orch.start(enableBuiltInSensors: true, feishuDBURL: dbURL, skipExistingFeishuOnFirstRun: false)
        defer { orch.stop() }

        for _ in 0..<40 {
            if orch.feishuSensorStatus() == .watching && (try? orch.store.eventCount()) == 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(orch.feishuSensorStatus() == .watching)
        #expect(try orch.store.eventCount() == 1)

        orch.setFeishuSensorEnabled(false)
        #expect(orch.feishuSensorStatus() == .disabled)
    }

    @Test("20. Monitor releases without retain cycle, third-party bz symlinks stay untouched, and top-level config update preserves comments")
    func reviewFixesMonitorDeinitAndSymlinkSafety() async throws {
        let shortID = String(UUID().uuidString.prefix(8))
        let dir = URL(fileURLWithPath: "/tmp/bz-t20-\(shortID)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // (a) FeishuSensorMonitor must deallocate cleanly without calling stop() (no FSEventStream retain cycle)
        let dbURL = dir.appendingPathComponent("usernoted.db")
        var db: OpaquePointer?
        #expect(sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        let ddl = """
        CREATE TABLE app (app_id INTEGER PRIMARY KEY, identifier TEXT NOT NULL);
        CREATE TABLE record (rec_id INTEGER PRIMARY KEY, app_id INTEGER NOT NULL, data BLOB, delivered_date REAL);
        """
        #expect(sqlite3_exec(db, ddl, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        weak var weakMonitor: FeishuSensorMonitor?
        do {
            let m = FeishuSensorMonitor(
                dbURL: dbURL,
                cursorURL: dir.appendingPathComponent("cursor.txt"),
                skipExistingOnFirstRun: true,
                eventSink: { _ in true }
            )
            weakMonitor = m
            m.start()
            for _ in 0..<40 {
                if m.currentStatus() == .watching { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(m.currentStatus() == .watching)
        }
        for _ in 0..<20 {
            if weakMonitor == nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(weakMonitor == nil)

        // (b) Third-party `bz` symlinks stay untouched when force == false, and transient bundle paths skip auto-link
        let binDir = dir.appendingPathComponent("bin", isDirectory: true)
        let appBZ = dir.appendingPathComponent("Applications/Bianzhong.app/Contents/MacOS/bz")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appBZ.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/zsh\nexit 0\n".write(to: appBZ, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: appBZ.path)

        let linkPath = binDir.appendingPathComponent("bz").path
        let thirdPartyTarget = "/opt/thirdparty/bin/bz"
        #expect(Darwin.symlink(thirdPartyTarget, linkPath) == 0)

        let skipped = CLIIntegration.ensureCLISymlinks(
            sourceBZPath: appBZ.path,
            homeDir: dir,
            candidateDirs: [binDir],
            force: false
        )
        #expect(skipped.isEmpty)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath)) == thirdPartyTarget)

        let removed = CLIIntegration.removeCLISymlinks(homeDir: dir, candidateDirs: [binDir], force: false)
        #expect(removed.isEmpty)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath)) == thirdPartyTarget)

        #expect(CLIIntegration.shouldAutoInstallOnLaunch(bundleURL: URL(fileURLWithPath: "/Applications/Bianzhong.app")) == true)
        #expect(CLIIntegration.shouldAutoInstallOnLaunch(bundleURL: URL(fileURLWithPath: "/Volumes/Bianzhong 0.2.0/Bianzhong.app")) == false)
        #expect(CLIIntegration.shouldAutoInstallOnLaunch(bundleURL: URL(fileURLWithPath: "/private/var/folders/ab/AppTranslocation/123/d/Bianzhong.app")) == false)
        #expect(CLIIntegration.shouldAutoInstallOnLaunch(bundleURL: URL(fileURLWithPath: "/tmp/.build/debug/BianzhongApp")) == false)

        // (c) setFeishuSensorEnabled updates only top-level key and preserves inline comments
        let cfgURL = dir.appendingPathComponent("config.yml")
        let initialCfg = """
        # Top comment
        triage:
          feishu_sensor_enabled: true
        feishu_sensor_enabled: true   # keep this comment
        """
        try initialCfg.write(to: cfgURL, atomically: true, encoding: .utf8)
        try AppConfig.setFeishuSensorEnabled(false, in: cfgURL)
        let updatedCfg = try String(contentsOf: cfgURL, encoding: .utf8)
        #expect(updatedCfg.contains("  feishu_sensor_enabled: true"))
        #expect(updatedCfg.contains("feishu_sensor_enabled: false   # keep this comment"))
        #expect(AppConfig.load(from: cfgURL).feishuSensorEnabled == false)
    }

    @Test("21. Per-field AND matching, cumulative window threshold, expect-window watchdog, rule toggle, and FDA detection")
    func advancedRuleMatchingThresholdExpectAndFDA() async throws {
        let shortID = String(UUID().uuidString.prefix(8))
        let stateDir = URL(fileURLWithPath: "/tmp/bz-s21-\(shortID)", isDirectory: true)
        let cfgDir = URL(fileURLWithPath: "/tmp/bz-c21-\(shortID)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: stateDir)
            try? FileManager.default.removeItem(at: cfgDir)
        }
        let paths = BianzhongPaths(configDir: cfgDir, stateDir: stateDir)
        try paths.ensureDirectories()

        // (a) Per-field matching & AND logic: title == 群名 && body contains keywords
        let andRuleMD = """
        ---
        id: feishu-group-and
        enabled: true
        description: 仅匹配支付研发群里同时含退款和报错的通知
        match:
          type: ["dev.bianzhong.feishu.notification"]
          title_equals: ["支付研发群"]
          body_all: ["退款"]
          body_any: ["报错", "500"]
          body_exclude: ["演练"]
        funnel:
          dedup_ttl: 60s
          debounce: 0s
          cooldown: 0s
        execution:
          driver: none
        ---
        ## Phase 1
        noop
        """
        let andRule = ChimeRule.parse(markdown: andRuleMD, defaultID: "feishu-group-and")
        #expect(andRule.titleEquals == ["支付研发群"])
        #expect(andRule.bodyAll == ["退款"])
        #expect(andRule.bodyAny == ["报错", "500"])
        #expect(andRule.bodyExclude == ["演练"])

        let store = try SQLiteStore(dbURL: paths.dbURL)
        let funnel = WakeupFunnel(store: store, rules: [andRule])

        // Wrong group title (even though body matches) -> dropped
        let wrongGroup = EventEnvelope(
            source: "bz://sensor/feishu",
            type: "dev.bianzhong.feishu.notification",
            correlationKey: "c1",
            payload: ["title": "闲聊群", "body": "退款接口 500 报错"]
        )
        if case .dropped(let stage, _) = funnel.ingest(wrongGroup, onReady: { _, _ in }) {
            #expect(stage == "dropped_rule")
        } else {
            Issue.record("Expected wrong group to be dropped")
        }

        // Right group, body missing required AND token "退款" -> dropped
        let missingBodyAll = EventEnvelope(
            source: "bz://sensor/feishu",
            type: "dev.bianzhong.feishu.notification",
            correlationKey: "c2",
            payload: ["title": "支付研发群", "body": "登录接口 500"]
        )
        if case .dropped(let stage, _) = funnel.ingest(missingBodyAll, onReady: { _, _ in }) {
            #expect(stage == "dropped_rule")
        } else {
            Issue.record("Expected missing body_all to be dropped")
        }

        // Right group, matches body_all + body_any, but hits body_exclude -> dropped
        let excludedBody = EventEnvelope(
            source: "bz://sensor/feishu",
            type: "dev.bianzhong.feishu.notification",
            correlationKey: "c3",
            payload: ["title": "支付研发群", "body": "演练：退款接口 500"]
        )
        if case .dropped(let stage, _) = funnel.ingest(excludedBody, onReady: { _, _ in }) {
            #expect(stage == "dropped_rule")
        } else {
            Issue.record("Expected body_exclude to drop event")
        }

        // Exact group + body_all + body_any -> ready!
        let exactMatch = EventEnvelope(
            source: "bz://sensor/feishu",
            type: "dev.bianzhong.feishu.notification",
            correlationKey: "c4",
            payload: ["title": "支付研发群", "body": "退款接口 500"]
        )
        if case .ready(_, let matched) = funnel.ingest(exactMatch, onReady: { _, _ in }) {
            #expect(matched.id == "feishu-group-and")
        } else {
            Issue.record("Expected exact title + body AND event to match")
        }

        // (b) Cumulative hit threshold: min_count: 2 + window: daily
        let thresholdMD = """
        ---
        id: daily-twice-alert
        enabled: true
        match:
          type: ["dev.bianzhong.feishu.notification"]
          title_equals: ["值班群"]
          body_any: ["超时"]
        funnel:
          dedup_ttl: 60s
          debounce: 0s
          cooldown: 0s
          min_count: 2
          window: daily
          count_scope: rule
          count_reset_on_trigger: true
        execution:
          driver: none
        ---
        ## Phase 1
        noop
        """
        let thresholdRule = ChimeRule.parse(markdown: thresholdMD, defaultID: "daily-twice-alert")
        #expect(thresholdRule.minCount == 2)
        #expect(thresholdRule.countWindow == .daily)
        funnel.updateRules([thresholdRule])

        let cal = Calendar.current
        let day1Morning = cal.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 10, minute: 0))!
        let day1Afternoon = cal.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 15, minute: 0))!
        let day2Morning = cal.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 9, minute: 0))!

        let hit1 = EventEnvelope(source: "bz://sensor/feishu", type: "dev.bianzhong.feishu.notification", correlationKey: "g1", payload: ["title": "值班群", "body": "超时 #1"])
        if case .dropped(let stage, let reason) = funnel.ingest(hit1, now: day1Morning, onReady: { _, _ in }) {
            #expect(stage == "dropped_threshold")
            #expect(reason == "threshold:1/2")
        } else {
            Issue.record("First hit should be held at 1/2")
        }

        let hit2 = EventEnvelope(source: "bz://sensor/feishu", type: "dev.bianzhong.feishu.notification", correlationKey: "g1", payload: ["title": "值班群", "body": "超时 #2"])
        if case .ready(let enriched, let rule) = funnel.ingest(hit2, now: day1Afternoon, onReady: { _, _ in }) {
            #expect(rule.id == "daily-twice-alert")
            #expect(enriched.payload["window_hit_count"] == "2")
        } else {
            Issue.record("Second hit on same day should trigger")
        }

        // Next day resets count (and count_reset_on_trigger also cleared) -> first hit held again
        let hit3 = EventEnvelope(source: "bz://sensor/feishu", type: "dev.bianzhong.feishu.notification", correlationKey: "g1", payload: ["title": "值班群", "body": "超时 #3"])
        if case .dropped(let stage, let reason) = funnel.ingest(hit3, now: day2Morning, onReady: { _, _ in }) {
            #expect(stage == "dropped_threshold")
            #expect(reason == "threshold:1/2")
        } else {
            Issue.record("Next day first hit should be held at 1/2")
        }

        // (c) Expect-window watchdog: satisfied when signal arrives in window, fires once when missed
        let expectMD = """
        ---
        id: daily-report-watchdog
        enabled: true
        description: 每天 09:00-09:30 预期收到数据日报
        match:
          type: ["dev.bianzhong.feishu.notification"]
          title_equals: ["数据日报群"]
          body_any: ["日报已产出"]
        expect:
          enabled: true
          window: "09:00-09:30"
          weekdays: ["mon", "tue", "wed", "thu", "fri"]
          suppress_on_match: true
        execution:
          driver: none
        on_complete:
          - type: notify
        ---
        ## Phase 1
        noop
        """
        let expectFile = paths.chimesDir.appendingPathComponent("daily-report-watchdog.md")
        try expectMD.write(to: expectFile, atomically: true, encoding: .utf8)
        let earlyMod = cal.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 12, minute: 0))!
        try FileManager.default.setAttributes([.modificationDate: earlyMod], ofItemAtPath: expectFile.path)

        let orch = try Orchestrator(paths: paths)
        let loadedExpect = orch.allRules().first(where: { $0.id == "daily-report-watchdog" })
        #expect(loadedExpect?.expectWindow?.windowStart == "09:00")
        #expect(loadedExpect?.expectWindow?.windowEnd == "09:30")
        #expect(loadedExpect?.expectWindow?.weekdays == [1, 2, 3, 4, 5])

        // Wednesday 2026-11-25 09:15: signal arrives on time -> satisfied, no alert after 09:35
        let wed0915 = cal.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 9, minute: 15))!
        let wed0935 = cal.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 9, minute: 35))!
        let reportMsg = EventEnvelope(source: "bz://sensor/feishu", type: "dev.bianzhong.feishu.notification", correlationKey: "r1", payload: ["title": "数据日报群", "body": "今日日报已产出"])
        let disp = orch.funnel.ingest(reportMsg, now: wed0915, onReady: { _, _ in })
        if case .dropped(let stage, _) = disp {
            #expect(stage == "expect_satisfied")
        } else {
            Issue.record("Expected signal within expect window to record expect_satisfied")
        }
        let missedOnWed = orch.checkExpectWindows(now: wed0935, calendar: cal)
        #expect(missedOnWed.isEmpty)

        // Thursday 2026-11-26 09:35: no signal arrived -> fires once!
        let thu0935 = cal.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 9, minute: 35))!
        let missedOnThu1 = orch.checkExpectWindows(now: thu0935, calendar: cal)
        #expect(missedOnThu1.count == 1)
        #expect(missedOnThu1.first?.type == "dev.bianzhong.expect.missed")
        // Second check on same Thursday must not double-fire
        let missedOnThu2 = orch.checkExpectWindows(now: thu0935, calendar: cal)
        #expect(missedOnThu2.isEmpty)

        // Saturday 2026-11-28 09:35: not in weekdays [1..5] -> does not fire
        let sat0935 = cal.date(from: DateComponents(year: 2026, month: 11, day: 28, hour: 9, minute: 35))!
        #expect(orch.checkExpectWindows(now: sat0935, calendar: cal).isEmpty)

        // (d) Rule toggle on disk via Orchestrator.setRuleEnabled preserves file & updates state
        try orch.setRuleEnabled(id: "daily-report-watchdog", enabled: false)
        #expect(orch.allRules().first(where: { $0.id == "daily-report-watchdog" })?.enabled == false)
        try orch.setRuleEnabled(id: "daily-report-watchdog", enabled: true)
        #expect(orch.allRules().first(where: { $0.id == "daily-report-watchdog" })?.enabled == true)

        // (e) FeishuSensorMonitor reports .needsFullDiskAccess (not .unavailable) on unreadable file (chmod 000)
        let lockedDB = stateDir.appendingPathComponent("locked-usernoted.db")
        try Data("sqlite-locked".utf8).write(to: lockedDB)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedDB.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lockedDB.path) }

        #expect(FeishuSensorRunner.probePermissionDenied(for: lockedDB) == true)
        let monitor = FeishuSensorMonitor(
            dbURL: lockedDB,
            cursorURL: stateDir.appendingPathComponent("fda-cursor.txt"),
            skipExistingOnFirstRun: true,
            eventSink: { _ in true }
        )
        monitor.start()
        defer { monitor.stop() }
        for _ in 0..<40 {
            if monitor.currentStatus() == .needsFullDiskAccess { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(monitor.currentStatus() == .needsFullDiskAccess)
    }

    @Test("22. Review regressions: block-sequence YAML, CRLF, late-init expect guard, pause satisfaction, replay timestamps, atomic threshold, and targeted test")
    func reviewRegressionsBlockYAMLWatchdogPauseReplayAndConcurrency() async throws {
        let shortID = String(UUID().uuidString.prefix(8))
        let stateDir = URL(fileURLWithPath: "/tmp/bz-s22-\(shortID)", isDirectory: true)
        let cfgDir = URL(fileURLWithPath: "/tmp/bz-c22-\(shortID)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: stateDir)
            try? FileManager.default.removeItem(at: cfgDir)
        }
        let paths = BianzhongPaths(configDir: cfgDir, stateDir: stateDir)
        try paths.ensureDirectories()

        // (a) Multi-line YAML block lists (- item), CRLF line endings, and expect.enabled = false preservation
        let crlfBlockMD = [
            "---",
            "id: block-list-rule",
            "enabled: true   # inline comment",
            "match:",
            "  title_equals:",
            "    - 支付研发群",
            "    - 核心告警群",
            "  body:",
            "    any:",
            "      - 报错",
            "      - 500",
            "expect:",
            "  enabled: false",
            "  window: 09:00-09:30",
            "  weekdays:",
            "    - mon",
            "    - fri",
            "---",
            "## Phase 1",
            "check"
        ].joined(separator: "\r\n")

        let crlfURL = paths.chimesDir.appendingPathComponent("block-list-rule.md")
        try crlfBlockMD.write(to: crlfURL, atomically: true, encoding: .utf8)
        let parsedBlock = ChimeRule.parse(markdown: crlfBlockMD, defaultID: "block-list-rule")
        #expect(parsedBlock.titleEquals == ["支付研发群", "核心告警群"])
        #expect(parsedBlock.bodyAny == ["报错", "500"])
        #expect(parsedBlock.expectWindow?.enabled == false)
        #expect(parsedBlock.expectWindow?.weekdays == [1, 5])

        try ChimeRule.setEnabled(false, in: crlfURL)
        let toggledText = try String(contentsOf: crlfURL, encoding: .utf8)
        #expect(!toggledText.contains("\n\n\n"))
        #expect(toggledText.contains("enabled: false   # inline comment"))
        try? FileManager.default.removeItem(at: crlfURL)

        // (b) Late-created expect rule after today's deadline must NOT retroactively misfire today,
        //     and paused daemon still records satisfaction for active expect windows
        let cal = Calendar.current
        let expectFile = paths.chimesDir.appendingPathComponent("morning-check.md")
        let expectMD = """
        ---
        id: morning-check
        enabled: true
        match:
          type: ["dev.bianzhong.feishu.notification"]
          title_equals: ["晨会群"]
          body_any: ["签到"]
        expect:
          enabled: true
          window: "09:00-09:30"
          suppress_on_match: true
        execution:
          driver: none
        on_complete:
          - type: notify
        ---
        ## Phase 1
        noop
        """
        try expectMD.write(to: expectFile, atomically: true, encoding: .utf8)
        let lateModDate = cal.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 17, minute: 0))!
        try FileManager.default.setAttributes([.modificationDate: lateModDate], ofItemAtPath: expectFile.path)

        let orch = try Orchestrator(paths: paths)
        // Checking at 17:05 on same day when rule was created at 17:00 (> 09:30 deadline) -> must NOT misfire
        let day1Late = cal.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 17, minute: 5))!
        #expect(orch.checkExpectWindows(now: day1Late, calendar: cal).isEmpty)

        // Next day (2026-11-26): pause daemon, emit matching event inside window -> still satisfies expect window!
        // Set mtime before day2 deadline (already 2026-11-25 17:00 <= 2026-11-26 09:30)
        orch.pause(forSeconds: 3600)
        let day2InWindow = cal.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 9, minute: 10))!
        let checkinEv = EventEnvelope(
            source: "bz://sensor/feishu",
            type: "dev.bianzhong.feishu.notification",
            correlationKey: "m1",
            payload: ["title": "晨会群", "body": "已完成签到"]
        )
        let satisfiedWhilePaused = orch.funnel.recordExpectWindowMatchesWhilePaused(checkinEv, now: day2InWindow)
        #expect(satisfiedWhilePaused == ["morning-check"])
        orch.resume()

        let day2AfterWindow = cal.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 9, minute: 40))!
        #expect(orch.checkExpectWindows(now: day2AfterWindow, calendar: cal).isEmpty)

        // Day 3 (2026-11-27): no signal -> fires properly!
        let day3AfterWindow = cal.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 9, minute: 40))!
        #expect(orch.checkExpectWindows(now: day3AfterWindow, calendar: cal).count == 1)

        // (c) RuleSimulator respects historical `event.ts` across separate days for `window: daily`
        let dailyRule = ChimeRule(
            id: "sim-daily-2",
            matchTypes: ["dev.bianzhong.feishu.notification"],
            keywordsAny: ["告警"],
            dedupTTLSeconds: 0,
            debounceSeconds: 0,
            cooldownSeconds: 0,
            minCount: 2,
            countWindow: .daily,
            driver: "none"
        )
        let evDayA = EventEnvelope(
            source: "bz://sensor/feishu",
            type: "dev.bianzhong.feishu.notification",
            ts: "2026-11-20T08:00:00Z",
            correlationKey: "k1",
            payload: ["title": "群A", "body": "告警 1"]
        )
        let evDayB = EventEnvelope(
            source: "bz://sensor/feishu",
            type: "dev.bianzhong.feishu.notification",
            ts: "2026-11-21T08:00:00Z",
            correlationKey: "k1",
            payload: ["title": "群A", "body": "告警 2"]
        )
        let simAcrossDays = await RuleSimulator.simulate(events: [evDayA, evDayB], rules: [dailyRule], config: AppConfig())
        #expect(simAcrossDays.directActionOnly == 0)
        #expect(simAcrossDays.droppedL0 == 2)

        let evSameDayB = EventEnvelope(
            source: "bz://sensor/feishu",
            type: "dev.bianzhong.feishu.notification",
            ts: "2026-11-20T09:00:00Z",
            correlationKey: "k1",
            payload: ["title": "群A", "body": "告警 3"]
        )
        let simSameDay = await RuleSimulator.simulate(events: [evDayA, evSameDayB], rules: [dailyRule], config: AppConfig())
        #expect(simSameDay.directActionOnly == 1)

        // (d) Atomic concurrent threshold counter: 6 concurrent hits with minCount=3 + resetOnTrigger=true -> exactly 2 triggers
        let store = orch.store
        let triggerCount = await withTaskGroup(of: Bool.self) { group -> Int in
            for i in 0..<6 {
                group.addTask {
                    let res = try? store.recordRuleHitAndCheckThreshold(
                        chimeID: "concurrent-rule",
                        scopeKey: "__rule__",
                        eventID: "ev-\(i)",
                        windowStartMs: 0,
                        minCount: 3,
                        resetOnTrigger: true,
                        nowMs: 1_000_000 + Int64(i)
                    )
                    return res?.triggered == true
                }
            }
            var total = 0
            for await fired in group where fired {
                total += 1
            }
            return total
        }
        #expect(triggerCount == 2)

        // (e) Targeted `triggerRuleTest` invokes the requested rule even when an earlier catch-all rule exists
        let catchAllFile = paths.chimesDir.appendingPathComponent("00-catch-all.md")
        try """
        ---
        id: 00-catch-all
        enabled: true
        match:
          type: ["*"]
        execution:
          driver: none
        on_complete: []
        ---
        """.write(to: catchAllFile, atomically: true, encoding: .utf8)

        let specificFile = paths.chimesDir.appendingPathComponent("99-specific.md")
        try """
        ---
        id: 99-specific
        enabled: true
        match:
          type: ["dev.bianzhong.feishu.notification"]
          title_equals: ["专属群"]
        execution:
          driver: none
        on_complete: []
        ---
        """.write(to: specificFile, atomically: true, encoding: .utf8)
        orch.reloadConfig()

        let badTarget = EventEnvelope(source: "bz://test", type: "dev.bianzhong.feishu.notification", correlationKey: "t", payload: ["title": "其他群"])
        #expect(orch.triggerRuleTest(ruleID: "99-specific", event: badTarget).ok == false)

        let goodTarget = EventEnvelope(source: "bz://test", type: "dev.bianzhong.feishu.notification", correlationKey: "t", payload: ["title": "专属群"])
        #expect(orch.triggerRuleTest(ruleID: "99-specific", event: goodTarget).ok == true)
    }

    @Test("23. SecretStore, Terminal selector, Config/Rule serialization, URL scheme, Outbound webhook signing, and Inbound WebhookServer")
    func unifiedConsoleConfigSecretsTerminalAndWebhookGateway() async throws {
        let shortID = String(UUID().uuidString.prefix(8))
        let stateDir = URL(fileURLWithPath: "/tmp/bz-s23-\(shortID)", isDirectory: true)
        let cfgDir = URL(fileURLWithPath: "/tmp/bz-c23-\(shortID)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: stateDir)
            try? FileManager.default.removeItem(at: cfgDir)
        }
        let paths = BianzhongPaths(configDir: cfgDir, stateDir: stateDir)
        try paths.ensureDirectories()

        // (a) SecretStore 0600 permissions, CRUD, env fallback, and token rotation
        let initialToken = SecretStore.ensureWebhookToken(paths: paths)
        #expect(initialToken.count >= 32)
        #expect(SecretStore.ensureWebhookToken(paths: paths) == initialToken)

        let attrs = try FileManager.default.attributesOfItem(atPath: paths.secretsFile.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect((perms & 0o777) == 0o600)

        try SecretStore.set(key: "FEISHU_BOT_SECRET", value: "sec-1234567890", paths: paths)
        #expect(SecretStore.resolve("FEISHU_BOT_SECRET", paths: paths) == "sec-1234567890")
        #expect(SecretStore.maskedPreview("sec-1234567890") == "sec-••••7890")
        #expect(SecretStore.resolve("PATH", paths: paths)?.isEmpty == false) // fallback to ProcessInfo.environment

        let rotatedToken = try SecretStore.rotateWebhookToken(paths: paths)
        #expect(rotatedToken != initialToken)
        #expect(SecretStore.resolve(SecretStore.webhookTokenKey, paths: paths) == rotatedToken)

        try SecretStore.remove(key: "FEISHU_BOT_SECRET", paths: paths)
        #expect(SecretStore.loadAll(paths: paths)["FEISHU_BOT_SECRET"] == nil)

        // (b) Terminal selector covers all 8 terminals cleanly
        #expect(TerminalLauncher.TerminalApp.allCases.count == 8)
        #expect(TerminalLauncher.detectTerminal(preference: "ghostty") == .ghostty)
        #expect(TerminalLauncher.detectTerminal(preference: "iterm") == .iterm)
        #expect(TerminalLauncher.detectTerminal(preference: "iterm2") == .iterm)
        #expect(TerminalLauncher.detectTerminal(preference: "warp") == .warp)
        #expect(TerminalLauncher.detectTerminal(preference: "kitty") == .kitty)
        #expect(TerminalLauncher.detectTerminal(preference: "wezterm") == .wezterm)
        #expect(TerminalLauncher.detectTerminal(preference: "alacritty") == .alacritty)
        #expect(TerminalLauncher.detectTerminal(preference: "cmux") == .cmux)
        #expect(TerminalLauncher.detectTerminal(preference: "terminal") == .terminal)

        // (c) AppConfig.save & ChimeRule.serializeToMarkdown round-trip fidelity
        var cfg = AppConfig(
            triageProvider: "decision_api",
            decisionAPIURL: "https://triage.example.com/v1",
            decisionAPIKeyEnv: "MY_TRIAGE_KEY",
            decisionAPITimeoutSeconds: 5.5,
            agentCLIDriver: "codex",
            agentCLIModel: "gpt-5-mini",
            terminal: "warp",
            feishuSensorEnabled: false,
            webhookServerEnabled: true,
            webhookHost: "127.0.0.1",
            webhookPort: 0,
            webhookCallbackBaseURL: "https://mac.tailnet.ts.net:17380",
            maxConcurrentRuns: 3,
            maxCausalDepth: 2,
            dailyMaxCostUSD: 4.5,
            dailyMaxRuns: 42,
            circuitBreakerFailures: 4,
            retentionDays: 14,
            workspaces: [WorkspaceEntry(name: "core", path: "/tmp/core", summary: "Core workspace")]
        )
        try AppConfig.save(cfg, to: paths.configFile)
        try AppConfig.setTerminal("iterm", in: paths.configFile)
        let reloadedCfg = AppConfig.load(from: paths.configFile)
        #expect(reloadedCfg.terminal == "iterm")
        #expect(reloadedCfg.dailyMaxRuns == 42)
        #expect(reloadedCfg.webhookServerEnabled == true)
        #expect(reloadedCfg.webhookPort == 0)
        #expect(reloadedCfg.webhookCallbackBaseURL == "https://mac.tailnet.ts.net:17380")
        #expect(reloadedCfg.triageProvider == "decision_api")
        #expect(reloadedCfg.workspaces.first?.name == "core")

        // Restore ephemeral port config with terminal warp via save
        cfg.terminal = "warp"
        try AppConfig.save(cfg, to: paths.configFile)

        let originalRule = ChimeRule(
            id: "webhook-ci-watch",
            enabled: true,
            description: "监听 GitHub Actions 失败并推送飞书卡片",
            matchTypes: ["dev.bianzhong.ci.failed", "dev.bianzhong.url.emit"],
            titleAny: ["CI", "Build"],
            bodyExclude: ["skip-bz"],
            dedupTTLSeconds: 120,
            debounceSeconds: 0,
            maxWaitSeconds: 15,
            cooldownSeconds: 0,
            minCount: 1,
            countWindow: .daily,
            countScope: .rule,
            countResetOnTrigger: true,
            expectWindow: ExpectWindowSpec(enabled: true, windowStart: "09:00", windowEnd: "09:30", weekdays: [1, 3, 5], suppressOnMatch: true, graceSeconds: 30),
            deferOnFocus: false,
            triageEnabled: false,
            triageProviderOverride: "none",
            sessionPolicy: .threaded,
            sessionTTLSeconds: 3600,
            autonomy: .notify,
            driver: "none",
            workingDir: "/tmp",
            onComplete: [
                ActionSpec(type: .notify),
                ActionSpec(
                    type: .webhook,
                    whenCondition: "phase == 'notify'",
                    preset: "feishu_bot",
                    urlEnv: "FEISHU_HOOK_URL",
                    secretEnv: "FEISHU_SIGN_KEY"
                )
            ],
            phase1Prompt: "Phase 1 prompt text",
            phase2Prompt: "Phase 2 prompt text"
        )
        let ruleURL = paths.chimesDir.appendingPathComponent("webhook-ci-watch.md")
        try originalRule.save(to: ruleURL)
        let reparsedRule = try #require(ChimeRule.loadAll(from: paths.chimesDir).first(where: { $0.id == "webhook-ci-watch" }))
        #expect(reparsedRule.id == "webhook-ci-watch")
        #expect(reparsedRule.matchTypes == ["dev.bianzhong.ci.failed", "dev.bianzhong.url.emit"])
        #expect(reparsedRule.titleAny == ["CI", "Build"])
        #expect(reparsedRule.bodyExclude == ["skip-bz"])
        #expect(reparsedRule.expectWindow?.weekdays == [1, 3, 5])
        #expect(reparsedRule.onComplete.count == 2)
        #expect(reparsedRule.onComplete.last?.preset == "feishu_bot")
        #expect(reparsedRule.onComplete.last?.secretEnv == "FEISHU_SIGN_KEY")
        #expect(reparsedRule.phase1Prompt == "Phase 1 prompt text")
        #expect(reparsedRule.phase2Prompt == "Phase 2 prompt text")

        // Disable expect window for live webhook ingestion test below
        var liveRule = reparsedRule
        liveRule.expectWindow = nil
        try liveRule.save(to: ruleURL)

        // (d) OutboundWebhookBuilder: Feishu bot HMAC-SHA256 sign + signed remote approval URL verification
        let approveCB = try #require(OutboundWebhookBuilder.signedApprovalURL(
            baseURL: "http://127.0.0.1:17380",
            approvalID: "apr-test-1",
            action: "approve",
            token: rotatedToken,
            ttlSeconds: 600,
            nowUnix: 1_700_000_000
        ))
        let cbComps = try #require(URLComponents(string: approveCB))
        let expParam = cbComps.queryItems?.first(where: { $0.name == "exp" })?.value
        let sigParam = cbComps.queryItems?.first(where: { $0.name == "sig" })?.value
        #expect(OutboundWebhookBuilder.verifyApprovalSignature(
            approvalID: "apr-test-1",
            action: "approve",
            expString: expParam,
            signature: sigParam,
            token: rotatedToken,
            nowUnix: 1_700_000_300
        ) == true)
        // Expired link rejected
        #expect(OutboundWebhookBuilder.verifyApprovalSignature(
            approvalID: "apr-test-1",
            action: "approve",
            expString: expParam,
            signature: sigParam,
            token: rotatedToken,
            nowUnix: 1_700_000_900
        ) == false)
        // Action mismatch ("reject" using "approve" signature) rejected
        #expect(OutboundWebhookBuilder.verifyApprovalSignature(
            approvalID: "apr-test-1",
            action: "reject",
            expString: expParam,
            signature: sigParam,
            token: rotatedToken,
            nowUnix: 1_700_000_300
        ) == false)

        let feishuReq = try OutboundWebhookBuilder.build(
            preset: .feishuBot,
            title: "CI 失败告警",
            text: "main 分支单测失败",
            chimeID: "webhook-ci-watch",
            phase: "propose",
            riskLevel: "medium",
            correlationKey: "ci:main",
            sessionID: "ses-1",
            approvalID: "apr-test-1",
            secret: "bot-sec",
            bearerToken: nil,
            chatID: nil,
            approveCallbackURL: approveCB,
            rejectCallbackURL: nil
        )
        let feishuJSON = try #require(JSONSerialization.jsonObject(with: feishuReq.body) as? [String: Any])
        #expect(feishuJSON["msg_type"] as? String == "interactive")
        #expect((feishuJSON["sign"] as? String)?.isEmpty == false)
        #expect((feishuJSON["timestamp"] as? String)?.isEmpty == false)
        let feishuBodyStr = String(decoding: feishuReq.body, as: UTF8.self)
        #expect(feishuBodyStr.contains("批准执行"))

        // (e) BianzhongURLRouter parsing
        let consoleURL = URL(string: "bianzhong://console?tab=webhooks&rule=webhook-ci-watch")!
        #expect(BianzhongURLRouter.parse(consoleURL) == .openConsole(section: "webhooks", ruleID: "webhook-ci-watch"))
        let approveDeepLink = URL(string: "bianzhong://approve?id=apr-99&note=ship&token=tok1")!
        #expect(BianzhongURLRouter.parse(approveDeepLink) == .approve(id: "apr-99", comment: "ship", token: "tok1"))

        // (f) Live Orchestrator + WebhookServer (ephemeral port 0) end-to-end HTTP + URL scheme + Audit funnel
        let orch = try Orchestrator(paths: paths)
        try orch.start(enableBuiltInSensors: false, enableWebhookServer: true)
        defer { orch.stop() }

        let whStatus = orch.webhookStatus()
        #expect(whStatus.enabled == true)
        #expect(whStatus.running == true)
        #expect(whStatus.port > 0)
        let base = "http://127.0.0.1:\(whStatus.port)"

        // 1. GET /v1/health -> 200 without auth
        let (_, healthResp) = try await URLSession.shared.data(from: URL(string: "\(base)/v1/health")!)
        #expect((healthResp as? HTTPURLResponse)?.statusCode == 200)

        // 2. POST /v1/emit without token -> 401
        var unauthReq = URLRequest(url: URL(string: "\(base)/v1/emit")!)
        unauthReq.httpMethod = "POST"
        unauthReq.httpBody = Data(#"{"title":"CI","body":"fail"}"#.utf8)
        let (_, unauthResp) = try await URLSession.shared.data(for: unauthReq)
        #expect((unauthResp as? HTTPURLResponse)?.statusCode == 401)

        // 3. POST /v1/hooks/feishu challenge verification via JSON body Verification Token (no Authorization header!)
        var challengeReq = URLRequest(url: URL(string: "\(base)/v1/hooks/feishu")!)
        challengeReq.httpMethod = "POST"
        challengeReq.httpBody = Data(#"{"type":"url_verification","token":"\#(rotatedToken)","challenge":"bz-challenge-ok"}"#.utf8)
        let (chalData, chalResp) = try await URLSession.shared.data(for: challengeReq)
        #expect((chalResp as? HTTPURLResponse)?.statusCode == 200)
        let chalObj = try #require(JSONSerialization.jsonObject(with: chalData) as? [String: Any])
        #expect(chalObj["challenge"] as? String == "bz-challenge-ok")

        // 4. POST /v1/hooks/github signed with X-Hub-Signature-256 (workflow_run failure -> dev.bianzhong.ci.failed)
        let ghBody = Data(#"{"action":"completed","repository":{"full_name":"chorust/bianzhong"},"workflow_run":{"name":"CI Build","conclusion":"failure","head_branch":"main","html_url":"https://github.com/chorust/bianzhong/actions/runs/1"}}"#.utf8)
        let ghSig = "sha256=" + OutboundWebhookBuilder.hmacSHA256Hex(key: rotatedToken, data: ghBody)
        var ghReq = URLRequest(url: URL(string: "\(base)/v1/hooks/github")!)
        ghReq.httpMethod = "POST"
        ghReq.setValue("workflow_run", forHTTPHeaderField: "X-GitHub-Event")
        ghReq.setValue(ghSig, forHTTPHeaderField: "X-Hub-Signature-256")
        ghReq.httpBody = ghBody
        let (_, ghResp) = try await URLSession.shared.data(for: ghReq)
        #expect((ghResp as? HTTPURLResponse)?.statusCode == 200)

        // Wait briefly for async notify approval creation
        for _ in 0..<40 {
            if !orch.pendingApprovals().isEmpty { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let pendingApr = try #require(orch.pendingApprovals().first)
        #expect(pendingApr.chimeID == "webhook-ci-watch")

        // 5. Signed remote approval callback: GET renders safe confirmation HTML WITHOUT resolving (unfurl-bot safe), POST resolves once!
        let liveCallbackURL = try #require(OutboundWebhookBuilder.signedApprovalURL(
            baseURL: base,
            approvalID: pendingApr.id,
            action: "approve",
            token: rotatedToken,
            ttlSeconds: 300
        ))
        let (getHTMLData, getCBResp) = try await URLSession.shared.data(from: URL(string: liveCallbackURL)!)
        #expect((getCBResp as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: getHTMLData, as: UTF8.self).contains("<form method='POST'"))
        #expect(orch.pendingApprovals().contains(where: { $0.id == pendingApr.id }) == true) // still pending after GET!

        var postCBReq = URLRequest(url: URL(string: liveCallbackURL)!)
        postCBReq.httpMethod = "POST"
        postCBReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        postCBReq.httpBody = Data("comment=LGTM+remote".utf8)
        let (_, postCBResp) = try await URLSession.shared.data(for: postCBReq)
        #expect((postCBResp as? HTTPURLResponse)?.statusCode == 200)
        #expect(orch.pendingApprovals().contains(where: { $0.id == pendingApr.id }) == false)

        // Second POST replay on already-resolved approval returns 409 Conflict!
        let (_, replayCBResp) = try await URLSession.shared.data(for: postCBReq)
        #expect((replayCBResp as? HTTPURLResponse)?.statusCode == 409)

        // 6. bianzhong://emit URL scheme CSRF guard + token auth + EventAuditRecord stage/search query
        let untrustedDeepLink = URL(string: "bianzhong://emit?type=dev.bianzhong.url.emit&title=Untrusted&body=blocked")!
        if case .requiresConfirmation = orch.handleIncomingURL(untrustedDeepLink) {
            // Expected: mutating URL without token must require interactive user confirmation
        } else {
            Issue.record("Expected untrusted bianzhong://emit without token to require confirmation")
        }
        let wrongTokenLink = URL(string: "bianzhong://emit?type=dev.bianzhong.url.emit&title=Bad&token=wrong")!
        #expect(orch.handleIncomingURL(wrongTokenLink) == .unauthorized)

        let emitDeepLink = URL(string: "bianzhong://emit?type=dev.bianzhong.url.emit&title=Build%20Alert&body=raycast-trigger&token=\(rotatedToken)")!
        if case .handled = orch.handleIncomingURL(emitDeepLink) {
            // Expected
        } else {
            Issue.record("Expected token-authenticated bianzhong://emit to succeed immediately")
        }

        let audits = try orch.store.listEventAuditRecords(limit: 20, searchQuery: "raycast-trigger")
        #expect(audits.count == 1)
        #expect(audits.first?.matchedChimeID == "webhook-ci-watch")

        // 7. Preferred terminal update persists via Orchestrator without losing comments
        orch.setPreferredTerminal("ghostty")
        #expect(orch.currentConfig().terminal == "ghostty")
        #expect(AppConfig.load(from: paths.configFile).terminal == "ghostty")
    }

    @Test("24. v0.4.0 Code Review regressions: atomic approve CAS, HTML escaping, quote/sub-second round-trip, rule rename cleanup, SQL audit pushdown, and Git worktree prune")
    func v040CodeReviewRegressions() async throws {
        let shortID = String(UUID().uuidString.prefix(8))
        let stateDir = URL(fileURLWithPath: "/tmp/bz-s24-\(shortID)", isDirectory: true)
        let cfgDir = URL(fileURLWithPath: "/tmp/bz-c24-\(shortID)", isDirectory: true)
        let repoDir = URL(fileURLWithPath: "/tmp/bz-r24-\(shortID)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: stateDir)
            try? FileManager.default.removeItem(at: cfgDir)
            try? FileManager.default.removeItem(at: repoDir)
        }
        let paths = BianzhongPaths(configDir: cfgDir, stateDir: stateDir)
        try paths.ensureDirectories()

        // (a) Lossless YAML quote/unescape & sub-second debounce round-trip across multiple saves + rename old-file cleanup
        let trickyWhen = #"kind == "todo" && path == "C:\\repo\\a""#
        let trickyCmd = #"printf "hello \"world\"\n""#
        let ruleV1 = ChimeRule(
            id: "alpha-rule",
            description: #"Desc with "quotes" and \backslash"#,
            matchTypes: ["dev.bianzhong.test"],
            debounceSeconds: 0.5,
            maxWaitSeconds: 2.5,
            minCount: 1,
            countWindow: .sliding(seconds: 3600),
            countScope: .correlation,
            countResetOnTrigger: false,
            preflightCmd: trickyCmd,
            onComplete: [
                ActionSpec(type: .webhook, whenCondition: trickyWhen, preset: "feishu_bot", urlEnv: "WH_URL")
            ],
            phase1Prompt: "P1",
            phase2Prompt: "P2"
        )

        var cfg = AppConfig(webhookServerEnabled: true, webhookHost: "127.0.0.1", webhookPort: 0)
        try AppConfig.save(cfg, to: paths.configFile)
        // Verify setTerminal preserves inline comments at top level
        let commentedCfg = "# Header\nterminal: auto   # keep-terminal-comment\nwebhook_server:\n  enabled: true\n  port: 0\n"
        try commentedCfg.write(to: paths.configFile, atomically: true, encoding: .utf8)
        try AppConfig.setTerminal("warp", in: paths.configFile)
        let afterTermText = try String(contentsOf: paths.configFile, encoding: .utf8)
        #expect(afterTermText.contains("terminal: warp   # keep-terminal-comment"))
        cfg = AppConfig.load(from: paths.configFile)
        #expect(cfg.terminal == "warp")

        let orch = try Orchestrator(paths: paths)
        try orch.start(enableBuiltInSensors: false, enableWebhookServer: true)
        defer { orch.stop() }

        let saved1 = try orch.saveRule(ruleV1)
        #expect(saved1.filePath?.hasSuffix("/alpha-rule.md") == true)
        #expect(saved1.whenConditionCheck(expectedWhen: trickyWhen))
        #expect(saved1.preflightCmd == trickyCmd)
        #expect(saved1.description == #"Desc with "quotes" and \backslash"#)
        #expect(abs(saved1.debounceSeconds - 0.5) < 0.001)
        #expect(abs(saved1.maxWaitSeconds - 2.5) < 0.001)
        #expect(saved1.countWindow == .sliding(seconds: 3600))
        #expect(saved1.countScope == .correlation)
        #expect(saved1.countResetOnTrigger == false)

        // Save a second time + rename ID -> old file alpha-rule.md must be deleted, zero backslash inflation!
        var renamed = saved1
        renamed.id = "beta-rule"
        let saved2 = try orch.saveRule(renamed)
        #expect(saved2.id == "beta-rule")
        #expect(FileManager.default.fileExists(atPath: paths.chimesDir.appendingPathComponent("alpha-rule.md").path) == false)
        #expect(FileManager.default.fileExists(atPath: paths.chimesDir.appendingPathComponent("beta-rule.md").path) == true)
        #expect(saved2.whenConditionCheck(expectedWhen: trickyWhen))
        #expect(saved2.preflightCmd == trickyCmd)
        #expect(orch.allRules().count == 1)

        // (b) Concurrent atomic approve() CAS: 8 concurrent callers -> exactly 1 wins!
        let casEvent = EventEnvelope(id: "ev-cas", source: "bz://test", type: "dev.bianzhong.test", correlationKey: "cas", payload: ["title": "CAS"])
        try orch.store.recordEvent(casEvent, funnelStage: "dispatched", matchedChimeID: "beta-rule")
        try orch.store.insertRun(id: "run-cas", eventID: casEvent.id, sessionID: nil, chimeID: "beta-rule", phase: "draft", driver: "none", status: "succeeded")
        let xssTitleApproval = ApprovalRecord(
            id: "apr-cas-1",
            runID: "run-cas",
            eventID: "ev-cas",
            sessionID: nil,
            chimeID: "beta-rule",
            kind: "notify",
            riskLevel: "low",
            title: "<script>alert(1)</script>",
            provenanceSummary: "test",
            proposedAction: "noop",
            targetRepo: nil,
            externalSessionID: nil,
            status: "pending",
            userComment: nil,
            createdAt: SQLiteStore.nowMs(),
            resolvedAt: nil
        )
        try orch.store.insertApproval(xssTitleApproval)

        // Verify HTML escaping on GET confirmation page before resolving
        let tok = SecretStore.ensureWebhookToken(paths: paths)
        let port = orch.webhookStatus().port
        let cbURL = try #require(OutboundWebhookBuilder.signedApprovalURL(
            baseURL: "http://127.0.0.1:\(port)",
            approvalID: "apr-cas-1",
            action: "approve",
            token: tok
        ))
        let (htmlBytes, _) = try await URLSession.shared.data(from: URL(string: cbURL)!)
        let htmlStr = String(decoding: htmlBytes, as: UTF8.self)
        #expect(!htmlStr.contains("<script>alert(1)</script>"))
        #expect(htmlStr.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))

        // Truncated Content-Length over raw TCP socket must return 400 Bad Request
        let rawFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        #expect(rawFD >= 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let connRC = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(rawFD, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(connRC == 0)
        let truncatedHTTP = Data("POST /v1/emit HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(tok)\r\nContent-Length: 500\r\n\r\n{\"a\":1}".utf8)
        _ = truncatedHTTP.withUnsafeBytes { Darwin.write(rawFD, $0.baseAddress!, $0.count) }
        Darwin.shutdown(rawFD, SHUT_WR) // EOF early while 493 bytes still missing!
        var replyBuf = [UInt8](repeating: 0, count: 512)
        let readN = Darwin.read(rawFD, &replyBuf, replyBuf.count)
        Darwin.close(rawFD)
        let replyText = readN > 0 ? String(decoding: replyBuf.prefix(readN), as: UTF8.self) : ""
        #expect(replyText.contains("HTTP/1.1 400"))

        let casWins = await withTaskGroup(of: Bool.self) { group -> Int in
            for _ in 0..<8 {
                group.addTask {
                    orch.approve(id: "apr-cas-1", comment: "race")
                }
            }
            var wins = 0
            for await won in group where won { wins += 1 }
            return wins
        }
        #expect(casWins == 1)

        // (c) SQL pushdown in listEventAuditRecords finds older `dispatched` row buried beneath 240 `dropped_rule` rows
        let targetEv = EventEnvelope(source: "bz://test", type: "dev.bianzhong.test", correlationKey: "needle", payload: ["title": "Needle Signal", "body": "deep_needle_100%"])
        try orch.store.recordEvent(targetEv, funnelStage: "dispatched", matchedChimeID: "beta-rule")
        for i in 0..<240 {
            let noise = EventEnvelope(source: "bz://noise", type: "dev.bianzhong.noise", correlationKey: "n-\(i)", payload: ["title": "Noise \(i)"])
            try orch.store.recordEvent(noise, funnelStage: "dropped_rule", dropReason: "no_chime_matched")
        }
        let dispatchedAudit = try orch.store.listEventAuditRecords(limit: 50, stageFilter: "dispatched")
        #expect(dispatchedAudit.contains(where: { $0.id == targetEv.id }))
        // Also verify literal `%` in searchQuery is properly escaped in LIKE ESCAPE '\'
        let literalPercentHit = try orch.store.listEventAuditRecords(limit: 20, searchQuery: "deep_needle_100%")
        #expect(literalPercentHit.count == 1)
        let literalPercentMiss = try orch.store.listEventAuditRecords(limit: 20, searchQuery: "Noise %")
        #expect(literalPercentMiss.isEmpty)

        // (d) Clean Git worktree removal prunes `.git/worktrees/<name>` and enforces path boundary + dirty guard
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        func git(_ dir: URL, _ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", dir.path] + args
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            try p.run()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0)
        }
        try git(repoDir, ["init", "-q"])
        try git(repoDir, ["config", "user.email", "test@bianzhong.dev"])
        try git(repoDir, ["config", "user.name", "Bianzhong Test"])
        try "hello\n".write(to: repoDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try git(repoDir, ["add", "README.md"])
        try git(repoDir, ["commit", "-q", "-m", "init"])

        let wtPath = TerminalLauncher.prepareWorktreeIfGitRepo(repoPath: repoDir.path, runID: "wt24", worktreesDir: paths.worktreesDir)
        #expect(wtPath != repoDir.path)
        let wtMetaDir = repoDir.appendingPathComponent(".git/worktrees")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: wtMetaDir.path)) ?? []).isEmpty == false)

        // Out-of-bounds path rejected
        #expect(throws: (any Error).self) {
            try orch.removeWorktree(at: repoDir.path)
        }

        // Dirty worktree rejected unless cleaned
        let dirtyFile = URL(fileURLWithPath: wtPath).appendingPathComponent("dirty.txt")
        try "uncommitted".write(to: dirtyFile, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) {
            try orch.removeWorktree(at: wtPath)
        }
        try FileManager.default.removeItem(at: dirtyFile)

        // Clean worktree removed AND `.git/worktrees/<name>` metadata pruned from parent repo!
        try orch.removeWorktree(at: wtPath)
        #expect(FileManager.default.fileExists(atPath: wtPath) == false)
        let remainingMeta = (try? FileManager.default.contentsOfDirectory(atPath: wtMetaDir.path)) ?? []
        #expect(remainingMeta.isEmpty)
    }

    @Test("25. v0.5.0 ACP warm-hold & inline steer, stopRun, Claude/OpenCode drivers, and Pocket PWA API")
    func v050AcpWarmHoldSteerStopAndPocketPWA() async throws {
        let shortID = String(UUID().uuidString.prefix(8))
        let rootDir = URL(fileURLWithPath: "/tmp/bz-t25-\(shortID)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let cfgDir = rootDir.appendingPathComponent("cfg", isDirectory: true)
        let stateDir = rootDir.appendingPathComponent("state", isDirectory: true)
        let workDir = rootDir.appendingPathComponent("repo", isDirectory: true)
        let binDir = rootDir.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        // (a) ClaudeDriver & OpenCodeDriver CLI spec & JSONL parser checks
        let claudeReq = AgentInvocationRequest(
            runID: "r1",
            correlationKey: "ck1",
            workingDirectory: workDir.path,
            promptText: "diagnose",
            eventFilePath: rootDir.appendingPathComponent("ev.json").path,
            sessionDir: stateDir.path,
            permissionProfile: .readOnly
        )
        let claudeDrv = ClaudeDriver()
        let claudeSpec = claudeDrv.buildSpawnSpec(request: claudeReq)
        #expect(claudeSpec.arguments.contains("--output-format"))
        #expect(claudeSpec.arguments.contains("stream-json"))
        #expect(claudeSpec.arguments.contains("plan"))
        let claudeEvents = claudeDrv.parseStdoutLine(#"{"type":"result","session_id":"claude-ses-99","result":"Claude 根因结论","total_cost_usd":0.042,"usage":{"input_tokens":120,"output_tokens":35,"cache_read_input_tokens":10}}"#)
        #expect(claudeEvents.contains(.sessionStarted(externalSessionID: "claude-ses-99")))
        #expect(claudeEvents.contains(.finalAnswer(text: "Claude 根因结论")))

        let ocDrv = OpenCodeDriver()
        let ocEvents = ocDrv.parseStdoutLine(#"{"type":"step_finish","sessionID":"oc-ses-77","part":{"cost":0.015,"tokens":{"input":80,"output":20,"cache":{"read":5}}}}"#)
        #expect(ocEvents.contains(.sessionStarted(externalSessionID: "oc-ses-77")))

        // (b) AppConfig notch_hud_enabled roundtrip
        let paths = BianzhongPaths(configDir: cfgDir, stateDir: stateDir)
        try paths.ensureDirectories()
        var initCfg = AppConfig()
        initCfg.webhookServerEnabled = true
        initCfg.webhookHost = "127.0.0.1"
        initCfg.webhookPort = Int.random(in: 29100...29800)
        initCfg.notchHUDEnabled = false
        try AppConfig.save(initCfg, to: paths.configFile)
        let reloadedCfg = AppConfig.load(from: paths.configFile)
        #expect(reloadedCfg.notchHUDEnabled == false)

        // (c) Mock ACP JSON-RPC 2.0 server script supporting initialize, session/new, session/prompt,
        //     session/update (text + diff), session/request_permission warm-hold, and follow-up steer!
        let mockAcpPy = binDir.appendingPathComponent("mock-acp-agent.py")
        let pyScript = """
        #!/usr/bin/env python3
        import json, sys, os

        turn = 0
        for raw in sys.stdin:
            raw = raw.strip()
            if not raw:
                continue
            msg = json.loads(raw)
            mid = msg.get("id")
            method = msg.get("method", "")
            if method == "initialize":
                sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": 1}}) + "\\n")
                sys.stdout.flush()
            elif method == "session/new":
                sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": "acp-ses-live-1", "configOptions": [{"id": "mode"}]}}) + "\\n")
                sys.stdout.flush()
            elif method == "session/set_config_option":
                sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": mid, "result": {}}) + "\\n")
                sys.stdout.flush()
            elif method == "session/prompt":
                turn += 1
                blocks = msg.get("params", {}).get("prompt", [])
                prompt_text = blocks[0].get("text", "") if blocks else ""
                if "STEER_MODE" in prompt_text or turn >= 2:
                    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "acp-ses-live-1", "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "已按指导调整方案：仅修改超时重试参数"}}}}) + "\\n")
                    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}}) + "\\n")
                    sys.stdout.flush()
                else:
                    # Stream a diff update + text chunk, then trigger warm-hold permission gate!
                    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "acp-ses-live-1", "update": {"sessionUpdate": "tool_call", "title": "Edit retry.swift", "content": [{"type": "diff", "path": "retry.swift", "oldText": "let retries = 1\\n", "newText": "let retries = 3\\n"}]}}}) + "\\n")
                    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "acp-ses-live-1", "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "定位到重试次数过低，准备应用补丁"}}}}) + "\\n")
                    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": "perm-req-1", "method": "session/request_permission", "params": {"sessionId": "acp-ses-live-1", "toolCall": {"title": "Write retry.swift"}, "options": [{"optionId": "allow-once", "kind": "allow_once"}, {"optionId": "reject-once", "kind": "reject_once"}]}}) + "\\n")
                    sys.stdout.flush()
                    # Wait in-place for client permission response!
                    perm_line = sys.stdin.readline().strip()
                    perm_resp = json.loads(perm_line) if perm_line else {}
                    chosen = perm_resp.get("result", {}).get("outcome", {}).get("optionId", "")
                    if chosen == "allow-once":
                        with open(os.path.join("\(workDir.path)", "patched.txt"), "w") as f:
                            f.write("warm_resumed_ok")
                        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "acp-ses-live-1", "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": " · 热恢复补丁已落盘"}}}}) + "\\n")
                    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}}) + "\\n")
                    sys.stdout.flush()
        """
        try pyScript.write(to: mockAcpPy, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockAcpPy.path)

        let acpDriverID = "mock-acp-\(shortID)-acp"
        AgentDriverRegistry.register(AcpAgentDriver(
            id: acpDriverID,
            executablePath: mockAcpPy.path,
            acpArguments: []
        ))
        defer { AgentDriverRegistry.unregister(id: acpDriverID) }

        let acpRule = """
        ---
        id: acp-warm-rule
        enabled: true
        match:
          type: ["dev.bianzhong.acp.test"]
        funnel:
          debounce: 0s
          cooldown: 0s
          triage:
            enabled: false
            provider: none
        execution:
          autonomy: draft_approve
          driver: \(acpDriverID)
          working_dir: \(workDir.path)
          worktree_on_phase2: false
        on_complete:
          - type: notify
        ---
        ## Phase 1
        Inspect and patch retry.swift
        """
        try acpRule.write(to: paths.chimesDir.appendingPathComponent("acp-warm-rule.md"), atomically: true, encoding: .utf8)

        // Also add a slow CLI rule to test 1-click stopRun(id:)
        let slowDriverID = "mock-slow-\(shortID)"
        struct SlowDriver: AgentDriver {
            let id: String
            func buildSpawnSpec(request: AgentInvocationRequest) -> SpawnSpec {
                SpawnSpec(executablePath: "/bin/sleep", arguments: ["30"], workingDirectory: request.workingDirectory)
            }
            func parseStdoutLine(_ line: String) -> [NormalizedAgentEvent] { [] }
            func isSuccessExit(exitCode: Int32, lastEvents: [NormalizedAgentEvent]) -> Bool { exitCode == 0 }
            func buildTakeoverCommand(sessionID: String, sessionDir: String, workingDirectory: String) -> String { "echo hi" }
        }
        AgentDriverRegistry.register(SlowDriver(id: slowDriverID))
        defer { AgentDriverRegistry.unregister(id: slowDriverID) }

        let slowRule = """
        ---
        id: slow-cancel-rule
        enabled: true
        match:
          type: ["dev.bianzhong.slow.test"]
        funnel:
          debounce: 0s
          triage:
            enabled: false
            provider: none
        execution:
          autonomy: draft_approve
          driver: \(slowDriverID)
          working_dir: \(workDir.path)
        ---
        ## Phase 1
        sleep
        """
        try slowRule.write(to: paths.chimesDir.appendingPathComponent("slow-cancel-rule.md"), atomically: true, encoding: .utf8)

        let orch = try Orchestrator(paths: paths)
        try orch.start(enableBuiltInSensors: false, enableWebhookServer: true)
        defer { orch.stop() }

        // Trigger ACP warm-hold flow
        let ev1 = EventEnvelope(source: "bz://test", type: "dev.bianzhong.acp.test", correlationKey: "acp:1", payload: ["title": "ACP 故障信号", "body": "retry error"])
        _ = orch.handleBusRequest(BusRequest(action: "emit", event: ev1))

        for _ in 0..<80 {
            if !orch.pendingApprovals().isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let warmApr = try #require(orch.pendingApprovals().first)
        #expect(orch.isWarmHeldApproval(warmApr.id) == true)
        #expect(warmApr.diffPreview?.contains("+let retries = 3") == true)
        #expect(orch.activeRuns().contains(where: { $0.status == "warm_hold" }))

        // (d) Verify Mobile Pocket Console PWA & authenticated JSON API while warm-hold is live!
        let tok = SecretStore.ensureWebhookToken(paths: paths)
        let port = orch.webhookStatus().port
        let (pwaBytes, pwaResp) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/pocket")!)
        #expect((pwaResp as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: pwaBytes, as: UTF8.self).contains("编钟 · 口袋控制台"))

        let (_, unauthResp) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/v1/pocket/state")!)
        #expect((unauthResp as? HTTPURLResponse)?.statusCode == 401)

        var stateReq = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/pocket/state")!)
        stateReq.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        let (stateBytes, stateResp) = try await URLSession.shared.data(for: stateReq)
        #expect((stateResp as? HTTPURLResponse)?.statusCode == 200)
        let stateObj = try #require(try JSONSerialization.jsonObject(with: stateBytes) as? [String: Any])
        let apiActiveRuns = (stateObj["active_runs"] as? [[String: Any]]) ?? []
        let apiApprovals = (stateObj["approvals"] as? [[String: Any]]) ?? []
        #expect(apiActiveRuns.contains(where: { ($0["status"] as? String) == "warm_hold" }))
        #expect((apiApprovals.first?["diffPreview"] as? String)?.contains("+let retries = 3") == true)

        // Resume warm-held ACP session in-place (<5ms gate release, no Phase 2 cold spawn!)
        #expect(orch.approve(id: warmApr.id, comment: "Approve warm") == true)
        let patchedFile = workDir.appendingPathComponent("patched.txt")
        for _ in 0..<60 {
            if FileManager.default.fileExists(atPath: patchedFile.path) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect((try? String(contentsOf: patchedFile, encoding: .utf8)) == "warm_resumed_ok")

        // Wait for completion notify card and test inline `steer(id:instruction:)`
        for _ in 0..<60 {
            if orch.pendingApprovals().contains(where: { $0.id != warmApr.id }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let postWarmCard = try #require(orch.pendingApprovals().first(where: { $0.id != warmApr.id }))
        #expect(orch.steer(id: postWarmCard.id, instruction: "STEER_MODE 请只改重试参数") == true)
        for _ in 0..<80 {
            if orch.pendingApprovals().contains(where: { $0.proposedAction.contains("已按指导调整方案") }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(orch.pendingApprovals().contains(where: { $0.proposedAction.contains("已按指导调整方案") }))

        // (e) Test 1-click stopRun(id:) on active slow run + Pocket API pause/resume
        let slowEv = EventEnvelope(source: "bz://test", type: "dev.bianzhong.slow.test", correlationKey: "slow:1", payload: ["title": "Slow Run"])
        _ = orch.handleBusRequest(BusRequest(action: "emit", event: slowEv))
        for _ in 0..<40 {
            if orch.activeRuns().contains(where: { $0.chimeID == "slow-cancel-rule" }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let activeSlow = try #require(orch.activeRuns().first(where: { $0.chimeID == "slow-cancel-rule" }))
        #expect(orch.stopRun(id: activeSlow.runID) == true)
        for _ in 0..<40 {
            if !orch.activeRuns().contains(where: { $0.runID == activeSlow.runID }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(orch.recentRuns().first(where: { $0.id == activeSlow.runID })?.status == "cancelled")

        var actReq = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/pocket/act")!)
        actReq.httpMethod = "POST"
        actReq.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        actReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        actReq.httpBody = Data(#"{"action":"pause","seconds":60}"#.utf8)
        let (_, actResp) = try await URLSession.shared.data(for: actReq)
        #expect((actResp as? HTTPURLResponse)?.statusCode == 200)
        #expect(orch.isPaused() == true)
    }

    @Test("26. v0.5.0 Code Review regressions: ACP worktree isolation & write-lease, ghost approval cleanup, Phase 2 cancel guard, steer session continuity, OpenCode plan/usage, and Pocket header-only auth")
    func v050CodeReviewRegressions() async throws {
        let shortID = String(UUID().uuidString.prefix(8))
        let rootDir = URL(fileURLWithPath: "/tmp/bz-t26-\(shortID)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let cfgDir = rootDir.appendingPathComponent("cfg", isDirectory: true)
        let stateDir = rootDir.appendingPathComponent("state", isDirectory: true)
        let repoDir = rootDir.appendingPathComponent("repo", isDirectory: true)
        let binDir = rootDir.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        func git(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", repoDir.path] + args
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            try p.run()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0)
        }
        try git(["init", "-q"])
        try git(["config", "user.email", "test@bianzhong.dev"])
        try git(["config", "user.name", "Bianzhong Test"])
        try "v1\n".write(to: repoDir.appendingPathComponent("app.txt"), atomically: true, encoding: .utf8)
        try git(["add", "app.txt"])
        try git(["commit", "-q", "-m", "initial"])

        // (a) OpenCodeDriver permission flags (`--agent plan` vs `--auto`) & `step_finish` usage accounting
        let oc = OpenCodeDriver()
        let roSpec = oc.buildSpawnSpec(request: AgentInvocationRequest(
            runID: "r-ro", correlationKey: "c", workingDirectory: repoDir.path,
            promptText: "plan", eventFilePath: "/tmp/e.json", sessionDir: stateDir.path, permissionProfile: .readOnly
        ))
        #expect(roSpec.arguments.contains("--agent"))
        #expect(roSpec.arguments.contains("plan"))
        #expect(!roSpec.arguments.contains("--auto"))

        let rwSpec = oc.buildSpawnSpec(request: AgentInvocationRequest(
            runID: "r-rw", correlationKey: "c", workingDirectory: repoDir.path,
            promptText: "exec", eventFilePath: "/tmp/e.json", sessionDir: stateDir.path, permissionProfile: .workspaceRW
        ))
        #expect(rwSpec.arguments.contains("--auto"))

        let stepEvs = oc.parseStdoutLine(#"{"type":"step_finish","sessionID":"oc-s1","part":{"cost":0.025,"tokens":{"input":100,"output":30,"cache":{"read":12}}}}"#)
        #expect(stepEvs.contains(.usageReported(input: 100, output: 30, cached: 12, costUSD: 0.025)))

        // (b) ACP driver with STRING JSON-RPC response IDs + usage reporting + cwd writing (`worktree_on_phase2: true` isolation!)
        let acpScriptURL = binDir.appendingPathComponent("mock-acp-wt.py")
        let py = """
        #!/usr/bin/env python3
        import json, sys, os

        for raw in sys.stdin:
            raw = raw.strip()
            if not raw:
                continue
            msg = json.loads(raw)
            mid = str(msg.get("id", ""))
            method = msg.get("method", "")
            if method == "initialize":
                sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": 1, "agentCapabilities": {"loadSession": True}}}) + "\\n")
                sys.stdout.flush()
            elif method == "session/load":
                sid = msg.get("params", {}).get("sessionId", "resumed")
                sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": sid}}) + "\\n")
                sys.stdout.flush()
            elif method == "session/new":
                sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": "acp-wt-ses-1"}}) + "\\n")
                sys.stdout.flush()
            elif method == "session/prompt":
                blocks = msg.get("params", {}).get("prompt", [])
                txt = blocks[0].get("text", "") if blocks else ""
                if "[Human Steer / 用户补充调整要求]: FOLLOWUP_STEER" in txt:
                    used_sid = msg.get("params", {}).get("sessionId", "")
                    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": used_sid, "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": f"RESUMED_OK:{used_sid}"}}}}) + "\\n")
                    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn", "usage": {"inputTokens": 50, "outputTokens": 15, "costUSD": 0.01}}}) + "\\n")
                    sys.stdout.flush()
                    continue
                sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": "perm-wt", "method": "session/request_permission", "params": {"sessionId": "acp-wt-ses-1", "toolCall": {"title": "Write isolated.txt"}, "options": [{"optionId": "allow-1", "kind": "allow_once"}]}}) + "\\n")
                sys.stdout.flush()
                ans_line = sys.stdin.readline().strip()
                if not ans_line:
                    break
                ans = json.loads(ans_line)
                opt = ans.get("result", {}).get("outcome", {}).get("optionId", "")
                if opt == "allow-1":
                    with open(os.path.join(os.getcwd(), "isolated.txt"), "w") as f:
                        f.write("in_worktree_only")
                    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "acp-wt-ses-1", "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Worktree edit complete"}}}}) + "\\n")
                sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn", "usage": {"inputTokens": 120, "outputTokens": 40, "costUSD": 0.03}}}) + "\\n")
                sys.stdout.flush()
        """
        try py.write(to: acpScriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: acpScriptURL.path)

        let acpDrvID = "mock-acp-wt-\(shortID)-acp"
        AgentDriverRegistry.register(AcpAgentDriver(id: acpDrvID, executablePath: acpScriptURL.path))
        defer { AgentDriverRegistry.unregister(id: acpDrvID) }

        let paths = BianzhongPaths(configDir: cfgDir, stateDir: stateDir)
        try paths.ensureDirectories()
        var cfg = AppConfig()
        cfg.webhookServerEnabled = true
        cfg.webhookHost = "127.0.0.1"
        cfg.webhookPort = Int.random(in: 29900...30800)
        try AppConfig.save(cfg, to: paths.configFile)

        let wtRule = """
        ---
        id: acp-wt-isolated
        enabled: true
        match:
          type: ["dev.bianzhong.wt.test"]
        funnel:
          debounce: 0s
          cooldown: 0s
          triage:
            enabled: false
            provider: none
        session:
          policy: ephemeral
        execution:
          autonomy: draft_approve
          driver: \(acpDrvID)
          working_dir: \(repoDir.path)
          worktree_on_phase2: true
        on_complete:
          - type: notify
        ---
        ## Phase 1
        edit isolated.txt
        """
        try wtRule.write(to: paths.chimesDir.appendingPathComponent("acp-wt-isolated.md"), atomically: true, encoding: .utf8)

        let orch = try Orchestrator(paths: paths)
        try orch.start(enableBuiltInSensors: false, enableWebhookServer: true)
        defer { orch.stop() }

        // Run 1: Warm-hold inside isolated worktree -> approve -> verify main repo stays untouched!
        _ = orch.handleBusRequest(BusRequest(action: "emit", event: EventEnvelope(
            source: "bz://test", type: "dev.bianzhong.wt.test", correlationKey: "wt:1", payload: ["title": "WT Isolation"]
        )))
        for _ in 0..<80 {
            if !orch.pendingApprovals().isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let warm1 = try #require(orch.pendingApprovals().first)
        let assignedWT = try #require(warm1.targetRepo)
        #expect(assignedWT != repoDir.path)
        #expect(assignedWT.contains("/worktrees/"))

        #expect(orch.approve(id: warm1.id, comment: "go") == true)
        for _ in 0..<80 {
            if orch.recentRuns().contains(where: { $0.status == "succeeded" }) && !orch.pendingApprovals().isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        // Main checkout must remain 100% clean; isolated worktree has `isolated.txt`!
        #expect(FileManager.default.fileExists(atPath: repoDir.appendingPathComponent("isolated.txt").path) == false)
        #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: assignedWT).appendingPathComponent("isolated.txt").path) == true)
        #expect(abs((orch.recentRuns().first?.costUSD ?? 0) - 0.03) < 0.0001)

        // (c) Non-warm-hold `steer()` preserves `externalSessionID` even when rule originally had `ephemeral` policy!
        let doneCard = try #require(orch.pendingApprovals().first)
        #expect(doneCard.externalSessionID == "acp-wt-ses-1")
        #expect(orch.steer(id: doneCard.id, instruction: "FOLLOWUP_STEER") == true)
        for _ in 0..<80 {
            if orch.pendingApprovals().contains(where: { $0.proposedAction.contains("RESUMED_OK:acp-wt-ses-1") }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let steeredCard = try #require(orch.pendingApprovals().first(where: { $0.proposedAction.contains("RESUMED_OK:acp-wt-ses-1") }))
        _ = orch.reject(id: steeredCard.id, comment: "done")

        // (d) Stopping a warm-held ACP run via `stopRun(id:)` expires its pending approval (no ghost inbox card) & prunes clean worktree!
        _ = orch.handleBusRequest(BusRequest(action: "emit", event: EventEnvelope(
            source: "bz://test", type: "dev.bianzhong.wt.test", correlationKey: "wt:2", payload: ["title": "Ghost Check"]
        )))
        for _ in 0..<80 {
            if !orch.pendingApprovals().isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let ghostCandidate = try #require(orch.pendingApprovals().first)
        let cancelWT = try #require(ghostCandidate.targetRepo)
        #expect(orch.stopRun(id: ghostCandidate.runID) == true)
        for _ in 0..<60 {
            if orch.activeRuns().isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(orch.pendingApprovals().isEmpty)
        #expect((try orch.store.getApproval(id: ghostCandidate.id))?.status == "expired")
        #expect(FileManager.default.fileExists(atPath: cancelWT) == false)

        // (e) Pocket API rejects query `?token=` (CSRF defense), emits `Cache-Control: no-store`, and honors `seconds` in `pause`
        let tok = SecretStore.ensureWebhookToken(paths: paths)
        let port = orch.webhookStatus().port
        let (_, queryAuthResp) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/v1/pocket/state?token=\(tok)")!)
        #expect((queryAuthResp as? HTTPURLResponse)?.statusCode == 401)

        var headerReq = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/pocket/state")!)
        headerReq.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        let (_, headerResp) = try await URLSession.shared.data(for: headerReq)
        let httpHeaderResp = try #require(headerResp as? HTTPURLResponse)
        #expect(httpHeaderResp.statusCode == 200)
        #expect(httpHeaderResp.value(forHTTPHeaderField: "Cache-Control") == "no-store")

        var shortPauseReq = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/pocket/act")!)
        shortPauseReq.httpMethod = "POST"
        shortPauseReq.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        shortPauseReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        shortPauseReq.httpBody = Data(#"{"action":"pause","seconds":0.25}"#.utf8)
        let (_, pauseResp) = try await URLSession.shared.data(for: shortPauseReq)
        #expect((pauseResp as? HTTPURLResponse)?.statusCode == 200)
        #expect(orch.isPaused() == true)
        try await Task.sleep(for: .milliseconds(400))
        #expect(orch.isPaused() == false)

        // (f) Customizable Notch Hotkey parsing, keycode/modifier mapping, and config persistence
        let defaultSpec = try #require(NotchHotkeySpec.parse("option+space"))
        #expect(defaultSpec.keyCode == 49)
        #expect(defaultSpec.carbonModifiers == NotchHotkeySpec.carbonOptionKey)
        #expect(defaultSpec.displayString == "⌥Space")

        let customRecorded = try #require(NotchHotkeySpec.fromKeyEvent(keyCode: 11, command: true, option: false, control: false, shift: true))
        #expect(customRecorded.canonicalString == "shift+cmd+b")
        #expect(customRecorded.displayString == "⇧⌘B")
        #expect(NotchHotkeySpec.fromKeyEvent(keyCode: 0, command: false, option: false, control: false, shift: false) == nil) // bare 'a' rejected
        #expect(NotchHotkeySpec.parse("none") == nil)
        #expect(NotchHotkeySpec.displayLabel(for: "none") == "无")

        orch.setNotchHotkey("ctrl+space")
        #expect(orch.currentConfig().notchHotkey == "ctrl+space")
        #expect(AppConfig.load(from: paths.configFile).notchHotkey == "ctrl+space")
    }
}

private extension ChimeRule {
    func whenConditionCheck(expectedWhen: String) -> Bool {
        onComplete.first?.whenCondition == expectedWhen
    }
}
