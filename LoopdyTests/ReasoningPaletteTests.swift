import SwiftUI
import UIKit
import Testing
@testable import Loopdy

@MainActor
struct ReasoningPaletteTests {
    @Test func renderedReasoningTrackUsesEachSelectedThemeAccent() async throws {
        let choices = AgentReasoningOption.all.map {
            LoopdyReasoningChoice(value: $0.value, label: $0.title, detail: $0.detail)
        }
        for definition in LoopdyThemeRegistry.builtIns {
            for appearance in [AppAppearance.light, .dark] {
                let size = CGSize(width: 380, height: 320)
                let root = LoopdyReasoningLevelControl(choices: choices, selectedValue: choices.last?.value,
                    isEnabled: true, accessibilityIdentifier: "palette", onSelect: { _ in })
                    .environment(\.loopdyUIV2Enabled, true)
                    .environment(\.appAppearance, LoopdyAppearanceContext(appearance: appearance, themeID: definition.id))
                    .environment(\.colorScheme, appearance == .dark ? .dark : .light)
                let controller = UIHostingController(rootView: root)
                let window = UIWindow(frame: CGRect(origin: .zero, size: size))
                window.rootViewController = controller
                window.makeKeyAndVisible()
                controller.view.frame = window.bounds
                try await Task.sleep(for: .milliseconds(100))
                controller.view.layoutIfNeeded()
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
                }
                let cg = try #require(image.cgImage)
                var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
                let context = try #require(CGContext(data: &pixels, width: cg.width, height: cg.height,
                    bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
                let theme = LoopdyTheme.resolve(
                    appearance: LoopdyAppearanceContext(appearance: appearance, themeID: definition.id),
                    colorScheme: appearance == .dark ? .dark : .light, contrast: .standard)
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                let tint = UIColor(theme.action).resolvedColor(with: UITraitCollection(
                    userInterfaceStyle: appearance == .dark ? .dark : .light))
                #expect(tint.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
                let expected = [red, green, blue].map { Int(($0 * 255).rounded()) }
                var matches = 0
                for i in stride(from: 0, to: pixels.count, by: 4) {
                    if (0..<3).allSatisfy({ abs(Int(pixels[i + $0]) - expected[$0]) < 20 }) {
                        matches += 1
                    }
                }
                // A full track contributes thousands of pixels. Matching only
                // the small label or thumb must not hide a forced spectrum.
                #expect(matches > 1000, "\(definition.name) \(appearance.rawValue) must paint the full track with its own accent")
                let directory = URL(fileURLWithPath: "/private/tmp/loopdy-chat-six/evidence/palette")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try image.pngData()?.write(to: directory.appendingPathComponent("\(definition.id.rawValue)-\(appearance.rawValue).png"))
                window.isHidden = true
            }
        }
    }
}
