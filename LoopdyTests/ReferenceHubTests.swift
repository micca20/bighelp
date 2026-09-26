import Foundation
import Observation
import Testing
@testable import Loopdy

struct ReferenceHubTests {
    @MainActor @Test(arguments: [false, true])
    func quickSelectionUsesMetadataNotFirstDescriptionOption(hasMetadata: Bool) async throws {
        let metadata = try ReferenceSnapshot(kind: .issue,
            identity: .github(GitHubReferenceIdentity(repositoryID: "1", resourceID: "2",
                owner: "example", repository: "app", number: 143)), title: "Issue",
            selectedContent: "Metadata envelope, description excluded", sourceRevision: "revision-a", fetchedAt: Date(timeIntervalSince1970: 1))
        let description = try ReferenceSnapshot(kind: metadata.kind, identity: metadata.identity,
            title: metadata.title, selectedContent: "Private description", sourceRevision: "revision-a",
            fetchedAt: metadata.fetchedAt)
        let owner = ReferenceHubOwner(accountID: "account", hostID: "host", deviceID: "device",
            authorizationEpoch: "1", sessionID: "session", agentID: "default", recipientIDs: ["default"])
        let result = ReferenceHubResult(resourceID: "issue", providerID: "github", category: .issues,
            title: "Issue", subtitle: "example/app", state: nil, isCached: false)
        let hub = ReferenceHubStore(owner: owner, providers: [ReferenceHubProvider(id: "github", label: "GitHub",
            categories: [.issues], search: { _, _, _ in ReferenceHubSearchPage(results: [result], isPartial: false) },
            resolve: { _, _ in ReferenceHubPreview(result: result, sourceKindLabel: "GitHub", options: [
                ReferenceContentOption(id: "description", label: "Description", snapshot: description),
                ReferenceContentOption(id: "metadata", label: "Metadata", snapshot: metadata)].filter { hasMetadata || $0.id != "metadata" }) },
            revalidate: { _, snapshot in snapshot })])
        var edits: [ReferenceNativeEdit] = []
        hub.attachEditor(id: UUID()) { edit in
            edits.append(edit)
            return true
        }
        hub.setEditorActive(true)
        hub.receive(source: "Before /issue after", selection: NSRange(location: 13, length: 0), hasMarkedText: false)
        for _ in 0..<20 where hub.results.isEmpty { try await Task.sleep(for: .milliseconds(30)) }
        hub.select(try #require(hub.results.first))
        for _ in 0..<20 where hub.isResolving { try await Task.sleep(for: .milliseconds(20)) }
        if !hasMetadata {
            #expect(edits.isEmpty, "Do not fall back to sharing a description")
            #expect(hub.preview?.options.count == 1)
            #expect(hub.isPresented)
            return
        }
        let edit = try #require(edits.first)
        #expect(edits.count == 1)
        #expect(edit.replacement == metadata.anchor)
        #expect(edit.selections.map(\.snapshot) == [metadata])
        #expect(edit.resultingSelection.location == 7 + metadata.anchor.utf16.count)
        #expect(hub.preview == nil)
        #expect(!hub.isPresented)
        #expect(hub.isEditorActive)
        #expect(hub.frozenSubmission == nil)
    }

    @MainActor @Test func localInspectionRetiresDelayedQuickInsertionWithoutChangingDraft() async throws {
        let snapshot = try ReferenceSnapshot(kind: .issue,
            identity: .github(GitHubReferenceIdentity(repositoryID: "1", resourceID: "2",
                owner: "example", repository: "app", number: 143)), title: "Issue",
            selectedContent: "Metadata", sourceRevision: "revision-a", fetchedAt: Date(timeIntervalSince1970: 1))
        let owner = ReferenceHubOwner(accountID: "account", hostID: "host", deviceID: "device",
            authorizationEpoch: "1", sessionID: "session", agentID: "default", recipientIDs: ["default"])
        let result = ReferenceHubResult(resourceID: "issue", providerID: "github", category: .issues,
            title: "Issue", subtitle: "example/app", state: nil, isCached: false)
        let preview = ReferenceHubPreview(result: result, sourceKindLabel: "GitHub", options: [
            ReferenceContentOption(id: "metadata", label: "Metadata", snapshot: snapshot)])
        var pendingResolve: CheckedContinuation<Void, Never>?
        var didReturn = false
        var delayFirstResolve = true
        let hub = ReferenceHubStore(owner: owner, providers: [ReferenceHubProvider(id: "github", label: "GitHub",
            categories: [.issues], search: { _, _, _ in ReferenceHubSearchPage(results: [result], isPartial: false) },
            resolve: { _, _ in
                if delayFirstResolve {
                    delayFirstResolve = false
                    // Deliberately ignore cancellation, like a late network completion.
                    await withCheckedContinuation { pendingResolve = $0 }
                    didReturn = true
                }
                return preview
            }, revalidate: { _, snapshot in snapshot })])
        var edits: [ReferenceNativeEdit] = []
        hub.attachEditor(id: UUID()) { edits.append($0); return true }
        hub.setEditorActive(true)
        let source = "Before /issue after"
        let caret = NSRange(location: 13, length: 0)
        hub.receive(source: source, selection: caret, hasMarkedText: false)
        let draftID = hub.draftID
        let revision = hub.revision
        let query = hub.query
        for _ in 0..<20 where hub.results.isEmpty { try await Task.sleep(for: .milliseconds(30)) }
        hub.select(try #require(hub.results.first))
        for _ in 0..<20 where pendingResolve == nil { try await Task.sleep(for: .milliseconds(20)) }
        let completion = try #require(pendingResolve)
        defer { pendingResolve?.resume() }

        // Both local command info and non-invocable skill rows use this transition.
        hub.beginLocalInspection()
        #expect(!hub.isResolving)
        completion.resume()
        pendingResolve = nil
        for _ in 0..<20 where !didReturn { try await Task.sleep(for: .milliseconds(20)) }
        #expect(didReturn)
        #expect(edits.isEmpty)
        #expect(hub.preview == nil)
        #expect(hub.isPresented)
        #expect(hub.isEditorActive)
        #expect(hub.source == source)
        #expect(hub.selection == caret)
        #expect(hub.owner == owner)
        #expect(hub.draftID == draftID)
        #expect(hub.revision == revision)
        #expect(hub.query == query)
        #expect(hub.selected.isEmpty)
        #expect(hub.frozenSubmission == nil)
        #expect(!hub.isPreparingSend)
        #expect(hub.results == [result])

        // Returning to provider inspection still works and never quick-inserts.
        hub.inspect(result)
        for _ in 0..<20 where hub.isResolving { try await Task.sleep(for: .milliseconds(20)) }
        #expect(hub.preview == preview)
        #expect(edits.isEmpty)
        #expect(hub.isPresented)
        hub.beginLocalInspection()
        #expect(hub.preview == nil)
    }

    @MainActor @Test func identicalEditorPublicationsDoNotInvalidateObservedSelections() {
        let hub = ReferenceHubStore(owner: nil, providers: [])
        hub.receive(source: "/note", selection: NSRange(location: 5, length: 0), hasMarkedText: false)
        let changed = ReferenceAdapterLease()
        withObservationTracking { _ = hub.selected; _ = hub.source } onChange: { changed.invalidate() }
        hub.receive(source: "/note", selection: NSRange(location: 5, length: 0), hasMarkedText: false)
        #expect(changed.isValid)
    }
    @Test func readableTagsPreserveCanonicalLinks() throws {
        let snapshot = try ReferenceSnapshot(kind: .pullRequest,
            identity: .github(GitHubReferenceIdentity(repositoryID: "1", resourceID: "2",
                owner: "example", repository: "app", number: 143)), title: "Fix references",
            selectedContent: "Metadata", sourceRevision: "revision-a", fetchedAt: Date(timeIntervalSince1970: 1))
        #expect(snapshot.displayLabel == "PR #143: Fix references")
        #expect(snapshot.anchor.contains("https://github.com/example/app/pull/143"))
        #expect(ReferenceCodec.decode(try ReferenceCodec.encode(source: snapshot.anchor, references: [snapshot])).references == [snapshot])
    }

    @MainActor @Test func unconfiguredHubStartsEmptyWithoutLoading() {
        let hub = ReferenceHubStore(owner: nil, providers: [])
        #expect(hub.results.isEmpty)
        #expect(!hub.isLoading)
    }
    @Test func middleQueryReplacementPreservesUnicodeAndSurroundingText() throws {
        let source = "Compare café /road to the plan."
        let range = (source as NSString).range(of: "/road")
        let query = try #require(ReferenceQueryContext.parse(source: source, selection: NSRange(location: range.location + range.length, length: 0)))
        #expect(query.query == "road")
        #expect(query.range == range)
        let edit = try ReferenceEditTransaction.replacing(query, in: source, with: "[Roadmap](https://example.com/roadmap)")
        #expect(edit.source == "Compare café [Roadmap](https://example.com/roadmap) to the plan.")
        #expect(edit.selection.length == 0)
        #expect(edit.selection.location == ("Compare café [Roadmap](https://example.com/roadmap)" as NSString).length)
    }

    @Test func snapshotRoundTripPreservesLeadingBOMAndSelectedUnicodeBytes() throws {
        let content = "\u{FEFF}Leading BOM and 👩‍💻 e\u{0301}"
        let snapshot = try ReferenceSnapshot(kind: .wiki, identity: .wiki(WikiReferenceIdentity(namespace: "notes", relativePath: "index.md")), title: "Fixture", selectedContent: content, sourceRevision: "revision-a", fetchedAt: Date(timeIntervalSince1970: 1))
        let encoded = try ReferenceCodec.encode(source: "Review " + snapshot.anchor, references: [snapshot])
        let decoded = ReferenceCodec.decode(encoded)
        #expect(decoded.hasValidAppendix)
        let selected = try #require(decoded.references.first)
        #expect(Data(selected.selectedContent.utf8) == Data(content.utf8))
    }

    @Test func ordinaryDraftsPathsAndCodeNeverRequireOptionalProviders() {
        for source in ["Ordinary chat", "https://example.com/page", "/Users/example/wiki", "`/stop`", "```\n/stop\n```"] {
            #expect(ReferenceQueryContext.parse(source: source, selection: NSRange(location: (source as NSString).length, length: 0)) == nil)
        }
    }
}
