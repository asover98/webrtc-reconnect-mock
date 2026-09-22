import Foundation

// MARK: - Small kind enums (no full modules)

enum MediaDeviceKind: String, Equatable, Sendable {
    case camera
    case microphone
}

enum PresenceAction: String, Equatable, Sendable {
    case joined
    case left
}

enum PinAction: String, Equatable, Sendable {
    case pinned
    case unpinned
}

/// Admin- or host-selected conference presentation mode (signaling event).
enum ConferenceModeKind: String, Equatable, Sendable {
    case grid
    case speaker
    case webinar
}

enum TileConnectionState: String, Equatable, Sendable {
    case connecting
    case connected
    case reconnecting
    case disconnected
}

enum TileTrackKind: String, Equatable, Sendable {
    case audio
    case video
    case screen
}

// MARK: - One umbrella event for UI coalesce

/// All noisy conference UI signals land here. `TileStateMerger` updates the shared
/// room model immediately (one handler per case), then emits one UI snapshot (~1 Hz).
/// Enums only — no chat/emoji/presence modules.
enum ConferenceUIEvent: Equatable, Sendable {
    // Media toggles
    case mediaToggle(participantId: String, kind: MediaDeviceKind, enabled: Bool)
    // Reactions / chat
    case emoji(participantId: String, emoji: String)
    case chat(participantId: String, text: String)
    // Roster presence
    case presence(participantId: String, action: PresenceAction)
    // Pin / admin mute / mode
    case pin(participantId: String, action: PinAction)
    case mutedByAdmin(participantId: String, muted: Bool)
    case conferenceMode(ConferenceModeKind)
    // Classic tile signals (Innotech-style)
    case speaking(tileId: String, isSpeaking: Bool)
    case connection(tileId: String, state: TileConnectionState)
    case track(tileId: String, kind: TileTrackKind, available: Bool)
    case reconnectHint(tileId: String, hint: String?)
}

/// Backward-compatible name used by earlier scaffold + SoftAsserts.
typealias TileUIEvent = ConferenceUIEvent
