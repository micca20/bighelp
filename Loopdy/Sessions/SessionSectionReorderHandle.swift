import SwiftUI

/// A normal button leaves the long press available to native drag. A Menu
/// opens on touch-down and can consume that gesture before the drag starts.
@MainActor
struct SessionSectionReorderHandle: View {
    let title: String
    let identifier: String
    let canMoveUp: Bool
    let canMoveDown: Bool
    let move: (SessionSectionMoveDirection) -> Void
    let drag: () -> NSItemProvider
    @State private var showsActions = false

    var body: some View {
        Button("Reorder \(title)", systemImage: "line.3.horizontal") {
            showsActions = true
        }
        .labelStyle(.iconOnly)
        .frame(width: LoopdyTokens.hitTarget, height: LoopdyTokens.hitTarget)
        .contentShape(.rect)
        .accessibilityHint("Drag to another project section, or tap for Move Up and Move Down.")
        .accessibilityIdentifier(identifier)
        .onDrag { drag() }
        .confirmationDialog("Reorder \(title)", isPresented: $showsActions, titleVisibility: .visible) {
            Button("Move Up", systemImage: "arrow.up") { move(.up) }
                .disabled(!canMoveUp)
            Button("Move Down", systemImage: "arrow.down") { move(.down) }
                .disabled(!canMoveDown)
            Button("Cancel", role: .cancel) {}
        }
        .accessibilityAction(named: "Move Up") { if canMoveUp { move(.up) } }
        .accessibilityAction(named: "Move Down") { if canMoveDown { move(.down) } }
    }
}
