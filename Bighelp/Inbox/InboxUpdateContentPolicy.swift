enum InboxUpdateContentPolicy {
    enum PrimaryContent: Equatable {
        case generativeUICard
        case bighelpCard
        case fallbackText
    }

    static func primaryContent(for item: DashboardInboxItem) -> PrimaryContent {
        if item.bighelpCard != nil { return .bighelpCard }
        if item.card != nil { return .generativeUICard }
        return .fallbackText
    }
}
