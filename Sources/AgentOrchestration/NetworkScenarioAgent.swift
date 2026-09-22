import Foundation

/// Deterministic mapping: `NetworkSnapshot` → `MediaKnobs` (L0–L3 / preferAudio).
/// No LLM — pure thresholds so bad-network demos are reproducible.
struct NetworkScenarioAgent {
    struct Thresholds: Equatable, Sendable {
        var lossL1: Double = 2.0
        var lossL2: Double = 5.0
        var lossL3: Double = 12.0
        var rttL1Ms: Double = 150
        var rttL2Ms: Double = 300
        var rttL3Ms: Double = 500
        var bwL2Kbps: Double = 400
        var bwL3Kbps: Double = 150
    }

    var thresholds: Thresholds = .init()

    func decide(from network: NetworkSnapshot) -> MediaKnobs {
        guard network.pathSatisfied else {
            return MediaKnobs(
                level: 3,
                preferAudio: true,
                pauseVideoSend: true,
                pauseVideoRecv: true,
                reason: "path_unsatisfied"
            )
        }

        let loss = network.lossPercent ?? 0
        let rtt = network.rttMs ?? 0
        let bw = network.estimatedBandwidthKbps ?? .infinity

        var level = 0
        if loss >= thresholds.lossL3 || rtt >= thresholds.rttL3Ms || bw <= thresholds.bwL3Kbps {
            level = 3
        } else if loss >= thresholds.lossL2 || rtt >= thresholds.rttL2Ms || bw <= thresholds.bwL2Kbps {
            level = 2
        } else if loss >= thresholds.lossL1 || rtt >= thresholds.rttL1Ms || network.isConstrained {
            level = 1
        }

        if network.isExpensive && level < 1 {
            level = 1
        }

        level = MediaKnobs.clampedLevel(level)

        switch level {
        case 0:
            return .l0
        case 1:
            return MediaKnobs(
                level: 1,
                preferAudio: false,
                pauseVideoSend: false,
                pauseVideoRecv: false,
                reason: "soft_degrade"
            )
        case 2:
            return MediaKnobs(
                level: 2,
                preferAudio: true,
                pauseVideoSend: true,
                pauseVideoRecv: false,
                reason: "protect_audio"
            )
        default:
            return MediaKnobs(
                level: 3,
                preferAudio: true,
                pauseVideoSend: true,
                pauseVideoRecv: true,
                reason: "severe_network"
            )
        }
    }
}
