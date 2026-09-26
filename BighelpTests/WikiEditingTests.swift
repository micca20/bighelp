import Foundation
import Testing
@testable import Bighelp

struct WikiEditingTests {
    @MainActor @Test func absentOwnerHasNoFileBoundDraftsOrStorageWork() {
        let store = WikiDraftStore(owner: nil)
        #expect(store.drafts.isEmpty)
    }
}
