#if os(visionOS)
import RealityKit
import SwiftUI

/// The 3D agent inside a window: the same sculpted character as in the room,
/// standing a little out of the glass. Drag to turn it; pinch for a hop.
struct SpatialAvatarPreview: View {
    let look: SpatialAvatarLook
    /// An engine mood to act out ("thinking", "dance"…), or nil to idle.
    var mood: String?
    /// How tall its space is, in points; it's a little narrower than tall.
    var height: CGFloat
    /// Off where a tap on it means something else (Agent Studio opens the designer).
    var isInteractive = true
    var onPinch: (() -> Void)?

    @State private var rig = SpatialAvatarRig()
    @State private var spin: Float = 0
    @State private var spinAtDragStart: Float = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            RealityView { content in
                content.add(rig.root)
                rig.updates = content.subscribe(to: SceneEvents.Update.self) { [rig] _ in rig.update() }
            } update: { content in
                // How many meters a point is in this window's 3D space (1360 points a
                // meter at the usual size), measured rather than assumed.
                let top = content.convert(Point3D(x: 0, y: 0, z: 0), from: .local, to: .scene)
                let below = content.convert(Point3D(x: 0, y: 100, z: 0), from: .local, to: .scene)
                let measured = simd_distance(top, below) / 100
                let metersPerPoint = measured > 0.0001 && measured < 0.01 ? measured : 1 / 1360
                let heightMeters = Float(height) * metersPerPoint
                let scale = heightMeters / SpatialAvatarRig.standingHeight
                // The content's origin is this view's center (the "scene" space it's
                // measured in is the window's). Feet on the bottom edge, forward enough
                // that the glass doesn't cut its back.
                rig.root.scale = SIMD3(repeating: scale)
                // A little above the bottom, so hops and tails stay inside.
                rig.root.position = [0, -heightMeters * 0.44, SpatialAvatarRig.reach * scale]
                rig.root.orientation = simd_quatf(angle: spin, axis: [0, 1, 0])
                rig.show(look)
                rig.mood = mood
                rig.reduceMotion = reduceMotion
            }
            .allowsHitTesting(false)
            // Vision Pro only targets what's drawn, so this can't be fully clear.
            Color.white.opacity(0.001)
        }
        .frame(width: height * 0.9, height: height)
        .modifier(PreviewGestures(isEnabled: isInteractive, onTap: {
            rig.poke()
            onPinch?()
        }, onTurn: { width in
            spin = spinAtDragStart + Float(width) * 0.012
        }, onTurnEnded: {
            spinAtDragStart = spin
        }))
    }
}

private struct PreviewGestures: ViewModifier {
    let isEnabled: Bool
    let onTap: () -> Void
    let onTurn: (CGFloat) -> Void
    let onTurnEnded: () -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .onTapGesture(perform: onTap)
                .simultaneousGesture(DragGesture(minimumDistance: 10)
                    .onChanged { onTurn($0.translation.width) }
                    .onEnded { _ in onTurnEnded() })
        } else {
            content
        }
    }
}
#endif
