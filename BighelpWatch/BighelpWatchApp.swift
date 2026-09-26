import SwiftUI

@main
struct BighelpWatchApp: App {
    @State private var store: WatchCompanionStore

    init() {
        _store = State(initialValue: WatchCompanionStore())
    }

    var body: some Scene {
        WindowGroup {
            WatchCompanionRootView(store: store)
                .preferredColorScheme(.dark)
        }
    }
}
