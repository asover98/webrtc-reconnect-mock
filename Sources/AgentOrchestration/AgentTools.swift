import Foundation

// MARK: - Shared knob / report models (wrappers around existing mock concepts)

/// Media degradation knobs aligned with the mock's L0–L3 congestion ladder + preferAudio.
struct MediaKnobs: Equatable, Sendable {
    /// 0...3 — same semantics as `WebRTCClient.mediaPolicyLevel`.
    var level: Int
    var preferAudio: Bool
    var pauseVideoSend: Bool
    var pauseVideoRecv: Bool
    var reason: String

    static let l0 = MediaKnobs(
        level: 0,
        preferAudio: false,
        pauseVideoSend: false,
        pauseVideoRecv: false,
        reason: "full_av"
    )

    static func clampedLevel(_ value: Int) -> Int {
        min(3, max(0, value))
    }
}

struct NetworkSnapshot: Equatable, Sendable {
    var pathSatisfied: Bool
    var isExpensive: Bool
    var isConstrained: Bool
    var rttMs: Double?
    var lossPercent: Double?
    var estimatedBandwidthKbps: Double?

    static let healthy = NetworkSnapshot(
        pathSatisfied: true,
        isExpensive: false,
        isConstrained: false,
        rttMs: 40,
        lossPercent: 0.2,
        estimatedBandwidthKbps: 2_500
    )

    static let badCell = NetworkSnapshot(
        pathSatisfied: true,
        isExpensive: true,
        isConstrained: true,
        rttMs: 380,
        lossPercent: 8.5,
        estimatedBandwidthKbps: 180
    )
}

struct CallQualityReport: Equatable, Sendable {
    var score: Double // 0...1
    var summary: String
    var sampleCount: Int
    var lastLevel: Int?
    var generatedAt: Date
}

// MARK: - Tool protocols (Agent = decide, Tool = apply / observe)

protocol MediaKnobApplying: AnyObject {
    func applyMediaKnobs(_ knobs: MediaKnobs)
}

protocol StatsProviding: AnyObject {
    func latestStatsLines() -> [String]
}

protocol RosterSnapshotProviding: AnyObject {
    func latestRosterSnapshot() -> TileRosterSnapshot
}

// MARK: - Logging stub tools (safe defaults for demo / compile)

final class LoggingMediaKnobApplier: MediaKnobApplying {
    private(set) var lastApplied: MediaKnobs?
    var logHandler: ((String) -> Void)?

    func applyMediaKnobs(_ knobs: MediaKnobs) {
        lastApplied = knobs
        let line = "[AgentTool] applyMediaKnobs L\(knobs.level) preferAudio=\(knobs.preferAudio) pauseSend=\(knobs.pauseVideoSend) pauseRecv=\(knobs.pauseVideoRecv) reason=\(knobs.reason)"
        logHandler?(line)
        print(line)
    }
}

final class LoggingStatsProvider: StatsProviding {
    var lines: [String] = []
    func latestStatsLines() -> [String] { lines }
}

final class LoggingRosterProvider: RosterSnapshotProviding {
    var snapshot: TileRosterSnapshot = .empty
    func latestRosterSnapshot() -> TileRosterSnapshot { snapshot }
}
