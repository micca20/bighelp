import Foundation
import Testing
@testable import Loopdy

#if DEBUG && targetEnvironment(simulator)
@MainActor
struct WikiHomeTests {
    @Test func blockedIndexOpensReadableReadmeOnFirstSelection() async throws {
        let host = WikiHomeFixtureMessaging()
        let store = host.makeStore()
        try await store.discoverRoots()
        try await store.home(#require(store.connections.first))
        #expect(store.document?.path == "README.md")
        #expect(store.document?.originalSource == "# Welcome to your Wiki\nReadable home page.\n")
        #expect(host.reads == ["index.md", "README.md"])
        #expect(host.listings.isEmpty)
        #expect(!store.isLoading)
    }

    @Test(arguments: ["PATH_NOT_FOUND", "SECRET_SCAN_BLOCKED"])
    func unusableHomeCandidatesOpenRoot(code: String) async throws {
        let host = WikiHomeFixtureMessaging()
        host.failures["README.md"] = code
        let store = host.makeStore()
        try await store.discoverRoots()
        try await store.home(#require(store.connections.first))
        #expect(store.document == nil)
        #expect(store.directory?.path == "")
        #expect(store.entries.map(\.path) == ["notes.md"])
        #expect(host.listings == [""])
        #expect(!store.isLoading)
    }

    @Test func healthyIndexRemainsPreferred() async throws {
        let host = WikiHomeFixtureMessaging()
        host.failures = [:]
        let store = host.makeStore()
        try await store.discoverRoots()
        try await store.home(#require(store.connections.first))
        #expect(store.document?.path == "index.md")
        #expect(host.reads == ["index.md"])
        #expect(host.listings.isEmpty)
    }

    @Test func directBlockedFileRemainsRefusedWithAccurateMessage() async throws {
        let host = WikiHomeFixtureMessaging()
        let store = host.makeStore()
        try await store.discoverRoots()
        do {
            try await store.open(#require(store.connections.first), path: "index.md")
            Issue.record("Direct blocked content must remain refused")
        } catch {
            #expect(WikiError.safe(error) == .remote("SECRET_SCAN_BLOCKED"))
            #expect(error.localizedDescription == "The host blocked this file because it may contain credentials. Review it on your host before opening it here.")
        }
        #expect(store.document == nil)
        #expect(host.reads == ["index.md"])
        #expect(host.listings.isEmpty)
    }

    @Test(arguments: ["WIKI_NOT_ALLOWED", "WIKI_UNAVAILABLE", "STATE_UNAVAILABLE", "REVISION_STALE"])
    func nonCandidateFailuresDoNotFallback(code: String) async throws {
        let host = WikiHomeFixtureMessaging()
        host.failures["index.md"] = code
        let store = host.makeStore()
        try await store.discoverRoots()
        do {
            try await store.home(#require(store.connections.first))
            Issue.record("Authorization and operational failures must propagate")
        } catch { #expect(WikiError.safe(error) == .remote(code)) }
        #expect(host.reads == ["index.md"])
        #expect(host.listings.isEmpty)
    }

    @Test(arguments: ["PATH_NOT_FOUND", "SECRET_SCAN_BLOCKED"])
    func lateHomeFailureCannotReplaceNewerNavigation(code: String) async throws {
        let host = WikiHomeFixtureMessaging()
        host.failures["index.md"] = code
        let store = host.makeStore()
        try await store.discoverRoots()
        let connection = try #require(store.connections.first)
        var held: CheckedContinuation<Void, Never>?
        host.beforeReadResult = { _ in await withCheckedContinuation { held = $0 } }
        let home = Task { try await store.home(connection) }
        for _ in 0..<1_000 where held == nil { await Task.yield() }
        let continuation = try #require(held)
        try await store.browse(connection, path: "nested")
        host.beforeReadResult = nil
        continuation.resume()
        do { try await home.value; Issue.record("Superseded home must not continue") }
        catch is CancellationError { }
        catch { Issue.record("Expected navigation cancellation, got \(error)") }
        #expect(store.directory?.path == "nested")
        #expect(store.document == nil)
        #expect(host.reads == ["index.md"])
        #expect(host.listings == ["nested"])
    }

    @Test(arguments: [false, true])
    func cancelledOrRetiredHomeCannotFallback(retireOwner: Bool) async throws {
        let host = WikiHomeFixtureMessaging()
        let store = host.makeStore()
        try await store.discoverRoots()
        let connection = try #require(store.connections.first)
        var held: CheckedContinuation<Void, Never>?
        host.beforeReadResult = { _ in await withCheckedContinuation { held = $0 } }
        let home = Task { try await store.home(connection) }
        for _ in 0..<1_000 where held == nil { await Task.yield() }
        let continuation = try #require(held)
        if retireOwner { store.setContext(owner: nil, client: nil) } else { home.cancel() }
        host.beforeReadResult = nil
        continuation.resume()
        do { try await home.value; Issue.record("Cancelled home must not succeed") }
        catch { }
        #expect(host.reads == ["index.md"])
        #expect(host.listings.isEmpty)
        #expect(store.document == nil)
        #expect(!store.isLoading)
    }
}
#endif
