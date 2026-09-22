import Foundation

/// Applies `MediaKnobs` onto the existing `WebRTCClient` via **public** APIs only.
///
/// Mapping (`applyMediaPolicyLevel` is private on `WebRTCClient`):
/// - `level` N → `resetCongestion()` then `simulateCongestionStep()` N times (L0…L3 ladder).
/// - `preferAudio` → `setPreferAudio(true)` after steps (never call `setPreferAudio(false)`
///   after raising level — that resets to L0).
/// - `pauseVideoSend` / `pauseVideoRecv` follow the congestion ladder + prefer-audio policy
///   already implemented inside `WebRTCClient` (L2 pause send, L3 pause recv).
///
/// Status: `appendLog` is private — we append to `StatusLog` when provided and rely on
/// `statusLine` / `eventLog` published by the client after public calls.
@MainActor
final class WebRTCClientMediaKnobApplier: MediaKnobApplying {
    private let client: WebRTCClient
    private weak var statusLog: StatusLog?

    init(client: WebRTCClient, statusLog: StatusLog? = nil) {
        self.client = client
        self.statusLog = statusLog
    }

    func applyMediaKnobs(_ knobs: MediaKnobs) {
        let target = MediaKnobs.clampedLevel(knobs.level)

        client.resetCongestion()
        if target > 0 {
            for _ in 0..<target {
                client.simulateCongestionStep()
            }
        }

        if knobs.preferAudio {
            client.setPreferAudio(true)
        }

        let line =
            "[MediaKnobApplier] L\(target) preferAudio=\(knobs.preferAudio) " +
            "pauseSend=\(knobs.pauseVideoSend) pauseRecv=\(knobs.pauseVideoRecv) " +
            "reason=\(knobs.reason) → \(client.statusLine)"
        statusLog?.append(line)
    }
}

/// Observes published WebRTCClient HUD/log surface for AnalyticsAgent.
@MainActor
final class WebRTCClientStatsProvider: StatsProviding {
    private let client: WebRTCClient

    init(client: WebRTCClient) {
        self.client = client
    }

    func latestStatsLines() -> [String] {
        var lines: [String] = [
            client.statusLine,
            "mediaPolicyLevel=L\(client.mediaPolicyLevel)",
            "preferAudio=\(client.preferAudio)",
            "videoPaused send=\(client.videoPausedSend) recv=\(client.videoPausedRecv) reason=\(client.videoPauseReason)",
        ]
        lines.append(contentsOf: client.eventLog.prefix(8))
        return lines
    }
}
