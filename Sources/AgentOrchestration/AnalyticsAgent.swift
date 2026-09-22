import Foundation

/// Ingests stats / log lines → `CallQualityReport`. Deterministic heuristics only.
struct AnalyticsAgent {
    func makeReport(from lines: [String], lastLevel: Int? = nil) -> CallQualityReport {
        let joined = lines.joined(separator: "\n").lowercased()
        var score = 1.0
        var notes: [String] = []

        if joined.contains("path unsatisfied") || joined.contains("path_unsatisfied") {
            score -= 0.5
            notes.append("path_unsatisfied")
        }
        if joined.contains("iceconnectionstate → failed") || joined.contains("ice failed") {
            score -= 0.3
            notes.append("ice_failed")
        }
        if joined.contains("loss=") {
            // crude parse: look for loss=N%
            if let loss = Self.firstDouble(after: "loss=", in: joined) {
                if loss > 10 { score -= 0.25; notes.append("high_loss") }
                else if loss > 3 { score -= 0.1; notes.append("elevated_loss") }
            }
        }
        if joined.contains("preferaudio=true") || joined.contains("protect_audio") {
            score -= 0.05
            notes.append("prefer_audio")
        }
        if let lastLevel {
            score -= Double(lastLevel) * 0.08
            notes.append("level_L\(lastLevel)")
        }

        score = min(1, max(0, score))
        let summary: String
        if notes.isEmpty {
            summary = "healthy"
        } else {
            summary = notes.joined(separator: ",")
        }

        return CallQualityReport(
            score: score,
            summary: summary,
            sampleCount: lines.count,
            lastLevel: lastLevel,
            generatedAt: Date()
        )
    }

    private static func firstDouble(after marker: String, in text: String) -> Double? {
        guard let range = text.range(of: marker) else { return nil }
        let rest = text[range.upperBound...]
        var digits = ""
        for ch in rest {
            if ch.isNumber || ch == "." || ch == "-" {
                digits.append(ch)
            } else if !digits.isEmpty {
                break
            }
        }
        return Double(digits)
    }
}
