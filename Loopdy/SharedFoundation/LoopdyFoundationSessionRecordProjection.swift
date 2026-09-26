import Foundation

extension LoopdyFoundationSession {
    init(projecting record: SessionRecord, agentName: String) {
        self.init(
            id: record.id,
            title: record.title,
            agentName: agentName,
            updatedAt: record.updatedAt,
            draft: record.draft,
            events: record.items.enumerated().compactMap { offset, item in
                guard case .message(let text) = item.content else { return nil }
                return LoopdyFoundationEvent(
                    id: item.id,
                    role: item.role == .human ? .user : .assistant,
                    text: text,
                    sourceOrder: item.metadata.sourceOrder ?? (offset + 1)
                )
            }
        )
    }
}
