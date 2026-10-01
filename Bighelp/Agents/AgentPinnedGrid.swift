import SwiftUI

/// The Pinned grid on Agents. Tap opens an agent's chat. Touch and hold lifts
/// the agent: drag it to a new place and the others make room (pinned agents
/// only), or let go without moving to see that agent's actions.
///
/// Long-press menus can't be used here: the grid is one List row, and a List
/// row shows the first menu in it whichever agent was pressed.
struct AgentPinnedGrid: View {
    let agents: [AgentProfile]
    let canReorder: Bool
    let imageURL: (AgentProfile) -> URL?
    let liveState: (AgentProfile) -> AgentLiveState
    let isPrimary: (AgentProfile) -> Bool
    let open: (AgentProfile) -> Void
    let manage: (AgentProfile) -> Void
    let reorder: ([String]) -> Void
    let create: (() -> Void)?
    @Binding var isArranging: Bool

    private struct Lift: Equatable {
        let id: String
        /// Where each place in the grid was when the agent was lifted.
        let slots: [CGRect]
        /// The finger's spot within the lifted tile.
        let grab: CGSize
        var location: CGPoint
        var moved = false
    }

    private static let space = "agents.pinned"
    @State private var frames: [String: CGRect] = [:]
    @State private var arrangement: [AgentProfile]?
    @State private var lift: Lift?
    @GestureState private var isPressing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shown: [AgentProfile] { arrangement ?? agents }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: BighelpTokens.space8, alignment: .top), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: BighelpTokens.space12) {
            ForEach(shown) { agent in tile(agent) }
            if let create {
                AgentNewTile(action: create)
                    .accessibilityIdentifier("agents.featured.create")
            }
        }
        .coordinateSpace(.named(Self.space))
        .onChange(of: isPressing) { _, pressing in
            // Ends a lift however the touch ended, including a cancelled one.
            if !pressing { finish() }
        }
    }

    private func tile(_ agent: AgentProfile) -> some View {
        let lifted = lift?.id == agent.id
        return AgentFeaturedTile(
            agent: agent, imageURL: imageURL(agent), liveState: liveState(agent),
            isPrimary: isPrimary(agent), isLifted: lifted
        )
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frames[agent.id] = $0 }
        .offset(lifted ? offset(for: agent) : .zero)
        .zIndex(lifted ? 1 : 0)
        .onTapGesture { open(agent) }
        .gesture(press(agent))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(canReorder ? "Opens this agent's chat. Touch and hold to move it or for more actions."
                                      : "Opens this agent's chat. Touch and hold for more actions.")
        .accessibilityAction { open(agent) }
        .accessibilityAction(named: "Manage agent") { manage(agent) }
        .accessibilityAction(named: "Move earlier") { move(agent, by: -1) }
        .accessibilityAction(named: "Move later") { move(agent, by: 1) }
        .accessibilityIdentifier("agents.featured.\(agent.id)")
    }

    private func press(_ agent: AgentProfile) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)))
            .updating($isPressing) { value, pressing, _ in
                if case .second(true, _) = value { pressing = true }
            }
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if lift == nil { begin(agent, at: drag?.startLocation) }
                if let drag { follow(to: drag.location, translation: drag.translation) }
            }
    }

    private func begin(_ agent: AgentProfile, at start: CGPoint?) {
        let slots = agents.map { frames[$0.id] ?? .zero }
        guard let index = agents.firstIndex(where: { $0.id == agent.id }) else { return }
        let slot = slots[index]
        let point = start ?? CGPoint(x: slot.midX, y: slot.midY)
        BighelpHaptics.tap(rigid: true)
        isArranging = true
        arrangement = agents
        withAnimation(.snappy(duration: 0.2)) {
            lift = Lift(id: agent.id, slots: slots,
                        grab: CGSize(width: point.x - slot.minX, height: point.y - slot.minY), location: point)
        }
    }

    private func follow(to location: CGPoint, translation: CGSize) {
        guard var current = lift else { return }
        current.location = location
        if hypot(translation.width, translation.height) > 8 { current.moved = true }
        lift = current
        guard canReorder, current.moved, var order = arrangement,
              let from = order.firstIndex(where: { $0.id == current.id }),
              let to = nearestSlot(to: location, in: current.slots), to != from else { return }
        let agent = order.remove(at: from)
        order.insert(agent, at: to)
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { arrangement = order }
    }

    private func finish() {
        guard let finished = lift else { return }
        let order = arrangement?.map(\.id)
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
            lift = nil
            arrangement = nil
        }
        isArranging = false
        if !finished.moved, let agent = agents.first(where: { $0.id == finished.id }) {
            manage(agent)
        } else if canReorder, let order, order != agents.map(\.id) {
            reorder(order)
        }
    }

    /// Keeps the lifted tile under the finger while the grid reflows around it.
    private func offset(for agent: AgentProfile) -> CGSize {
        guard let lift, let index = shown.firstIndex(where: { $0.id == agent.id }),
              lift.slots.indices.contains(index) else { return .zero }
        let slot = lift.slots[index]
        return CGSize(width: lift.location.x - lift.grab.width - slot.minX,
                      height: lift.location.y - lift.grab.height - slot.minY)
    }

    private func nearestSlot(to point: CGPoint, in slots: [CGRect]) -> Int? {
        if let inside = slots.firstIndex(where: { $0.contains(point) }) { return inside }
        return slots.indices.min { lhs, rhs in
            hypot(slots[lhs].midX - point.x, slots[lhs].midY - point.y)
                < hypot(slots[rhs].midX - point.x, slots[rhs].midY - point.y)
        }
    }

    private func move(_ agent: AgentProfile, by step: Int) {
        guard canReorder, let index = agents.firstIndex(where: { $0.id == agent.id }),
              agents.indices.contains(index + step) else { return }
        var order = agents.map(\.id)
        order.swapAt(index, index + step)
        reorder(order)
    }
}
