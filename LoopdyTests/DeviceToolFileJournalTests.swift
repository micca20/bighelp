import Foundation
import Testing
@testable import Loopdy

@MainActor
struct DeviceToolFileJournalTests {
    @Test func pendingMutationSurvivesProcessRecreationAndIsScoped() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "journal.json")
        let owner = DeviceToolScope(deviceID: "phone", authorizationEpoch: 1, hostID: "host")
        let record = DeviceToolJournalEntry(fingerprint: "request-digest", expiresAt: 1120, result: nil)
        try DeviceToolFileJournal(url: url, clock: { 1000 }).save(record, requestID: "request", scope: owner)
        let reloaded = DeviceToolFileJournal(url: url, clock: { 1000 })
        #expect(try reloaded.entry(requestID: "request", scope: owner) == record)
        let other = DeviceToolScope(deviceID: "phone", authorizationEpoch: 2, hostID: "host")
        #expect(try reloaded.entry(requestID: "request", scope: other) == nil)
    }

    @Test func corruptJournalFailsClosedBeforeNewMutation() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("invalid".utf8).write(to: url)
        let journal = DeviceToolFileJournal(url: url)
        let owner = DeviceToolScope(deviceID: "phone", authorizationEpoch: 1, hostID: "host")
        #expect(throws: (any Error).self) { try journal.entry(requestID: "request", scope: owner) }
    }
}
