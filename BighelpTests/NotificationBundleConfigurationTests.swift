import Foundation
import Testing

struct NotificationBundleConfigurationTests {
    @Test func applicationBundleContainsPublicBuzzKitConfiguration() throws {
        let key = try #require(Bundle.main.object(forInfoDictionaryKey: "BighelpBuzzKitClientKey") as? String)
        #expect(!key.contains("$("))
        #expect(!key.contains(" "))
        // The key comes from the git-ignored Config/Local.xcconfig; builds without it leave notifications off.
        if !key.isEmpty {
            #expect(key.hasPrefix("bk_pk_"))
            #expect(key.utf8.count >= 16)
        }
        #expect(Bundle.main.object(forInfoDictionaryKey: "BighelpBuzzKitAPIURL") as? String == "https://api.buzzkit.dev")
    }
}
