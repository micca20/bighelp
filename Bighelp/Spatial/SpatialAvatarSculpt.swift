#if os(visionOS)
import RealityKit
import SwiftUI

/// Turns the kit's flat drawings into rounded 3D parts, like a vinyl toy of
/// the 2D character. Big shapes (bodies, heads, ears, arms) become solids: the
/// outline is swept through shrinking slices, so a circle becomes a ball and a
/// drop becomes a real drop. Small shapes drawn on top of a solid (eyes,
/// mouths, cheeks, patches) are shallow caps laid onto its curved surface.
/// Painted shading and glare are left out; the room's light does that.
enum SpatialAvatarSculpt {
    /// A drawn shape as polygons in art space (y down), for working out how
    /// parts sit on each other.
    struct Outline: Sendable {
        let rings: [[CGPoint]]
        let bounds: CGRect
        var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

        init?(_ path: Path, transform: CGAffineTransform) {
            var rings: [[CGPoint]] = []
            var ring: [CGPoint] = []
            var current = CGPoint.zero
            func flush() {
                if ring.count > 2 { rings.append(ring) }
                ring = []
            }
            path.applying(transform).forEach { element in
                switch element {
                case .move(let point):
                    flush()
                    ring = [point]
                    current = point
                case .line(let point):
                    ring.append(point)
                    current = point
                case .quadCurve(let point, let control):
                    for step in 1...8 {
                        let t = CGFloat(step) / 8
                        let u = 1 - t
                        ring.append(CGPoint(x: u * u * current.x + 2 * u * t * control.x + t * t * point.x,
                                            y: u * u * current.y + 2 * u * t * control.y + t * t * point.y))
                    }
                    current = point
                case .curve(let point, let control1, let control2):
                    for step in 1...10 {
                        let t = CGFloat(step) / 10
                        let u = 1 - t
                        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                        ring.append(CGPoint(x: a * current.x + b * control1.x + c * control2.x + d * point.x,
                                            y: a * current.y + b * control1.y + c * control2.y + d * point.y))
                    }
                    current = point
                case .closeSubpath:
                    flush()
                }
            }
            flush()
            let all = rings.flatMap { $0 }
            guard let first = all.first else { return nil }
            var box = CGRect(origin: first, size: .zero)
            for point in all { box = box.union(CGRect(origin: point, size: .zero)) }
            guard box.width > 0.5, box.height > 0.5 else { return nil }
            self.rings = rings
            self.bounds = box
        }

        var area: CGFloat { bounds.width * bounds.height }

        /// Points around the outline, pulled `inset` of the way toward its center.
        func samples(inset: CGFloat, count: Int = 16) -> [CGPoint] {
            let points = rings.flatMap { $0 }
            guard !points.isEmpty else { return [] }
            let stride = max(points.count / count, 1)
            return Swift.stride(from: 0, to: points.count, by: stride).map { index in
                let point = points[index]
                return CGPoint(x: point.x + (center.x - point.x) * inset, y: point.y + (center.y - point.y) * inset)
            }
        }

        /// How much of this outline lies inside `other` (0–1).
        func share(inside other: Outline) -> CGFloat {
            let points = rings.flatMap { $0 }
            guard !points.isEmpty else { return 0 }
            let stride = max(points.count / 48, 1)
            var inside = 0, total = 0
            for index in Swift.stride(from: 0, to: points.count, by: stride) {
                total += 1
                if other.contains(points[index]) { inside += 1 }
            }
            return CGFloat(inside) / CGFloat(total)
        }

        /// Even-odd, like the fill.
        func contains(_ point: CGPoint) -> Bool {
            var inside = false
            for ring in rings {
                var j = ring.count - 1
                for i in ring.indices {
                    let a = ring[i], b = ring[j]
                    if (a.y > point.y) != (b.y > point.y),
                       point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                        inside.toggle()
                    }
                    j = i
                }
            }
            return inside
        }

        /// How far the outline is from the center in the direction of `point`.
        func reach(toward point: CGPoint) -> CGFloat? {
            let origin = center
            let dx = point.x - origin.x, dy = point.y - origin.y
            let length = hypot(dx, dy)
            guard length > 0.0001 else { return max(bounds.width, bounds.height) / 2 }
            let ux = dx / length, uy = dy / length
            var nearest: CGFloat?
            for ring in rings {
                var j = ring.count - 1
                for i in ring.indices {
                    let a = ring[j], b = ring[i]
                    let ex = b.x - a.x, ey = b.y - a.y
                    let denominator = ux * ey - uy * ex
                    if abs(denominator) > 1e-9 {
                        let t = ((a.x - origin.x) * ey - (a.y - origin.y) * ex) / denominator
                        let s = ((a.x - origin.x) * uy - (a.y - origin.y) * ux) / denominator
                        if t > 0.0001, s >= 0, s <= 1 { nearest = min(nearest ?? t, t) }
                    }
                    j = i
                }
            }
            return nearest
        }
    }

    /// A rounded part, centered on the plane `z` and `halfDepth` thick each way (art units).
    struct Solid: Sendable {
        let outline: Outline
        let halfDepth: CGFloat
        var z: CGFloat = 0

        /// The front surface over `point`, if it's inside the part.
        func front(at point: CGPoint) -> CGFloat? {
            guard let bulge = bulge(at: point) else { return nil }
            return z + bulge
        }

        func back(at point: CGPoint) -> CGFloat? {
            guard let bulge = bulge(at: point) else { return nil }
            return z - bulge
        }

        private func bulge(at point: CGPoint) -> CGFloat? {
            guard let reach = outline.reach(toward: point), reach > 0 else { return nil }
            let s = hypot(point.x - outline.center.x, point.y - outline.center.y) / reach
            guard s < 1 else { return nil }
            return halfDepth * sqrt(1 - s * s)
        }

        /// Which way the front surface faces at `point`, in art space (y down, z toward you).
        func normal(at point: CGPoint) -> SIMD3<Float> {
            let step: CGFloat = 1.5
            guard let center = front(at: point) else { return [0, 0, 1] }
            let dx = ((front(at: CGPoint(x: point.x + step, y: point.y)) ?? center)
                - (front(at: CGPoint(x: point.x - step, y: point.y)) ?? center)) / (2 * step)
            let dy = ((front(at: CGPoint(x: point.x, y: point.y + step)) ?? center)
                - (front(at: CGPoint(x: point.x, y: point.y - step)) ?? center)) / (2 * step)
            return simd_normalize(SIMD3(Float(-dx), Float(-dy), 1))
        }
    }

    /// How thick a part is for its size: round shapes come out close to balls.
    static func halfDepth(for outline: Outline) -> CGFloat {
        0.44 * min(outline.bounds.width, outline.bounds.height)
    }

    /// Flat shading and glare painted into the 2D art. In 3D, real light does this.
    static func isPaintedShading(token: String, fillOpacity: Double?, opacity: Double?) -> Bool {
        let color = token.uppercased()
        let strength = (fillOpacity ?? 1) * ((opacity ?? 1) > 0 ? (opacity ?? 1) : 1)
        if color == "#000000" || color == "@INK" { return strength < 0.4 }
        if color == "#FFFFFF" || color == "#FFF" { return strength < 0.5 }
        return false
    }

    /// Slices from back to front for a solid. The mesh is built from the
    /// y-flipped path, so `center` is in flipped local units.
    static func solidSlices(center: CGPoint, halfDepth: CGFloat, count: Int = 22) -> [simd_float4x4] {
        let limit = 1.38 // radians; the last slices are small caps
        return (0..<count).map { index in
            let angle = -limit + 2 * limit * Double(index) / Double(count - 1)
            return slice(center: center, scale: CGFloat(cos(angle)), z: halfDepth * CGFloat(sin(angle)))
        }
    }

    /// Slices for a shape laid onto a surface that curves with `radius`: a thin
    /// rim, then a cap following the surface. Returns how high the cap rises.
    static func decalSlices(center: CGPoint, halfSize: CGFloat, radius: CGFloat) -> (slices: [simd_float4x4], rise: CGFloat) {
        let size = min(halfSize, radius * 0.9)
        let base = sqrt(max(radius * radius - size * size, 0))
        var slices = [slice(center: center, scale: 1, z: -1.2)]
        let steps = 6
        for step in 0...steps {
            let scale = 1 - 0.92 * CGFloat(step) / CGFloat(steps)
            let r = scale * size
            slices.append(slice(center: center, scale: scale, z: sqrt(max(radius * radius - r * r, 0)) - base))
        }
        return (slices, radius - base)
    }

    private static func slice(center: CGPoint, scale: CGFloat, z: CGFloat) -> simd_float4x4 {
        let s = Float(scale)
        return simd_float4x4(columns: (
            SIMD4(s, 0, 0, 0),
            SIMD4(0, s, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(Float(center.x) * (1 - s), Float(center.y) * (1 - s), Float(z), 1)
        ))
    }

    /// The creator's pattern over the body color, for a shape's bounds (art
    /// units), painted by the same painter as the 2D avatar.
    @MainActor
    static func patternTexture(_ pattern: CompanionPattern, bodyHex: String, bounds: CGRect) -> TextureResource? {
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let pixelsPerUnit: CGFloat = 5
        let size = CGSize(width: bounds.width * pixelsPerUnit, height: bounds.height * pixelsPerUnit)
        let canvas = Canvas { context, _ in
            context.scaleBy(x: pixelsPerUnit, y: pixelsPerUnit)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            context.fill(Path(bounds.insetBy(dx: -4, dy: -4)), with: .color(Color(buddyHex: bodyHex)))
            let painter = BuddyPainter(ctx: context, u: 2,
                                       palette: BuddyPalette(bodyHex: bodyHex, eyeHex: BuddyPalette.inkHex),
                                       look: BuddyLook(pattern: pattern), pose: BuddyPose())
            // Twice over: real light softens tone-on-tone patterns that read fine flat.
            painter.drawPattern(in: context, bounds: bounds)
            painter.drawPattern(in: context, bounds: bounds)
        }
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = 1
        guard let image = renderer.cgImage else { return nil }
        return try? TextureResource(image: image, options: .init(semantic: .color))
    }

    /// The same mesh with texture coordinates laid flat over `bounds` (art
    /// units), so a pattern lands where the 2D art puts it.
    @MainActor
    static func withPlanarMapping(_ mesh: MeshResource, bounds: CGRect) -> MeshResource? {
        var descriptors: [MeshDescriptor] = []
        for model in mesh.contents.models {
            for part in model.parts {
                guard let triangles = part.triangleIndices else { continue }
                let positions = part.positions.elements
                var descriptor = MeshDescriptor(name: part.id)
                descriptor.positions = MeshBuffers.Positions(positions)
                if let normals = part.normals { descriptor.normals = MeshBuffers.Normals(normals.elements) }
                // The mesh is y-flipped art; texture rows run from the top.
                descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(positions.map { position in
                    SIMD2(Float((CGFloat(position.x) - bounds.minX) / bounds.width),
                          1 - Float((CGFloat(-position.y) - bounds.minY) / bounds.height))
                })
                descriptor.primitives = .triangles(triangles.elements)
                descriptors.append(descriptor)
            }
        }
        guard !descriptors.isEmpty else { return nil }
        return try? MeshResource.generate(from: descriptors)
    }

    /// A mesh swept through `slices` from the y-flipped `path`.
    @MainActor
    static func mesh(_ path: Path, slices: [simd_float4x4]) -> MeshResource? {
        var options = MeshResource.ShapeExtrusionOptions()
        options.extrusionMethod = .traceTransforms(slices)
        options.boundaryResolution = .uniformSegmentsPerSpan(segmentCount: 8)
        options.chamferRadius = 0
        return try? MeshResource(extruding: path.applying(CGAffineTransform(scaleX: 1, y: -1)),
                                 extrusionOptions: options)
    }
}
#endif
