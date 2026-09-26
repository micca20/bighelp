enum InboxUpdateContentPolicy {
    enum PrimaryContent: Equatable {
        case generativeUICard
        case loopdyCard
        case fallbackText
    }

    static func primaryContent(for item: DashboardInboxItem) -> PrimaryContent {
        if item.loopdyCard != nil { return .loopdyCard }
        if item.card != nil { return .generativeUICard }
        return .fallbackText
    }
}
