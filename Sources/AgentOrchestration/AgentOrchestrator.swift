import Foundation

/// Wires the hybrid A+B demo flow:
/// bad network → NetworkScenarioAgent knobs → apply tool → Analytics snapshot.
///
/// Agents **decide**; tools **apply / observe**. No LLM, no secrets.
@MainActor
final class AgentOrchestrator {
    let networkAgent = NetworkScenarioAgent()
    let analyticsAgent = AnalyticsAgent()
    let layoutAgent = LayoutAdaptivityAgent()

    private let mediaTool: MediaKnobApplying
    private let statsTool: StatsProviding
    private let rosterTool: RosterSnapshotProviding

    private(set) var lastKnobs: MediaKnobs = .l0
    private(set) var lastReport: CallQualityReport?
    private(set) var lastLayout: LayoutPlan?

    var logHandler: ((String) -> Void)?

    init(
        mediaTool: MediaKnobApplying = LoggingMediaKnobApplier(),
        statsTool: StatsProviding = LoggingStatsProvider(),
        rosterTool: RosterSnapshotProviding = LoggingRosterProvider()
    ) {
        self.mediaTool = mediaTool
        self.statsTool = statsTool
        self.rosterTool = rosterTool

        if let logging = mediaTool as? LoggingMediaKnobApplier {
            logging.logHandler = { [weak self] line in self?.logHandler?(line) }
        }
    }

    /// Demo entry: feed a network snapshot through the agent → tool → analytics chain.
    @discardableResult
    func runNetworkAdaptation(network: NetworkSnapshot) -> CallQualityReport {
        log("demo: network adaptation start satisfied=\(network.pathSatisfied) rtt=\(network.rttMs ?? -1) loss=\(network.lossPercent ?? -1)")

        let knobs = networkAgent.decide(from: network)
        lastKnobs = knobs
        log("agent: NetworkScenarioAgent → L\(knobs.level) preferAudio=\(knobs.preferAudio) reason=\(knobs.reason)")

        mediaTool.applyMediaKnobs(knobs)
        log("tool: MediaKnobApplying applied")

        var lines = statsTool.latestStatsLines()
        lines.append(
            "network rtt=\(network.rttMs.map { String(format: "%.0f" , $0) } ?? "n/a") loss=\(network.lossPercent.map { String(format: "%.1f" , $0) } ?? "n/a")%"
        )
        lines.append("preferAudio=\(knobs.preferAudio) mediaPolicyLevel=L\(knobs.level) reason=\(knobs.reason)")

        let report = analyticsAgent.makeReport(from: lines, lastLevel: knobs.level)
        lastReport = report
        log("agent: AnalyticsAgent score=\(String(format: "%.2f", report.score)) summary=\(report.summary)")
        return report
    }

    /// Optional layout pass using coalesced roster (UICoalescing output).
    @discardableResult
    func runLayoutPass(sizeClass: LayoutSizeClass) -> LayoutPlan {
        let roster = rosterTool.latestRosterSnapshot()
        let plan = layoutAgent.plan(roster: roster, sizeClass: sizeClass)
        lastLayout = plan
        log("agent: LayoutAdaptivityAgent mode=\(plan.mode.rawValue) cols=\(plan.columns) reason=\(plan.reason)")
        return plan
    }

    /// Convenience: bad-cell fixture used by the HUD research demo.
    @discardableResult
    func runBadNetworkDemo() -> CallQualityReport {
        runNetworkAdaptation(network: .badCell)
    }

    private func log(_ message: String) {
        let line = "[AgentOrchestrator] \(message)"
        logHandler?(line)
        print(line)
    }
}
