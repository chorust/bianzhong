import Foundation

public struct SimulatedEventResult: Codable, Sendable, Equatable {
    public let eventID: String
    public let type: String
    public let title: String
    public let l0Outcome: String
    public let matchedChimeID: String?
    public let l1Decision: TriageDecision?
    public let wouldWakeAgent: Bool
    public let triggeredActions: [String]
}

public struct SimulationSummary: Codable, Sendable, Equatable {
    public let totalEvents: Int
    public let droppedL0: Int
    public let droppedL1: Int
    public let wouldWakeAgent: Int
    public let directActionOnly: Int
    public let results: [SimulatedEventResult]
}

/// Replays synthetic or historical events through L0 rules (and optional L1 triage)
/// in an isolated scratch store without mutating production data or spawning L2 agents.
public enum RuleSimulator {
    public static func simulate(
        events: [EventEnvelope],
        rules: [ChimeRule],
        config: AppConfig,
        runL1: Bool = false
    ) async -> SimulationSummary {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bz-sim-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let scratchDB = tempDir.appendingPathComponent("sim.db")
        guard let scratchStore = try? SQLiteStore(dbURL: scratchDB) else {
            return SimulationSummary(totalEvents: events.count, droppedL0: events.count, droppedL1: 0, wouldWakeAgent: 0, directActionOnly: 0, results: [])
        }

        // Disable debounce wait in dry-run simulation so L0 evaluates synchronously
        let syncRules = rules.map { rule -> ChimeRule in
            var copy = rule
            copy.debounceSeconds = 0
            copy.cooldownSeconds = 0
            return copy
        }
        let funnel = WakeupFunnel(store: scratchStore, rules: syncRules, maxCausalDepth: config.maxCausalDepth)

        var results: [SimulatedEventResult] = []
        var droppedL0 = 0
        var droppedL1 = 0
        var wouldWakeAgent = 0
        var directActionOnly = 0

        for event in events {
            let disposition = funnel.ingest(event) { _, _ in }
            let title = event.payload["title"] ?? event.payload["command"] ?? event.correlationKey

            switch disposition {
            case .dropped(let stage, let reason):
                droppedL0 += 1
                results.append(
                    SimulatedEventResult(
                        eventID: event.id,
                        type: event.type,
                        title: title,
                        l0Outcome: "\(stage):\(reason)",
                        matchedChimeID: nil,
                        l1Decision: nil,
                        wouldWakeAgent: false,
                        triggeredActions: []
                    )
                )

            case .coalescing(let chimeID, _):
                results.append(
                    SimulatedEventResult(
                        eventID: event.id,
                        type: event.type,
                        title: title,
                        l0Outcome: "coalescing",
                        matchedChimeID: chimeID,
                        l1Decision: nil,
                        wouldWakeAgent: false,
                        triggeredActions: []
                    )
                )

            case .ready(let passedEvent, let rule):
                var decision: TriageDecision?
                var wakeAgent = rule.driver != "none"

                if runL1 && rule.triageEnabled {
                    let provider = TriageProviderFactory.make(config: config, override: rule.triageProviderOverride)
                    let req = TriageRequest(
                        event: passedEvent,
                        candidateRuleID: rule.id,
                        candidateDescription: rule.description,
                        workspaces: config.workspaces
                    )
                    let d = await provider.classify(request: req)
                    decision = d
                    if d.action != .dispatchAgent {
                        wakeAgent = false
                        if d.action == .ignore {
                            droppedL1 += 1
                        }
                    }
                }

                if rule.driver == "none" {
                    directActionOnly += 1
                } else if wakeAgent {
                    wouldWakeAgent += 1
                }

                let actionCtx = ActionContext(
                    event: passedEvent,
                    rule: rule,
                    approval: nil,
                    phase: rule.driver == "none" ? "direct" : "draft",
                    summaryText: passedEvent.payload["body"] ?? "",
                    sessionID: nil
                )
                let matchedActions = rule.onComplete
                    .filter { ActionConditionEvaluator.matches($0.whenCondition, context: actionCtx) }
                    .map { $0.type.rawValue }

                results.append(
                    SimulatedEventResult(
                        eventID: event.id,
                        type: event.type,
                        title: title,
                        l0Outcome: "matched:\(rule.id)",
                        matchedChimeID: rule.id,
                        l1Decision: decision,
                        wouldWakeAgent: wakeAgent,
                        triggeredActions: matchedActions
                    )
                )
            }
        }

        return SimulationSummary(
            totalEvents: events.count,
            droppedL0: droppedL0,
            droppedL1: droppedL1,
            wouldWakeAgent: wouldWakeAgent,
            directActionOnly: directActionOnly,
            results: results
        )
    }
}
