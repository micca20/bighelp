import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Demo-mode pets, drawn here in code. No petdex art ships in the app; these
/// stand in for the gallery so the Pets tab works without a host.
enum PetdexFixtures {
    private struct Design {
        let name: String
        let body: UInt32
        let feature: Feature
    }

    private enum Feature: CaseIterable { case ears, antenna, horns, leaf, none }

    private static let designs: [Design] = [
        Design(name: "Pip", body: 0xF6A04D, feature: .ears),
        Design(name: "Mochi", body: 0xF2D0E4, feature: .none),
        Design(name: "Bolt", body: 0x5DB7E8, feature: .antenna),
        Design(name: "Fern", body: 0x7BC86C, feature: .leaf),
        Design(name: "Ember", body: 0xE5584F, feature: .horns),
        Design(name: "Nimbus", body: 0xC9D3E6, feature: .none),
        Design(name: "Juniper", body: 0x9B87F5, feature: .ears),
        Design(name: "Pebble", body: 0x9AA0A6, feature: .antenna),
    ]

    private static let moods = ["", "Sleepy ", "Tiny ", "Royal "]

    static let pets: [PetdexPet] = moods.enumerated().flatMap { moodIndex, mood in
        designs.enumerated().map { index, design in
            let name = mood + design.name
            return PetdexPet(slug: name.lowercased().replacingOccurrences(of: " ", with: "-"), displayName: name,
                             spritesheetURL: nil, installed: moodIndex == 0 && index < 2, curated: moodIndex == 0)
        }
    }

    /// A 96×104 PNG, the size Hermes's `pet.thumb` returns.
    static func thumbnail(slug: String) -> Data? {
        guard let index = pets.firstIndex(where: { $0.slug == slug }) else { return nil }
        let design = designs[index % designs.count]
        let mood = index / designs.count
        let grid = PixelGrid(width: 24, height: 26)
        draw(design, mood: mood, on: grid)
        return grid.png(scale: 4)
    }

    /// A full 1536×1872 sheet (8 columns × 9 rows of 192×208 frames, today's
    /// petdex layout) with each row's frames moving a little, for demo moves.
    static func sheet(slug: String) -> Data? {
        guard let index = pets.firstIndex(where: { $0.slug == slug }) else { return nil }
        let design = designs[index % designs.count]
        let mood = index / designs.count
        let grid = PixelGrid(width: 24 * 8, height: 26 * 9)
        // Per row (idle, run right, run left, wave, jump, failed, waiting, run, review): x and y steps.
        let steps: [[(Int, Int)]] = [
            [(0, 0), (0, 0), (0, 1), (0, 1), (0, 0), (0, 0)],
            [(0, 0), (1, -1), (2, 0), (1, -1), (0, 0), (-1, -1)],
            [(0, 0), (-1, -1), (-2, 0), (-1, -1), (0, 0), (1, -1)],
            [(-1, 0), (0, 0), (1, 0), (0, 0), (-1, 0), (0, 0)],
            [(0, 0), (0, -1), (0, -2), (0, -2), (0, -1), (0, 0)],
            [(0, 0), (0, 1), (0, 1), (0, 2), (0, 2), (0, 2)],
            [(0, 0), (0, 0), (0, 0), (0, -1), (0, 0), (0, 0)],
            [(0, 0), (0, -1), (0, 0), (0, -1), (0, 0), (0, -1)],
            [(0, 0), (0, 0), (1, 0), (1, 0), (0, 0), (0, 0)],
        ]
        for (row, frames) in steps.enumerated() {
            for (column, step) in frames.enumerated() {
                grid.cell = (column * 24, row * 26, 24, 26)
                grid.origin = (column * 24 + step.0, row * 26 + step.1)
                draw(design, mood: mood, on: grid)
            }
        }
        return grid.png(scale: 8)
    }

    private static func draw(_ design: Design, mood: Int, on grid: PixelGrid) {
        let outline: UInt32 = 0x2E3238
        let shade = darker(design.body)
        // Body: a soft oval resting on two feet.
        for y in 7..<22 {
            for x in 3..<21 {
                let dx = (Double(x) - 11.5) / 8.5, dy = (Double(y) - 14.5) / 7.5
                let d = dx * dx + dy * dy
                if d <= 1 { grid.set(x, y, d > 0.72 ? outline : (y > 17 ? shade : design.body)) }
            }
        }
        for x in [7, 8, 15, 16] { grid.set(x, 22, outline); grid.set(x, 23, outline) }
        // Eyes, closed when sleepy.
        for x in [8, 15] {
            if mood == 1 {
                grid.set(x - 1, 13, outline); grid.set(x, 13, outline); grid.set(x + 1, 13, outline)
            } else {
                grid.set(x, 12, 0xFFFFFF); grid.set(x, 13, outline); grid.set(x, 14, outline)
            }
        }
        grid.set(11, 16, outline); grid.set(12, 16, outline)
        switch design.feature {
        case .ears:
            for (x, y) in [(5, 6), (6, 5), (6, 6), (17, 5), (17, 6), (18, 6)] { grid.set(x, y, outline) }
        case .antenna:
            for y in 3..<7 { grid.set(12, y, outline) }
            grid.set(11, 2, 0xF6C445); grid.set(12, 2, 0xF6C445); grid.set(13, 2, 0xF6C445)
        case .horns:
            for (x, y) in [(6, 5), (7, 6), (17, 5), (16, 6)] { grid.set(x, y, 0xF2F1EC) }
        case .leaf:
            for (x, y) in [(12, 6), (13, 5), (14, 4), (14, 5), (15, 4)] { grid.set(x, y, 0x3E9B4F) }
        case .none:
            break
        }
        if mood == 3 { for x in [9, 11, 13, 15] { grid.set(x, 5, 0xF6C445); grid.set(x, 6, 0xF6C445) } }
    }

    private static func darker(_ rgb: UInt32) -> UInt32 {
        let r = (rgb >> 16 & 255) * 4 / 5, g = (rgb >> 8 & 255) * 4 / 5, b = (rgb & 255) * 4 / 5
        return r << 16 | g << 8 | b
    }

    private final class PixelGrid {
        let width: Int, height: Int
        private var pixels: [UInt32?]
        /// Where drawing starts and the frame it stays inside (sheets only).
        var origin = (0, 0)
        var cell: (x: Int, y: Int, width: Int, height: Int)?

        init(width: Int, height: Int) {
            self.width = width
            self.height = height
            pixels = Array(repeating: nil, count: width * height)
        }

        func set(_ x: Int, _ y: Int, _ rgb: UInt32) {
            let x = x + origin.0, y = y + origin.1
            if let cell, !(cell.x..<cell.x + cell.width).contains(x) || !(cell.y..<cell.y + cell.height).contains(y) {
                return
            }
            guard (0..<width).contains(x), (0..<height).contains(y) else { return }
            pixels[y * width + x] = rgb
        }

        func png(scale: Int) -> Data? {
            let w = width * scale, h = height * scale
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            for y in 0..<h {
                for x in 0..<w {
                    guard let rgb = pixels[(y / scale) * width + x / scale] else { continue }
                    let offset = (y * w + x) * 4
                    bytes[offset] = UInt8(rgb >> 16 & 255)
                    bytes[offset + 1] = UInt8(rgb >> 8 & 255)
                    bytes[offset + 2] = UInt8(rgb & 255)
                    bytes[offset + 3] = 255
                }
            }
            guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                  let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            else { return nil }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
                return nil
            }
            CGImageDestinationAddImage(destination, image, nil)
            return CGImageDestinationFinalize(destination) ? output as Data : nil
        }
    }
}
