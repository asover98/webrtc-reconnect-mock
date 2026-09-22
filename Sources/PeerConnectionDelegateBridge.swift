import Foundation
import LiveKitWebRTC

/// Counts of local ICE candidates by `typ` (host / srflx / relay / other).
struct ICECandidateTypeCounts: Equatable {
    var host: Int = 0
    var srflx: Int = 0
    var relay: Int = 0
    var other: Int = 0

    var total: Int { host + srflx + relay + other }

    var summaryLine: String {
        "ICE candidates summary host=\(host) srflx=\(srflx) relay=\(relay) other=\(other)"
    }

    mutating func add(sdp: String) {
        let typ = Self.extractTyp(from: sdp)
        switch typ {
        case "host": host += 1
        case "srflx": srflx += 1
        case "relay": relay += 1
        default: other += 1
        }
    }

    static func extractTyp(from sdp: String) -> String {
        // candidate:... typ host ...
        let parts = sdp.split(separator: " ")
        if let idx = parts.firstIndex(of: "typ"), parts.index(after: idx) < parts.endIndex {
            return String(parts[parts.index(after: idx)])
        }
        return "other"
    }
}

/// ObjC-compatible bridge: LKRTCPeerConnectionDelegate → StatusLog on MainActor.
final class PeerConnectionDelegateBridge: NSObject, LKRTCPeerConnectionDelegate {
    private weak var log: StatusLog?

    /// When true, every local ICE candidate is logged (spammy). Default OFF — prefer summary.
    var verboseICECandidates: Bool = false

    private(set) var candidateCounts = ICECandidateTypeCounts()
    private var candidatesSinceLastSummary = 0
    private let summaryEveryN = 8

    var onIceConnectionChange: ((LKRTCIceConnectionState) -> Void)?
    var onIceGatheringChange: ((LKRTCIceGatheringState) -> Void)?
    var onConnectionStateChange: ((LKRTCPeerConnectionState) -> Void)?
    var onSignalingChange: ((LKRTCSignalingState) -> Void)?
    var onCandidateCountsChange: ((ICECandidateTypeCounts) -> Void)?

    init(log: StatusLog) {
        self.log = log
        super.init()
    }

    func resetCandidateCounts() {
        candidateCounts = ICECandidateTypeCounts()
        candidatesSinceLastSummary = 0
    }

    private func emit(_ message: String) {
        Task { @MainActor in
            self.log?.append(message)
        }
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didChange stateChanged: LKRTCSignalingState
    ) {
        emit("signalingState → \(Self.signalingName(stateChanged))")
        onSignalingChange?(stateChanged)
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {
        emit("didAddStream (\(stream.streamId))")
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {
        emit("didRemoveStream (\(stream.streamId))")
    }

    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {
        emit("shouldNegotiate (e.g. after restartIce)")
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didChange newState: LKRTCIceConnectionState
    ) {
        emit("iceConnectionState → \(Self.iceConnectionName(newState))")
        onIceConnectionChange?(newState)
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didChange newState: LKRTCIceGatheringState
    ) {
        emit("iceGatheringState → \(Self.iceGatheringName(newState))")
        if newState == .complete, candidateCounts.total > 0 {
            emit(candidateCounts.summaryLine)
            candidatesSinceLastSummary = 0
        }
        onIceGatheringChange?(newState)
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didChange newState: LKRTCPeerConnectionState
    ) {
        emit("connectionState → \(Self.connectionName(newState))")
        onConnectionStateChange?(newState)
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didGenerate candidate: LKRTCIceCandidate
    ) {
        candidateCounts.add(sdp: candidate.sdp)
        candidatesSinceLastSummary += 1
        onCandidateCountsChange?(candidateCounts)

        if verboseICECandidates {
            let preview = String(candidate.sdp.prefix(80))
            emit("local ICE candidate: \(preview)…")
        } else if candidatesSinceLastSummary >= summaryEveryN {
            emit(candidateCounts.summaryLine)
            candidatesSinceLastSummary = 0
        }
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didRemove candidates: [LKRTCIceCandidate]
    ) {
        emit("removed \(candidates.count) ICE candidate(s)")
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didOpen dataChannel: LKRTCDataChannel
    ) {
        emit("dataChannel opened: \(dataChannel.label)")
    }

    // MARK: - Name helpers

    static func signalingName(_ state: LKRTCSignalingState) -> String {
        switch state {
        case .stable: return "stable"
        case .haveLocalOffer: return "haveLocalOffer"
        case .haveLocalPrAnswer: return "haveLocalPrAnswer"
        case .haveRemoteOffer: return "haveRemoteOffer"
        case .haveRemotePrAnswer: return "haveRemotePrAnswer"
        case .closed: return "closed"
        @unknown default: return "unknown(\(state.rawValue))"
        }
    }

    static func iceConnectionName(_ state: LKRTCIceConnectionState) -> String {
        switch state {
        case .new: return "new"
        case .checking: return "checking"
        case .connected: return "connected"
        case .completed: return "completed"
        case .failed: return "failed"
        case .disconnected: return "disconnected"
        case .closed: return "closed"
        case .count: return "count"
        @unknown default: return "unknown(\(state.rawValue))"
        }
    }

    static func iceGatheringName(_ state: LKRTCIceGatheringState) -> String {
        switch state {
        case .new: return "new"
        case .gathering: return "gathering"
        case .complete: return "complete"
        @unknown default: return "unknown(\(state.rawValue))"
        }
    }

    static func connectionName(_ state: LKRTCPeerConnectionState) -> String {
        switch state {
        case .new: return "new"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .disconnected: return "disconnected"
        case .failed: return "failed"
        case .closed: return "closed"
        @unknown default: return "unknown(\(state.rawValue))"
        }
    }
}
