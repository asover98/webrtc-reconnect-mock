import Foundation

enum LayoutSizeClass: String, Equatable, Sendable {
    case compact
    case regular
}

enum LayoutMode: String, Equatable, Sendable {
    case grid
    case list
    case focusSpeaking
}

struct LayoutPlan: Equatable, Sendable {
    var mode: LayoutMode
    var columns: Int
    var orderedTileIds: [String]
    var reason: String
}

/// Chooses a simple grid/list layout from roster + size class. Deterministic.
struct LayoutAdaptivityAgent {
    func plan(roster: TileRosterSnapshot, sizeClass: LayoutSizeClass) -> LayoutPlan {
        let ids = roster.tiles.map(\.id)
        let count = ids.count

        if count == 0 {
            return LayoutPlan(mode: .grid, columns: 1, orderedTileIds: [], reason: "empty")
        }

        let speaking = roster.tiles.first(where: \.isSpeaking)?.id
        if let speaking, count >= 4 {
            var ordered = [speaking] + ids.filter { $0 != speaking }
            return LayoutPlan(
                mode: .focusSpeaking,
                columns: sizeClass == .regular ? 3 : 2,
                orderedTileIds: ordered,
                reason: "focus_speaking"
            )
        }

        if sizeClass == .compact && count > 2 {
            return LayoutPlan(mode: .list, columns: 1, orderedTileIds: ids, reason: "compact_list")
        }

        let columns: Int
        switch (sizeClass, count) {
        case (.regular, 1...1): columns = 1
        case (.regular, 2...4): columns = 2
        case (.regular, _): columns = 3
        case (.compact, 1...1): columns = 1
        default: columns = 2
        }

        return LayoutPlan(mode: .grid, columns: columns, orderedTileIds: ids, reason: "grid")
    }
}
