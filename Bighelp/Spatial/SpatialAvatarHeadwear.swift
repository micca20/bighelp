#if os(visionOS)
import RealityKit
import SwiftUI
import UIKit

/// Agent Studio headwear in 3D: the same shapes and colors as the 2D painter
/// (BuddyPainter.topper), built as real objects on top of the head. Sizes are
/// in art units; the head's top is at (x, y) and the headwear is `width` wide.
@MainActor
enum SpatialAvatarHeadwear {
    struct Piece {
        let entity: ModelEntity
        /// Where the mesh sits, in the rig's y-flipped art units.
        let placement: simd_float4x4
        var floats = false
    }

    static func pieces(_ topper: CompanionTopper, x: CGFloat, y: CGFloat, width w: CGFloat,
                       bodyHex: String) -> [Piece] {
        switch topper {
        case .none:
            return []
        case .catEars:
            return [-1.0, 1.0].flatMap { (side: CGFloat) -> [Piece] in
                let base = x + side * w * 0.3
                let ear = polygon([(base - side * w * 0.17, y + w * 0.1), (base + side * w * 0.06, y - w * 0.36),
                                   (base + side * w * 0.2, y + w * 0.04)])
                let inner = polygon([(base - side * w * 0.08, y + w * 0.05), (base + side * w * 0.05, y - w * 0.22),
                                     (base + side * w * 0.12, y + w * 0.02)])
                let earDepth = w * 0.09
                return [
                    solid(ear, material: vinyl(bodyHex), halfDepth: earDepth),
                    solid(inner, material: vinyl(BuddyPalette.blushHex), halfDepth: earDepth * 0.35,
                          forward: earDepth * 0.72),
                ].compactMap { $0 }
            }
        case .bearEars:
            return [-1.0, 1.0].flatMap { (side: CGFloat) -> [Piece] in
                let center = SIMD3(Float(x + side * w * 0.34), Float(-(y - w * 0.02)), 0)
                let radius = Float(w * 0.16)
                let ear = Piece(entity: ModelEntity(mesh: .generateSphere(radius: radius), materials: [vinyl(bodyHex)]),
                                placement: translation(center) * scaling([1, 1, 0.7]))
                let inner = Piece(entity: ModelEntity(mesh: .generateSphere(radius: radius * 0.52),
                                                      materials: [vinyl(CompanionColor.shade(bodyHex, by: 0.4))]),
                                  placement: translation(center + [0, 0, radius * 0.55]) * scaling([1, 1, 0.35]))
                return [ear, inner]
            }
        case .crown:
            let ring = Float(w * 0.29)
            let bandHeight = Float(w * 0.15)
            let bandCenter = SIMD3(Float(x), Float(-(y - w * 0.05)), 0)
            var pieces = [Piece(entity: ModelEntity(mesh: .generateCylinder(height: bandHeight, radius: ring),
                                                    materials: [gold()]),
                                placement: translation(bandCenter))]
            let spikeHeight = Float(w * 0.2)
            for index in 0..<8 {
                let angle = Float(index) / 8 * 2 * .pi
                let spot = bandCenter + [sin(angle) * ring * 0.92, bandHeight / 2 + spikeHeight / 2, cos(angle) * ring * 0.92]
                pieces.append(Piece(entity: ModelEntity(mesh: .generateCone(height: spikeHeight, radius: Float(w * 0.065)),
                                                        materials: [gold()]),
                                    placement: translation(spot)))
            }
            for (angle, hex) in [(-0.55, "#FF5A7A"), (0.0, "#5AB0FF"), (0.55, "#5CE0A0")] as [(Float, String)] {
                let spot = bandCenter + [sin(angle) * ring, 0, cos(angle) * ring]
                pieces.append(Piece(entity: ModelEntity(mesh: .generateSphere(radius: Float(w * 0.045)),
                                                        materials: [gem(hex)]),
                                    placement: translation(spot)))
            }
            return pieces
        case .halo:
            var ring = Path()
            ring.addArc(center: .zero, radius: w * 0.3, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
            ring.closeSubpath()
            ring.addArc(center: .zero, radius: w * 0.21, startAngle: .zero, endAngle: .degrees(360), clockwise: true)
            ring.closeSubpath()
            var options = MeshResource.ShapeExtrusionOptions()
            options.extrusionMethod = .linear(depth: Float(w * 0.05))
            options.chamferRadius = Float(w * 0.02)
            options.boundaryResolution = .uniformSegmentsPerSpan(segmentCount: 12)
            guard let mesh = try? MeshResource(extruding: ring, extrusionOptions: options) else { return [] }
            var glow = gold()
            glow.emissiveColor = .init(color: UIColor(Color(buddyHex: "#FFE9A3")))
            glow.emissiveIntensity = 0.8
            let lying = simd_float4x4(simd_quatf(angle: .pi / 2, axis: [1, 0, 0]))
            return [Piece(entity: ModelEntity(mesh: mesh, materials: [glow]),
                          placement: translation([Float(x), Float(-(y - w * 0.26)), 0]) * lying, floats: true)]
        case .devilHorns:
            return [-1.0, 1.0].compactMap { (side: CGFloat) -> Piece? in
                let base = x + side * w * 0.26
                var horn = Path()
                horn.move(to: CGPoint(x: base - side * w * 0.1, y: y + w * 0.06))
                horn.addQuadCurve(to: CGPoint(x: base + side * w * 0.16, y: y - w * 0.3),
                                  control: CGPoint(x: base - side * w * 0.08, y: y - w * 0.18))
                horn.addQuadCurve(to: CGPoint(x: base + side * w * 0.1, y: y + w * 0.06),
                                  control: CGPoint(x: base + side * w * 0.14, y: y - w * 0.08))
                horn.closeSubpath()
                return solid(horn, material: vinyl("#E5484D", shine: 0.9), halfDepth: w * 0.07)
            }
        case .sprout:
            let stemHeight = Float(w * 0.3)
            var pieces = [Piece(entity: ModelEntity(mesh: .generateCylinder(height: stemHeight, radius: Float(w * 0.025)),
                                                    materials: [vinyl("#3FA35B")]),
                                placement: translation([Float(x), Float(-(y - w * 0.12)), 0]))]
            let tip = CGPoint(x: x, y: y - w * 0.28)
            for (dx, degrees) in [(-w * 0.12, -20.0), (w * 0.12, 25.0)] as [(CGFloat, Double)] {
                let leaf = Path(ellipseIn: CGRect(x: tip.x + dx - w * 0.13, y: tip.y - w * 0.065, width: w * 0.26, height: w * 0.13))
                    .applying(CGAffineTransform(translationX: tip.x, y: tip.y).rotated(by: degrees * .pi / 180)
                        .translatedBy(x: -tip.x, y: -tip.y))
                if let piece = solid(leaf, material: vinyl("#5DCB6A"), halfDepth: w * 0.035) { pieces.append(piece) }
            }
            return pieces
        case .swoosh:
            var tuft = Path()
            tuft.move(to: CGPoint(x: x - w * 0.08, y: y + w * 0.06))
            tuft.addQuadCurve(to: CGPoint(x: x + w * 0.2, y: y - w * 0.28), control: CGPoint(x: x - w * 0.12, y: y - w * 0.3))
            tuft.addQuadCurve(to: CGPoint(x: x + w * 0.1, y: y + w * 0.06), control: CGPoint(x: x + w * 0.02, y: y - w * 0.14))
            tuft.closeSubpath()
            return [solid(tuft, material: vinyl(CompanionColor.shade(bodyHex, by: -0.2)), halfDepth: w * 0.08)]
                .compactMap { $0 }
        }
    }

    // MARK: Building blocks

    /// A rounded solid from a flat outline in art coordinates.
    private static func solid(_ path: Path, material: PhysicallyBasedMaterial, halfDepth: CGFloat,
                              forward: CGFloat = 0) -> Piece? {
        let bounds = path.boundingRect
        guard let mesh = SpatialAvatarSculpt.mesh(path, slices: SpatialAvatarSculpt.solidSlices(
            center: CGPoint(x: bounds.midX, y: -bounds.midY), halfDepth: halfDepth)) else { return nil }
        return Piece(entity: ModelEntity(mesh: mesh, materials: [material]),
                     placement: translation([0, 0, Float(forward)]))
    }

    private static func polygon(_ points: [(CGFloat, CGFloat)]) -> Path {
        var path = Path()
        path.addLines(points.map { CGPoint(x: $0.0, y: $0.1) })
        path.closeSubpath()
        return path
    }

    private static func translation(_ offset: SIMD3<Float>) -> simd_float4x4 {
        var matrix = matrix_identity_float4x4
        matrix.columns.3 = SIMD4(offset, 1)
        return matrix
    }

    private static func scaling(_ factors: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(diagonal: SIMD4(factors, 1))
    }

    private static func vinyl(_ hex: String, shine: Float = 0.35) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: UIColor(Color(buddyHex: hex)))
        material.roughness = 0.5
        material.clearcoat = .init(floatLiteral: shine)
        material.clearcoatRoughness = 0.3
        return material
    }

    private static func gold() -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: UIColor(Color(buddyHex: BuddyPalette.goldHex)))
        material.metallic = 1.0
        material.roughness = 0.28
        return material
    }

    private static func gem(_ hex: String) -> PhysicallyBasedMaterial {
        var material = vinyl(hex, shine: 1)
        material.roughness = 0.1
        return material
    }
}
#endif
