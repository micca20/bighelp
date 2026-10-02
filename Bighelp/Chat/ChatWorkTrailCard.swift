import SwiftUI

/// A run of tool calls as one quiet activity line: what the agent is doing now
/// ("Searching the web… · 2 steps"), or how the run ended. It unfolds the
/// steps underneath. In the chat each step is its own recycled row
/// (`rendersExpandedEvents: false`); elsewhere they're drawn here.
struct ChatWorkTrailCard: View {
    let turn: ChatActivityTurn
    let rendersExpandedEvents: Bool
    /// What the live turn is waiting on the person for, if anything.
    let waiting: ChatActivityWaiting?
    let onDisclosureChange: () -> Void

    @Environment(\.chatActivityDisclosureStore) private var inheritedDisclosures
    @State private var localDisclosures = ChatActivityDisclosureStore()
    private var disclosures: ChatActivityDisclosureStore { inheritedDisclosures ?? localDisclosures }
    private var isExpanded: Bool { disclosures.isExpanded(turn) }

    init(
        turn: ChatActivityTurn,
        rendersExpandedEvents: Bool = true,
        waiting: ChatActivityWaiting? = nil,
        onDisclosureChange: @escaping () -> Void = {}
    ) {
        self.turn = turn
        self.rendersExpandedEvents = rendersExpandedEvents
        self.waiting = waiting
        self.onDisclosureChange = onDisclosureChange
    }

    var body: some View {
        let disclosures = disclosures
        VStack(alignment: .leading, spacing: 0) {
            BighelpActivityRow(
                phase: ChatActivityPresentation.trailPhase(for: turn.events, waiting: waiting),
                stepCount: ChatActivityPresentation.stepCount(of: turn.events),
                detailsBelow: true,
                isExpanded: Binding(get: { disclosures.isExpanded(turn) },
                                    set: { disclosures.setExpanded($0, for: turn) }),
                onDisclosureChange: onDisclosureChange,
                accessibilityIdentifier: "chat.work-trail.\(turn.id)"
            )
            if isExpanded, rendersExpandedEvents {
                ForEach(turn.events) { event in
                    ChatActivityRow(event: event, onDisclosureChange: onDisclosureChange)
                }
                .modifier(ChatToolDetailStyle())
            }
        }
        .environment(\.chatActivityDisclosureStore, disclosures)
    }
}

enum ChatActivityDisclosureAccessibility {
    static func value(isExpanded: Bool) -> String {
        isExpanded ? "Expanded" : "Collapsed"
    }
}
