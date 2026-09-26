import Foundation

@MainActor
enum DirectHermesApplicationFactory {
    static func makeRegistry() -> LoopdyHostRegistry {
        #if DEBUG && targetEnvironment(simulator)
        if let runID = ProcessInfo.processInfo.environment["LOOPDY_UI_TEST_RUN_ID"], UUID(uuidString: runID) != nil {
            return LoopdyHostRegistry(root: URL.applicationSupportDirectory
                .appending(path: "DirectHermesTestHosts", directoryHint: .isDirectory).appending(path: runID),
                keychainService: "app.loopdy.direct-test." + runID)
        }
        #endif
        return LoopdyHostRegistry()
    }

    static func makeStore() -> DirectHermesWorkspaceStore {
        #if DEBUG && targetEnvironment(simulator)
        if let runID = ProcessInfo.processInfo.environment["LOOPDY_UI_TEST_RUN_ID"], UUID(uuidString: runID) != nil {
            // Native UI tests still authenticate against the actual selected host.
            // Only their local credential/draft namespace is isolated.
            return DirectHermesWorkspaceStore(vault: DirectHermesKeychainVault(service: "app.loopdy.direct-test." + runID),
                drafts: DirectHermesDraftStore(root: URL.applicationSupportDirectory
                    .appending(path: "DirectHermesTestDrafts", directoryHint: .isDirectory).appending(path: runID)))
        }
        #endif
        return DirectHermesWorkspaceStore()
    }
}
