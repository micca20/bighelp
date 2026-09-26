import Foundation
import Testing
@testable import Bighelp

@MainActor
struct PluginUpdateStoreTests {
    @Test func lostAcknowledgementResumesSameOperationWithoutAnotherStart() async throws {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let client = PluginUpdateFixture()
        client.startError = URLError(.networkConnectionLost)
        let first = PluginUpdateStore(scope: "device:host", client: client, defaults: defaults, operationID: { "update_0123456789abcdef" })
        await first.start()
        #expect(first.pendingOperationID == "update_0123456789abcdef")
        #expect(client.starts == ["update_0123456789abcdef"])
        client.result = .init(operationID: "update_0123456789abcdef", phase: .complete, targetRevision: String(repeating: "a", count: 40), activeRevision: String(repeating: "a", count: 40), runtimeID: "fresh_runtime", message: "Complete")
        let reopened = PluginUpdateStore(scope: "device:host", client: client, defaults: defaults)
        await reopened.refreshStatus()
        #expect(reopened.status?.phase == .complete)
        #expect(reopened.pendingOperationID == nil)
        #expect(client.starts.count == 1)
    }

    @Test func wrongRevisionCannotComplete() async {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let client = PluginUpdateFixture()
        let store = PluginUpdateStore(scope: "device:host", client: client, defaults: defaults, operationID: { "update_0123456789abcdef" })
        await store.start()
        client.result = .init(operationID: "update_0123456789abcdef", phase: .complete, targetRevision: String(repeating: "a", count: 40), activeRevision: String(repeating: "b", count: 40), runtimeID: "fresh_runtime", message: "Complete")
        await store.refreshStatus()
        #expect(store.status?.phase != .complete)
        #expect(store.pendingOperationID != nil)
    }

    @Test func staleHostCannotStartOrAcceptStatus() async {
        let client = PluginUpdateFixture()
        let store = PluginUpdateStore(scope: "old-host", client: client, defaults: UserDefaults(suiteName: UUID().uuidString)!, isCurrent: { false })
        await store.start()
        await store.refreshStatus()
        #expect(client.starts.isEmpty)
        #expect(client.statusReads == 0)
        #expect(store.status == nil)
    }
}

@MainActor
private final class PluginUpdateFixture: PluginUpdateClient {
    var starts: [String] = []
    var statusReads = 0
    var startError: (any Error)?
    var result = PluginUpdateStatus(operationID: "update_0123456789abcdef", phase: .accepted, targetRevision: nil, activeRevision: nil, runtimeID: nil, message: "Updating")

    func start(operationID: String) async throws -> PluginUpdateStatus {
        starts.append(operationID)
        if let startError { throw startError }
        return result
    }
    func status(operationID: String?) async throws -> PluginUpdateStatus {
        statusReads += 1
        return result
    }
}
