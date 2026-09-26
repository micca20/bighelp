import SwiftUI
import Testing
import UIKit
@testable import Loopdy

/// The bundled avatar kit loads, and every character draws in every state and
/// creator option. Set LOOPDY_AVATAR_RENDER_DIR to save PNGs for review.
@MainActor
struct AvatarKitRenderTests {
    static let moods = ["idle", "listening", "thinking", "alert", "bounce", "happy", "sleepy", "sad", "dance", "scan"]

    private let output = ProcessInfo.processInfo.environment["LOOPDY_AVATAR_RENDER_DIR"].map(URL.init(fileURLWithPath:))

    @Test func bundledKitMatchesTheCharacterList() throws {
        let kit = try #require(AvatarKit.bundled)
        #expect(Set(kit.characters.map(\.id)) == Set(CompanionCharacter.allCases.map(\.rawValue)))
        #expect(kit.states == ["idle", "listening", "thinking", "waiting", "talking", "happy", "sleeping"])
        #expect(kit.themes.first?.id == "original")
        for character in CompanionCharacter.allCases {
            let art = kit.character(character.rawValue)
            #expect(art?.name == character.displayName)
            #expect((art?.family == "bits") == character.isBit)
            #expect((art?.face != nil) == character.isBit)
        }
        for mood in BuddyPose.moods {
            #expect(kit.states.contains(AvatarKitScene.states(for: mood).state), "\(mood)")
        }
    }

    @Test func pathDataParsesEveryCommand() {
        let path = AvatarKitPath.parse("M10 10 L20 10 Q25 15 20 20 C 18 24, 12 24, 10 20 Z m5-5 h2 v2 l-2 0z")
        #expect(!path.isEmpty)
        let bounds = path.boundingRect
        #expect(bounds.minX >= 9.9 && bounds.maxX <= 25.1 && bounds.minY >= 4.9 && bounds.maxY <= 24.1)
        // Clockwise half circle over the top: (0,10) → (20,10) through (10,0).
        let arc = AvatarKitPath.parse("M0 10 A10 10 0 0 1 20 10").boundingRect
        #expect(abs(arc.minX) < 0.1 && abs(arc.maxX - 20) < 0.1 && abs(arc.minY) < 0.1 && abs(arc.maxY - 10) < 0.1)
    }

    @Test func timingFollowsCSSKeyframes() {
        let stops = [AvatarKit.Stop(t: 0, tf: .init(r: -10), o: nil), AvatarKit.Stop(t: 1, tf: .init(r: 10), o: nil)]
        let linear = AvatarKit.Animation(name: "x", dur: 2, delay: 0, ease: "linear", dir: "normal", iter: 0)
        #expect(abs((AvatarKitTiming.sample(linear, stops: stops, time: 1, baseOpacity: 1).transform?.r ?? 99) - 0) < 0.001)
        let alternate = AvatarKit.Animation(name: "x", dur: 2, delay: 0, ease: "linear", dir: "alternate", iter: 0)
        #expect(abs((AvatarKitTiming.sample(alternate, stops: stops, time: 2.5, baseOpacity: 1).transform?.r ?? 99) - 5) < 0.001)
        #expect(abs(AvatarKitTiming.ease("ease-in-out", 0.5) - 0.5) < 0.01)
        #expect(AvatarKitTiming.ease("steps(1)", 0.99) == 0)
    }

    @Test func everyCharacterDrawsInEveryMood() throws {
        for character in CompanionCharacter.allCases {
            for mood in Self.moods {
                let look = CompanionAppearance(character: character, usesCharacterColors: true)
                try render(avatar(look, mood: mood), name: "mood-\(character.rawValue)-\(mood)")
            }
        }
    }

    @Test func everyCreatorOptionDraws() throws {
        for character in [CompanionCharacter.lobster, .messenger, .robot] {
            let base = CompanionAppearance(character: character, usesCharacterColors: true)
            for way in AvatarKit.bundled?.themes ?? [] {
                var look = base
                look.colorway = way.id == "original" ? nil : way.id
                try render(avatar(look), name: "colorway-\(character.rawValue)-\(way.id)")
            }
            for topper in CompanionTopper.allCases {
                var look = base
                look.topper = topper
                try render(avatar(look), name: "topper-\(character.rawValue)-\(topper.rawValue)")
            }
            for pattern in CompanionPattern.allCases {
                var look = base
                look.pattern = pattern
                try render(avatar(look), name: "pattern-\(character.rawValue)-\(pattern.rawValue)")
            }
        }
    }

    @Test func everyBitFaceOptionDraws() throws {
        let base = CompanionAppearance(character: .orb, usesCharacterColors: true)
        let plain = try pixels(avatar(base))
        func differs(_ change: (inout CompanionAppearance) -> Void, _ name: String) throws {
            var look = base
            change(&look)
            try render(avatar(look), name: name)
            let drawn = try pixels(avatar(look))
            let changed = zip(plain, drawn).filter {
                abs(Int($0.r) - Int($1.r)) + abs(Int($0.g) - Int($1.g)) + abs(Int($0.b) - Int($1.b)) + abs(Int($0.a) - Int($1.a)) > 12
            }.count
            // The smallest option (a fang) changes about a dozen pixels at this size.
            #expect(changed > 8, "\(name) looks the same as Bop's own face")
        }
        for eyes in CompanionBitEyes.allCases where eyes != .round {
            try differs({ $0.bitEyes = eyes }, "bit-eyes-\(eyes.rawValue)")
        }
        for mouth in CompanionBitMouth.allCases where mouth != .smile {
            try differs({ $0.bitMouth = mouth }, "bit-mouth-\(mouth.rawValue)")
        }
        for accessory in CompanionBitAccessory.allCases where accessory != .antenna {
            try differs({ $0.bitAccessory = accessory }, "bit-accessory-\(accessory.rawValue)")
        }
        try differs({ $0.showsCheeks = false }, "bit-cheeks-off")
        #expect(base.avatarKitFace == nil)
        #expect(CompanionAppearance(character: .lobster, bitEyes: .visor).avatarKitFace == nil)
    }

    @Test func mainColorRecolorsTheBody() throws {
        for character in CompanionCharacter.allCases {
            let red = try pixels(avatar(CompanionAppearance(character: character, colorHex: "#E5484D", matchesTheme: false)))
            let blue = try pixels(avatar(CompanionAppearance(character: character, colorHex: "#3B82F6", matchesTheme: false)))
            let redness = red.reduce(0) { $0 + max(0, Int($1.r) - Int($1.b)) }
            let blueness = blue.reduce(0) { $0 + max(0, Int($1.b) - Int($1.r)) }
            #expect(redness > 20_000, "\(character) should look red")
            #expect(blueness > 20_000, "\(character) should look blue")
        }
    }

    @Test func savedLooksKeepWorking() throws {
        let legacy = Data(##"{"character":"pip","colorHex":"#4F46E5","matchesTheme":false}"##.utf8)
        let look = try JSONDecoder().decode(CompanionAppearance.self, from: legacy)
        #expect(look.character == .octopus)
        #expect(!look.usesCharacterColors && look.colorway == nil)
        let unknown = Data(##"{"character":"future-friend","colorHex":"#4F46E5","matchesTheme":false,"colorway":"Not OK!"}"##.utf8)
        let lenient = try JSONDecoder().decode(CompanionAppearance.self, from: unknown)
        #expect(lenient.character == .lobster && lenient.colorway == nil)
        let styled = CompanionAppearance(character: .fox, colorway: "neon", usesCharacterColors: true)
        #expect(try JSONDecoder().decode(CompanionAppearance.self, from: JSONEncoder().encode(styled)) == styled)
        let bit = CompanionAppearance(character: .gem, usesCharacterColors: true, bitEyes: .dot, bitMouth: .fang,
                                      bitAccessory: .bow, showsCheeks: false)
        #expect(try JSONDecoder().decode(CompanionAppearance.self, from: JSONEncoder().encode(bit)) == bit)
        let future = Data(##"{"character":"cube","colorHex":"#4F46E5","matchesTheme":false,"bitEyes":"laser"}"##.utf8)
        let cube = try JSONDecoder().decode(CompanionAppearance.self, from: future)
        #expect(cube.character == .cube && cube.bitEyes == nil && cube.showsCheeks)
    }

    // MARK: Helpers

    private func avatar(_ look: CompanionAppearance, mood: String? = nil) -> some View {
        CompanionAvatar(appearance: look, reaction: .idle, isAnimating: false, activityMood: mood)
            .frame(width: 200, height: 200)
    }

    private func render(_ view: some View, name: String) throws {
        let image = try snapshot(view)
        let visible = try pixels(image).filter { $0.a > 16 }.count
        #expect(visible > 4_000, "\(name) drew almost nothing")
        if let output {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try #require(image.pngData()).write(to: output.appendingPathComponent("\(name).png"))
        }
    }

    private func snapshot(_ view: some View) throws -> UIImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        renderer.isOpaque = false
        return try #require(renderer.uiImage)
    }

    private func pixels(_ view: some View) throws -> [(r: UInt8, g: UInt8, b: UInt8, a: UInt8)] {
        try pixels(snapshot(view))
    }

    private func pixels(_ image: UIImage) throws -> [(r: UInt8, g: UInt8, b: UInt8, a: UInt8)] {
        let source = try #require(image.cgImage)
        let width = source.width
        let height = source.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 0, to: bytes.count, by: 4).map { (bytes[$0], bytes[$0 + 1], bytes[$0 + 2], bytes[$0 + 3]) }
    }
}
