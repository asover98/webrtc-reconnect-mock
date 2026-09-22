import Foundation
import Combine

/// Connection state for the signaling WebSocket (or loopback mock).
enum SignalingState: String {
    case disconnected
    case connecting
    case connected
    case reconnecting
}

/// Outbound / inbound JSON message shapes for the mock protocol.
/// Resume handshake carries `callSessionId` + `cursor` + `reconnectReason` (locked schema).
struct SignalingMessage: Codable, Equatable {
    var type: String
    var room: String?
    var callSessionId: String?
    var cursor: Int?
    var reconnect: Bool?
    var ok: Bool?
    var reason: String?
    var preferAudio: Bool?
    var reconnectReason: String?
}

/// URLSessionWebSocketTask client with exponential backoff auto-reconnect,
/// `callSessionId` + `lastEventCursor`, and a resume handshake.
///
/// When URL is `mock://local`, uses an in-process loopback (`MockSignalingLoop`)
/// instead of a real socket — preferred on iOS Simulator over `NWListener`
/// (no local port, no ATS, no background listener lifecycle issues).
@MainActor
final class SignalingClient: ObservableObject {
    @Published private(set) var state: SignalingState = .disconnected
    @Published private(set) var callSessionId: String?
    @Published private(set) var lastEventCursor: Int = 0
    @Published private(set) var lastError: String?
    /// Last reason sent on `resume` (demo/export logs).
    @Published private(set) var lastReconnectReason: String = "ws_drop"

    /// Default mock URL — no real network.
    static let mockURL = URL(string: "mock://local")!

    private let log: StatusLog
    private var url: URL = SignalingClient.mockURL
    private var room: String = ""
    private var wantsConnection = false
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?

    // Real WS
    private var session: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?

    // Loopback mock
    private var useMock = false
    private var mockLoop: MockSignalingLoop?

    var onMessage: ((SignalingMessage) -> Void)?
    var onStateChange: ((SignalingState) -> Void)?

    init(log: StatusLog) {
        self.log = log
    }

    // MARK: - Public API

    func connect(url: URL = SignalingClient.mockURL, room: String) {
        self.url = url
        self.room = room
        wantsConnection = true
        reconnectAttempt = 0
        useMock = (url.scheme?.lowercased() == "mock")
        reconnectTask?.cancel()
        reconnectTask = nil
        openTransport(isResume: callSessionId != nil)
    }

    func disconnect() {
        wantsConnection = false
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        tearDownTransport(reason: "client disconnect")
        setState(.disconnected)
        log.append("signaling: disconnected (callSessionId kept=\(callSessionId ?? "nil") cursor=\(lastEventCursor))")
    }

    /// Clear session identity (full leave / new join as new participant).
    func resetSession() {
        callSessionId = nil
        lastEventCursor = 0
    }

    func send(_ message: SignalingMessage) {
        guard state == .connected || state == .reconnecting else {
            log.append("signaling: send dropped (state=\(state.rawValue)) type=\(message.type)")
            return
        }
        do {
            let data = try JSONEncoder().encode(message)
            guard let text = String(data: data, encoding: .utf8) else { return }
            if useMock {
                mockLoop?.clientSend(text)
            } else if let task = webSocketTask {
                task.send(.string(text)) { [weak self] error in
                    Task { @MainActor in
                        if let error {
                            self?.log.append("signaling: send error \(error.localizedDescription)")
                        }
                    }
                }
            }
            log.append("signaling → \(message.type) callSessionId=\(message.callSessionId ?? "nil") cursor=\(message.cursor.map(String.init) ?? "nil") reconnectReason=\(message.reconnectReason ?? "-")")
        } catch {
            log.append("signaling: encode failed \(error.localizedDescription)")
        }
    }

    /// Explicit resume handshake after a blip (same callSessionId + cursor + reconnectReason).
    func sendResumeHandshake(reconnectReason: String = "ws_drop") {
        guard let sid = callSessionId else {
            log.append("signaling: resume skipped — no callSessionId (will join fresh)")
            sendJoin(reconnect: false)
            return
        }
        lastReconnectReason = reconnectReason
        let msg = SignalingMessage(
            type: "resume",
            room: room,
            callSessionId: sid,
            cursor: lastEventCursor,
            reconnect: true,
            ok: nil,
            reason: nil,
            preferAudio: nil,
            reconnectReason: reconnectReason
        )
        send(msg)
    }

    func sendJoin(reconnect: Bool) {
        let msg = SignalingMessage(
            type: "join",
            room: room,
            callSessionId: reconnect ? callSessionId : nil,
            cursor: reconnect ? lastEventCursor : 0,
            reconnect: reconnect,
            ok: nil,
            reason: nil,
            preferAudio: nil,
            reconnectReason: nil
        )
        send(msg)
    }

    // MARK: - Transport

    private func openTransport(isResume: Bool) {
        tearDownTransport(reason: nil)
        setState(isResume ? .reconnecting : .connecting)
        log.append(
            "signaling: \(isResume ? "reconnecting" : "connecting") url=\(url.absoluteString) room=\(room) callSessionId=\(callSessionId ?? "nil") cursor=\(lastEventCursor)"
        )

        if useMock {
            let loop = MockSignalingLoop { [weak self] text in
                Task { @MainActor in
                    self?.handleIncomingText(text)
                }
            }
            mockLoop = loop
            loop.start()
            setState(.connected)
            lastError = nil
            log.append("signaling: mock://local connected (in-process loopback)")
            if isResume, callSessionId != nil {
                sendResumeHandshake(reconnectReason: lastReconnectReason)
            } else {
                sendJoin(reconnect: false)
            }
            return
        }

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        let urlSession = URLSession(configuration: config)
        session = urlSession
        let task = urlSession.webSocketTask(with: url)
        webSocketTask = task
        task.resume()
        setState(.connected)
        lastError = nil
        startReceiveLoop()
        if isResume, callSessionId != nil {
            sendResumeHandshake(reconnectReason: lastReconnectReason)
        } else {
            sendJoin(reconnect: false)
        }
    }

    private func tearDownTransport(reason: String?) {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        mockLoop?.stop()
        mockLoop = nil
        if let reason {
            log.append("signaling: transport down (\(reason))")
        }
    }

    private func startReceiveLoop() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                guard let task = self.webSocketTask else { break }
                do {
                    let message = try await task.receive()
                    switch message {
                    case .string(let text):
                        await MainActor.run { self.handleIncomingText(text) }
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            await MainActor.run { self.handleIncomingText(text) }
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    await MainActor.run {
                        self.handleTransportFailure(error.localizedDescription)
                    }
                    break
                }
            }
        }
    }

    private func handleIncomingText(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        do {
            let msg = try JSONDecoder().decode(SignalingMessage.self, from: data)
            applyServerMessage(msg)
            onMessage?(msg)
            log.append("signaling ← \(msg.type) callSessionId=\(msg.callSessionId ?? "nil") cursor=\(msg.cursor.map(String.init) ?? "nil") ok=\(msg.ok.map(String.init(describing:)) ?? "-") reconnectReason=\(msg.reconnectReason ?? "-")")
        } catch {
            log.append("signaling: bad JSON \(error.localizedDescription) raw=\(text.prefix(120))")
        }
    }

    private func applyServerMessage(_ msg: SignalingMessage) {
        switch msg.type {
        case "joinAck":
            if let sid = msg.callSessionId {
                callSessionId = sid
            }
            if let c = msg.cursor {
                lastEventCursor = c
            }
            reconnectAttempt = 0
        case "resumeAck":
            if msg.ok == false {
                // Server rejected resume → treat as fresh join next time.
                log.append("signaling: resume rejected — clearing callSessionId for rejoin")
                callSessionId = nil
                lastEventCursor = 0
            } else {
                if let sid = msg.callSessionId { callSessionId = sid }
                if let c = msg.cursor { lastEventCursor = max(lastEventCursor, c) }
                reconnectAttempt = 0
            }
        case "event", "sync":
            if let c = msg.cursor {
                lastEventCursor = max(lastEventCursor, c)
            }
        default:
            if let c = msg.cursor {
                lastEventCursor = max(lastEventCursor, c)
            }
        }
    }

    private func handleTransportFailure(_ reason: String) {
        lastError = reason
        log.append("signaling: failure \(reason)")
        tearDownTransport(reason: nil)
        guard wantsConnection else {
            setState(.disconnected)
            return
        }
        scheduleReconnect()
    }

    /// Simulate a signal-only drop (for Force signal drop). Keeps callSessionId/cursor.
    func simulateDrop() {
        guard wantsConnection else { return }
        lastReconnectReason = "forced"
        log.append("signaling: simulated drop (callSessionId=\(callSessionId ?? "nil") cursor=\(lastEventCursor) reconnectReason=forced)")
        tearDownTransport(reason: "simulated drop")
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        setState(.reconnecting)
        reconnectTask?.cancel()
        let attempt = reconnectAttempt
        reconnectAttempt += 1
        // Exponential backoff: 0.5s, 1s, 2s, 4s … capped at 8s
        let delay = min(8.0, 0.5 * pow(2.0, Double(attempt)))
        log.append("signaling: backoff \(String(format: "%.1f", delay))s attempt=\(reconnectAttempt)")
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.wantsConnection else { return }
            self.openTransport(isResume: self.callSessionId != nil)
        }
    }

    private func setState(_ new: SignalingState) {
        guard state != new else { return }
        state = new
        onStateChange?(new)
    }
}

// MARK: - In-process mock (mock://local)

/// Tiny loopback that answers join / resume without a real socket.
/// Prefer this over `NWListener` on iOS Simulator — no bind/port/ATS.
final class MockSignalingLoop: @unchecked Sendable {
    private let onServerMessage: @Sendable (String) -> Void
    private var running = false
    private var callSessionId: String?
    private var serverCursor: Int = 0
    private let queue = DispatchQueue(label: "WebRTCReconnectMock.MockSignalingLoop")

    init(onServerMessage: @escaping @Sendable (String) -> Void) {
        self.onServerMessage = onServerMessage
    }

    func start() {
        queue.sync { running = true }
    }

    func stop() {
        queue.sync { running = false }
    }

    func clientSend(_ text: String) {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.handleClientJSON(text)
        }
    }

    private func handleClientJSON(_ text: String) {
        guard let data = text.data(using: .utf8),
              let msg = try? JSONDecoder().decode(SignalingMessage.self, from: data) else {
            reply(SignalingMessage(type: "error", room: nil, callSessionId: nil, cursor: nil, reconnect: nil, ok: false, reason: "bad_json", preferAudio: nil, reconnectReason: nil))
            return
        }

        switch msg.type {
        case "join":
            if callSessionId == nil {
                callSessionId = UUID().uuidString.lowercased()
                serverCursor = 0
            }
            // Fresh join resets cursor when reconnect!=true or no prior session match
            if msg.reconnect != true {
                serverCursor = 0
                if msg.callSessionId == nil {
                    callSessionId = UUID().uuidString.lowercased()
                }
            }
            reply(SignalingMessage(
                type: "joinAck",
                room: msg.room,
                callSessionId: callSessionId,
                cursor: serverCursor,
                reconnect: msg.reconnect,
                ok: true,
                reason: nil,
                preferAudio: nil,
                reconnectReason: nil
            ))
            // Emit a synthetic room event so cursor advances.
            serverCursor += 1
            reply(SignalingMessage(
                type: "event",
                room: msg.room,
                callSessionId: callSessionId,
                cursor: serverCursor,
                reconnect: nil,
                ok: true,
                reason: "participant_joined",
                preferAudio: nil,
                reconnectReason: nil
            ))

        case "resume":
            let ok: Bool
            if let sid = msg.callSessionId, sid == callSessionId {
                ok = true
            } else if callSessionId == nil, let sid = msg.callSessionId {
                // First mock process after app relaunch: accept and adopt client session.
                callSessionId = sid
                serverCursor = msg.cursor ?? 0
                ok = true
            } else {
                ok = false
            }
            if ok {
                let clientCursor = msg.cursor ?? 0
                reply(SignalingMessage(
                    type: "resumeAck",
                    room: msg.room,
                    callSessionId: callSessionId,
                    cursor: max(serverCursor, clientCursor),
                    reconnect: true,
                    ok: true,
                    reason: nil,
                    preferAudio: nil,
                    reconnectReason: msg.reconnectReason
                ))
                // Gap-fill: if client is behind, bump an event.
                if clientCursor < serverCursor {
                    reply(SignalingMessage(
                        type: "event",
                        room: msg.room,
                        callSessionId: callSessionId,
                        cursor: serverCursor,
                        reconnect: nil,
                        ok: true,
                        reason: "replay",
                        preferAudio: nil,
                        reconnectReason: nil
                    ))
                } else {
                    serverCursor = max(serverCursor, clientCursor)
                }
            } else {
                reply(SignalingMessage(
                    type: "resumeAck",
                    room: msg.room,
                    callSessionId: nil,
                    cursor: 0,
                    reconnect: true,
                    ok: false,
                    reason: "unknown_session",
                    preferAudio: nil,
                    reconnectReason: nil
                ))
            }

        default:
            reply(SignalingMessage(
                type: "ack",
                room: msg.room,
                callSessionId: callSessionId,
                cursor: serverCursor,
                reconnect: nil,
                ok: true,
                reason: msg.type,
                preferAudio: nil,
                reconnectReason: nil
            ))
        }
    }

    private func reply(_ message: SignalingMessage) {
        guard running else { return }
        guard let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8) else { return }
        // Slight async to mimic network.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.onServerMessage(text)
        }
    }
}
