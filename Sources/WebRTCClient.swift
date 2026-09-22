import Foundation
import Combine
import UIKit
@preconcurrency import AVFoundation
@preconcurrency import LiveKitWebRTC

/// ADR recovery branches (logged next to cursor / ufrag / mids).
enum RecoveryBranch: String {
    case idle
    case none
    case signalOnly = "signal_only"
    case iceRestart = "ice_restart"
    case resumeThenRestart = "resume_then_restart"
    case hardRecycle = "hard_recycle"
}

/// One completed scenario timing (action → completion).
struct MetricRecord: Identifiable, Equatable {
    let id: UUID
    let name: String
    let startedAt: Date
    let completedAt: Date
    let deltaMs: Int
    let note: String
}

/// Thin client around LiveKit's LK-prefixed WebRTC xcframework.
/// Join → signaling connect (mock://local) → PC + local A/V (when hardware exists).
/// Path loss / Force Reconnect runs WS resume then ICE restart per ADR ladder.
/// Baseline: no LiveKit Cloud.
@MainActor
final class WebRTCClient: ObservableObject {
    // MARK: - HUD / research logs
    @Published private(set) var statusLine: String = "WebRTC not initialized"
    @Published private(set) var callSessionId: String = "—"
    @Published private(set) var signalCursor: Int = 0
    @Published private(set) var lastBranch: RecoveryBranch = .idle
    @Published private(set) var iceUfrag: String = "—"
    @Published private(set) var midList: [String] = []
    @Published private(set) var mediaPolicyLevel: Int = 0
    @Published private(set) var videoPausedSend: Bool = false
    @Published private(set) var videoPausedRecv: Bool = false
    @Published private(set) var videoPauseReason: String = "none"
    @Published private(set) var preferAudio: Bool = false
    @Published private(set) var pathDescription: String = "path: unknown"
    @Published private(set) var eventLog: [String] = []
    @Published private(set) var signalingStateText: String = "disconnected"
    @Published private(set) var iceConnectionStateText: String = "—"
    @Published private(set) var iceGatheringStateText: String = "—"
    @Published private(set) var pcSignalingStateText: String = "—"
    @Published private(set) var connectionStateText: String = "—"
    @Published private(set) var candidateCounts = ICECandidateTypeCounts()
    /// getStats stub snapshot — "n/a (no peer)" until remote/SFU answerer exists.
    @Published private(set) var callStats: CallStatsSnapshot = .empty

    // Local preview / capture
    @Published private(set) var captureSession: AVCaptureSession?
    @Published private(set) var cameraActive: Bool = false
    @Published private(set) var cameraStatus: String = "idle"
    @Published private(set) var micActive: Bool = false

    // Metrics HUD
    @Published private(set) var lastMetricName: String = "—"
    @Published private(set) var lastMetricDeltaMs: Int?
    @Published private(set) var metricRecords: [MetricRecord] = []

    let pathMonitor: NetworkPathMonitor
    let signaling: SignalingClient

    private let log: StatusLog
    private var peerConnectionFactory: LKRTCPeerConnectionFactory?
    private var peerConnection: LKRTCPeerConnection?
    private var pcDelegate: PeerConnectionDelegateBridge?
    private var iceRestartAttempts: Int = 0
    private let iceRestartBudget = 3
    private var roomName: String = ""
    private var joined = false
    private var pathDebounceTask: Task<Void, Never>?
    private var lastPathSatisfied: Bool?
    /// Stub mid map until SDP assigns real mids (ADR-004 appTrackId→mid).
    private var appTrackIdToMid: [String: String] = [:]
    private var cancellables = Set<AnyCancellable>()

    // Local media (survives PC recycle)
    private var videoSource: LKRTCVideoSource?
    private var audioSource: LKRTCAudioSource?
    private var localVideoTrack: LKRTCVideoTrack?
    private var localAudioTrack: LKRTCAudioTrack?
    private var cameraCapturer: LKRTCCameraVideoCapturer?
    private var mediaAttachTask: Task<Void, Never>?
    private var hudPollTask: Task<Void, Never>?

    // Open scenario timers: name → start
    private var openMetrics: [String: Date] = [:]
    private var lastCongestionAt: Date?
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(log: StatusLog) {
        self.log = log
        self.pathMonitor = NetworkPathMonitor(log: log)
        self.signaling = SignalingClient(log: log)

        LKRTCInitializeSSL()
        let encoderFactory = LKRTCDefaultVideoEncoderFactory()
        let decoderFactory = LKRTCDefaultVideoDecoderFactory()
        peerConnectionFactory = LKRTCPeerConnectionFactory(
            encoderFactory: encoderFactory,
            decoderFactory: decoderFactory
        )
        statusLine = "Factory ready (LiveKitWebRTC)"
        appendLog("init: factory ready")

        pathMonitor.start()
        pathMonitor.$pathDescription
            .receive(on: RunLoop.main)
            .sink { [weak self] desc in
                guard let self else { return }
                self.pathDescription = desc
                self.handlePathDescriptionChange(desc)
            }
            .store(in: &cancellables)

        signaling.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.signalingStateText = state.rawValue
            }
            .store(in: &cancellables)

        signaling.$lastEventCursor
            .receive(on: RunLoop.main)
            .sink { [weak self] cursor in
                self?.signalCursor = cursor
            }
            .store(in: &cancellables)

        signaling.$callSessionId
            .receive(on: RunLoop.main)
            .sink { [weak self] sid in
                guard let self, let sid, !sid.isEmpty else { return }
                if self.callSessionId == "—" || self.callSessionId.isEmpty {
                    self.callSessionId = sid
                }
            }
            .store(in: &cancellables)

        signaling.onMessage = { [weak self] msg in
            Task { @MainActor in
                self?.handleSignalingMessage(msg)
            }
        }
    }

    // MARK: - Join / leave

    func join(room: String) {
        roomName = room
        joined = true
        if callSessionId == "—" || callSessionId.isEmpty {
            callSessionId = UUID().uuidString.lowercased()
        }
        iceRestartAttempts = 0
        mediaPolicyLevel = 0
        videoPausedSend = false
        videoPausedRecv = false
        videoPauseReason = "none"
        preferAudio = false
        lastBranch = .idle
        lastCongestionAt = nil

        signaling.connect(url: SignalingClient.mockURL, room: room)

        guard createPeerConnection(reason: "join") else {
            statusLine = "Join failed — PC create failed (\(room))"
            appendLog("join FAIL room=\(room)")
            return
        }

        appTrackIdToMid = [
            "local-audio": "0",
            "local-video": "1"
        ]
        midList = ["0", "1"]
        refreshUfragFromLocalDescription()
        statusLine = "Joined stub room=\(room) session=\(shortSession) — attaching local media"
        appendLog("join OK room=\(room) callSessionId=\(callSessionId) signaling=mock://local")
        publishHUD()

        StatsCollector.resetBaseline()
        callStats = .empty
        candidateCounts = ICECandidateTypeCounts()

        mediaAttachTask?.cancel()
        mediaAttachTask = Task { @MainActor [weak self] in
            await self?.attachLocalMedia(reason: "join")
        }
        startHUDPoll()
    }

    func leave() {
        joined = false
        pathDebounceTask?.cancel()
        mediaAttachTask?.cancel()
        stopHUDPoll()
        signaling.disconnect()
        signaling.resetSession()
        stopLocalMedia()
        peerConnection?.close()
        peerConnection = nil
        pcDelegate = nil
        midList = []
        iceUfrag = "—"
        callSessionId = "—"
        iceGatheringStateText = "—"
        connectionStateText = "—"
        iceConnectionStateText = "—"
        pcSignalingStateText = "—"
        candidateCounts = ICECandidateTypeCounts()
        callStats = .empty
        StatsCollector.resetBaseline()
        statusLine = "Left room"
        appendLog("leave")
        publishHUD()
    }

    // MARK: - ADR-003 force buttons

    /// Force signal drop → `signal_only` (WS resume; no ICE restart).
    /// Metric: drop → resumeAck.
    func forceSignalDrop() {
        guard joined else {
            statusLine = "Signal drop ignored — not joined"
            return
        }
        lastBranch = .signalOnly
        beginMetric("signal_only")
        signaling.simulateDrop()
        statusLine = "signal_only: WS resume+cursor (no ICE) cursor=\(signalCursor)"
        appendLog(
            "branch=signal_only callSessionId=\(callSessionId) cursor=\(signalCursor) ufrag=\(iceUfrag) mids=\(midList)"
        )
        publishHUD()
    }

    /// Full ladder step: signaling resume then ICE restart (ADR primary path).
    func forceReconnect() {
        guard joined else {
            statusLine = "Force reconnect ignored — not joined"
            return
        }
        lastBranch = .resumeThenRestart
        appendLog("branch=resume_then_restart begin callSessionId=\(callSessionId) cursor=\(signalCursor)")
        statusLine = "resume_then_restart: signaling resume → ICE restart"
        runResumeThenICERestart(reason: "force_reconnect")
        publishHUD()
    }

    /// Force ICE restart → same PC / callSessionId / mids; iceRestart offer.
    /// Metric: start → ice connected / setLocal success.
    func forceICERestart() {
        guard peerConnection != nil else {
            statusLine = "ICE restart ignored — not joined"
            return
        }
        performICERestart(reason: "manual")
    }

    /// Hard reconnect → new PC; keep callSessionId (grace); republish same tracks.
    /// Metric: start → new PC ready.
    func hardReconnect(reason: String = "manual") {
        lastBranch = .hardRecycle
        beginMetric("hard_recycle")
        peerConnection?.close()
        peerConnection = nil
        pcDelegate = nil
        iceRestartAttempts = 0
        midList = []
        iceUfrag = "—"

        if signaling.state != .connected {
            signaling.connect(url: SignalingClient.mockURL, room: roomName)
        }

        guard createPeerConnection(reason: "hard_recycle:\(reason)") else {
            statusLine = "hard_recycle PC create failed"
            appendLog("branch=hard_recycle FAIL reason=\(reason)")
            publishHUD()
            return
        }
        attachExistingTracksToPeerConnection()
        appTrackIdToMid = [
            "local-audio": "0",
            "local-video": "1"
        ]
        midList = ["0", "1"]
        refreshUfragFromLocalDescription()
        refreshMidsFromPC()
        completeMetric("hard_recycle", note: "new PC ready")
        statusLine = "hard_recycle new PC keep session=\(shortSession) reason=\(reason)"
        appendLog(
            "branch=hard_recycle reason=\(reason) callSessionId=\(callSessionId) cursor=\(signalCursor) ufrag=\(iceUfrag) mids=\(midList) tracks=\(Array(appTrackIdToMid.keys).sorted())"
        )
        publishHUD()
    }

    /// Prefer-audio policy — pause local video send (track.isEnabled) + log intent.
    func setPreferAudio(_ enabled: Bool) {
        preferAudio = enabled
        if enabled {
            videoPauseReason = "prefer_audio_policy"
            videoPausedSend = true
            if mediaPolicyLevel < 2 { mediaPolicyLevel = 2 }
            localVideoTrack?.isEnabled = false
            statusLine = "prefer-audio ON — protect audio, pause video send"
            appendLog(
                "preferAudio=true policy=protect_audio pause_video_send mediaPolicyLevel=L\(mediaPolicyLevel)"
            )
        } else {
            videoPauseReason = "none"
            videoPausedSend = false
            videoPausedRecv = false
            mediaPolicyLevel = 0
            localVideoTrack?.isEnabled = true
            statusLine = "prefer-audio OFF — full A/V allowed"
            appendLog("preferAudio=false policy=full_av mediaPolicyLevel=L0")
        }
        if signaling.state == .connected {
            signaling.send(SignalingMessage(
                type: "preferAudio",
                room: roomName,
                callSessionId: signaling.callSessionId,
                cursor: signaling.lastEventCursor,
                reconnect: nil,
                ok: nil,
                reason: enabled ? "enable" : "disable",
                preferAudio: enabled,
                reconnectReason: nil
            ))
        }
        publishHUD()
    }

    /// Prefer-audio ladder only — never arms ICE restart (ADR-004).
    /// Metric: level changes L0–L3 with branch=none.
    func simulateCongestionStep() {
        guard peerConnection != nil else {
            statusLine = "Congestion ignored — not joined"
            return
        }
        lastBranch = .none
        let previous = mediaPolicyLevel
        if mediaPolicyLevel < 3 {
            mediaPolicyLevel += 1
        }
        applyMediaPolicyLevel()
        recordCongestionMetric(from: previous, to: mediaPolicyLevel)
        statusLine = "congestion L\(mediaPolicyLevel) (no ICE) reason=\(videoPauseReason) branch=none"
        appendLog(
            "mediaPolicyLevel=L\(mediaPolicyLevel) videoPaused send=\(videoPausedSend) recv=\(videoPausedRecv) reason=\(videoPauseReason) preferAudio=\(preferAudio) branch=none"
        )
        publishHUD()
    }

    func resetCongestion() {
        lastBranch = .none
        let previous = mediaPolicyLevel
        mediaPolicyLevel = 0
        applyMediaPolicyLevel()
        recordCongestionMetric(from: previous, to: 0)
        statusLine = "mediaPolicyLevel=L0 branch=none"
        appendLog("mediaPolicyLevel=L0 reset preferAudio=false branch=none")
        publishHUD()
    }

    // MARK: - Export

    /// Write StatusLog + metrics deltas to a temp .txt for the share sheet.
    func writeExportFile() -> URL? {
        let rawStamp = isoFormatter.string(from: Date())
        let safeStamp = rawStamp
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebRTCReconnectMock-\(safeStamp).txt")

        var out = "WebRTCReconnectMock export (baseline, no LiveKit Cloud)\n"
        out += "exportedAt=\(rawStamp)\n"
        out += "callSessionId=\(callSessionId) cursor=\(signalCursor) branch=\(lastBranch.rawValue)\n\n"

        out += "=== ICE/SDP snapshot ===\n"
        out += "iceConnectionState=\(iceConnectionStateText)\n"
        out += "iceGatheringState=\(iceGatheringStateText)\n"
        out += "signalingState(ws)=\(signalingStateText)\n"
        out += "pcSignalingState=\(pcSignalingStateText)\n"
        out += "connectionState=\(connectionStateText)\n"
        out += "ufrag=\(iceUfrag)\n"
        out += "mids=\(midList.joined(separator: ","))\n"
        out += "branch=\(lastBranch.rawValue)\n"
        out += "mediaPolicyLevel=L\(mediaPolicyLevel)\n"
        out += "callSessionId=\(callSessionId)\n"
        out += "cursor=\(signalCursor)\n\n"

        out += "=== Candidate summary ===\n"
        out += candidateCounts.summaryLine + "\n"
        out += "(raw per-candidate StatusLog lines gated; verboseICECandidates default OFF)\n\n"

        out += "=== getStats (stub) ===\n"
        out += callStats.exportBlock() + "\n\n"

        out += "=== Metrics deltas ===\n"
        if metricRecords.isEmpty {
            out += "(none yet — Join, then tap a scenario button)\n"
        } else {
            for r in metricRecords {
                out += "\(r.name)\tdelta=\(r.deltaMs)ms\t\(r.note)\tstart=\(isoFormatter.string(from: r.startedAt))\tend=\(isoFormatter.string(from: r.completedAt))\n"
            }
        }
        if let last = lastMetricDeltaMs {
            out += "\nlastMetric=\(lastMetricName) lastDelta=\(last)ms\n"
        }
        out += "\n=== StatusLog ===\n"
        out += log.joinedText()
        out += "\n"

        // Always dump full export to Xcode console so it can be pasted into chat for analysis.
        print("=== WebRTCReconnectMock EXPORT BEGIN ===")
        print(out)
        print("=== WebRTCReconnectMock EXPORT END ===")
        UIPasteboard.general.string = out

        do {
            try out.write(to: url, atomically: true, encoding: .utf8)
            appendLog("export wrote \(url.lastPathComponent) + console print + pasteboard")
            return url
        } catch {
            appendLog("export FAIL \(error.localizedDescription) (console/pasteboard still filled)")
            return nil
        }
    }

    // MARK: - Ladder helpers

    private func runResumeThenICERestart(reason: String) {
        appendLog("ladder[\(reason)]: step1 signaling resume session=\(signaling.callSessionId ?? "nil") cursor=\(signaling.lastEventCursor)")

        switch signaling.state {
        case .disconnected, .reconnecting, .connecting:
            signaling.connect(url: SignalingClient.mockURL, room: roomName)
        case .connected:
            signaling.sendResumeHandshake(reconnectReason: "forced")
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            appendLog("ladder[\(reason)]: step2 ICE restart")
            self.performICERestart(reason: "after_resume:\(reason)")
        }
    }

    private func performICERestart(reason: String) {
        guard let pc = peerConnection else {
            statusLine = "ICE restart ignored — no PC"
            appendLog("ice_restart skipped — no PC reason=\(reason)")
            return
        }
        if iceRestartAttempts >= iceRestartBudget {
            appendLog("ICE restart budget exhausted → escalate hard_recycle")
            hardReconnect(reason: "ice_restart_budget")
            return
        }

        if lastBranch != .resumeThenRestart {
            lastBranch = .iceRestart
        }
        iceRestartAttempts += 1
        beginMetric("ice_restart")

        pc.restartIce()
        appendLog("restartIce() called reason=\(reason) attempt=\(iceRestartAttempts)")

        let constraints = LKRTCMediaConstraints(
            mandatoryConstraints: ["IceRestart": "true"],
            optionalConstraints: nil
        )
        pc.offer(for: constraints) { [weak self] sdp, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.statusLine = "ice_restart offer failed: \(error.localizedDescription)"
                    self.appendLog("ice_restart FAIL \(error.localizedDescription)")
                    self.publishHUD()
                    return
                }
                guard let sdp else {
                    self.statusLine = "ice_restart offer failed: nil SDP"
                    self.appendLog("ice_restart FAIL nil SDP")
                    self.publishHUD()
                    return
                }
                pc.setLocalDescription(sdp) { [weak self] setError in
                    Task { @MainActor in
                        guard let self else { return }
                        if let setError {
                            self.statusLine = "ice_restart setLocal failed: \(setError.localizedDescription)"
                            self.appendLog("ice_restart setLocal FAIL \(setError.localizedDescription)")
                        } else {
                            self.refreshUfragFromLocalDescription()
                            self.refreshMidsFromPC()
                            // Local-only mock: ICE rarely reaches "connected" without a remote answer.
                            // Complete on setLocal success; label agreed as localOfferApplied / setLocal(iceRestart).
                            // ice-connected may still complete open ice_restart if it lands first.
                            self.completeMetric(
                                "ice_restart",
                                note: "setLocal(iceRestart)",
                                displayAs: "localOfferApplied"
                            )
                            self.statusLine = "ice_restart #\(self.iceRestartAttempts) same PC session=\(self.shortSession)"
                            self.appendLog(
                                "branch=\(self.lastBranch.rawValue) attempt=\(self.iceRestartAttempts) callSessionId=\(self.callSessionId) cursor=\(self.signalCursor) ufrag=\(self.iceUfrag) mids=\(self.midList) reason=\(reason)"
                            )
                            if self.signaling.state == .connected {
                                self.signaling.send(SignalingMessage(
                                    type: "iceRestartOffer",
                                    room: self.roomName,
                                    callSessionId: self.signaling.callSessionId,
                                    cursor: self.signaling.lastEventCursor,
                                    reconnect: nil,
                                    ok: nil,
                                    reason: reason,
                                    preferAudio: self.preferAudio,
                                    reconnectReason: nil
                                ))
                            }
                        }
                        self.publishHUD()
                    }
                }
            }
        }
    }

    private func handlePathDescriptionChange(_ desc: String) {
        guard joined else { return }
        let satisfied = desc.contains("satisfied")
        defer { lastPathSatisfied = satisfied }

        guard let previous = lastPathSatisfied else { return }

        if previous && !satisfied {
            appendLog("path loss detected — debounce before ladder")
            pathDebounceTask?.cancel()
            pathDebounceTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled, self.joined else { return }
                self.lastBranch = .resumeThenRestart
                self.statusLine = "path loss → resume_then_restart"
                self.runResumeThenICERestart(reason: "path_loss")
                self.publishHUD()
            }
        } else if !previous && satisfied {
            appendLog("path recovered — ensure signaling + ICE restart")
            pathDebounceTask?.cancel()
            pathDebounceTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled, self.joined else { return }
                self.lastBranch = .resumeThenRestart
                self.statusLine = "path recover → resume_then_restart"
                self.runResumeThenICERestart(reason: "path_recover")
                self.publishHUD()
            }
        }
    }

    private func handleSignalingMessage(_ msg: SignalingMessage) {
        switch msg.type {
        case "joinAck":
            if let sid = msg.callSessionId {
                callSessionId = sid
            }
            statusLine = "signaling joinAck session=\(shortSession) cursor=\(msg.cursor ?? 0)"
        case "resumeAck":
            if msg.ok == false {
                appendLog("resumeAck rejected → will need full rejoin/recycle")
                completeMetric("signal_only", note: "resumeAck rejected")
            } else {
                appendLog("resumeAck ok session=\(msg.callSessionId ?? "?") cursor=\(msg.cursor ?? -1)")
                completeMetric("signal_only", note: "resumeAck")
            }
        default:
            break
        }
        publishHUD()
    }

    private func handleIceConnectionState(_ state: LKRTCIceConnectionState) {
        iceConnectionStateText = PeerConnectionDelegateBridge.iceConnectionName(state)
        if state == .connected || state == .completed {
            completeMetric("ice_restart", note: "ice \(iceConnectionStateText)")
        }
    }

    // MARK: - Local camera + mic

    private func attachLocalMedia(reason: String) async {
        guard let factory = peerConnectionFactory else { return }

        activateAudioSession()

        let camOK = await requestAccess(.video)
        let micOK = await requestAccess(.audio)
        appendLog("permissions camera=\(camOK) mic=\(micOK) reason=\(reason)")

        if micOK {
            if audioSource == nil {
                audioSource = factory.audioSource(with: nil)
            }
            if localAudioTrack == nil, let audioSource {
                localAudioTrack = factory.audioTrack(with: audioSource, trackId: "local-audio")
            }
            micActive = localAudioTrack != nil
            appendLog("mic track ready=\(micActive)")
        } else {
            micActive = false
            appendLog("mic skipped — permission denied")
        }

        if camOK {
            if videoSource == nil {
                videoSource = factory.videoSource()
            }
            if localVideoTrack == nil, let videoSource {
                localVideoTrack = factory.videoTrack(with: videoSource, trackId: "local-video")
            }
            startCameraCapturer(source: videoSource)
        } else {
            cameraActive = false
            cameraStatus = "no camera permission (simulator?)"
            appendLog("camera skipped — permission denied / unavailable")
        }

        attachExistingTracksToPeerConnection()
        applyMediaPolicyLevel()
        createInitialOfferIfNeeded(reason: "after_attach:\(reason)")
        statusLine = "Joined room=\(roomName) cam=\(cameraStatus) mic=\(micActive ? "on" : "off")"
        publishHUD()
    }

    private func startCameraCapturer(source: LKRTCVideoSource?) {
        guard let source else {
            cameraStatus = "no video source"
            cameraActive = false
            return
        }

        let devices = LKRTCCameraVideoCapturer.captureDevices()
        guard let device = devices.first(where: { $0.position == .front }) ?? devices.first else {
            cameraStatus = "unavailable (simulator / no device)"
            cameraActive = false
            captureSession = nil
            appendLog("camera: no capture devices — fail soft")
            return
        }

        let formats = LKRTCCameraVideoCapturer.supportedFormats(for: device)
        guard let format = Self.selectFormat(formats) else {
            cameraStatus = "no supported format"
            cameraActive = false
            appendLog("camera: no supported format on \(device.localizedName)")
            return
        }

        if cameraCapturer == nil {
            cameraCapturer = LKRTCCameraVideoCapturer(delegate: source)
        }
        guard let capturer = cameraCapturer else { return }

        captureSession = capturer.captureSession
        let fps = Self.preferredFps(for: format)
        cameraStatus = "starting \(device.localizedName) \(fps)fps"
        capturer.startCapture(with: device, format: format, fps: fps) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.cameraActive = false
                    self.cameraStatus = "failed: \(error.localizedDescription)"
                    self.appendLog("camera start FAIL \(error.localizedDescription) — fail soft")
                } else {
                    self.cameraActive = true
                    self.captureSession = capturer.captureSession
                    self.cameraStatus = "live \(device.position == .front ? "front" : "back") \(fps)fps"
                    self.appendLog("camera start OK device=\(device.localizedName) fps=\(fps)")
                }
                self.publishHUD()
            }
        }
    }

    private func attachExistingTracksToPeerConnection() {
        guard let pc = peerConnection else { return }
        if let audio = localAudioTrack {
            _ = pc.add(audio, streamIds: ["local"])
            appendLog("PC addTrack local-audio")
        }
        if let video = localVideoTrack {
            _ = pc.add(video, streamIds: ["local"])
            appendLog("PC addTrack local-video")
        }
    }

    private func stopLocalMedia() {
        cameraCapturer?.stopCapture()
        cameraCapturer = nil
        captureSession = nil
        cameraActive = false
        cameraStatus = "stopped"
        micActive = false
        localVideoTrack?.isEnabled = false
        localAudioTrack?.isEnabled = false
        localVideoTrack = nil
        localAudioTrack = nil
        videoSource = nil
        audioSource = nil
        appendLog("local media stopped")
    }

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .videoChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            appendLog("audioSession playAndRecord/videoChat OK")
        } catch {
            appendLog("audioSession FAIL \(error.localizedDescription)")
        }
    }

    private func requestAccess(_ media: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: media)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private static func selectFormat(_ formats: [AVCaptureDevice.Format]) -> AVCaptureDevice.Format? {
        guard !formats.isEmpty else { return nil }
        let targetW = 640
        let targetH = 480
        return formats.min { a, b in
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            let sa = abs(Int(da.width) - targetW) + abs(Int(da.height) - targetH)
            let sb = abs(Int(db.width) - targetW) + abs(Int(db.height) - targetH)
            return sa < sb
        }
    }

    private static func preferredFps(for format: AVCaptureDevice.Format) -> Int {
        let maxRate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
        return Int(min(maxRate, 30))
    }

    private func applyMediaPolicyLevel() {
        switch mediaPolicyLevel {
        case 1:
            videoPauseReason = "layer_drop"
            videoPausedSend = false
            videoPausedRecv = false
            localVideoTrack?.isEnabled = true
        case 2:
            videoPauseReason = "pause_video_send"
            videoPausedSend = true
            videoPausedRecv = false
            preferAudio = true
            localVideoTrack?.isEnabled = false
        case 3:
            videoPauseReason = "pause_video_send_recv"
            videoPausedSend = true
            videoPausedRecv = true
            preferAudio = true
            localVideoTrack?.isEnabled = false
        default:
            videoPauseReason = "none"
            videoPausedSend = false
            videoPausedRecv = false
            preferAudio = false
            localVideoTrack?.isEnabled = true
        }
    }

    // MARK: - Metrics

    private func beginMetric(_ name: String) {
        openMetrics[name] = Date()
        appendLog("metric \(name) START")
    }

    private func completeMetric(_ name: String, note: String, displayAs: String? = nil) {
        guard let start = openMetrics.removeValue(forKey: name) else { return }
        let end = Date()
        let ms = max(0, Int((end.timeIntervalSince(start) * 1000.0).rounded()))
        let label = displayAs ?? name
        lastMetricName = label
        lastMetricDeltaMs = ms
        let record = MetricRecord(
            id: UUID(),
            name: label,
            startedAt: start,
            completedAt: end,
            deltaMs: ms,
            note: note
        )
        metricRecords.append(record)
        appendLog("metric \(label) DONE delta=\(ms)ms \(note)")
    }

    private func recordCongestionMetric(from previous: Int, to next: Int) {
        let now = Date()
        let start = lastCongestionAt ?? now
        let ms = max(0, Int((now.timeIntervalSince(start) * 1000.0).rounded()))
        lastCongestionAt = now
        lastMetricName = "congestion"
        lastMetricDeltaMs = ms
        let note = "L\(previous)→L\(next) branch=none"
        let record = MetricRecord(
            id: UUID(),
            name: "congestion",
            startedAt: start,
            completedAt: now,
            deltaMs: ms,
            note: note
        )
        metricRecords.append(record)
        appendLog("metric congestion DONE delta=\(ms)ms \(note)")
    }

    // MARK: - Internals

    private var shortSession: String {
        String(callSessionId.prefix(8))
    }

    @discardableResult
    private func createPeerConnection(reason: String) -> Bool {
        guard let factory = peerConnectionFactory else { return false }
        let bridge = PeerConnectionDelegateBridge(log: log)
        bridge.verboseICECandidates = false
        bridge.resetCandidateCounts()
        bridge.onIceConnectionChange = { [weak self] state in
            Task { @MainActor in
                self?.handleIceConnectionState(state)
            }
        }
        bridge.onIceGatheringChange = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                self.iceGatheringStateText = PeerConnectionDelegateBridge.iceGatheringName(state)
                self.candidateCounts = bridge.candidateCounts
                self.publishHUD()
            }
        }
        bridge.onConnectionStateChange = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                self.connectionStateText = PeerConnectionDelegateBridge.connectionName(state)
                self.publishHUD()
            }
        }
        bridge.onSignalingChange = { [weak self] state in
            Task { @MainActor in
                self?.pcSignalingStateText = PeerConnectionDelegateBridge.signalingName(state)
            }
        }
        bridge.onCandidateCountsChange = { [weak self] counts in
            Task { @MainActor in
                self?.candidateCounts = counts
            }
        }
        pcDelegate = bridge

        let config = LKRTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.iceServers = [
            LKRTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])
        ]
        let constraints = LKRTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )
        peerConnection = factory.peerConnection(
            with: config,
            constraints: constraints,
            delegate: bridge
        )
        iceConnectionStateText = "new"
        iceGatheringStateText = "new"
        pcSignalingStateText = "stable"
        connectionStateText = "new"
        candidateCounts = ICECandidateTypeCounts()
        appendLog("PC create reason=\(reason) ok=\(peerConnection != nil)")
        return peerConnection != nil
    }

    private func createInitialOfferIfNeeded(reason: String) {
        guard let pc = peerConnection else { return }
        let constraints = LKRTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )
        pc.offer(for: constraints) { [weak self] sdp, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.appendLog("initial offer FAIL \(error.localizedDescription) reason=\(reason)")
                    return
                }
                guard let sdp else { return }
                pc.setLocalDescription(sdp) { [weak self] setError in
                    Task { @MainActor in
                        guard let self else { return }
                        if let setError {
                            self.appendLog("initial setLocal FAIL \(setError.localizedDescription)")
                        } else {
                            self.refreshUfragFromLocalDescription()
                            self.refreshMidsFromPC()
                            self.appendLog("initial local SDP set reason=\(reason) ufrag=\(self.iceUfrag) mids=\(self.midList)")
                            self.publishHUD()
                        }
                    }
                }
            }
        }
    }

    private func refreshUfragFromLocalDescription() {
        if let sdp = peerConnection?.localDescription?.sdp,
           let ufrag = Self.extractICEUfrag(from: sdp) {
            iceUfrag = ufrag
        } else {
            iceUfrag = iceUfrag == "—" ? "pending" : iceUfrag
        }
    }

    private func refreshMidsFromPC() {
        guard let pc = peerConnection else { return }
        let mids = pc.transceivers.compactMap { $0.mid }
        if !mids.isEmpty {
            midList = mids
        }
    }

    private static func extractICEUfrag(from sdp: String) -> String? {
        for line in sdp.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("a=ice-ufrag:") {
                return String(trimmed.dropFirst("a=ice-ufrag:".count))
            }
        }
        return nil
    }

    private func appendLog(_ line: String) {
        log.append(line)
        if let last = log.lines.last {
            eventLog.insert(last, at: 0)
            if eventLog.count > 40 {
                eventLog = Array(eventLog.prefix(40))
            }
        }
    }

    // MARK: - HUD poll (states + getStats stub every ~2s while joined)

    private func startHUDPoll() {
        stopHUDPoll()
        hudPollTask = Task { @MainActor [weak self] in
            while let self, self.joined, !Task.isCancelled {
                self.refreshLivePCStates()
                self.refreshStatsStub()
                self.publishHUD()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func stopHUDPoll() {
        hudPollTask?.cancel()
        hudPollTask = nil
    }

    private func refreshLivePCStates() {
        guard let pc = peerConnection else { return }
        iceConnectionStateText = PeerConnectionDelegateBridge.iceConnectionName(pc.iceConnectionState)
        iceGatheringStateText = PeerConnectionDelegateBridge.iceGatheringName(pc.iceGatheringState)
        connectionStateText = PeerConnectionDelegateBridge.connectionName(pc.connectionState)
        pcSignalingStateText = PeerConnectionDelegateBridge.signalingName(pc.signalingState)
        if let bridge = pcDelegate {
            candidateCounts = bridge.candidateCounts
        }
        refreshUfragFromLocalDescription()
        refreshMidsFromPC()
    }

    private func refreshStatsStub() {
        StatsCollector.fetch(from: peerConnection) { [weak self] snap in
            Task { @MainActor in
                guard let self, self.joined else { return }
                self.callStats = snap
            }
        }
    }

    private func publishHUD() {
        objectWillChange.send()
    }
}
