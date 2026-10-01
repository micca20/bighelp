import XCTest
import SwiftUI
import UIKit
@testable import Bighelp

final class AgentCompanionAvatarTests: XCTestCase {
    @MainActor
    func testEveryCompanionProducesAPreparedAvatarWithoutChangingPetPreferences() async throws {
        let previousPreferences = UserDefaults.standard.data(forKey: "loopdy.companion.preferences")
        var rendered = Set<String>()
        for character in CompanionCharacter.allCases {
            do {
                let png = try await AgentCompanionAvatarRenderer.renderPNG(character: character,
                    appearance: .init(appearance: .light),
                    colorScheme: .light, colorSchemeContrast: .standard)
                let image = try XCTUnwrap(UIImage(data: png))
                XCTAssertEqual(image.cgImage?.width, 512)
                XCTAssertEqual(image.cgImage?.height, 512)
                let prepared = try AvatarImageProcessor().prepare(data: png)
                XCTAssertLessThanOrEqual(prepared.pixelSize.width, 1_024)
                XCTAssertLessThanOrEqual(prepared.pixelSize.height, 1_024)
                XCTAssertLessThanOrEqual(prepared.data.count, 1_500_000)
                XCTAssertNotNil(UIImage(data: prepared.data))
                let capture = XCTAttachment(image: image)
                capture.name = "agent-avatar-" + character.rawValue
                capture.lifetime = .keepAlways
                add(capture)
                rendered.insert(character.rawValue)
            } catch {
                XCTFail("\(character.rawValue) avatar failed: \(String(reflecting: type(of: error)))")
            }
        }
        XCTAssertEqual(rendered, Set(CompanionCharacter.allCases.map(\.rawValue)))
        XCTAssertEqual(UserDefaults.standard.data(forKey: "loopdy.companion.preferences"), previousPreferences)
    }
}
