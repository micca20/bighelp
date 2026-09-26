import SwiftUI

/// Resolved colors for one avatar (six-digit hex).
struct AvatarKitColors: Equatable, Sendable {
    var primary: String
    var secondary: String
    var accent: String
    var background: String
    var ink: String
    var skin: String

    init(character: AvatarKit.Character) {
        let c = character.colors
        primary = c["p"] ?? "#888888"
        secondary = c["s"] ?? primary
        accent = c["a"] ?? primary
        background = c["bg"] ?? "#F2F2F2"
        ink = c["ink"] ?? "#2A2238"
        skin = c["skin"] ?? "#F6CFB0"
    }

    /// Applies a kit colorway (primary, secondary, accent, background, ink).
    mutating func apply(_ theme: AvatarKit.Theme) {
        if let value = theme.colors["primary"] { primary = value }
        if let value = theme.colors["secondary"] { secondary = value }
        if let value = theme.colors["accent"] { accent = value }
        if let value = theme.colors["background"] { background = value }
        if let value = theme.colors["ink"] { ink = value }
    }

    func color(_ token: String) -> Color {
        switch token {
        case "@p": Color(buddyHex: primary)
        case "@s": Color(buddyHex: secondary)
        case "@a": Color(buddyHex: accent)
        case "@bg": Color(buddyHex: background)
        case "@ink": Color(buddyHex: ink)
        case "@skin": Color(buddyHex: skin)
        default: Color(buddyHex: token)
        }
    }
}

/// A Bit's face parts: the kit's eyes, mouth, accessory and cheeks options.
struct AvatarKitFace: Equatable, Sendable {
    var eyes = "round"
    var mouth = "smile"
    var accessory = "none"
    var cheeks = true

    /// Whether a part drawn only for some options shows with this face.
    func shows(_ when: [String: [String]]) -> Bool {
        when.allSatisfy { option, values in
            switch option {
            case "eyes": values.contains(eyes)
            case "mouth": values.contains(mouth)
            case "acc": values.contains(accessory)
            case "cheeks": values.contains(cheeks ? "on" : "off")
            default: true
            }
        }
    }
}

extension AvatarKitFace {
    /// A Bit's own face.
    init(_ face: AvatarKit.Face?) {
        self.init()
        if let face {
            eyes = face.eyes
            mouth = face.mouth
            accessory = face.accessory
        }
    }
}

/// What the avatar is doing in one frame.
struct AvatarKitFrame {
    /// One of the kit's states: idle, listening, thinking, waiting, talking, happy, sleeping.
    var state = "idle"
    var time: Double = 0
    var animates = true
    /// Gaze, −1…1 on each axis (the kit's thinking state looks up on its own).
    var look = CGPoint.zero
    /// A Bit's face; nil draws its own.
    var face: AvatarKitFace?
    var showsBackground = true
    /// Extra whole-character motion in art units, around the feet (100, 182).
    var offset = CGSize.zero
    var rotation: Double = 0
    var squash: CGFloat = 1
}

enum AvatarKitRenderer {
    /// Draws `character` filling the smaller side of `size`.
    /// `decorateBody` draws on top of the body in art space (headwear), `fill` sees each shape.
    static func draw(
        _ character: AvatarKit.Character,
        kit: AvatarKit,
        colors: AvatarKitColors,
        frame: AvatarKitFrame,
        in context: GraphicsContext,
        size: CGSize,
        decorateBody: ((GraphicsContext) -> Void)? = nil,
        decorateShape: ((GraphicsContext, Path, String) -> Void)? = nil
    ) {
        let side = min(size.width, size.height)
        guard side > 0 else { return }
        var canvas = context
        canvas.translateBy(x: (size.width - side) / 2, y: (size.height - side) / 2)
        canvas.scaleBy(x: side / 200, y: side / 200)
        let environment = Environment(
            kit: kit, colors: colors, frame: frame,
            face: frame.face ?? AvatarKitFace(character.face),
            lookDistance: character.look,
            decorateBody: decorateBody, decorateShape: decorateShape
        )
        draw(character.tree, in: canvas, environment)
    }

    private struct Environment {
        let kit: AvatarKit
        let colors: AvatarKitColors
        let frame: AvatarKitFrame
        let face: AvatarKitFace
        let lookDistance: Double
        let decorateBody: ((GraphicsContext) -> Void)?
        let decorateShape: ((GraphicsContext, Path, String) -> Void)?
    }

    private static func draw(_ node: AvatarKit.Node, in context: GraphicsContext, _ env: Environment) {
        let style = node.style(for: env.frame.state)
        if style.hide == true || (node.isBackground && !env.frame.showsBackground) { return }
        if !node.when.isEmpty, !env.face.shows(node.when) { return }

        var c = context
        var opacity = style.o ?? 1
        var transform = style.tf
        var translate = style.tl
        if env.frame.animates, let animation = style.an, let stops = env.kit.keyframes[animation.name] {
            let sample = AvatarKitTiming.sample(animation, stops: stops, time: env.frame.time, baseOpacity: opacity)
            if let animated = sample.transform { transform = animated }
            if let animated = sample.translate { translate = animated }
            if let animated = sample.opacity { opacity = animated }
        }
        if let t = translate, t.count == 8 {
            let gaze = env.frame.look, distance = env.lookDistance
            c.translateBy(x: t[0] + t[1] * distance + (t[2] + t[3] * distance) * gaze.x,
                          y: t[4] + t[5] * distance + (t[6] + t[7] * distance) * gaze.y)
        }
        if let matrix = node.matrix { c.concatenate(matrix) }
        if let transform, let origin = style.org, origin.count == 2 {
            c.translateBy(x: origin[0] + (transform.tx ?? 0), y: origin[1] + (transform.ty ?? 0))
            c.rotate(by: .degrees(transform.r ?? 0))
            c.scaleBy(x: transform.sx ?? 1, y: transform.sy ?? 1)
            c.translateBy(x: -origin[0], y: -origin[1])
        }
        if node.isRig {
            let frame = env.frame
            c.translateBy(x: 100 + frame.offset.width, y: 182 + frame.offset.height)
            c.scaleBy(x: frame.squash, y: 1 / frame.squash)
            c.translateBy(x: 0, y: -62)
            c.rotate(by: .degrees(frame.rotation))
            c.translateBy(x: -100, y: -120)
        }
        guard opacity > 0.001 else { return }
        c.opacity *= opacity

        if let path = node.path {
            if let fill = style.f, fill != "none" {
                c.fill(path, with: .color(env.colors.color(fill).opacity(style.fo ?? 1)))
                env.decorateShape?(c, path, fill)
            }
            if let stroke = style.s, stroke != "none" {
                c.stroke(path, with: .color(env.colors.color(stroke).opacity(style.so ?? 1)), style: StrokeStyle(
                    lineWidth: style.sw ?? 1,
                    lineCap: style.cap == "round" ? .round : style.cap == "square" ? .square : .butt,
                    lineJoin: style.join == "round" ? .round : style.join == "bevel" ? .bevel : .miter
                ))
            }
        } else if node.kind == "text", let text = node.text, let origin = node.textOrigin {
            let font = Font.system(size: style.fs ?? 12, weight: .heavy, design: .rounded)
            if let stroke = style.s, stroke != "none" {
                let outline = c.resolve(Text(text).font(font).foregroundColor(env.colors.color(stroke).opacity(style.so ?? 1)))
                let radius = (style.sw ?? 1) / 2
                for step in 0..<8 {
                    let angle = Double(step) * .pi / 4
                    c.draw(outline, at: CGPoint(x: origin.x + cos(angle) * radius, y: origin.y + sin(angle) * radius), anchor: .bottomLeading)
                }
            }
            if let fill = style.f, fill != "none" {
                c.draw(Text(text).font(font).foregroundColor(env.colors.color(fill).opacity(style.fo ?? 1)), at: origin, anchor: .bottomLeading)
            }
        }
        for child in node.children { draw(child, in: c, env) }
        if node.isBody { env.decorateBody?(c) }
    }
}
