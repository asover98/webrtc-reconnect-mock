import Foundation

struct ChatLine: Equatable, Sendable, Identifiable {
    var id: String
    var participantId: String
    var text: String
}

struct ReactionFlash: Equatable, Sendable {
    var participantId: String
    var emoji: String
}

/// Coalesced UI state after merge/throttle (~1 Hz).
struct TileRosterSnapshot: Equatable, Sendable {
    var tiles: [TileUIState]
    var conferenceMode: ConferenceModeKind
    var recentChat: [ChatLine]
    var lastReaction: ReactionFlash?
    var updatedAt: Date

    static let empty = TileRosterSnapshot(
        tiles: [],
        conferenceMode: .grid,
        recentChat: [],
        lastReaction: nil,
        updatedAt: .distantPast
    )

    /// Convenience for layout agent / older call sites that only care about tiles.
    init(tiles: [TileUIState], updatedAt: Date) {
        self.tiles = tiles
        self.conferenceMode = .grid
        self.recentChat = []
        self.lastReaction = nil
        self.updatedAt = updatedAt
    }

    init(
        tiles: [TileUIState],
        conferenceMode: ConferenceModeKind,
        recentChat: [ChatLine],
        lastReaction: ReactionFlash?,
        updatedAt: Date
    ) {
        self.tiles = tiles
        self.conferenceMode = conferenceMode
        self.recentChat = recentChat
        self.lastReaction = lastReaction
        self.updatedAt = updatedAt
    }
}

struct TileUIState: Equatable, Identifiable, Sendable {
    var id: String
    var isSpeaking: Bool
    var connection: TileConnectionState
    var hasAudio: Bool
    var hasVideo: Bool
    var hasScreen: Bool
    var cameraEnabled: Bool
    var microphoneEnabled: Bool
    var isPinned: Bool
    var mutedByAdmin: Bool
    var reconnectHint: String?
    var lastEmoji: String?

    static func blank(id: String) -> TileUIState {
        TileUIState(
            id: id,
            isSpeaking: false,
            connection: .disconnected,
            hasAudio: false,
            hasVideo: false,
            hasScreen: false,
            cameraEnabled: false,
            microphoneEnabled: false,
            isPinned: false,
            mutedByAdmin: false,
            reconnectHint: nil,
            lastEmoji: nil
        )
    }
}
