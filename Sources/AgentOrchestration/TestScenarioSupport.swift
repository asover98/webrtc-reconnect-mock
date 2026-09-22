import Foundation

/// Soft assertion helper for demo / playground checks without a full XCTest target.
struct SoftAssert {
    private(set) var failures: [String] = []

    mutating func equal<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "") {
        if actual != expected {
            let suffix = message.isEmpty ? "" : " — \(message)"
            failures.append("expected \(expected), got \(actual)\(suffix)")
        }
    }

    mutating func `true`(_ value: Bool, _ message: String = "") {
        if !value {
            failures.append(message.isEmpty ? "expected true" : message)
        }
    }

    var allPassed: Bool { failures.isEmpty }

    func report() -> String {
        if allPassed { return "SoftAssert: OK" }
        return "SoftAssert failures:\n" + failures.map { " - \($0)" }.joined(separator: "\n")
    }
}

/// Expected degradation for known network fixtures (SoftAssert / demo hooks).
enum TestScenarioSupport {
    /// Bad cell → expect L2+ with preferAudio / pause video send.
    static func expectedKnobs(for network: NetworkSnapshot) -> MediaKnobs {
        NetworkScenarioAgent().decide(from: network)
    }

    /// Documented fixture: `NetworkSnapshot.badCell` should land on L2 protect_audio.
    static func assertBadCellDegradation(agent: NetworkScenarioAgent = NetworkScenarioAgent()) -> SoftAssert {
        var soft = SoftAssert()
        let knobs = agent.decide(from: .badCell)
        soft.true(knobs.level >= 2, "badCell should be L2+")
        soft.equal(knobs.preferAudio, true, "badCell preferAudio")
        soft.equal(knobs.pauseVideoSend, true, "badCell pauseVideoSend")
        return soft
    }

    /// Healthy path stays L0.
    static func assertHealthyStaysL0(agent: NetworkScenarioAgent = NetworkScenarioAgent()) -> SoftAssert {
        var soft = SoftAssert()
        let knobs = agent.decide(from: .healthy)
        soft.equal(knobs.level, 0, "healthy L0")
        soft.equal(knobs.preferAudio, false, "healthy preferAudio off")
        return soft
    }

    /// Tile / conference UI merge reducer: mixed event kinds without Combine.
    static func assertTileMergeReducer() -> SoftAssert {
        var soft = SoftAssert()
        var room = ConferenceRoomState()
        let burst: [ConferenceUIEvent] = [
            .presence(participantId: "a", action: .joined),
            .presence(participantId: "b", action: .joined),
            .connection(tileId: "a", state: .connected),
            .speaking(tileId: "a", isSpeaking: true),
            .mediaToggle(participantId: "a", kind: .camera, enabled: true),
            .mediaToggle(participantId: "a", kind: .microphone, enabled: true),
            .emoji(participantId: "b", emoji: "👍"),
            .chat(participantId: "b", text: "hello"),
            .pin(participantId: "a", action: .pinned),
            .mutedByAdmin(participantId: "b", muted: true),
            .conferenceMode(.speaker),
            .presence(participantId: "b", action: .left),
        ]
        for event in burst {
            TileStateMerger.apply(event, to: &room)
        }
        soft.equal(room.tiles["a"]?.isSpeaking ?? false, true, "speaking")
        soft.equal(room.tiles["a"]?.cameraEnabled ?? false, true, "camera")
        soft.equal(room.tiles["a"]?.isPinned ?? false, true, "pinned")
        soft.equal(room.tiles["b"] == nil, true, "b left")
        soft.equal(room.conferenceMode, .speaker, "mode")
        soft.equal(room.recentChat.count, 1, "chat")
        soft.equal(room.lastReaction?.emoji, "👍", "emoji")
        return soft
    }
}
