import Foundation
import Combine

/// In-app scrolling status log shared by WebRTC + path monitor + signaling.
/// Lines are stamped with ISO-8601 (UTC, fractional seconds).
@MainActor
final class StatusLog: ObservableObject {
    @Published private(set) var lines: [String] = []

    private let maxLines = 200
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func append(_ message: String) {
        let stamp = iso.string(from: Date())
        lines.append("[\(stamp)] \(message)")
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    func clear() {
        lines.removeAll()
    }

    func joinedText() -> String {
        lines.joined(separator: "\n")
    }
}
