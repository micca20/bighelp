import Foundation
import Testing
@testable import Bighelp

@MainActor
struct ResponseHapticsSettingsTests {
    @Test func defaultsOnAndPersistsExplicitOffAndOn() {
        let name = "response-haptics-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.responseHapticsEnabled)
        settings.responseHapticsEnabled = false
        #expect(!SettingsStore(defaults: defaults).responseHapticsEnabled)
        settings.responseHapticsEnabled = true
        #expect(SettingsStore(defaults: defaults).responseHapticsEnabled)
    }
}
