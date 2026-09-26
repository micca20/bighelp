import SwiftUI
import UIKit

@MainActor
enum AgentCompanionAvatarRenderer {
    enum RenderError: Swift.Error {
        case unavailable
        case emptyImage
        case encodingFailed
    }

    static let pixelDimension = 512

    static func renderPNG(
        character: CompanionCharacter,
        appearance: BighelpAppearanceContext,
        colorScheme: ColorScheme,
        colorSchemeContrast: ColorSchemeContrast
    ) async throws -> Data {
        try await renderPNG(
            companion: CompanionAppearance(character: character, usesCharacterColors: true),
            appearance: appearance,
            colorScheme: colorScheme,
            colorSchemeContrast: colorSchemeContrast
        )
    }

    /// Renders the full creator look (color, eyes, headwear, pattern) in a still pose.
    static func renderPNG(
        companion: CompanionAppearance,
        appearance: BighelpAppearanceContext,
        colorScheme: ColorScheme,
        colorSchemeContrast: ColorSchemeContrast,
        pixelSize: Int = AgentCompanionAvatarRenderer.pixelDimension
    ) async throws -> Data {
        try Task.checkCancellation()
        guard let scene = foregroundScene else { throw RenderError.unavailable }

        let side = CGFloat(pixelSize)
        let content = CompanionAvatar(
            appearance: companion,
            reaction: .idle,
            isAnimating: false
        )
        .frame(width: side, height: side)
        .environment(\.appAppearance, appearance)
        .environment(\.colorScheme, colorScheme)

        let host = UIHostingController(rootView: content)
        host.safeAreaRegions = []
        host.traitOverrides.accessibilityContrast = colorSchemeContrast == .increased ? .high : .normal
        host.view.backgroundColor = .clear
        host.view.isOpaque = false

        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(
            x: scene.coordinateSpace.bounds.maxX + side,
            y: scene.coordinateSpace.bounds.minY,
            width: side,
            height: side
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        await Task.yield()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        for _ in 0..<3 {
            try Task.checkCancellation()
            let image = centered(snapshot(host.view, size: CGSize(width: side, height: side)), side: side)
            if containsVisiblePixels(image) {
                guard let data = image.pngData() else { throw RenderError.encodingFailed }
                return data
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        throw RenderError.emptyImage
    }

    private static var foregroundScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first {
            $0.activationState == .foregroundActive && $0.windows.contains(where: \.isKeyWindow)
        } ?? scenes.first { $0.activationState == .foregroundActive }
    }

    private static func snapshot(_ view: UIView, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
    }

    private static func centered(_ image: UIImage, side: CGFloat) -> UIImage {
        guard let source = image.cgImage else { return image }
        let width = source.width, height = source.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        var left = width, top = height, right = -1, bottom = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 16 {
                left = min(left, x); right = max(right, x)
                top = min(top, y); bottom = max(bottom, y)
            }
        }
        guard right >= left, bottom >= top, let normalized = context.makeImage(),
              let cropped = normalized.cropping(to: CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)) else { return image }
        let scale = side * 0.8 / CGFloat(max(cropped.width, cropped.height))
        let size = CGSize(width: CGFloat(cropped.width) * scale, height: CGFloat(cropped.height) * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            UIImage(cgImage: cropped).draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2,
                width: size.width, height: size.height))
        }
    }

    private static func containsVisiblePixels(_ image: UIImage) -> Bool {
        guard let source = image.cgImage else { return false }
        let width = min(source.width, 128)
        let height = min(source.height, 128)
        guard width > 0, height > 0 else { return false }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }

        context.interpolationQuality = .low
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        var visiblePixelCount = 0
        for alphaIndex in stride(from: 3, to: pixels.count, by: 4) where pixels[alphaIndex] > 16 {
            visiblePixelCount += 1
            if visiblePixelCount >= 64 { return true }
        }
        return false
    }
}
