import SwiftUI

/// Vision Pro's pinch-and-drag between lanes. Pinch a card and move your hand:
/// it lifts toward you and follows, the lane under it lights up, and letting
/// go drops it there. A pinch without moving still opens the card.
@MainActor @Observable
final class KanbanSpatialDrag {
    static let space = "kanban.board"

    private(set) var task: HermesKanbanTask?
    /// Where the card sat when it was picked up, in the board's space.
    private(set) var origin: CGRect = .zero
    private(set) var translation: CGSize = .zero
    private(set) var location: CGPoint = .zero
    @ObservationIgnored var laneFrames: [KanbanLane: CGRect] = [:]

    /// The lane the card would land in, if it can go there.
    var target: KanbanLane? {
        guard let task, let lane = laneFrames.first(where: { $0.value.contains(location) })?.key,
              lane.accepts(task) else { return nil }
        return lane
    }

    func move(_ task: HermesKanbanTask, from origin: CGRect, translation: CGSize, location: CGPoint) {
        if self.task?.id != task.id {
            self.task = task
            self.origin = origin
        }
        self.translation = translation
        self.location = location
    }

    /// Ends the drag; returns the card and its new lane when it was dropped on one.
    func drop() -> (HermesKanbanTask, KanbanLane)? {
        defer {
            task = nil
            translation = .zero
        }
        guard let task, let target else { return nil }
        return (task, target)
    }
}

private struct KanbanSpatialDragKey: EnvironmentKey {
    static let defaultValue: KanbanSpatialDrag? = nil
}

extension EnvironmentValues {
    /// Set on Vision Pro's board; cards use it instead of the system drag.
    var kanbanSpatialDrag: KanbanSpatialDrag? {
        get { self[KanbanSpatialDragKey.self] }
        set { self[KanbanSpatialDragKey.self] = newValue }
    }
}

extension View {
    /// Pinch-and-drag for one card on Vision Pro's board.
    @ViewBuilder
    func kanbanSpatialDraggable(_ task: HermesKanbanTask, drag: KanbanSpatialDrag?, frame: CGRect,
                                drop: @escaping (HermesKanbanTask, KanbanLane) -> Void) -> some View {
        if let drag {
            self
                .highPriorityGesture(
                    DragGesture(minimumDistance: 8, coordinateSpace: .named(KanbanSpatialDrag.space))
                        .onChanged { value in
                            drag.move(task, from: frame, translation: value.translation, location: value.location)
                        }
                        .onEnded { _ in
                            withAnimation(.snappy) {
                                if let (task, lane) = drag.drop() { drop(task, lane) }
                            }
                        }
                )
                .opacity(drag.task?.id == task.id ? 0.3 : 1)
        } else {
            self
        }
    }

    /// Reports a lane's frame on the board so a dragged card knows where it is.
    @ViewBuilder
    func kanbanLaneFrame(_ lane: KanbanLane, drag: KanbanSpatialDrag?) -> some View {
        if let drag {
            onGeometryChange(for: CGRect.self) { $0.frame(in: .named(KanbanSpatialDrag.space)) } action: {
                drag.laneFrames[lane] = $0
            }
        } else {
            self
        }
    }
}

/// The picked-up card, floating above the board in front of the lanes.
struct KanbanDraggedCard: View {
    @Bindable var model: KanbanBoardModel
    let drag: KanbanSpatialDrag

    var body: some View {
        if let task = drag.task {
            KanbanCardView(task: task, agent: model.agent(task.assignee))
                .frame(width: drag.origin.width)
                .scaleEffect(1.05)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 14)
                #if os(visionOS)
                .offset(z: 48)
                #endif
                .offset(x: drag.origin.minX + drag.translation.width, y: drag.origin.minY + drag.translation.height)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
