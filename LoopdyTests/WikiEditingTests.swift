import Foundation
import Testing
@testable import Loopdy

struct WikiEditingTests {
    @MainActor @Test func absentOwnerHasNoFileBoundDraftsOrStorageWork() {
        let store = WikiDraftStore(owner: nil)
        #expect(store.drafts.isEmpty)
    }
}
