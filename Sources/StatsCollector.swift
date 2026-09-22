import Foundation
import LiveKitWebRTC

/// Compact getStats snapshot for HUD + Export.
/// Values are meaningful only with a remote peer / LiveKit SFU answerer.
/// Solo mock (no remote answer) typically yields empty RTP / candidate-pair rows → HUD shows "n/a (no peer)".
struct CallStatsSnapshot: Equatable {
    var rttMs: Double?
    var lossPercent: Double?
    var jitterMs: Double?
    var bitrateKbps: Double?
    var framesPerSecond: Double?
    var frameWidth: Int?
    var frameHeight: Int?
    var pairState: String?
    var rawTypeCounts: [String: Int] = [:]
    var fetchedAt: Date?
    var hasPeerData: Bool = false

    static let empty = CallStatsSnapshot()

    var hudSummary: String {
        guard hasPeerData else { return "n/a (no peer)" }
        var parts: [String] = []
        if let rttMs { parts.append(String(format: "rtt=%.0fms", rttMs)) }
        if let lossPercent { parts.append(String(format: "loss=%.1f%%", lossPercent)) }
        if let jitterMs { parts.append(String(format: "jitter=%.1fms", jitterMs)) }
        if let bitrateKbps { parts.append(String(format: "br=%.0fkbps", bitrateKbps)) }
        if let framesPerSecond { parts.append(String(format: "fps=%.0f", framesPerSecond)) }
        if let w = frameWidth, let h = frameHeight { parts.append("\(w)x\(h)") }
        if let pairState { parts.append("pair=\(pairState)") }
        return parts.isEmpty ? "n/a (no peer)" : parts.joined(separator: " ")
    }

    func exportBlock() -> String {
        var lines: [String] = []
        lines.append("hasPeerData=\(hasPeerData)")
        if let fetchedAt {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            lines.append("fetchedAt=\(f.string(from: fetchedAt))")
        }
        lines.append("rttMs=\(rttMs.map { String(format: "%.1f", $0) } ?? "n/a")")
        lines.append("lossPercent=\(lossPercent.map { String(format: "%.2f", $0) } ?? "n/a")")
        lines.append("jitterMs=\(jitterMs.map { String(format: "%.2f", $0) } ?? "n/a")")
        lines.append("bitrateKbps=\(bitrateKbps.map { String(format: "%.1f", $0) } ?? "n/a")")
        lines.append("framesPerSecond=\(framesPerSecond.map { String(format: "%.1f", $0) } ?? "n/a")")
        lines.append("frame=\(frameWidth.map(String.init) ?? "n/a")x\(frameHeight.map(String.init) ?? "n/a")")
        lines.append("candidatePairState=\(pairState ?? "n/a")")
        if !rawTypeCounts.isEmpty {
            let sorted = rawTypeCounts.keys.sorted().map { "\($0)=\(rawTypeCounts[$0] ?? 0)" }
            lines.append("reportTypes: \(sorted.joined(separator: " "))")
        }
        lines.append("note: values become meaningful with a remote peer / LiveKit SFU answerer (solo mock → n/a)")
        return lines.joined(separator: "\n")
    }
}

/// Parses `LKRTCPeerConnection.statisticsWithCompletionHandler` reports (LiveKitWebRTC 150.x).
/// Stub: does not integrate LiveKit Cloud — call sites pass the local mock PC only.
enum StatsCollector {
    /// Previous sample for bitrate delta (bytes / time).
    private static var lastBytesSent: UInt64?
    private static var lastBytesRecv: UInt64?
    private static var lastSampleAt: Date?

    static func resetBaseline() {
        lastBytesSent = nil
        lastBytesRecv = nil
        lastSampleAt = nil
    }

    static func fetch(
        from peerConnection: LKRTCPeerConnection?,
        completion: @escaping (CallStatsSnapshot) -> Void
    ) {
        guard let pc = peerConnection else {
            resetBaseline()
            completion(.empty)
            return
        }
        pc.statistics { report in
            let snap = parse(report: report)
            DispatchQueue.main.async {
                completion(snap)
            }
        }
    }

    static func parse(report: LKRTCStatisticsReport?) -> CallStatsSnapshot {
        guard let report else { return .empty }

        var snap = CallStatsSnapshot()
        snap.fetchedAt = Date()
        var typeCounts: [String: Int] = [:]

        var packetsSent: UInt64 = 0
        var packetsLost: Int64 = 0
        var bytesSent: UInt64 = 0
        var bytesRecv: UInt64 = 0
        var jitterSum: Double = 0
        var jitterSamples = 0
        var sawRtp = false
        var sawPair = false

        for (_, stat) in report.statistics {
            let type = stat.type
            typeCounts[type, default: 0] += 1
            let values = stat.values

            switch type {
            case "outbound-rtp":
                sawRtp = true
                if let n = number(values, "packetsSent") { packetsSent += UInt64(n.uint64Value) }
                if let n = number(values, "bytesSent") { bytesSent += UInt64(n.uint64Value) }
                if let n = number(values, "framesPerSecond") {
                    snap.framesPerSecond = max(snap.framesPerSecond ?? 0, n.doubleValue)
                }
                if let n = number(values, "frameWidth") { snap.frameWidth = n.intValue }
                if let n = number(values, "frameHeight") { snap.frameHeight = n.intValue }

            case "inbound-rtp":
                sawRtp = true
                if let n = number(values, "packetsLost") { packetsLost += n.int64Value }
                if let n = number(values, "packetsReceived") {
                    // included in loss% denominator via sent+recv approximation below
                    _ = n
                }
                if let n = number(values, "bytesReceived") { bytesRecv += UInt64(n.uint64Value) }
                if let n = number(values, "jitter") {
                    // WebRTC jitter is seconds
                    jitterSum += n.doubleValue * 1000.0
                    jitterSamples += 1
                }
                if let n = number(values, "framesPerSecond") {
                    snap.framesPerSecond = max(snap.framesPerSecond ?? 0, n.doubleValue)
                }
                if let n = number(values, "frameWidth") { snap.frameWidth = n.intValue }
                if let n = number(values, "frameHeight") { snap.frameHeight = n.intValue }

            case "remote-inbound-rtp":
                sawRtp = true
                if let n = number(values, "roundTripTime") {
                    // seconds → ms
                    snap.rttMs = n.doubleValue * 1000.0
                }
                if let n = number(values, "packetsLost") { packetsLost += n.int64Value }
                if let n = number(values, "jitter") {
                    jitterSum += n.doubleValue * 1000.0
                    jitterSamples += 1
                }
                if let n = number(values, "fractionLost") {
                    snap.lossPercent = n.doubleValue * 100.0
                }

            case "candidate-pair":
                let nominated = bool(values, "nominated") ?? false
                let selected = bool(values, "selected") ?? false
                let state = string(values, "state")
                if nominated || selected || state == "succeeded" {
                    sawPair = true
                    snap.pairState = state
                    if let n = number(values, "currentRoundTripTime") {
                        snap.rttMs = n.doubleValue * 1000.0
                    }
                    if let n = number(values, "availableOutgoingBitrate") {
                        // bits/s → kbps
                        snap.bitrateKbps = n.doubleValue / 1000.0
                    }
                }

            default:
                break
            }
        }

        snap.rawTypeCounts = typeCounts

        if jitterSamples > 0 {
            snap.jitterMs = jitterSum / Double(jitterSamples)
        }

        // Loss%: prefer remote-inbound fractionLost; else packetsLost / packetsSent.
        if snap.lossPercent == nil, packetsSent > 0, packetsLost >= 0 {
            snap.lossPercent = (Double(packetsLost) / Double(packetsSent)) * 100.0
        }

        // Bitrate estimate from bytes delta when pair didn't supply availableOutgoingBitrate.
        let now = Date()
        if snap.bitrateKbps == nil {
            let totalBytes = bytesSent + bytesRecv
            if let prevAt = lastSampleAt,
               let prevSent = lastBytesSent,
               let prevRecv = lastBytesRecv {
                let dt = now.timeIntervalSince(prevAt)
                if dt > 0.2 {
                    let dBytes = Double((bytesSent &- prevSent) &+ (bytesRecv &- prevRecv))
                    snap.bitrateKbps = (dBytes * 8.0 / dt) / 1000.0
                    _ = totalBytes
                }
            }
        }
        lastBytesSent = bytesSent
        lastBytesRecv = bytesRecv
        lastSampleAt = now

        snap.hasPeerData = sawRtp || sawPair || snap.rttMs != nil || snap.bitrateKbps != nil
            || snap.framesPerSecond != nil || snap.frameWidth != nil
        // Solo mock often still has outbound-rtp with local-only numbers — treat "no remote"
        // when there is no candidate-pair / remote-inbound and no inbound bytes.
        if sawRtp && !sawPair && bytesRecv == 0 && snap.rttMs == nil {
            // Keep parsed outbound fps/size if present, but mark HUD as no-peer when nothing remote-ish.
            if snap.framesPerSecond == nil && snap.frameWidth == nil {
                snap.hasPeerData = false
            }
        }

        return snap
    }

    private static func number(_ values: [String: NSObject], _ key: String) -> NSNumber? {
        values[key] as? NSNumber
    }

    private static func string(_ values: [String: NSObject], _ key: String) -> String? {
        values[key] as? String
    }

    private static func bool(_ values: [String: NSObject], _ key: String) -> Bool? {
        if let n = values[key] as? NSNumber { return n.boolValue }
        if let s = values[key] as? String {
            return s == "true" || s == "1"
        }
        return nil
    }
}
