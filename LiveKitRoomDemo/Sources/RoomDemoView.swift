import LiveKit
import SwiftUI

@MainActor
final class RoomDemoModel: ObservableObject {
    enum Role: String, CaseIterable, Identifiable {
        case simulator
        case iphone
        var id: String { rawValue }
        var title: String { rawValue == "simulator" ? "Simulator" : "iPhone" }
    }

    @Published var role: Role = .simulator
    @Published var connectionState: ConnectionState = .disconnected
    @Published var statusText: String = "Idle"
    @Published var errorText: String?
    @Published var localVideoTrack: VideoTrack?
    @Published var remoteVideoTrack: VideoTrack?

    private let room = Room()
    private var tokens: TokensFile

    struct TokensFile {
        let url: String
        let room: String
        let iphoneToken: String
        let simulatorToken: String
    }

    init() {
        self.tokens = Self.loadTokens()
        room.add(delegate: DelegateBox(owner: self))
    }

    private static func loadTokens() -> TokensFile {
        guard
            let url = Bundle.main.url(forResource: "Tokens", withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let serverURL = plist["url"] as? String,
            let room = plist["room"] as? String,
            let iphoneToken = plist["iphoneToken"] as? String,
            let simulatorToken = plist["simulatorToken"] as? String
        else {
            return TokensFile(url: "", room: "", iphoneToken: "", simulatorToken: "")
        }
        return TokensFile(
            url: serverURL,
            room: room,
            iphoneToken: iphoneToken,
            simulatorToken: simulatorToken
        )
    }

    var tokenForRole: String {
        role == .simulator ? tokens.simulatorToken : tokens.iphoneToken
    }

    func connect() {
        errorText = nil
        guard !tokens.url.isEmpty, !tokenForRole.isEmpty else {
            errorText = "Tokens.plist missing or empty — copy secrets/Tokens.plist into LiveKitRoomDemo/Resources."
            return
        }
        statusText = "Connecting as \(role.title)…"
        Task {
            do {
                try await room.connect(url: tokens.url, token: tokenForRole)
                try await room.localParticipant.setCamera(enabled: true)
                try await room.localParticipant.setMicrophone(enabled: true)
                refreshTracks()
                statusText = "Connected · room \(tokens.room)"
            } catch {
                errorText = String(describing: error)
                statusText = "Connect failed"
            }
        }
    }

    func leave() {
        Task {
            await room.disconnect()
            localVideoTrack = nil
            remoteVideoTrack = nil
            statusText = "Left"
        }
    }

    fileprivate func refreshTracks() {
        localVideoTrack = room.localParticipant.videoTracks
            .compactMap { $0.track as? VideoTrack }
            .first
        remoteVideoTrack = room.remoteParticipants.values
            .flatMap(\.videoTracks)
            .compactMap { $0.track as? VideoTrack }
            .first
        connectionState = room.connectionState
    }

    /// RoomDelegate cannot be the ObservableObject easily across actor; thin box.
    private final class DelegateBox: RoomDelegate, @unchecked Sendable {
        weak var owner: RoomDemoModel?
        init(owner: RoomDemoModel) { self.owner = owner }

        func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldValue: ConnectionState) {
            Task { @MainActor in
                self.owner?.connectionState = connectionState
                self.owner?.statusText = "State: \(String(describing: connectionState))"
                self.owner?.refreshTracks()
            }
        }

        func room(_ room: Room, participant: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
            Task { @MainActor in self.owner?.refreshTracks() }
        }

        func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
            Task { @MainActor in self.owner?.refreshTracks() }
        }

        func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
            Task { @MainActor in self.owner?.refreshTracks() }
        }

        func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
            Task { @MainActor in self.owner?.refreshTracks() }
        }

        func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
            Task { @MainActor in
                self.owner?.remoteVideoTrack = nil
                self.owner?.refreshTracks()
            }
        }
    }
}

struct RoomDemoView: View {
    @StateObject private var model = RoomDemoModel()

    var body: some View {
        VStack(spacing: 12) {
            Text("LiveKit Room Demo")
                .font(.headline)
            Text(model.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let errorText = model.errorText {
                Text(errorText)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Picker("Identity", selection: $model.role) {
                ForEach(RoomDemoModel.Role.allCases) { role in
                    Text(role.title).tag(role)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.connectionState != .disconnected)

            HStack(spacing: 8) {
                videoPane(title: "Local", track: model.localVideoTrack)
                videoPane(title: "Remote", track: model.remoteVideoTrack)
            }
            .frame(maxHeight: .infinity)

            HStack {
                Button("Connect") { model.connect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.connectionState != .disconnected)
                Button("Leave", role: .destructive) { model.leave() }
                    .buttonStyle(.bordered)
                    .disabled(model.connectionState == .disconnected)
            }
        }
        .padding()
    }

    @ViewBuilder
    private func videoPane(title: String, track: VideoTrack?) -> some View {
        VStack {
            Text(title).font(.caption)
            ZStack {
                Color.black.opacity(0.85)
                if let track {
                    SwiftUIVideoView(track, layoutMode: .fill)
                } else {
                    Text("No video")
                        .foregroundStyle(.white.opacity(0.7))
                        .font(.caption)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
