import CryptoKit
import Foundation
import Testing
@testable import Loopdy

@MainActor
struct ManagedNotificationLedgerMigrationTests {
    @Test(arguments: [false, true])
    func retiredRelayGrantLoadsWithoutNewAuthorityOrLostHistory(pendingRevocation: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "owners-v1.json")
        let original = try legacySnapshot(pendingRevocation: pendingRevocation)
        try original.write(to: file)
        let ledger = try LoopdyManagedNotificationLedger(root: root)
        #expect(ledger.enrollments.isEmpty)
        #expect(ledger.retiredRelayEnrollmentCount == 1)
        #expect(try Data(contentsOf: file) == original, "Loading never overwrites the old provider record")

        let fresh = LoopdyManagedEnrollmentRecord(
            accountScope: "fixture-scope", accountID: "fixture-account", hostConnectionID: "fixture-host",
            profile: "default", creationBody: nil, enrollmentID: UUID().uuidString.lowercased(),
            grant: nil, richLiveActivitySupported: false, enabled: false, revokePending: false, subscriptions: []
        )
        try ledger.save(fresh)
        let stored = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let encodedBackup = try #require(stored["retiredRelaySnapshot"] as? String)
        #expect(Data(base64Encoded: encodedBackup) == original,
                "Original grant and pending-revocation bytes survive fresh enrollment")
        let reopened = try LoopdyManagedNotificationLedger(root: root)
        #expect(reopened.enrollments == [fresh])
        #expect(!reopened.enrollments[0].enabled)
        #expect(reopened.enrollments[0].grant == nil)
    }

    @Test func unknownGrantShapeStillFailsClosedWithoutWriting() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "owners-v1.json")
        let original = try legacySnapshot(omitRecipientKey: true)
        try original.write(to: file)
        #expect(throws: (any Error).self) { try LoopdyManagedNotificationLedger(root: root) }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func migratedLegacyTombstoneRemainsStoredButCannotBeAnActiveEnrollment() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "owners-v1.json")
        let original = try legacySnapshot(pendingRevocation: true)
        try original.write(to: file)
        let ledger = try LoopdyManagedNotificationLedger(root: root)
        let other = LoopdyManagedEnrollmentRecord(
            accountScope: "other-scope", accountID: "other-account", hostConnectionID: "other-host",
            profile: "default", creationBody: nil, enrollmentID: UUID().uuidString.lowercased(),
            grant: nil, richLiveActivitySupported: false, enabled: false, revokePending: false, subscriptions: []
        )
        try ledger.save(other)
        let reopened = try LoopdyManagedNotificationLedger(root: root)
        #expect(reopened.retiredRelayEnrollmentCount == 1)
        #expect(reopened.enrollments == [other])
    }

    private func legacySnapshot(pendingRevocation: Bool = false, omitRecipientKey: Bool = false) throws -> Data {
        let publicKey = P256.Signing.PrivateKey().publicKey.x963Representation
        let encodedKey = LoopdyNotificationBase64URL.encode(publicKey)
        let keyID = LoopdyNotificationBase64URL.encode(Data(SHA256.hash(data: publicKey)))
        var grant: [String: Any] = [
            "grantId": UUID().uuidString.lowercased(), "hostPublicKey": encodedKey, "hostKeyId": keyID,
            "recipientPublicKey": encodedKey, "recipientKeyId": keyID, "recipientRevision": 1,
            "deviceId": "fixture-device", "tenantId": "fixture-tenant", "profile": "default",
            "createdAt": 1_800_000_000, "expiresAt": 1_800_010_000, "revision": 1,
            "authorizationEpoch": 1, "state": "active",
            "eventTypes": ["approval.required", "session.completed", "session.failed"]
        ]
        if omitRecipientKey { grant.removeValue(forKey: "recipientPublicKey") }
        var record: [String: Any] = [
            "accountScope": "fixture-scope", "accountID": "fixture-account", "hostConnectionID": "fixture-host",
            "profile": "default", "enrollmentID": UUID().uuidString.lowercased(), "grant": grant,
            "richLiveActivitySupported": true, "enabled": true, "revokePending": pendingRevocation,
            "subscriptions": ["fixture-session"]
        ]
        if pendingRevocation { record["creationBody"] = Data("original legacy intent".utf8).base64EncodedString() }
        let key = LoopdyManagedNotificationLedger.key(scope: "fixture-scope", host: "fixture-host", profile: "default")
        return try JSONSerialization.data(withJSONObject: ["version": 1, "activities": [:], "enrollments": [key: record]], options: [.prettyPrinted, .sortedKeys])
    }
}
