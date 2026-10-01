import Foundation
import Observation

/// What the widgets show beyond chats and tasks: the default agent's latest
/// Feed posts and Goals, and the colors picked in Settings. The shell keeps it
/// current; the widget snapshot publisher reads it.
@MainActor
@Observable
final class BighelpWidgetExtras {
    static let shared = BighelpWidgetExtras()

    var feed: [BighelpWidgetSnapshot.BoardItem] = []
    var goals: [BighelpWidgetSnapshot.BoardItem] = []
    var lightPalette: BighelpWidgetSnapshot.Palette?
    var darkPalette: BighelpWidgetSnapshot.Palette?

    func update(board: AgentBoardStore) {
        let feed = board.feed.sorted { $0.createdAt > $1.createdAt }.prefix(4).map {
            BighelpWidgetSnapshot.BoardItem(id: $0.id, title: Self.clip($0.title, 70), icon: String($0.icon.prefix(1)),
                                           note: $0.source.isEmpty ? nil : Self.clip($0.source, 40), date: $0.createdAt)
        }
        let goals = board.goals.sorted { ($0.isDone ? 1 : 0, $0.createdAt) < ($1.isDone ? 1 : 0, $1.createdAt) }
            .prefix(4).map {
                BighelpWidgetSnapshot.BoardItem(id: $0.id, title: Self.clip($0.title, 60), icon: String($0.icon.prefix(1)),
                                               note: $0.note.isEmpty ? nil : Self.clip($0.note, 80),
                                               isDone: $0.isDone, date: $0.updatedAt)
            }
        if Array(feed) != self.feed { self.feed = Array(feed) }
        if Array(goals) != self.goals { self.goals = Array(goals) }
    }

    func update(appearance context: BighelpAppearanceContext) {
        func palette(_ scheme: AppAppearance) -> BighelpWidgetSnapshot.Palette {
            let theme = BighelpTheme.resolve(
                appearance: BighelpAppearanceContext(
                    appearance: scheme,
                    lightBackground: context.lightBackground, darkBackground: context.darkBackground,
                    bubbleColor: context.bubbleColor, customBubbleHex: context.customBubbleHex),
                colorScheme: scheme == .dark ? .dark : .light, contrast: .standard)
            return .init(canvasHex: theme.canvasHex, surfaceHex: theme.surfaceHex,
                         primaryTextHex: theme.primaryTextHex, secondaryTextHex: theme.secondaryTextHex,
                         accentHex: theme.actionHex, accentForegroundHex: theme.actionForegroundHex)
        }
        let light = palette(.light), dark = palette(.dark)
        if light != lightPalette { lightPalette = light }
        if dark != darkPalette { darkPalette = dark }
    }

    private static func clip(_ value: String, _ limit: Int) -> String {
        let collapsed = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count <= limit ? collapsed : String(collapsed.prefix(limit - 1)) + "…"
    }
}
