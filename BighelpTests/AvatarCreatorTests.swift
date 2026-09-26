import Foundation
import Testing
import UIKit
@testable import Bighelp

@MainActor
struct AvatarCreatorTests {
    @Test func looksSavedBeforeTheCreatorStillLoad() throws {
        let saved = Data(##"{"character":"pip","colorHex":"#3366AA","matchesTheme":false}"##.utf8)
        let look = try JSONDecoder().decode(CompanionAppearance.self, from: saved)
        #expect(look.character == .octopus)
        #expect(look.eyeStyle == nil && look.eyeColorHex == nil && look.topper == nil)
        #expect(look.pattern == nil && look.vibe == nil)
    }

    @Test func creatorChoicesRoundTripAndUnknownValuesFallBack() throws {
        let look = CompanionAppearance(character: .cat, colorHex: "#2bb3b1", matchesTheme: false,
            eyeStyle: .venom, eyeColorHex: "c2185b", topper: .crown, pattern: .hex, vibe: .dancer)
        let restored = try JSONDecoder().decode(CompanionAppearance.self, from: JSONEncoder().encode(look))
        #expect(restored == look)
        #expect(restored.colorHex == "#2BB3B1")
        #expect(restored.eyeColorHex == "#C2185B")

        // A newer build's option must not cost this build the whole pet.
        let future = Data(##"{"character":"sol","colorHex":"#F6C445","matchesTheme":false,"eyeStyle":"laser","topper":"wizardHat","pattern":"tartan","vibe":"moonwalk","eyeColorHex":"not-a-color"}"##.utf8)
        let lenient = try JSONDecoder().decode(CompanionAppearance.self, from: future)
        #expect(lenient.character == .dragon)
        #expect(lenient.eyeStyle == nil && lenient.topper == nil && lenient.pattern == nil)
        #expect(lenient.vibe == nil && lenient.eyeColorHex == nil)
    }

    @Test func agentCompanionKeepsEveryCreatorChoice() {
        let defaults = isolatedDefaults()
        let store = CompanionStore(defaults: defaults)
        let look = CompanionAppearance(character: .owl, colorHex: "#7B4FD6", matchesTheme: false,
            eyeStyle: .scowl, topper: .catEars, pattern: .camo, vibe: .sleepy)
        store.setOverride(look, for: "host:agent")
        #expect(store.override(for: "host:agent") == look)
        #expect(CompanionStore(defaults: defaults).override(for: "host:agent") == look)
    }

    @Test func eyesStayReadableOnAnyBodyColor() {
        // Ink eyes vanish on a charcoal body; snow eyes on a snow body.
        #expect(CompanionAvatar.readableEyeColor(authored: "#16181B", body: "#2E3238") == "#F5F6F4")
        #expect(CompanionAvatar.readableEyeColor(authored: "#F5F6F4", body: "#F2F1EC") == "#16181B")
        // A readable authored color is kept as designed.
        #expect(CompanionAvatar.readableEyeColor(authored: "#16181B", body: "#F6C445") == "#16181B")
        #expect(CompanionAvatar.readableEyeColor(authored: "#F5F6F4", body: "#1E7A4E") == "#F5F6F4")
    }

    @Test func everyCharacterOffersEveryTab() {
        let model = AvatarCreatorModel(appearance: CompanionAppearance(character: .lobster))
        model.tab = .extras
        for character in CompanionCharacter.allCases {
            model.select(character)
            #expect(model.tabs == [.character, .color, .extras, .moves])
            #expect(model.tab == .extras)
        }
        #expect(CompanionCharacter.characters.count == 10 && CompanionCharacter.bits.count == 10)
    }

    @Test func colorChoicesAndShuffle() {
        let model = AvatarCreatorModel(appearance: CompanionAppearance(character: .lobster, matchesTheme: true))
        model.selectColor("#3F6FD8")
        #expect(!model.appearance.matchesTheme && model.appearance.colorHex == "#3F6FD8")
        model.selectThemeColor()
        #expect(model.appearance.matchesTheme)
        for _ in 0..<20 {
            let before = model.appearance.character
            model.shuffle()
            #expect(model.appearance.character != before)
            #expect(!model.appearance.matchesTheme)
            #expect(model.tabs.contains(model.tab))
        }
    }

    @Test func newAgentsCloneTheDefaultAgentUnlessCloningIsUnavailable() async throws {
        let store = AgentDirectoryStore(
            client: AgentDirectoryFixtureClient(profiles: [.financeFixture, .defaultFixture]),
            defaults: isolatedDefaults()
        )
        try await store.load()
        let model = AgentEditorModel.creating(store: store, processor: AvatarImageProcessor(),
                                               profileCloneSupport: .nativeBundleOnly)
        #expect(model.draft.cloneSourceProfileID == AgentProfile.defaultFixture.id)
        #expect(model.cloneSourceName == AgentProfile.defaultFixture.name)
        #expect(!model.draft.skipBundledSkills)
        #expect(!model.hasUnsavedChanges)
        model.selectCloneSource(nil)
        #expect(model.cloneSourceName == nil)

        let unsupported = AgentEditorModel.creating(store: store, processor: AvatarImageProcessor())
        #expect(unsupported.draft.cloneSourceProfileID == nil)
        let editing = AgentEditorModel.editing(.financeFixture, store: store, processor: AvatarImageProcessor())
        #expect(editing.draft.cloneSourceProfileID == nil && editing.cloneSourceName == nil)
    }

    @Test func creatorLookTravelsWithItsAvatarUntilRemoved() async throws {
        let store = AgentDirectoryStore(client: AgentDirectoryFixtureClient(profiles: []), defaults: isolatedDefaults())
        let model = AgentEditorModel.creating(store: store, processor: AvatarImageProcessor())
        let png = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        let look = CompanionAppearance(character: .fox, colorHex: "#9B87F5", matchesTheme: false, vibe: .bouncy)
        try await model.importCompanionAvatar(data: png, appearance: look)
        #expect(model.selectedCompanionAppearance == look)
        #expect(model.selectedCompanionCharacter == .fox)
        try await model.importAvatar(data: png)
        #expect(model.selectedCompanionAppearance == nil)
        try await model.importCompanionAvatar(data: png, appearance: look)
        model.removeAvatar()
        #expect(model.selectedCompanionAppearance == nil && model.pendingAvatar == nil)
    }
}
