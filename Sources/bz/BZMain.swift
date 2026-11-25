import BianzhongCore
import Darwin
import Foundation

private func printUsage() {
    print("""
    bz - Bianzhong CLI

    USAGE:
      bz init
      bz config [--gui]
      bz emit --type <type> [--source <src>] [--title <title>] [--subtitle <subt>] [--body <body>] [--cwd <dir>] [--correlation-key <key>] [--privacy public|internal|sensitive|restricted]
      bz status | inbox
      bz approve <approval-id> [--note <text>]
      bz reject <approval-id> [--note <text>]
      bz takeover <approval-id>
      bz simulate --type <type> [--source <src>] [--title <title>] [--subtitle <subt>] [--body <body>] [--cwd <dir>] [--chime <id>] [--with-l1]
      bz replay [--last 50] [--chime <id>] [--with-l1]
      bz tune [<chime-id>] [--dry-run] [--gui]
      bz digest
      bz gc
      bz reset-circuit <chime-id>
      bz install-cli [--zsh]
      bz uninstall-cli
      bz shell-hook zsh
      bz reload
    """)
}

private func argValue(_ flag: String, in args: [String]) -> String? {
    guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
    return args[idx + 1]
}

private func buildEnvelopeFromArgs(_ args: [String]) -> EventEnvelope {
    let type = argValue("--type", in: args) ?? "dev.bianzhong.manual"
    let source = argValue("--source", in: args) ?? "bz://cli/emit"
    let title = argValue("--title", in: args) ?? ""
    let subtitle = argValue("--subtitle", in: args) ?? ""
    let cwd = argValue("--cwd", in: args) ?? ""
    let bodyArg = argValue("--body", in: args)
    let body: String
    if let bodyArg {
        body = bodyArg
    } else if isatty(STDIN_FILENO) == 0 {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    } else {
        body = ""
    }
    let corr = argValue("--correlation-key", in: args) ?? "\(type):\(title.isEmpty ? "default" : title)"
    let privacyRaw = argValue("--privacy", in: args) ?? "internal"
    let privacy = PrivacyLevel(rawValue: privacyRaw) ?? .internal

    var payload: [String: String] = [:]
    if !title.isEmpty { payload["title"] = title }
    if !subtitle.isEmpty { payload["subtitle"] = subtitle }
    if !cwd.isEmpty { payload["cwd"] = cwd }
    if !body.isEmpty { payload["body"] = body }

    return EventEnvelope(
        source: source,
        type: type,
        correlationKey: corr,
        privacyLevel: privacy,
        payload: payload,
        ambientContext: .captureCurrent()
    )
}

private func runInteractiveCLI(binary: String, arguments: [String], cwd: URL) throws -> Int32 {
    let proc = Process()
    proc.currentDirectoryURL = cwd
    proc.executableURL = URL(fileURLWithPath: binary)
    proc.arguments = arguments
    try proc.run()
    proc.waitUntilExit()
    return proc.terminationStatus
}

private func printSimulationSummary(_ summary: SimulationSummary) {
    print("Simulated \(summary.totalEvents) event(s): wake_agent=\(summary.wouldWakeAgent), direct_action=\(summary.directActionOnly), dropped_l0=\(summary.droppedL0), dropped_l1=\(summary.droppedL1)")
    for r in summary.results {
        let l1 = r.l1Decision.map { " | L1=\($0.action.rawValue)" } ?? ""
        let acts = r.triggeredActions.isEmpty ? "" : " | actions=[\(r.triggeredActions.joined(separator: ","))]"
        print("  - [\(r.type)] \(r.title) -> \(r.l0Outcome)\(l1) | wake_agent=\(r.wouldWakeAgent)\(acts)")
    }
}

let args = Array(CommandLine.arguments.dropFirst())
let paths = BianzhongPaths()

guard let subcommand = args.first else {
    printUsage()
    exit(0)
}

Task {
    do {
        switch subcommand {
        case "init":
            let created = try DefaultTemplates.installDefaultsIfMissing(paths: paths)
            if created.isEmpty {
                print("Already initialized at \(paths.configDir.path)")
            } else {
                print("Initialized Bianzhong config at \(paths.configDir.path):")
                created.forEach { print("  + \($0)") }
            }

        case "config":
            _ = try DefaultTemplates.installDefaultsIfMissing(paths: paths)
            let cfg = AppConfig.load(from: paths.configFile)
            let cfgDir = paths.configDir.path
            if args.contains("--gui") || isatty(STDIN_FILENO) == 0 {
                let cmd: String
                if let omp = AgentDriverRegistry.resolveBinary(name: "omp") {
                    cmd = "cd \(shellQuote(cfgDir)) && \(shellQuote(omp)) --cwd \(shellQuote(cfgDir))"
                } else if let codex = AgentDriverRegistry.resolveBinary(name: "codex") {
                    cmd = "cd \(shellQuote(cfgDir)) && \(shellQuote(codex)) -C \(shellQuote(cfgDir))"
                } else {
                    fputs("Neither omp nor codex found on PATH.\n", stderr)
                    exit(1)
                }
                _ = TerminalLauncher.launchCommand(cmd, preferredTerminal: cfg.terminal)
                print("Launched config assistant in \(cfgDir)")
            } else if let omp = AgentDriverRegistry.resolveBinary(name: "omp") {
                exit(try runInteractiveCLI(binary: omp, arguments: ["--cwd", cfgDir], cwd: paths.configDir))
            } else if let codex = AgentDriverRegistry.resolveBinary(name: "codex") {
                exit(try runInteractiveCLI(binary: codex, arguments: ["-C", cfgDir], cwd: paths.configDir))
            } else {
                fputs("Neither omp nor codex found on PATH. Edit \(paths.chimesDir.path) directly.\n", stderr)
                exit(1)
            }

        case "emit":
            let env = buildEnvelopeFromArgs(args)
            let resp = try SocketClient.send(request: BusRequest(action: "emit", event: env), socketURL: paths.socketURL)
            print("\(resp.disposition ?? resp.message)")
            exit(resp.ok ? 0 : 1)

        case "simulate":
            let cfg = AppConfig.load(from: paths.configFile)
            var rules = ChimeRule.loadAll(from: paths.chimesDir)
            if let chimeFilter = argValue("--chime", in: args) {
                rules = rules.filter { $0.id == chimeFilter }
            }
            let ev = buildEnvelopeFromArgs(args)
            let summary = await RuleSimulator.simulate(
                events: [ev],
                rules: rules,
                config: cfg,
                runL1: args.contains("--with-l1")
            )
            printSimulationSummary(summary)

        case "replay":
            let cfg = AppConfig.load(from: paths.configFile)
            var rules = ChimeRule.loadAll(from: paths.chimesDir)
            if let chimeFilter = argValue("--chime", in: args) {
                rules = rules.filter { $0.id == chimeFilter }
            }
            let limit = Int(argValue("--last", in: args) ?? "50") ?? 50
            let store = try SQLiteStore(dbURL: paths.dbURL)
            let events = try store.listRecentEvents(limit: limit)
            let summary = await RuleSimulator.simulate(
                events: events,
                rules: rules,
                config: cfg,
                runL1: args.contains("--with-l1")
            )
            printSimulationSummary(summary)

        case "tune":
            _ = try DefaultTemplates.installDefaultsIfMissing(paths: paths)
            let store = try SQLiteStore(dbURL: paths.dbURL)
            let chimeID = args.dropFirst().first { !$0.hasPrefix("-") }
            let tune = try RuleTuner.prepareTuneSession(paths: paths, store: store, chimeID: chimeID)
            print("Prepared \(tune.sampleCount) rejected sample(s) at \(tune.contextFile.path)")
            if args.contains("--dry-run") {
                print(tune.prompt)
                exit(0)
            }
            let cfg = AppConfig.load(from: paths.configFile)
            let cfgDir = paths.configDir.path
            if args.contains("--gui") || isatty(STDIN_FILENO) == 0 {
                if let omp = AgentDriverRegistry.resolveBinary(name: "omp") {
                    let cmd = "cd \(shellQuote(cfgDir)) && \(shellQuote(omp)) --cwd \(shellQuote(cfgDir)) \(shellQuote(tune.prompt))"
                    _ = TerminalLauncher.launchCommand(cmd, preferredTerminal: cfg.terminal)
                } else if let codex = AgentDriverRegistry.resolveBinary(name: "codex") {
                    let cmd = "cd \(shellQuote(cfgDir)) && \(shellQuote(codex)) -C \(shellQuote(cfgDir)) \(shellQuote(tune.prompt))"
                    _ = TerminalLauncher.launchCommand(cmd, preferredTerminal: cfg.terminal)
                }
            } else if let omp = AgentDriverRegistry.resolveBinary(name: "omp") {
                exit(try runInteractiveCLI(binary: omp, arguments: ["--cwd", cfgDir, tune.prompt], cwd: paths.configDir))
            } else if let codex = AgentDriverRegistry.resolveBinary(name: "codex") {
                exit(try runInteractiveCLI(binary: codex, arguments: ["-C", cfgDir, tune.prompt], cwd: paths.configDir))
            } else {
                print(tune.prompt)
            }

        case "digest":
            if let resp = try? SocketClient.send(request: BusRequest(action: "flush_digest"), socketURL: paths.socketURL) {
                print(resp.message)
            } else {
                let orch = try Orchestrator(paths: paths)
                let digest = orch.flushWakeDigest()
                print(digest == nil ? "No deferred digest items." : "Flushed digest \(digest!.id)")
            }

        case "gc":
            if let resp = try? SocketClient.send(request: BusRequest(action: "gc"), socketURL: paths.socketURL) {
                print(resp.message)
            } else {
                let cfg = AppConfig.load(from: paths.configFile)
                let store = try SQLiteStore(dbURL: paths.dbURL)
                let report = RuntimeGovernance().performGC(paths: paths, store: store, retentionDays: cfg.retentionDays)
                print("GC pruned \(report.prunedEvents) events, \(report.removedRunDirs) runs, \(report.removedWorktrees) worktrees (preserved dirty: \(report.preservedDirtyWorktrees.count))")
            }

        case "reset-circuit":
            guard args.count >= 2 else { fputs("Usage: bz reset-circuit <chime-id>\n", stderr); exit(1) }
            let resp = try SocketClient.send(request: BusRequest(action: "reset_circuit", chimeID: args[1]), socketURL: paths.socketURL)
            print(resp.message)

        case "install-cli":
            guard let sourceBZ = CLIIntegration.resolveBundledBZPath() else {
                fputs("Unable to locate bz binary to symlink.\n", stderr)
                exit(1)
            }
            let linked = CLIIntegration.ensureCLISymlinks(sourceBZPath: sourceBZ, force: args.contains("--force"))
            print(linked.isEmpty ? "No writable bin directories found." : "Linked bz -> \(linked.joined(separator: ", "))")
            if args.contains("--zsh") {
                try CLIIntegration.setZshHook(enabled: true)
                print("Enabled Zsh slow-command hook in ~/.zshrc (run: source ~/.zshrc)")
            }

        case "uninstall-cli":
            let removed = CLIIntegration.removeCLISymlinks(force: args.contains("--force"))
            if args.contains("--zsh") || CLIIntegration.isZshHookInstalled() {
                try CLIIntegration.setZshHook(enabled: false)
                print("Removed Zsh hook block from ~/.zshrc")
            }
            print(removed.isEmpty ? "No managed bz symlinks found." : "Removed: \(removed.joined(separator: ", "))")

        case "shell-hook":
            let shell = args.dropFirst().first ?? "zsh"
            if shell != "zsh" {
                fputs("Only zsh is currently supported.\n", stderr)
                exit(1)
            }
            let exe = CommandLine.arguments.first ?? "bz"
            print(ShellHook.zshScript(bzExecutablePath: exe))

        case "status", "inbox":
            if let resp = try? SocketClient.send(request: BusRequest(action: "status"), socketURL: paths.socketURL) {
                if let s = resp.status {
                    let feishu = s.feishuSensor ?? "disabled"
                    print("Bianzhong daemon pid=\(s.daemonPID) rules=\(s.loadedRules) feishu=\(feishu) events=\(s.eventsCount) pending=\(s.pendingApprovalsCount) runs=\(s.runsCount) paused=\(s.paused)")
                }
                let items = resp.approvals ?? []
                if items.isEmpty {
                    print("No pending approvals.")
                } else {
                    for item in items {
                        print("[\(item.id)] (\(item.kind)/\(item.riskLevel)) \(item.title) :: \(item.provenanceSummary)")
                        print("  \(item.proposedAction.replacingOccurrences(of: "\n", with: " ").prefix(160))")
                    }
                }
            } else {
                let store = try SQLiteStore(dbURL: paths.dbURL)
                let counts = try store.countsSummary()
                let usage = try store.todayUsageSummary()
                print("Daemon offline | events=\(counts.events) pending=\(counts.pendingApprovals) runs=\(counts.runs) | today_runs=\(usage.runsCount) today_cost=$\(String(format: "%.2f", usage.totalCostUSD))")
                for item in try store.listPendingApprovals() {
                    print("[\(item.id)] (\(item.kind)) \(item.title)")
                }
            }

        case "approve":
            guard args.count >= 2 else { fputs("Usage: bz approve <id> [--note ...]\n", stderr); exit(1) }
            let note = argValue("--note", in: args)
            let resp = try SocketClient.send(request: BusRequest(action: "approve", approvalID: args[1], comment: note), socketURL: paths.socketURL)
            print(resp.message)

        case "reject":
            guard args.count >= 2 else { fputs("Usage: bz reject <id> [--note ...]\n", stderr); exit(1) }
            let note = argValue("--note", in: args)
            let resp = try SocketClient.send(request: BusRequest(action: "reject", approvalID: args[1], comment: note), socketURL: paths.socketURL)
            print(resp.message)

        case "takeover":
            guard args.count >= 2 else { fputs("Usage: bz takeover <id>\n", stderr); exit(1) }
            let resp = try SocketClient.send(request: BusRequest(action: "takeover", approvalID: args[1]), socketURL: paths.socketURL)
            print(resp.takeoverCommand ?? resp.message)

        case "reload":
            let resp = try SocketClient.send(request: BusRequest(action: "reload"), socketURL: paths.socketURL)
            print(resp.message)

        default:
            printUsage()
            exit(1)
        }
        exit(0)
    } catch {
        fputs("bz error: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

dispatchMain()
