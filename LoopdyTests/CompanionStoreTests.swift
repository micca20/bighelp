import Foundation
import Testing
@testable import Loopdy

@MainActor
struct CompanionStoreTests {
    @Test func sizeAndAdventurePersistWithoutReplacingCharacterOverrides() throws {
        let defaults = isolatedDefaults()
        let store = CompanionStore(defaults: defaults)
        store.defaultAppearance = .init(character: .robot, colorHex: "#8844EE", matchesTheme: false)
        store.setOverride(.init(character: .dragon), for: "my-host:my-agent")
        store.sizeScale = 1.35
        store.isAdventurous = true
        store.isEnabled = false
        let restored = CompanionStore(defaults: defaults)
        #expect(restored.sizeScale == 1.35)
        #expect(restored.isAdventurous)
        #expect(!restored.isEnabled)
        #expect(restored.defaultAppearance == store.defaultAppearance)
        #expect(restored.agentOverrides == store.agentOverrides)
    }

    @Test func schemaOneWithoutNewKeysKeepsExistingPetChoices() throws {
        let defaults = isolatedDefaults()
        let bytes = Data(##"{"schemaVersion":1,"isEnabled":true,"defaultAppearance":{"character":"clip","colorHex":"#123456","matchesTheme":false},"agentOverrides":{}}"##.utf8)
        defaults.set(bytes, forKey: "loopdy.companion.preferences")
        let restored = CompanionStore(defaults: defaults)
        #expect(restored.isEnabled)
        #expect(restored.defaultAppearance.character == .robot)
        #expect(restored.defaultAppearance.colorHex == "#123456")
        #expect(restored.sizeScale == 1)
        #expect(!restored.isAdventurous)
    }

    @Test func companionScaleRejectsNonfiniteAndOutOfRangeValues() {
        let defaults = isolatedDefaults()
        let store = CompanionStore(defaults: defaults)
        for value in [Double.nan, .infinity, -.infinity, -3, 500] {
            store.sizeScale = value
            #expect(store.sizeScale.isFinite)
            #expect((0.6...1.5).contains(store.sizeScale))
            #expect(CompanionStore(defaults: defaults).sizeScale == store.sizeScale)
        }
    }

    @Test func petsAreOptInAndAllSuppliedChoicesExist() {
        let store = CompanionStore(defaults: isolatedDefaults())
        #expect(!store.isEnabled)
        #expect(Set(CompanionCharacter.allCases.map(\.rawValue)) == Set([
            "lobster", "messenger", "zeus", "octopus", "robot", "dragon", "owl", "cat", "fox", "dog",
            "orb", "cube", "wedge", "hex", "drop", "capsule", "cloud", "ghost", "bloom", "gem",
        ]))
    }

    @Test func overrideIsExactAndDoesNotChangeHomeDefault() {
        let store = CompanionStore(defaults: isolatedDefaults())
        let standard = CompanionAppearance(character: .dog, colorHex: "#8844EE", matchesTheme: false)
        let override = CompanionAppearance(character: .robot, colorHex: "#33AADD", matchesTheme: false)
        store.defaultAppearance = standard
        store.setOverride(override, for: "host-a:agent-a")
        #expect(store.appearance(for: nil) == standard)
        #expect(store.appearance(for: "host-a:agent-a") == override)
        #expect(store.appearance(for: "host-b:agent-a") == standard)
        #expect(store.appearance(for: "host-a:agent-b") == standard)
        store.setOverride(nil, for: "host-a:agent-a")
        #expect(store.appearance(for: "host-a:agent-a") == standard)
    }

    @Test func disablingRetainsChoicesAcrossReopen() {
        let defaults = isolatedDefaults()
        let store = CompanionStore(defaults: defaults)
        let standard = CompanionAppearance(character: .messenger, colorHex: "#CC4488", matchesTheme: false)
        let override = CompanionAppearance(character: .octopus, colorHex: "#3366AA", matchesTheme: true)
        store.isEnabled = true
        store.defaultAppearance = standard
        store.setOverride(override, for: "host:agent")
        store.isEnabled = false
        let restored = CompanionStore(defaults: defaults)
        #expect(!restored.isEnabled)
        #expect(restored.defaultAppearance == standard)
        #expect(restored.appearance(for: "host:agent") == override)
        restored.isEnabled = true
        #expect(restored.appearance(for: "host:agent") == override)
    }

    @Test func everyAcceptedOverrideSurvivesTheStorageByteLimit() {
        let defaults = isolatedDefaults()
        let store = CompanionStore(defaults: defaults)
        for index in 0..<256 {
            store.setOverride(.init(character: .robot, colorHex: "#ABCDEF", matchesTheme: false),
                              for: String(repeating: "a", count: 480) + "-\(index)")
        }
        let restored = CompanionStore(defaults: defaults)
        #expect(restored.agentOverrides == store.agentOverrides)
    }

    @Test func scopedAgentKeysCannotCollideAtSeparators() {
        #expect(CompanionStore.agentKey(agentScope: "a:b", agentID: "c")
                != CompanionStore.agentKey(agentScope: "a", agentID: "b:c"))
    }

    @Test func accountBoundaryClearsOverridesButKeepsAppearancePreference() {
        let store = CompanionStore(defaults: isolatedDefaults())
        let standard = CompanionAppearance(character: .dragon, colorHex: "#FFBB66", matchesTheme: true)
        store.defaultAppearance = standard
        store.setOverride(.init(character: .robot, colorHex: "#123456", matchesTheme: false), for: "host:agent")
        store.clearAgentOverrides()
        #expect(store.appearance(for: "host:agent") == standard)
        #expect(store.defaultAppearance == standard)
    }
}
