import Foundation
import Testing
@testable import Bighelp

@MainActor
struct HostRuntimeStoreTests {
    @Test func validatesKnownRestartEvidenceAndPreservesUnknownHermesState() throws {
        let value = try HostRuntimeStatus.decode(payload())
        #expect(value.plugin.restartState == .required)
        #expect(value.hermes.runningVersion == nil)
        #expect(value.hermes.updateState == .unknown)
        #expect(value.hermes.restartState == .unknown)
        #expect(value.hermes.cliVersion == "0.21.0")
    }

    @Test func rejectsMissingFieldsAndContradictoryCompatibility() throws {
        var missing = payload()
        missing.removeValue(forKey: "hermes")
        #expect(throws: (any Error).self) { try HostRuntimeStatus.decode(missing) }
        var contradictory = payload()
        contradictory["compatibility"] = .object([
            "state": .string("compatible"), "checkedOperations": .array([.string("agents.list")]),
            "unavailableOperations": .array([.string("agents.list")]), "issues": .array([])
        ])
        #expect(throws: (any Error).self) { try HostRuntimeStatus.decode(contradictory) }
    }

    @Test func unsupportedDiagnosticsDoesNotMeanOutdatedGateway() async {
        let client = ControlledHostRuntimeClient()
        client.failure = HostRuntimeClientError.unsupported
        let store = HostRuntimeStore(scope: "host-a", client: client)
        await store.refresh()
        #expect(store.availability == .unsupported)
        #expect(store.status == nil)
        #expect(!store.isChecking)
    }

    @Test func lostRefreshRetainsEvidenceButMarksItUnverified() async throws {
        let client = ControlledHostRuntimeClient()
        client.value = try HostRuntimeStatus.decode(payload())
        let store = HostRuntimeStore(scope: "host-a", client: client)
        await store.refresh()
        let previous = store.status
        client.failure = HostRuntimeClientError.invalidResponse
        await store.refresh()
        #expect(store.status == previous)
        #expect(store.availability == .unavailable)
    }

    @Test func oldHostCompletionCannotPublishIntoNewScope() async throws {
        let client = ControlledHostRuntimeClient()
        client.value = try HostRuntimeStatus.decode(payload())
        client.suspend = true
        let ownership = HostRuntimeOwnershipFixture()
        let store = HostRuntimeStore(scope: "host-a", client: client, isCurrent: { ownership.isCurrent })
        let task = Task { await store.refresh() }
        while client.continuation == nil { await Task.yield() }
        ownership.isCurrent = false
        store.invalidate()
        client.continuation?.resume()
        await task.value
        #expect(store.status == nil)
        #expect(store.checkedAt == nil)
        #expect(!store.isChecking)
    }

    @Test func concurrentRefreshesDoNotDuplicateRequests() async throws {
        let client = ControlledHostRuntimeClient()
        client.value = try HostRuntimeStatus.decode(payload())
        client.suspend = true
        let store = HostRuntimeStore(scope: "host-a", client: client)
        let task = Task { await store.refresh() }
        while client.continuation == nil { await Task.yield() }
        await store.refresh()
        #expect(client.calls == 1)
        client.continuation?.resume()
        await task.value
        #expect(store.availability == .supported)
    }

    private func payload() -> [String: BighelpJSONValue] {
        [
            "schemaVersion": .integer(1), "runtimeId": .string("runtime_fixture"), "observedAt": .integer(1788000000),
            "hermes": .object([
                "runningVersion": .null, "cliVersion": .string("0.21.0"), "updateState": .string("unknown"),
                "updateCheckedAt": .null, "restartState": .string("unknown")
            ]),
            "plugin": .object([
                "runningVersion": .string("2.8.0"), "installedRevision": .string(String(repeating: "a", count: 40)),
                "activeRevision": .string(String(repeating: "b", count: 40)), "restartState": .string("required")
            ]),
            "compatibility": .object([
                "state": .string("unknown"), "checkedOperations": .array([]),
                "unavailableOperations": .array([]), "issues": .array([])
            ])
        ]
    }
}

@MainActor
private final class HostRuntimeOwnershipFixture {
    var isCurrent = true
}

@MainActor
private final class ControlledHostRuntimeClient: HostRuntimeClient {
    var value: HostRuntimeStatus?
    var failure: (any Error)?
    var suspend = false
    var continuation: CheckedContinuation<Void, Never>?
    var calls = 0
    func status() async throws -> HostRuntimeStatus {
        calls += 1
        if suspend { await withCheckedContinuation { continuation = $0 } }
        if let failure { throw failure }
        guard let value else { throw HostRuntimeClientError.invalidResponse }
        return value
    }
}
