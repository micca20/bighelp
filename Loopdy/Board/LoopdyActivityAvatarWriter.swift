import UIKit

/// Writes a small copy of an agent's picture to the shared app group for the
/// Live Activity. Rewrites only when the picture changed.
enum LoopdyActivityAvatarWriter {
    static func write(agentID: String, from source: URL) {
        guard let destination = LoopdyActivityAvatarStore.fileURL(agentID: agentID),
              let data = try? Data(contentsOf: source), data.count <= 16_777_216,
              let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return }
        let side = CGFloat(LoopdyActivityAvatarStore.pixelSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let scale = max(side / image.size.width, side / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            image.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2,
                                  width: size.width, height: size.height))
        }
        guard let png = resized.pngData(), png.count <= 262_144 else { return }
        if let existing = try? Data(contentsOf: destination), existing == png { return }
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? png.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
