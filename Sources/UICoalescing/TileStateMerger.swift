import Foundation
import Combine

/// Listens to a high-rate stream of `ConferenceUIEvent`s, updates a shared
/// `ConferenceRoomState` immediately (one small handler per event), then emits
/// a coalesced `TileRosterSnapshot` at most ~1 Hz for the UI.
///
/// Responsibilities (SOLID):
/// 1. Listen — `ingest`
/// 2. Update shared model — per-event `apply*` handlers
/// 3. Apply to UI — throttled `snapshots` / `currentSnapshot`
///
/// Pure `apply` helpers stay static for SoftAssert / unit tests without Combine.
final class TileStateMerger {
    static let defaultEmitInterval: TimeInterval = 1.0
    static let maxRecentChat = 20

    private let subject = PassthroughSubject<ConferenceUIEvent, Never>()
    private let state = ConferenceMergeState()

    let snapshots: AnyPublisher<TileRosterSnapshot, Never>

    init(emitInterval: TimeInterval = TileStateMerger.defaultEmitInterval) {
        let interval = max(emitInterval, 0.05)
        let state = self.state

        snapshots = subject
            .handleEvents(receiveOutput: { event in
                Self.apply(event, into: state)
            })
            .map { _ in state.makeSnapshot() }
            .throttle(for: .seconds(interval), scheduler: DispatchQueue.main, latest: true)
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    func ingest(_ event: ConferenceUIEvent) {
        subject.send(event)
    }

    func ingest<S: Sequence>(_ events: S) where S.Element == ConferenceUIEvent {
        events.forEach(ingest)
    }

    func currentSnapshot() -> TileRosterSnapshot {
        state.makeSnapshot()
    }

    func reset() {
        state.reset()
    }

    // MARK: - Pure reducers (dispatch only)

    /// Tile-dictionary helper for SoftAsserts that only inspect tiles.
    static func apply(_ event: ConferenceUIEvent, to tiles: inout [String: TileUIState]) {
        var room = ConferenceRoomState(tiles: tiles)
        apply(event, to: &room)
        tiles = room.tiles
    }

    static func apply(_ event: ConferenceUIEvent, into state: ConferenceMergeState) {
        apply(event, to: &state.room)
    }

    /// Routes to one handler per event — keeps SRP and avoids a pasta switch body.
    static func apply(_ event: ConferenceUIEvent, to room: inout ConferenceRoomState) {
        switch event {
        case let .mediaToggle(participantId, kind, enabled):
            applyMediaToggle(participantId: participantId, kind: kind, enabled: enabled, to: &room)
        case let .emoji(participantId, emoji):
            applyEmoji(participantId: participantId, emoji: emoji, to: &room)
        case let .chat(participantId, text):
            applyChat(participantId: participantId, text: text, to: &room)
        case let .presence(participantId, action):
            applyPresence(participantId: participantId, action: action, to: &room)
        case let .pin(participantId, action):
            applyPin(participantId: participantId, action: action, to: &room)
        case let .mutedByAdmin(participantId, muted):
            applyMutedByAdmin(participantId: participantId, muted: muted, to: &room)
        case let .conferenceMode(mode):
            applyConferenceMode(mode, to: &room)
        case let .speaking(tileId, isSpeaking):
            applySpeaking(tileId: tileId, isSpeaking: isSpeaking, to: &room)
        case let .connection(tileId, conn):
            applyConnection(tileId: tileId, state: conn, to: &room)
        case let .track(tileId, kind, available):
            applyTrack(tileId: tileId, kind: kind, available: available, to: &room)
        case let .reconnectHint(tileId, hint):
            applyReconnectHint(tileId: tileId, hint: hint, to: &room)
        }
    }

    // MARK: - Per-event model updates

    private static func applyMediaToggle(
        participantId: String,
        kind: MediaDeviceKind,
        enabled: Bool,
        to room: inout ConferenceRoomState
    ) {
        var tile = room.tiles[participantId] ?? .blank(id: participantId)
        switch kind {
        case .camera:
            tile.cameraEnabled = enabled
            tile.hasVideo = enabled
        case .microphone:
            tile.microphoneEnabled = enabled
            tile.hasAudio = enabled
            if enabled { tile.mutedByAdmin = false }
        }
        room.tiles[participantId] = tile
    }

    private static func applyEmoji(
        participantId: String,
        emoji: String,
        to room: inout ConferenceRoomState
    ) {
        var tile = room.tiles[participantId] ?? .blank(id: participantId)
        tile.lastEmoji = emoji
        room.tiles[participantId] = tile
        room.lastReaction = ReactionFlash(participantId: participantId, emoji: emoji)
    }

    private static func applyChat(
        participantId: String,
        text: String,
        to room: inout ConferenceRoomState
    ) {
        let line = ChatLine(
            id: "\(participantId)-\(room.chatSeq)",
            participantId: participantId,
            text: text
        )
        room.chatSeq += 1
        room.recentChat.append(line)
        if room.recentChat.count > maxRecentChat {
            room.recentChat.removeFirst(room.recentChat.count - maxRecentChat)
        }
    }

    private static func applyPresence(
        participantId: String,
        action: PresenceAction,
        to room: inout ConferenceRoomState
    ) {
        switch action {
        case .joined:
            if room.tiles[participantId] == nil {
                var tile = TileUIState.blank(id: participantId)
                tile.connection = .connected
                room.tiles[participantId] = tile
            } else {
                room.tiles[participantId]?.connection = .connected
            }
        case .left:
            room.tiles.removeValue(forKey: participantId)
        }
    }

    private static func applyPin(
        participantId: String,
        action: PinAction,
        to room: inout ConferenceRoomState
    ) {
        var tile = room.tiles[participantId] ?? .blank(id: participantId)
        tile.isPinned = (action == .pinned)
        room.tiles[participantId] = tile
    }

    private static func applyMutedByAdmin(
        participantId: String,
        muted: Bool,
        to room: inout ConferenceRoomState
    ) {
        var tile = room.tiles[participantId] ?? .blank(id: participantId)
        tile.mutedByAdmin = muted
        if muted {
            tile.microphoneEnabled = false
            tile.hasAudio = false
        }
        room.tiles[participantId] = tile
    }

    private static func applyConferenceMode(
        _ mode: ConferenceModeKind,
        to room: inout ConferenceRoomState
    ) {
        room.conferenceMode = mode
    }

    private static func applySpeaking(
        tileId: String,
        isSpeaking: Bool,
        to room: inout ConferenceRoomState
    ) {
        var tile = room.tiles[tileId] ?? .blank(id: tileId)
        tile.isSpeaking = isSpeaking
        room.tiles[tileId] = tile
    }

    private static func applyConnection(
        tileId: String,
        state: TileConnectionState,
        to room: inout ConferenceRoomState
    ) {
        var tile = room.tiles[tileId] ?? .blank(id: tileId)
        tile.connection = state
        room.tiles[tileId] = tile
    }

    private static func applyTrack(
        tileId: String,
        kind: TileTrackKind,
        available: Bool,
        to room: inout ConferenceRoomState
    ) {
        var tile = room.tiles[tileId] ?? .blank(id: tileId)
        switch kind {
        case .audio:
            tile.hasAudio = available
            tile.microphoneEnabled = available
        case .video:
            tile.hasVideo = available
            tile.cameraEnabled = available
        case .screen:
            tile.hasScreen = available
        }
        room.tiles[tileId] = tile
    }

    private static func applyReconnectHint(
        tileId: String,
        hint: String?,
        to room: inout ConferenceRoomState
    ) {
        var tile = room.tiles[tileId] ?? .blank(id: tileId)
        tile.reconnectHint = hint
        room.tiles[tileId] = tile
    }
}

struct ConferenceRoomState: Equatable, Sendable {
    var tiles: [String: TileUIState] = [:]
    var conferenceMode: ConferenceModeKind = .grid
    var recentChat: [ChatLine] = []
    var lastReaction: ReactionFlash?
    var chatSeq: Int = 0

    init(
        tiles: [String: TileUIState] = [:],
        conferenceMode: ConferenceModeKind = .grid,
        recentChat: [ChatLine] = [],
        lastReaction: ReactionFlash? = nil,
        chatSeq: Int = 0
    ) {
        self.tiles = tiles
        self.conferenceMode = conferenceMode
        self.recentChat = recentChat
        self.lastReaction = lastReaction
        self.chatSeq = chatSeq
    }
}

final class ConferenceMergeState {
    var room = ConferenceRoomState()

    func makeSnapshot() -> TileRosterSnapshot {
        TileRosterSnapshot(
            tiles: room.tiles.values.sorted { $0.id < $1.id },
            conferenceMode: room.conferenceMode,
            recentChat: room.recentChat,
            lastReaction: room.lastReaction,
            updatedAt: Date()
        )
    }

    func reset() {
        room = ConferenceRoomState()
    }
}

typealias ConferenceUICoalescer = TileStateMerger
