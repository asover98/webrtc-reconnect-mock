import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var webRTCClient: WebRTCClient
    @EnvironmentObject private var statusLog: StatusLog
    @State private var roomName: String = "research-room"
    @State private var statusMessage: String = "Idle — Join to start local preview + mock signaling"
    @State private var shareURL: URL?
    @State private var showShare = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    localPreview
                    roomControls
                    hudPanel
                    forceButtons
                    mediaButtons
                    agentsResearchSection
                    eventLog
                }
                .padding()
            }
            .navigationTitle("WebRTC Reconnect")
            .sheet(isPresented: $showShare) {
                if let shareURL {
                    ShareSheet(items: [shareURL])
                }
            }
        }
    }

    private var roomControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Multiparty conference mock")
                .font(.headline)
            TextField("Room name", text: $roomName)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
            Text(statusMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(webRTCClient.statusLine)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text(webRTCClient.pathDescription)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
            Text("signaling: \(webRTCClient.signalingStateText)  cursor=\(webRTCClient.signalCursor)")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hudPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("HUD")
                .font(.subheadline.weight(.semibold))
            Text("PC / ICE")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            hudRow("iceConnection", webRTCClient.iceConnectionStateText)
            hudRow("iceGathering", webRTCClient.iceGatheringStateText)
            hudRow("pcSignaling", webRTCClient.pcSignalingStateText)
            hudRow("connection", webRTCClient.connectionStateText)
            hudRow("candidates", webRTCClient.candidateCounts.summaryLine.replacingOccurrences(of: "ICE candidates summary ", with: ""))
            Text("Session")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            hudRow("branch", webRTCClient.lastBranch.rawValue)
            hudRow("callSessionId", shortId(webRTCClient.callSessionId))
            hudRow("cursor", "\(webRTCClient.signalCursor)")
            hudRow("ufrag", shortId(webRTCClient.iceUfrag))
            hudRow("mids", webRTCClient.midList.joined(separator: ","))
            hudRow("mediaPolicyLevel", "L\(webRTCClient.mediaPolicyLevel)")
            hudRow("preferAudio", webRTCClient.preferAudio ? "ON" : "OFF")
            hudRow(
                "videoPaused",
                "send=\(webRTCClient.videoPausedSend) recv=\(webRTCClient.videoPausedRecv) reason=\(webRTCClient.videoPauseReason)"
            )
            hudRow("camera", webRTCClient.cameraStatus)
            hudRow("mic", webRTCClient.micActive ? "on" : "off")
            hudRow("lastMetric", lastMetricHUD)
            Text("getStats (stub)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            hudRow("stats", webRTCClient.callStats.hudSummary)
            Text("Meaningful with a remote peer / LiveKit SFU answerer.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .font(.caption2.monospaced())
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func shortId(_ value: String) -> String {
        guard value != "—", value.count > 12 else { return value }
        return String(value.prefix(8)) + "…"
    }

    private var lastMetricHUD: String {
        if let ms = webRTCClient.lastMetricDeltaMs {
            return "\(webRTCClient.lastMetricName)  \(ms)ms"
        }
        return "—"
    }

    private func hudRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(key)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
        }
    }

    private var forceButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ADR reconnect ladder")
                .font(.subheadline.weight(.semibold))
            Button("Join") {
                webRTCClient.join(room: roomName)
                statusMessage = "Joined — signaling mock://local + PC + local A/V (if hardware)"
            }
            .buttonStyle(.borderedProminent)

            Button("Force Reconnect") {
                webRTCClient.forceReconnect()
                statusMessage = "resume_then_restart — WS resume → ICE restart"
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)

            Button("Force signal drop") {
                webRTCClient.forceSignalDrop()
                statusMessage = "signal_only — drop → resumeAck (HUD last delta)"
            }
            .buttonStyle(.bordered)

            Button("Force ICE restart") {
                webRTCClient.forceICERestart()
                statusMessage = "ice_restart — start → localOfferApplied (setLocal) / ice connected"
            }
            .buttonStyle(.bordered)

            Button("Hard reconnect") {
                webRTCClient.hardReconnect()
                statusMessage = "hard_recycle — start → new PC ready"
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var mediaButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ADR prefer-audio / congestion")
                .font(.subheadline.weight(.semibold))
            Toggle(
                "Prefer audio",
                isOn: Binding(
                    get: { webRTCClient.preferAudio },
                    set: { webRTCClient.setPreferAudio($0) }
                )
            )
            .font(.subheadline)
            Text("Pauses local video send (track.isEnabled). Not an ICE restart.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Button("Force congestion") {
                    webRTCClient.simulateCongestionStep()
                    statusMessage = "Congestion L\(webRTCClient.mediaPolicyLevel) branch=none"
                }
                .buttonStyle(.bordered)
                Button("Reset L0") {
                    webRTCClient.resetCongestion()
                    statusMessage = "mediaPolicyLevel reset to L0 branch=none"
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }


    private var agentsResearchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agents & UI coalesce")
                .font(.subheadline.weight(.semibold))
            Text("AgentOrchestrator bad-cell → knobs → WebRTCClient (public APIs). SoftAssert in log.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("Run agent bad-network demo") {
                runAgentBadNetworkDemo()
            }
            .buttonStyle(.bordered)
            .tint(.purple)
            Button("Burst UI coalesce demo") {
                runUICoalesceBurstDemo()
            }
            .buttonStyle(.bordered)
            .tint(.indigo)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @MainActor
    private func runAgentBadNetworkDemo() {
        let applier = WebRTCClientMediaKnobApplier(client: webRTCClient, statusLog: statusLog)
        let stats = WebRTCClientStatsProvider(client: webRTCClient)
        let orch = AgentOrchestrator(mediaTool: applier, statsTool: stats)
        orch.logHandler = { statusLog.append($0) }
        let report = orch.runBadNetworkDemo()
        let soft1 = TestScenarioSupport.assertBadCellDegradation()
        let soft2 = TestScenarioSupport.assertTileMergeReducer()
        statusLog.append(soft1.report())
        statusLog.append(soft2.report())
        let softOK = soft1.allPassed && soft2.allPassed
        statusMessage = String(
            format: "Agent demo score=%.2f %@ | SoftAssert %@",
            report.score,
            report.summary,
            softOK ? "OK" : "FAIL"
        )
    }

    /// Fire many ConferenceUIEvent kinds through the reducer (no Combine wait).
    @MainActor
    private func runUICoalesceBurstDemo() {
        var room = ConferenceRoomState()
        let burst: [ConferenceUIEvent] = [
            .presence(participantId: "alice", action: .joined),
            .presence(participantId: "bob", action: .joined),
            .presence(participantId: "carol", action: .joined),
            .mediaToggle(participantId: "alice", kind: .camera, enabled: true),
            .mediaToggle(participantId: "alice", kind: .microphone, enabled: true),
            .mediaToggle(participantId: "bob", kind: .camera, enabled: false),
            .speaking(tileId: "alice", isSpeaking: true),
            .speaking(tileId: "alice", isSpeaking: false),
            .speaking(tileId: "alice", isSpeaking: true),
            .emoji(participantId: "carol", emoji: "🎉"),
            .chat(participantId: "bob", text: " Lag? "),
            .chat(participantId: "alice", text: " Prefer audio on."),
            .pin(participantId: "alice", action: .pinned),
            .conferenceMode(.speaker),
            .mutedByAdmin(participantId: "carol", muted: true),
            .connection(tileId: "bob", state: .reconnecting),
            .reconnectHint(tileId: "bob", hint: "ice_restart"),
            .presence(participantId: "carol", action: .left),
        ]
        for event in burst {
            TileStateMerger.apply(event, to: &room)
        }
        let snap = TileRosterSnapshot(
            tiles: room.tiles.values.sorted { $0.id < $1.id },
            conferenceMode: room.conferenceMode,
            recentChat: room.recentChat,
            lastReaction: room.lastReaction,
            updatedAt: Date()
        )
        let soft = TestScenarioSupport.assertTileMergeReducer()
        statusLog.append(
            "UI coalesce burst: tiles=\(snap.tiles.count) mode=\(snap.conferenceMode.rawValue) chat=\(snap.recentChat.count) reaction=\(snap.lastReaction?.emoji ?? "-")"
        )
        for tile in snap.tiles {
            statusLog.append(
                "  tile \(tile.id) cam=\(tile.cameraEnabled) mic=\(tile.microphoneEnabled) pin=\(tile.isPinned) speak=\(tile.isSpeaking) mutedByAdmin=\(tile.mutedByAdmin)"
            )
        }
        statusLog.append(soft.report())
        statusMessage = "UI coalesce: \(snap.tiles.count) tiles, mode=\(snap.conferenceMode.rawValue), SoftAssert \(soft.allPassed ? "OK" : "FAIL")"
    }

    private var eventLog: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Event log")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Export Log") {
                    if let url = webRTCClient.writeExportFile() {
                        shareURL = url
                        showShare = true
                    }
                }
                .buttonStyle(.bordered)
            }
            let lines = webRTCClient.eventLog.isEmpty
                ? statusLog.lines.reversed().map { $0 }
                : Array(webRTCClient.eventLog.prefix(16))
            ForEach(Array(lines.prefix(16)), id: \.self) { line in
                Text(line)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var localPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black)
            if webRTCClient.cameraActive, let session = webRTCClient.captureSession {
                LocalPreviewView(captureSession: session)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "video.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text(webRTCClient.cameraStatus == "idle" ? "Local preview" : webRTCClient.cameraStatus)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text("Simulator often has no camera — fail soft. Use a phone for live preview.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
        }
        .frame(height: 200)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }
}

#Preview {
    let log = StatusLog()
    return ContentView()
        .environmentObject(WebRTCClient(log: log))
        .environmentObject(log)
}
