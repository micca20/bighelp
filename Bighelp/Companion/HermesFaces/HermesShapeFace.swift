import Foundation

/// Hermes Desktop's "geometric faces" (Bot Mode's classic shapes), ported from
/// its MIT-licensed `avatar.tsx` (© 2026 Nous Research): a flat body in a
/// 40×44 box with two eyes and catchlights. Notices: ThirdParty-NOTICES.txt.
enum HermesShapeFace {
    /// The shapes Hermes Desktop's picker offers, in its order.
    static let pickerShapes = ["circle", "blob", "squircle", "pill", "triangle", "hexagon", "cloud", "drop"]
    /// The shapes a name falls back to when nothing was picked.
    static let defaultShapes = ["circle", "squircle", "pill", "triangle", "hexagon", "cloud", "drop"]
    /// The primary profile's friendly violet, and the last-resort color.
    static let primaryColor = "#8b5cf6"
    /// Hermes Desktop's swatches: twelve hues at the profile palette's saturation and lightness.
    static let swatches: [String] = (0..<12).map { "hsl(\($0 * 30) 68% 58%)" }

    static func displayName(_ shape: String) -> String {
        switch shape {
        case "blob": "Wobble"
        case "squircle": "Rounded"
        default: shape.capitalized
        }
    }

    /// `profileColor`: a stable hue from the name; none for the default profile.
    static func profileColor(_ name: String) -> String? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key != "default" else { return nil }
        var hash: UInt32 = 0
        for unit in key.utf16 { hash = hash &* 31 &+ UInt32(unit) }
        return "hsl(\(hash % 360) 68% 58%)"
    }

    /// `avatarColor`: a picked color, else the name's hue, else violet.
    static func color(_ picked: String?, name: String) -> String {
        if let picked, !picked.isEmpty { return picked }
        return profileColor(name) ?? primaryColor
    }

    /// `defaultShapeFor`: the name's shape when nothing was picked.
    static func defaultShape(for name: String) -> String {
        var hash: UInt32 = 0
        // `for (const ch of name)` walks code points; `charCodeAt(0)` reads each one's first UTF-16 unit.
        for scalar in name.unicodeScalars {
            hash = hash &* 31 &+ UInt32(String(scalar).utf16.first ?? 0)
        }
        return defaultShapes[Int(hash % UInt32(defaultShapes.count))]
    }

    /// `isDarkColor`, quirk included: it reads the color as hex, so any `hsl()`
    /// color counts as dark and gets cream eyes, exactly as Hermes Desktop draws it.
    static func isDark(_ color: String) -> Bool {
        let digits = color.dropFirst().prefix { $0.isHexDigit }
        let value = Int(digits.prefix(13), radix: 16) ?? 0
        let r = Double((value >> 16) & 255), g = Double((value >> 8) & 255), b = Double(value & 255)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b < 110
    }

    /// Where the eyes sit: the cloud's body is lower.
    static func eyeLine(_ shape: String) -> Double { shape == "cloud" ? 22 : 17.2 }

    // MARK: Outline (sampleFaceRing)

    static func ring(_ shape: String, steps: Int = 52) -> [(Double, Double)] {
        let kind = shape.hasPrefix("sigil-") ? "circle" : shape
        if kind == "drop" || kind == "teardrop" { return dropRing(steps) }
        if kind == "cloud" { return cloudRing(steps) }
        return (0..<steps).map { index in
            let a = (Double(index) / Double(steps)) * Double.pi * 2 - Double.pi / 2
            let c = cos(a), s = sin(a)
            var rx = 16.0, ry = 16.0
            switch kind {
            case "circle":
                rx = 16.2; ry = 16.2
            case "blob":
                rx = 16 + 1.7 * sin(3 * a) + 0.7 * cos(5 * a); ry = rx
            case "squircle":
                let d = superDistance(c, s, 5)
                rx = 16.2 / d; ry = rx
            case "pill":
                let d = pow(pow(abs(c), 8) + pow(abs(s / 0.72), 8), 1.0 / 8)
                rx = 16 / (d == 0 ? 1 : d); ry = rx
            case "triangle", "tetrahedron", "wedge":
                let u = (a + Double.pi / 2 + Double.pi * 2).truncatingRemainder(dividingBy: Double.pi * 2)
                let sector = (u / ((Double.pi * 2) / 3)).truncatingRemainder(dividingBy: 1)
                rx = 13.5 / max(0.42, cos((sector - 0.5) * 1.9)); ry = rx
            case "hexagon", "hex", "icosahedron", "dodecahedron":
                let segment = Double.pi / 3
                rx = 16.2 * (cos(segment / 2) / cos(a - segment * BlobNumber.jsRound(a / segment)))
                ry = rx
            case "cube", "octahedron":
                let d = superDistance(c, s, 3.1)
                rx = 16 / d; ry = rx
            case "pebble":
                rx = 16.4 * (1.04 - 0.14 * cos(2 * a))
                ry = 15.2 * (1.06 + 0.08 * sin(2 * a))
            default:
                rx = 16.2; ry = 16.2
            }
            return (20 + rx * c, 20 + ry * s)
        }
    }

    private static func superDistance(_ c: Double, _ s: Double, _ p: Double) -> Double {
        let d = pow(pow(abs(c), p) + pow(abs(s), p), 1 / p)
        return d == 0 ? 1 : d
    }

    private static func cubic(_ p0: (Double, Double), _ p1: (Double, Double), _ p2: (Double, Double),
                              _ p3: (Double, Double), _ t: Double) -> (Double, Double) {
        let u = 1 - t
        return (u * u * u * p0.0 + 3 * u * u * t * p1.0 + 3 * u * t * t * p2.0 + t * t * t * p3.0,
                u * u * u * p0.1 + 3 * u * u * t * p1.1 + 3 * u * t * t * p2.1 + t * t * t * p3.1)
    }

    private static func dropRing(_ steps: Int) -> [(Double, Double)] {
        let n = max(8, steps / 3)
        var points: [(Double, Double)] = []
        for index in 0..<n { points.append(cubic((20, 3), (20, 3), (6, 20), (6, 27), Double(index) / Double(n))) }
        for index in 0...n {
            let t = (Double(index) / Double(n)) * Double.pi
            points.append((20 - 14 * cos(t), 27 + 13.5 * sin(t)))
        }
        for index in 1...n { points.append(cubic((34, 27), (34, 20), (20, 3), (20, 3), Double(index) / Double(n))) }
        return points
    }

    private struct Arc { var cx: Double, cy: Double, rx: Double, ry: Double, theta1: Double, dtheta: Double }

    /// SVG's endpoint arc as a center arc (`svgArc`).
    private static func arc(_ x1: Double, _ y1: Double, _ radiusX: Double, _ radiusY: Double,
                            _ large: Bool, _ sweep: Bool, _ x2: Double, _ y2: Double) -> Arc {
        let dx = (x1 - x2) / 2, dy = (y1 - y2) / 2
        var rx = radiusX, ry = radiusY
        var rx2 = rx * rx, ry2 = ry * ry
        let lambda = (dx * dx) / rx2 + (dy * dy) / ry2
        if lambda > 1 {
            let s = lambda.squareRoot()
            rx *= s; ry *= s; rx2 = rx * rx; ry2 = ry * ry
        }
        let numerator = rx2 * ry2 - rx2 * dy * dy - ry2 * dx * dx
        let denominator = rx2 * dy * dy + ry2 * dx * dx
        var sq = max(0, numerator / denominator).squareRoot()
        if large == sweep { sq = -sq }
        let cx = sq * ((rx * dy) / ry) + (x1 + x2) / 2
        let cy = sq * ((-ry * dx) / rx) + (y1 + y2) / 2
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let n = hypot(ux, uy) * hypot(vx, vy)
            var a = acos(max(-1, min(1, (ux * vx + uy * vy) / (n == 0 ? 1 : n))))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let theta1 = angle(1, 0, (x1 - cx) / rx, (y1 - cy) / ry)
        var dtheta = angle((x1 - cx) / rx, (y1 - cy) / ry, (x2 - cx) / rx, (y2 - cy) / ry)
        if !sweep, dtheta > 0 { dtheta -= Double.pi * 2 }
        if sweep, dtheta < 0 { dtheta += Double.pi * 2 }
        return Arc(cx: cx, cy: cy, rx: rx, ry: ry, theta1: theta1, dtheta: dtheta)
    }

    private static func sample(_ arc: Arc, _ n: Int) -> [(Double, Double)] {
        (0..<n).map { index in
            let theta = arc.theta1 + arc.dtheta * (Double(index) / Double(n))
            return (arc.cx + arc.rx * cos(theta), arc.cy + arc.ry * sin(theta))
        }
    }

    /// Three puffs and a flat floor: the same outline as Hermes Desktop's cloud path.
    private static func cloudRing(_ steps: Int) -> [(Double, Double)] {
        let a1 = arc(11, 32, 7.5, 7.5, false, true, 10, 17.1)
        let a2 = arc(10, 17.1, 9.5, 9.5, false, true, 29, 12.5)
        let a3 = arc(29, 12.5, 7, 7, false, true, 30, 32)
        let lengths = [abs(a1.dtheta) * a1.rx, abs(a2.dtheta) * a2.rx, abs(a3.dtheta) * a3.rx, 19]
        let total = lengths.reduce(0, +)
        let n = max(64, steps)
        let n1 = max(8, Int(BlobNumber.jsRound(Double(n) * lengths[0] / total)))
        let n2 = max(10, Int(BlobNumber.jsRound(Double(n) * lengths[1] / total)))
        let n3 = max(10, Int(BlobNumber.jsRound(Double(n) * lengths[2] / total)))
        let n4 = max(4, n - n1 - n2 - n3)
        var points = sample(a1, n1) + sample(a2, n2) + sample(a3, n3)
        for index in 0..<n4 { points.append((30 + (11 - 30) * (Double(index) / Double(n4)), 32)) }
        return points
    }
}

/// CSS colors as Hermes stores them: `#rgb`, `#rrggbb` or `hsl(h s% l%)`.
enum HermesCSSColor {
    static func rgb(_ text: String) -> (red: Double, green: Double, blue: Double)? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        if value.hasPrefix("#") {
            var digits = String(value.dropFirst())
            if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
            guard digits.count == 6, let number = Int(digits, radix: 16) else { return nil }
            return (Double((number >> 16) & 255) / 255, Double((number >> 8) & 255) / 255, Double(number & 255) / 255)
        }
        guard value.hasPrefix("hsl(") || value.hasPrefix("hsla("), value.hasSuffix(")"),
              let open = value.firstIndex(of: "(") else { return nil }
        let inner = value[value.index(after: open)..<value.index(before: value.endIndex)]
        let parts = inner.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "/" })
            .map { $0.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "deg", with: "") }
        guard parts.count >= 3, let h = Double(parts[0]), let s = Double(parts[1]), let l = Double(parts[2]) else {
            return nil
        }
        return hsl(h, min(100, max(0, s)) / 100, min(100, max(0, l)) / 100)
    }

    private static func hsl(_ hue: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let a = s * min(l, 1 - l)
        func channel(_ n: Double) -> Double {
            let k = (n + h / 30).truncatingRemainder(dividingBy: 12)
            return l - a * max(-1, min(k - 3, 9 - k, 1))
        }
        return (channel(0), channel(8), channel(4))
    }
}
