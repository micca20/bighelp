import XCTest
import UIKit

final class RootChromeCanvasUITests: BighelpUITestCase {
    @MainActor
    func testAllRootScreensKeepDarkCanvasBehindChrome() throws {
        // Live chrome always paints the Ember "after dark" canvas (#121110).
        try verifyRootCanvas(appearance: "dark", expected: [18, 17, 16])
    }

    @MainActor
    func testAllRootScreensKeepLightCanvasBehindChrome() throws {
        // Live chrome always paints the Ember cream canvas (#FFF9F5).
        try verifyRootCanvas(appearance: "light", expected: [255, 249, 245])
    }

    @MainActor
    private func verifyRootCanvas(appearance: String, expected: [Int]) throws {
        XCUIDevice.shared.orientation = .portrait
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                               "-test-root-chrome-canvas", "-loopdy.demo.appearance", appearance]
        app.launch()
        let tabs = ["tab.agents", "tab.sessions", "tab.scheduled-tasks", "tab.profile"]
        for tab in tabs {
            openRootTab(tab, in: app, timeout: 5)
            let nav = app.otherElements["primary-navigation"]
            XCTAssertTrue(nav.waitForExistence(timeout: 3))
            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "root-canvas-\(appearance)-\(tab)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let image = try XCTUnwrap(screenshot.image.cgImage)
            let scale = CGFloat(image.width) / app.frame.width
            let probes: [(String, CGPoint)] = [
                ("header", CGPoint(x: app.frame.midX, y: 90)),
                ("bottom bar outer margin", CGPoint(x: 2, y: nav.frame.midY)),
                ("bottom safe area", CGPoint(x: 2, y: app.frame.maxY - 8))
            ]
            for (region, point) in probes {
                let color = try pixel(image, at: CGPoint(x: point.x * scale, y: point.y * scale))
                for channel in 0..<3 {
                    // Native glass casts a small shadow into its outer margin.
                    let tolerance = region == "bottom bar outer margin" ? 10.0 : 5.0
                    XCTAssertEqual(Double(color[channel]), Double(expected[channel]), accuracy: tolerance,
                                   "\(tab) \(region) must paint the theme canvas, not a system-color band")
                }
            }
        }
    }

    private func pixel(_ image: CGImage, at point: CGPoint) throws -> [UInt8] {
        let crop = try XCTUnwrap(image.cropping(to: CGRect(x: point.x, y: point.y, width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                                    bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return rgba
    }
}
