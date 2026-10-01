import SwiftUI

@main
struct BighelpWatchApp: App {
    @State private var store = WatchStore(phone: Self.makePhone())

    var body: some Scene {
        WindowGroup {
            WatchRootView(store: store)
                .preferredColorScheme(.dark)
        }
    }

    /// Demo data for tests and screenshots, otherwise the paired iPhone.
    @MainActor
    private static func makePhone() -> any WatchPhoneTalking {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-watch-demo") { return WatchDemoPhone() }
        #endif
        return WatchPhone()
    }
}
