import SwiftUI

extension Color {
    /// `#RRGGBB` (with or without `#`), via the companion color helpers.
    init(buddyHex hex: String) {
        let color = CompanionColor.components(hex)
        self.init(red: color.red, green: color.green, blue: color.blue)
    }
}

/// Colors for one character: the chosen body color and its shades.
struct BuddyPalette: Sendable {
    let bodyHex: String
    let eyeHex: String

    static let inkHex = "#2B1F33"
    static let skinHex = "#FFD6C0"
    static let goldHex = "#F5C24A"
    static let snowHex = "#FBFAFF"
    static let blushHex = "#FF7A9C"
    static let tongueHex = "#FF8FA3"

    /// Negative amounts darken, positive lighten.
    func shade(_ amount: Double) -> String { CompanionColor.shade(bodyHex, by: amount) }
    func color(_ amount: Double = 0) -> Color { Color(buddyHex: shade(amount)) }
    var eye: Color { Color(buddyHex: eyeHex) }
    static var ink: Color { Color(buddyHex: inkHex) }
}

/// Creator choices the painter applies to every character.
struct BuddyLook: Equatable, Sendable {
    var eyeStyle: CompanionEyeStyle = .plain
    var topper: CompanionTopper = .none
    var pattern: CompanionPattern = .none
}

/// Drawing helpers in 100×100 design units. `u` converts units to points.
struct BuddyPainter {
    let ctx: GraphicsContext
    let u: CGFloat
    let palette: BuddyPalette
    let look: BuddyLook
    let pose: BuddyPose

    var t: Double { pose.time }

    // MARK: Geometry

    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * u, y: y * u) }

    func oval(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: (cx - rx) * u, y: (cy - ry) * u, width: rx * 2 * u, height: ry * 2 * u))
    }

    func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> Path { oval(cx, cy, r, r) }

    func roundedRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path {
        Path(roundedRect: CGRect(x: x * u, y: y * u, width: w * u, height: h * u), cornerRadius: r * u, style: .continuous)
    }

    func polygon(_ points: [(CGFloat, CGFloat)]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: p(first.0, first.1))
        for point in points.dropFirst() { path.addLine(to: p(point.0, point.1)) }
        path.closeSubpath()
        return path
    }

    /// An ellipse rotated `degrees` around `pivot` (design units).
    func rotatedOval(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat,
                     degrees: CGFloat, pivot: (CGFloat, CGFloat)? = nil) -> Path {
        let center = pivot.map { p($0.0, $0.1) } ?? p(cx, cy)
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: degrees * .pi / 180)
            .translatedBy(x: -center.x, y: -center.y)
        return oval(cx, cy, rx, ry).applying(transform)
    }

    func rotated(_ path: Path, degrees: CGFloat, around pivot: (CGFloat, CGFloat)) -> Path {
        let center = p(pivot.0, pivot.1)
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: degrees * .pi / 180)
            .translatedBy(x: -center.x, y: -center.y)
        return path.applying(transform)
    }

    /// A tapered tube through `points`, `startWidth` to `endWidth` wide.
    func tube(_ points: [CGPoint], startWidth: CGFloat, endWidth: CGFloat) -> Path {
        guard points.count > 1 else { return Path() }
        var left: [CGPoint] = []
        var right: [CGPoint] = []
        for index in points.indices {
            let previous = points[max(index - 1, 0)]
            let next = points[min(index + 1, points.count - 1)]
            var dx = next.x - previous.x
            var dy = next.y - previous.y
            let length = max(hypot(dx, dy), 0.0001)
            dx /= length
            dy /= length
            let progress = CGFloat(index) / CGFloat(points.count - 1)
            let half = (startWidth + (endWidth - startWidth) * progress) / 2
            left.append(CGPoint(x: (points[index].x - dy * half) * u, y: (points[index].y + dx * half) * u))
            right.append(CGPoint(x: (points[index].x + dy * half) * u, y: (points[index].y - dx * half) * u))
        }
        var path = Path()
        path.move(to: left[0])
        for point in left.dropFirst() { path.addLine(to: point) }
        for point in right.reversed() { path.addLine(to: point) }
        path.closeSubpath()
        // Round the tip.
        let tip = points[points.count - 1]
        path.addPath(circle(tip.x, tip.y, endWidth / 2))
        return path
    }

    /// One outline around overlapping shapes (a beard of puffs, a head on a body).
    func merged(_ paths: [Path]) -> Path {
        guard var result = paths.first else { return Path() }
        for path in paths.dropFirst() { result = result.union(path) }
        return result
    }

    /// Mirrors a path across the character's vertical center line.
    func mirrored(_ path: Path) -> Path {
        path.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 100 * u, ty: 0))
    }

    // MARK: Surfaces

    /// Glossy candy fill: light top, rich middle, deep base, soft highlight.
    func glossy(_ path: Path, hex: String, pattern: Bool = false, gloss: Double = 1, outline: Bool = true) {
        let bounds = path.boundingRect
        guard bounds.width > 0, bounds.height > 0 else { return }
        let top = Color(buddyHex: CompanionColor.shade(hex, by: 0.26))
        let base = Color(buddyHex: hex)
        let deep = Color(buddyHex: CompanionColor.shade(hex, by: -0.24))
        ctx.fill(path, with: .linearGradient(
            Gradient(stops: [.init(color: top, location: 0), .init(color: base, location: 0.45), .init(color: deep, location: 1)]),
            startPoint: CGPoint(x: bounds.midX, y: bounds.minY),
            endPoint: CGPoint(x: bounds.midX, y: bounds.maxY)
        ))
        var inner = ctx
        inner.clip(to: path)
        if pattern, look.pattern != .none { drawPattern(in: inner, bounds: bounds) }
        inner.fill(path, with: .radialGradient(
            Gradient(colors: [.clear, Color(buddyHex: CompanionColor.shade(hex, by: -0.4)).opacity(0.42)]),
            center: CGPoint(x: bounds.midX - bounds.width * 0.12, y: bounds.minY + bounds.height * 0.34),
            startRadius: max(bounds.width, bounds.height) * 0.28,
            endRadius: max(bounds.width, bounds.height) * 0.78
        ))
        let highlight = CGRect(x: bounds.minX + bounds.width * 0.14, y: bounds.minY + bounds.height * 0.05,
                               width: bounds.width * 0.46, height: bounds.height * 0.3)
        inner.fill(Path(ellipseIn: highlight), with: .radialGradient(
            Gradient(colors: [.white.opacity(0.58 * gloss), .white.opacity(0)]),
            center: CGPoint(x: highlight.midX, y: highlight.midY), startRadius: 0, endRadius: highlight.width * 0.56
        ))
        let spark = CGRect(x: bounds.minX + bounds.width * 0.25, y: bounds.minY + bounds.height * 0.12,
                           width: bounds.width * 0.09, height: bounds.height * 0.055)
        inner.fill(Path(ellipseIn: spark), with: .color(.white.opacity(0.7 * gloss)))
        if outline {
            ctx.stroke(path, with: .color(Color(buddyHex: CompanionColor.shade(hex, by: -0.5)).opacity(0.5)), lineWidth: 0.8 * u)
        }
    }

    /// Soft matte fill for small parts (beaks, belly patches, soles).
    func matte(_ path: Path, hex: String) {
        let bounds = path.boundingRect
        ctx.fill(path, with: .linearGradient(
            Gradient(colors: [Color(buddyHex: CompanionColor.shade(hex, by: 0.12)), Color(buddyHex: CompanionColor.shade(hex, by: -0.12))]),
            startPoint: CGPoint(x: bounds.midX, y: bounds.minY), endPoint: CGPoint(x: bounds.midX, y: bounds.maxY)
        ))
    }

    // MARK: Face

    /// Both eyes, centered on `(cx, cy)`. `faceHex` keeps eyes readable when they sit on skin or a screen.
    func eyes(_ cx: CGFloat, _ cy: CGFloat, spacing: CGFloat, size: CGFloat) {
        let color = palette.eye
        let halfSpacing = spacing / 2
        switch pose.eyes {
        case let .open(openness, look):
            openEyes(cx, cy, halfSpacing, size, openness: max(openness, 0.12), scale: 1, look: look, color: color)
        case let .wide(look):
            openEyes(cx, cy, halfSpacing, size, openness: 1, scale: 1.16, look: look, color: color)
        case .happy:
            for side in [-1.0, 1.0] as [CGFloat] {
                let x = cx + side * halfSpacing
                var path = Path()
                path.move(to: p(x - size * 0.5, cy + size * 0.15))
                path.addQuadCurve(to: p(x + size * 0.5, cy + size * 0.15), control: p(x, cy - size * 0.6))
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: size * 0.28 * u, lineCap: .round))
            }
        case .closed:
            for side in [-1.0, 1.0] as [CGFloat] {
                let x = cx + side * halfSpacing
                var path = Path()
                path.move(to: p(x - size * 0.48, cy))
                path.addQuadCurve(to: p(x + size * 0.48, cy), control: p(x, cy + size * 0.5))
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: size * 0.24 * u, lineCap: .round))
            }
        case let .squint(look):
            let dx = look.x * size * 0.25
            if self.look.eyeStyle == .visor {
                ctx.fill(roundedRect(cx - halfSpacing - size * 0.7 + dx, cy - size * 0.14, spacing + size * 1.4, size * 0.28, size * 0.14), with: .color(color))
            } else {
                for side in [-1.0, 1.0] as [CGFloat] {
                    let x = cx + side * halfSpacing + dx
                    ctx.fill(roundedRect(x - size * 0.5, cy - size * 0.13, size, size * 0.26, size * 0.13), with: .color(color))
                }
            }
        case .sad:
            for side in [-1.0, 1.0] as [CGFloat] {
                let x = cx + side * halfSpacing
                let w = size * 0.95
                let h = size * 1.1
                var clipped = ctx
                // Inner corners lift, outer corners droop.
                clipped.clip(to: polygon([
                    (x - side * w, cy - h * 0.42), (x + side * w, cy - h * 0.02),
                    (x + side * w, cy + h), (x - side * w, cy + h)
                ]))
                clipped.fill(oval(x, cy + size * 0.05, w / 2, h / 2), with: .color(color))
                ctx.fill(circle(x - w * 0.12, cy + h * 0.1, size * 0.14), with: .color(.white.opacity(0.85)))
            }
        }
    }

    private func openEyes(_ cx: CGFloat, _ cy: CGFloat, _ halfSpacing: CGFloat, _ size: CGFloat,
                          openness: CGFloat, scale: CGFloat, look: CGPoint, color: Color) {
        let w = size * 0.95 * scale
        let h = size * 1.2 * scale * openness
        let dx = look.x * size * 0.28
        let dy = look.y * size * 0.22
        switch self.look.eyeStyle {
        case .visor:
            let bar = roundedRect(cx - halfSpacing - w * 0.8 + dx * 0.5, cy - h * 0.3 + dy * 0.5,
                                  halfSpacing * 2 + w * 1.6, h * 0.6, h * 0.3)
            ctx.fill(bar, with: .color(color))
            var shine = ctx
            shine.clip(to: bar)
            let sweep = CGFloat((t * 0.6).truncatingRemainder(dividingBy: 1))
            let x = cx - halfSpacing - w + (halfSpacing * 2 + w * 2) * sweep
            shine.fill(polygon([(x, cy - h), (x + size * 0.35, cy - h), (x + size * 0.1, cy + h), (x - size * 0.25, cy + h)]),
                       with: .color(.white.opacity(0.45)))
            shine.fill(roundedRect(cx - halfSpacing - w * 0.6, cy - h * 0.24, halfSpacing * 2 + w * 1.2, h * 0.14, h * 0.07),
                       with: .color(.white.opacity(0.4)))
        default:
            for side in [-1.0, 1.0] as [CGFloat] {
                let x = cx + side * halfSpacing + dx
                let y = cy + dy
                var shape: Path
                switch self.look.eyeStyle {
                case .scowl:
                    shape = oval(x, y, w / 2, h / 2)
                    var clipped = ctx
                    // Brows angle down toward the middle.
                    clipped.clip(to: polygon([
                        (x + side * w, y - h * 0.62), (x - side * w, y - h * 0.08),
                        (x - side * w, y + h), (x + side * w, y + h)
                    ]))
                    clipped.fill(shape, with: .color(color))
                case .venom:
                    shape = Path()
                    let inner = p(x - side * w * 0.55, y + h * 0.12)
                    let outer = p(x + side * w * 0.62, y - h * 0.22)
                    shape.move(to: inner)
                    shape.addQuadCurve(to: outer, control: p(x - side * w * 0.05, y - h * 0.7))
                    shape.addQuadCurve(to: inner, control: p(x + side * w * 0.1, y + h * 0.62))
                    shape.closeSubpath()
                    ctx.fill(shape, with: .color(color))
                default:
                    shape = oval(x, y, w / 2, h / 2)
                    ctx.fill(shape, with: .color(color))
                }
                if openness > 0.45 {
                    ctx.fill(circle(x - w * 0.16, y - h * 0.2, size * 0.19 * scale), with: .color(.white.opacity(0.95)))
                    ctx.fill(circle(x + w * 0.17, y + h * 0.2, size * 0.085 * scale), with: .color(.white.opacity(0.8)))
                }
            }
        }
    }

    func mouth(_ cx: CGFloat, _ cy: CGFloat, width w: CGFloat, color: Color = BuddyPalette.ink) {
        switch pose.mouth {
        case .smile:
            var path = Path()
            path.move(to: p(cx - w / 2, cy))
            path.addQuadCurve(to: p(cx + w / 2, cy), control: p(cx, cy + w * 0.5))
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: w * 0.17 * u, lineCap: .round))
        case .grin:
            var path = Path()
            path.move(to: p(cx - w / 2, cy - w * 0.05))
            path.addQuadCurve(to: p(cx + w / 2, cy - w * 0.05), control: p(cx, cy - w * 0.12))
            path.addQuadCurve(to: p(cx - w / 2, cy - w * 0.05), control: p(cx, cy + w * 0.95))
            path.closeSubpath()
            filledMouth(path, tongueAt: (cx, cy + w * 0.34), tongue: w * 0.26)
        case let .open(amount):
            let rx = w * 0.3
            let ry = w * (0.14 + 0.36 * amount)
            filledMouth(oval(cx, cy + ry * 0.3, rx, ry), tongueAt: (cx, cy + ry * 0.95), tongue: rx * 0.75)
        case .small:
            ctx.fill(oval(cx, cy + w * 0.08, w * 0.15, w * 0.19), with: .color(color))
        case .flat:
            var path = Path()
            path.move(to: p(cx - w * 0.28, cy + w * 0.08))
            path.addLine(to: p(cx + w * 0.28, cy + w * 0.08))
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: w * 0.15 * u, lineCap: .round))
        case .frown:
            var path = Path()
            path.move(to: p(cx - w * 0.38, cy + w * 0.25))
            path.addQuadCurve(to: p(cx + w * 0.38, cy + w * 0.25), control: p(cx, cy - w * 0.15))
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: w * 0.16 * u, lineCap: .round))
        }
    }

    private func filledMouth(_ path: Path, tongueAt tongue: (CGFloat, CGFloat), tongue size: CGFloat) {
        ctx.fill(path, with: .color(Color(buddyHex: "#3A1B2B")))
        var inside = ctx
        inside.clip(to: path)
        inside.fill(oval(tongue.0, tongue.1, size, size * 0.7), with: .color(Color(buddyHex: BuddyPalette.tongueHex)))
    }

    func blush(_ points: [(CGFloat, CGFloat)], size: CGFloat = 4.4) {
        guard pose.blush else { return }
        for point in points {
            ctx.fill(oval(point.0, point.1, size, size * 0.58), with: .radialGradient(
                Gradient(colors: [Color(buddyHex: BuddyPalette.blushHex).opacity(0.55), Color(buddyHex: BuddyPalette.blushHex).opacity(0)]),
                center: p(point.0, point.1), startRadius: 0, endRadius: size * u
            ))
        }
    }

    // MARK: Headwear

    /// Draws the chosen headwear centered on `(x, y)`, the top of the head.
    func topper(_ x: CGFloat, _ y: CGFloat, width w: CGFloat) {
        switch look.topper {
        case .none:
            break
        case .catEars:
            for side in [-1.0, 1.0] as [CGFloat] {
                let base = x + side * w * 0.3
                let ear = polygon([(base - side * w * 0.17, y + w * 0.1), (base + side * w * 0.06, y - w * 0.36), (base + side * w * 0.2, y + w * 0.04)])
                glossy(ear, hex: palette.bodyHex, gloss: 0.6)
                ctx.fill(polygon([(base - side * w * 0.08, y + w * 0.05), (base + side * w * 0.05, y - w * 0.22), (base + side * w * 0.12, y + w * 0.02)]),
                         with: .color(Color(buddyHex: BuddyPalette.blushHex).opacity(0.8)))
            }
        case .bearEars:
            for side in [-1.0, 1.0] as [CGFloat] {
                let cx = x + side * w * 0.34
                glossy(circle(cx, y - w * 0.02, w * 0.16), hex: palette.bodyHex, gloss: 0.6)
                ctx.fill(circle(cx, y - w * 0.01, w * 0.08), with: .color(palette.color(0.4)))
            }
        case .crown:
            let bottom = y + w * 0.02
            let top = y - w * 0.3
            let crown = polygon([
                (x - w * 0.3, bottom), (x - w * 0.34, top), (x - w * 0.16, y - w * 0.14),
                (x, top - w * 0.06), (x + w * 0.16, y - w * 0.14), (x + w * 0.34, top), (x + w * 0.3, bottom)
            ])
            glossy(crown, hex: BuddyPalette.goldHex, gloss: 0.9)
            for (gx, color) in [(x - w * 0.17, "#FF5A7A"), (x, "#5AB0FF"), (x + w * 0.17, "#5CE0A0")] {
                ctx.fill(circle(gx, y - w * 0.05, w * 0.045), with: .color(Color(buddyHex: color)))
            }
        case .halo:
            let bob = CGFloat(sin(t * 2)) * 1.2
            let ring = oval(x, y - w * 0.22 + bob, w * 0.3, w * 0.075)
            ctx.stroke(ring, with: .color(Color(buddyHex: "#FFE9A3").opacity(0.45)), lineWidth: w * 0.12 * u)
            ctx.stroke(ring, with: .color(Color(buddyHex: BuddyPalette.goldHex)), lineWidth: w * 0.05 * u)
        case .devilHorns:
            for side in [-1.0, 1.0] as [CGFloat] {
                let base = x + side * w * 0.26
                var horn = Path()
                horn.move(to: p(base - side * w * 0.1, y + w * 0.06))
                horn.addQuadCurve(to: p(base + side * w * 0.16, y - w * 0.3), control: p(base - side * w * 0.08, y - w * 0.18))
                horn.addQuadCurve(to: p(base + side * w * 0.1, y + w * 0.06), control: p(base + side * w * 0.14, y - w * 0.08))
                horn.closeSubpath()
                glossy(horn, hex: "#E5484D", gloss: 0.8)
            }
        case .sprout:
            let sway = CGFloat(sin(t * 1.6)) * 5
            var stem = Path()
            stem.move(to: p(x, y + w * 0.04))
            stem.addQuadCurve(to: p(x + sway * 0.3, y - w * 0.28), control: p(x - w * 0.06, y - w * 0.12))
            ctx.stroke(stem, with: .color(Color(buddyHex: "#3FA35B")), style: StrokeStyle(lineWidth: w * 0.045 * u, lineCap: .round))
            let tip = (x + sway * 0.3, y - w * 0.28)
            glossy(rotatedOval(tip.0 - w * 0.12, tip.1, w * 0.13, w * 0.065, degrees: -20 + sway, pivot: tip), hex: "#5DCB6A", gloss: 0.7)
            glossy(rotatedOval(tip.0 + w * 0.12, tip.1 - w * 0.02, w * 0.13, w * 0.065, degrees: 25 + sway, pivot: tip), hex: "#5DCB6A", gloss: 0.7)
        case .swoosh:
            var tuft = Path()
            tuft.move(to: p(x - w * 0.08, y + w * 0.06))
            tuft.addQuadCurve(to: p(x + w * 0.2, y - w * 0.28), control: p(x - w * 0.12, y - w * 0.3))
            tuft.addQuadCurve(to: p(x + w * 0.1, y + w * 0.06), control: p(x + w * 0.02, y - w * 0.14))
            tuft.closeSubpath()
            glossy(tuft, hex: palette.shade(-0.2), gloss: 0.7)
        }
    }

    // MARK: Patterns

    /// Tone-on-tone surface pattern, clipped by the caller to the body.
    func drawPattern(in context: GraphicsContext, bounds b: CGRect) {
        let dark = Color(buddyHex: palette.shade(-0.38))
        let light = Color(buddyHex: palette.shade(0.36))
        let mid = Color(buddyHex: palette.shade(-0.2))
        let bright = Color(buddyHex: palette.shade(0.58))
        let step = b.width / 5
        func rand(_ index: Int, _ salt: Int) -> CGFloat {
            var value = UInt64(truncatingIfNeeded: index &* 7919 &+ salt &* 104_729 &+ 12_345)
            value ^= value >> 13
            value = value &* 0x5851_F42D_4C95_7F2D
            value ^= value >> 29
            return CGFloat(value % 10_000) / 10_000
        }
        switch look.pattern {
        case .none:
            break
        case .hex:
            let radius = step * 0.55
            var row = 0
            var y = b.minY - radius
            while y < b.maxY + radius {
                var x = b.minX - radius + (row.isMultiple(of: 2) ? 0 : radius * 0.87)
                var column = 0
                while x < b.maxX + radius {
                    var hexagon = Path()
                    for corner in 0..<6 {
                        let angle = CGFloat(corner) * .pi / 3 + .pi / 6
                        let point = CGPoint(x: x + cos(angle) * radius * 0.92, y: y + sin(angle) * radius * 0.92)
                        corner == 0 ? hexagon.move(to: point) : hexagon.addLine(to: point)
                    }
                    hexagon.closeSubpath()
                    if (row + column).isMultiple(of: 3) { context.fill(hexagon, with: .color(mid.opacity(0.35))) }
                    context.stroke(hexagon, with: .color(light.opacity(0.55)), lineWidth: 0.6 * u)
                    x += radius * 1.74
                    column += 1
                }
                y += radius * 1.5
                row += 1
            }
        case .camo:
            for index in 0..<14 {
                let color = [dark, light, mid][index % 3]
                let rect = CGRect(x: b.minX + rand(index, 1) * b.width - step * 0.5, y: b.minY + rand(index, 2) * b.height - step * 0.4,
                                  width: step * (0.9 + rand(index, 3)), height: step * (0.6 + rand(index, 4) * 0.7))
                let transform = CGAffineTransform(translationX: rect.midX, y: rect.midY).rotated(by: rand(index, 5) * .pi)
                    .translatedBy(x: -rect.midX, y: -rect.midY)
                context.fill(Path(ellipseIn: rect).applying(transform), with: .color(color.opacity(0.55)))
            }
        case .ripple:
            var grid = Path()
            var x = b.minX
            while x <= b.maxX { grid.move(to: CGPoint(x: x, y: b.minY)); grid.addLine(to: CGPoint(x: x, y: b.maxY)); x += step * 0.8 }
            var y = b.minY
            while y <= b.maxY { grid.move(to: CGPoint(x: b.minX, y: y)); grid.addLine(to: CGPoint(x: b.maxX, y: y)); y += step * 0.8 }
            context.stroke(grid, with: .color(light.opacity(0.5)), lineWidth: 0.6 * u)
        case .wire:
            for index in 0..<9 {
                var trace = Path()
                let start = CGPoint(x: b.minX + rand(index, 7) * b.width, y: b.minY + rand(index, 8) * b.height)
                let corner = CGPoint(x: start.x + (rand(index, 9) - 0.5) * b.width * 0.5, y: start.y)
                let end = CGPoint(x: corner.x, y: corner.y + (rand(index, 10) - 0.5) * b.height * 0.5)
                trace.move(to: start)
                trace.addLine(to: corner)
                trace.addLine(to: end)
                context.stroke(trace, with: .color(bright.opacity(0.6)), style: StrokeStyle(lineWidth: 0.8 * u, lineCap: .round, lineJoin: .round))
                context.fill(Path(ellipseIn: CGRect(x: end.x - 1.3 * u, y: end.y - 1.3 * u, width: 2.6 * u, height: 2.6 * u)), with: .color(bright.opacity(0.8)))
            }
        case .nebula:
            context.fill(Path(b), with: .color(Color(buddyHex: palette.shade(-0.55)).opacity(0.55)))
            for index in 0..<3 {
                let center = CGPoint(x: b.minX + rand(index, 11) * b.width, y: b.minY + rand(index, 12) * b.height)
                context.fill(Path(ellipseIn: CGRect(x: center.x - step, y: center.y - step * 0.7, width: step * 2, height: step * 1.4)),
                             with: .radialGradient(Gradient(colors: [light.opacity(0.55), light.opacity(0)]), center: center, startRadius: 0, endRadius: step))
            }
            for index in 0..<22 {
                let point = CGPoint(x: b.minX + rand(index, 13) * b.width, y: b.minY + rand(index, 14) * b.height)
                let radius = (0.35 + rand(index, 15) * 0.6) * u
                context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
                             with: .color(.white.opacity(0.85)))
            }
        case .lava:
            for index in 0..<6 {
                let center = CGPoint(x: b.minX + rand(index, 16) * b.width, y: b.minY + rand(index, 17) * b.height)
                let radius = step * (0.5 + rand(index, 18) * 0.5)
                context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 1.6)),
                             with: .radialGradient(Gradient(colors: [bright.opacity(0.75), light.opacity(0.35), light.opacity(0)]),
                                                   center: center, startRadius: 0, endRadius: radius))
            }
            for index in 0..<4 {
                var crack = Path()
                var point = CGPoint(x: b.minX + rand(index, 19) * b.width, y: b.minY + rand(index, 20) * b.height)
                crack.move(to: point)
                for segment in 0..<3 {
                    point.x += (rand(index * 3 + segment, 21) - 0.5) * step
                    point.y += rand(index * 3 + segment, 22) * step * 0.7
                    crack.addLine(to: point)
                }
                context.stroke(crack, with: .color(dark.opacity(0.55)), style: StrokeStyle(lineWidth: 0.8 * u, lineCap: .round, lineJoin: .round))
            }
        case .plasma:
            let phase = CGFloat(t * 0.8)
            for band in 0..<7 {
                var wave = Path()
                let baseY = b.minY + CGFloat(band) * b.height / 6
                wave.move(to: CGPoint(x: b.minX, y: baseY))
                var x = b.minX
                while x <= b.maxX {
                    wave.addLine(to: CGPoint(x: x, y: baseY + sin((x - b.minX) / b.width * .pi * 3 + phase + CGFloat(band)) * step * 0.3))
                    x += b.width / 24
                }
                context.stroke(wave, with: .color((band.isMultiple(of: 2) ? light : dark).opacity(0.45)), lineWidth: step * 0.28)
            }
        case .lightning:
            for index in 0..<3 {
                var bolt = Path()
                var point = CGPoint(x: b.minX + (0.2 + CGFloat(index) * 0.3) * b.width, y: b.minY)
                bolt.move(to: point)
                for segment in 0..<5 {
                    point.x += (segment.isMultiple(of: 2) ? 1 : -1) * step * (0.25 + rand(index * 5 + segment, 23) * 0.3)
                    point.y += b.height / 5
                    bolt.addLine(to: point)
                }
                context.stroke(bolt, with: .color(bright.opacity(0.35)), style: StrokeStyle(lineWidth: 2.4 * u, lineCap: .round, lineJoin: .round))
                context.stroke(bolt, with: .color(bright.opacity(0.85)), style: StrokeStyle(lineWidth: 0.8 * u, lineCap: .round, lineJoin: .round))
            }
        }
    }

    // MARK: Effects

    /// Draws the pose's effect near `(x, y)`, the top-right of the head.
    func effect(_ x: CGFloat, _ y: CGFloat) {
        guard let effect = pose.effect else { return }
        switch effect {
        case .thought:
            for index in 0..<3 {
                let rise = CGFloat((t * 0.9 + Double(index) * 0.33).truncatingRemainder(dividingBy: 1))
                let radius = 1.6 + CGFloat(index) * 1.1
                ctx.fill(circle(x + CGFloat(index) * 4, y - CGFloat(index) * 5 - rise * 2, radius),
                         with: .color(.white.opacity(0.92 - Double(rise) * 0.3)))
                ctx.stroke(circle(x + CGFloat(index) * 4, y - CGFloat(index) * 5 - rise * 2, radius),
                           with: .color(BuddyPalette.ink.opacity(0.25)), lineWidth: 0.5 * u)
            }
            symbolBubble("•••", at: (x + 12, y - 18), background: .white, foreground: BuddyPalette.ink, size: 7)
        case .question:
            symbolBubble("?", at: (x + 6, y - 10), background: .white, foreground: BuddyPalette.ink, size: 11)
        case .alert:
            let pulse = 1 + CGFloat(sin(t * 8)) * 0.06
            symbolBubble("!", at: (x + 6, y - 10), background: Color(buddyHex: "#FF9F1C"), foreground: .white, size: 11 * pulse)
        case .sparkles:
            for (index, spot) in [(-38.0, -6.0), (8.0, -2.0), (-30.0, 22.0), (12.0, 26.0)].enumerated() {
                let twinkle = CGFloat(max(0, sin(t * 3 + Double(index) * 1.7)))
                sparkle(x + spot.0, y + spot.1, size: 2.2 + twinkle * 2.2, opacity: 0.35 + twinkle * 0.65)
            }
        case .sleep:
            for index in 0..<3 {
                let rise = CGFloat((t * 0.35 + Double(index) * 0.33).truncatingRemainder(dividingBy: 1))
                text("z", at: (x + rise * 8 + CGFloat(index) * 2, y + 2 - rise * 16), size: 6 + CGFloat(index) * 2,
                     color: BuddyPalette.ink.opacity(Double(1 - rise) * 0.8))
            }
        case .notes:
            for index in 0..<2 {
                let rise = CGFloat((t * 0.5 + Double(index) * 0.5).truncatingRemainder(dividingBy: 1))
                let side: CGFloat = index == 0 ? -44 : 4
                text(index == 0 ? "♪" : "♫", at: (x + side + CGFloat(sin(t * 3 + Double(index))) * 2, y + 8 - rise * 16), size: 9,
                     color: palette.color(-0.3).opacity(Double(1 - rise)))
            }
        case .tear:
            let fall = CGFloat((t * 0.6).truncatingRemainder(dividingBy: 1))
            var drop = Path()
            let dx = x - 30
            let dy = y + 26 + fall * 10
            drop.move(to: p(dx, dy - 3))
            drop.addQuadCurve(to: p(dx, dy + 2), control: p(dx + 3.2, dy + 1.5))
            drop.addQuadCurve(to: p(dx, dy - 3), control: p(dx - 3.2, dy + 1.5))
            ctx.fill(drop, with: .color(Color(buddyHex: "#6EC6FF").opacity(Double(1 - fall * 0.7))))
        case .hearts:
            for index in 0..<2 {
                let rise = CGFloat((t * 0.45 + Double(index) * 0.5).truncatingRemainder(dividingBy: 1))
                let side: CGFloat = index == 0 ? 2 : -42
                heart(x + side, y + 10 - rise * 16, size: 3.2, opacity: Double(1 - rise))
            }
        case .code:
            let glyphs = ["</>", "{ }", "=>"]
            for index in 0..<2 {
                let rise = CGFloat((t * 0.5 + Double(index) * 0.5).truncatingRemainder(dividingBy: 1))
                text(glyphs[(Int(t * 0.5) + index) % glyphs.count], at: (x + 2 - CGFloat(index) * 44, y + 10 - rise * 14), size: 6.5,
                     color: palette.color(-0.35).opacity(Double(1 - rise)))
            }
        }
    }

    func sparkle(_ x: CGFloat, _ y: CGFloat, size s: CGFloat, opacity: Double, hex: String = "#FFE27A") {
        var star = Path()
        star.move(to: p(x, y - s))
        star.addQuadCurve(to: p(x + s, y), control: p(x + s * 0.18, y - s * 0.18))
        star.addQuadCurve(to: p(x, y + s), control: p(x + s * 0.18, y + s * 0.18))
        star.addQuadCurve(to: p(x - s, y), control: p(x - s * 0.18, y + s * 0.18))
        star.addQuadCurve(to: p(x, y - s), control: p(x - s * 0.18, y - s * 0.18))
        ctx.fill(star, with: .color(Color(buddyHex: hex).opacity(opacity)))
    }

    func heart(_ x: CGFloat, _ y: CGFloat, size s: CGFloat, opacity: Double) {
        var shape = Path()
        shape.move(to: p(x, y + s))
        shape.addCurve(to: p(x - s, y - s * 0.3), control1: p(x - s * 0.4, y + s * 0.6), control2: p(x - s, y + s * 0.2))
        shape.addArc(center: p(x - s * 0.5, y - s * 0.35), radius: s * 0.52 * u, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        shape.addArc(center: p(x + s * 0.5, y - s * 0.35), radius: s * 0.52 * u, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        shape.addCurve(to: p(x, y + s), control1: p(x + s, y + s * 0.2), control2: p(x + s * 0.4, y + s * 0.6))
        ctx.fill(shape, with: .color(Color(buddyHex: "#FF5C8A").opacity(opacity)))
    }

    func text(_ value: String, at point: (CGFloat, CGFloat), size: CGFloat, color: Color) {
        ctx.draw(
            Text(value).font(.system(size: size * u, weight: .heavy, design: .rounded)).foregroundColor(color),
            at: p(point.0, point.1)
        )
    }

    private func symbolBubble(_ symbol: String, at point: (CGFloat, CGFloat), background: Color, foreground: Color, size: CGFloat) {
        let bubble = circle(point.0, point.1, size * 0.72)
        ctx.fill(bubble, with: .color(background))
        ctx.stroke(bubble, with: .color(BuddyPalette.ink.opacity(0.18)), lineWidth: 0.6 * u)
        text(symbol, at: (point.0, point.1 + size * 0.02), size: size * (symbol.count > 1 ? 0.6 : 0.95), color: foreground)
    }
}
