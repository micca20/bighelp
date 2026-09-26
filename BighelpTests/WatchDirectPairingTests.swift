import CryptoKit
import Foundation
import Testing
@testable import Bighelp

@MainActor
struct WatchDirectPairingTests {
    @Test func watchCreatesItsOwnIdentityAndOpensOnlyItsBoundGrant() throws {
        let signingKey = P256.Signing.PrivateKey()
        let agreementKey = Curve25519.KeyAgreement.PrivateKey()
        let request = try WatchBighelpEnrollmentRequest(
            requestID: "watch-enrollment-request-0001",
            deviceID: "watch_device_fixture_0001",
            publicKeySPKI: BighelpLinkDeviceSigner(
                deviceID: "watch_device_fixture_0001",
                authorizationEpoch: 1,
                privateKey: signingKey
            ).publicKeySPKI,
            agreementPublicKey: BighelpLinkBase64URL.encode(
                agreementKey.publicKey.rawRepresentation
            ),
            deviceName: "Sam’s Apple Watch"
        )
        let pending = try WatchPendingEnrollmentRecord(
            request: request,
            signingPrivateKey: signingKey.rawRepresentation,
            agreementPrivateKey: agreementKey.rawRepresentation
        )
        let restored = try JSONDecoder().decode(
            WatchPendingEnrollmentRecord.self,
            from: JSONEncoder().encode(pending)
        )
        var tamperedObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(pending)) as? [String: Any]
        )
        tamperedObject["signingPrivateKey"] = BighelpLinkBase64URL.encode(
            P256.Signing.PrivateKey().rawRepresentation
        )
        let tamperedData = try JSONSerialization.data(withJSONObject: tamperedObject)
        #expect(throws: WatchCompanionValidationError.self) {
            _ = try JSONDecoder().decode(WatchPendingEnrollmentRecord.self, from: tamperedData)
        }
        var invalidRequestObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(pending)) as? [String: Any]
        )
        var invalidRequest = try #require(invalidRequestObject["request"] as? [String: Any])
        invalidRequest["requestID"] = "invalid request id with spaces"
        invalidRequestObject["request"] = invalidRequest
        let invalidRequestData = try JSONSerialization.data(withJSONObject: invalidRequestObject)
        #expect(throws: WatchCompanionValidationError.self) {
            _ = try JSONDecoder().decode(
                WatchPendingEnrollmentRecord.self,
                from: invalidRequestData
            )
        }
        let accountKey = Data(repeating: 0xAB, count: 32)
        let envelope = try BighelpLinkHostGrant.seal(
            accountKey: accountKey,
            flowID: request.requestID,
            deviceID: request.deviceID,
            hostAgreementPublicKey: agreementKey.publicKey.rawRepresentation
        )
        let grant = try WatchBighelpEnrollmentGrant(
            requestID: request.requestID,
            deviceID: request.deviceID,
            baseURL: "https://link.loopdy.example",
            authorizationEpoch: 7,
            grantEnvelope: envelope
        )

        let credentials = try restored.openCredentials(from: grant)

        #expect(restored.request == request)
        #expect(credentials.deviceID == request.deviceID)
        #expect(credentials.authorizationEpoch == 7)
        #expect(credentials.signingPrivateKey.rawRepresentation == signingKey.rawRepresentation)
        #expect(credentials.accountKey == accountKey)
        #expect(request.usesDurableGrantDelivery)

        var legacyRequestObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        legacyRequestObject.removeValue(forKey: "deliveryVersion")
        let legacyRequest = try JSONDecoder().decode(
            WatchBighelpEnrollmentRequest.self,
            from: JSONSerialization.data(withJSONObject: legacyRequestObject)
        )
        #expect(legacyRequest.deliveryVersion == 1)
        #expect(!legacyRequest.usesDurableGrantDelivery)
        let legacyCommand = WatchCompanionCommand.enrollDirectClient(legacyRequest)
        #expect(
            try WatchCompanionCodec.decodeCommand(
                WatchCompanionCodec.encodeCommand(legacyCommand)
            ) == legacyCommand
        )
    }

    @Test func enrollmentRejectsMismatchedDeviceIdentity() throws {
        let signingKey = P256.Signing.PrivateKey()
        let agreementKey = Curve25519.KeyAgreement.PrivateKey()
        let envelope = try BighelpLinkHostGrant.seal(
            accountKey: Data(repeating: 0xAB, count: 32),
            flowID: "watch-enrollment-request-0001",
            deviceID: "different_watch_device_0001",
            hostAgreementPublicKey: agreementKey.publicKey.rawRepresentation
        )
        let grant = try WatchBighelpEnrollmentGrant(
            requestID: "watch-enrollment-request-0001",
            deviceID: "watch_device_fixture_0001",
            baseURL: "https://link.loopdy.example",
            authorizationEpoch: 7,
            grantEnvelope: envelope
        )

        #expect(throws: Error.self) {
            _ = try grant.openCredentials(
                signingPrivateKey: signingKey,
                agreementPrivateKey: agreementKey
            )
        }
    }


    @Test func watchWireUsesTheCanonicalUserAndVoiceRequestShapes() throws {
        let watchUser = WatchLinkUserMessage(
            messageID: "watch-message-00000001",
            sessionID: "link-session-00000001",
            agentID: "agent-1",
            turnID: "watch-turn-00000001",
            actorID: "watch-user",
            actorName: "You",
            deviceName: "Apple Watch",
            text: "Hello",
            sentAt: 1_788_448_000
        )
        let canonicalUser = BighelpLinkUserMessage(
            messageID: "watch-message-00000001",
            sessionID: "link-session-00000001",
            agentID: "agent-1",
            turnID: "watch-turn-00000001",
            actorID: "watch-user",
            actorName: "You",
            deviceName: "Apple Watch",
            text: "Hello",
            sentAt: 1_788_448_000
        )
        #expect(try jsonObject(watchUser) == jsonObject(canonicalUser))

        let watchVoice = WatchLinkVoiceRequest(
            requestID: "watch-voice-00000001",
            sessionID: "link-session-00000001",
            agentID: "agent-1",
            text: "Hello",
            sentAt: 1_788_448_000
        )
        let canonicalVoice = BighelpLinkVoiceSpeakRequest(
            requestID: "watch-voice-00000001",
            sessionID: "link-session-00000001",
            agentID: "agent-1",
            text: "Hello",
            speed: 1,
            sentAt: 1_788_448_000
        )
        #expect(try jsonObject(watchVoice) == jsonObject(canonicalVoice))

        let acknowledgement = WatchCompanionReply.enrollmentAccepted(
            requestID: "watch-enrollment-request-0001"
        )
        #expect(
            try WatchCompanionCodec.decodeReply(
                WatchCompanionCodec.encodeReply(acknowledgement)
            ) == acknowledgement
        )
        let receipt = WatchCompanionCommand.directEnrollmentReceived(
            requestID: "watch-enrollment-request-0001"
        )
        #expect(
            try WatchCompanionCodec.decodeCommand(
                WatchCompanionCodec.encodeCommand(receipt)
            ) == receipt
        )

        var delivery = WatchEnrollmentDeliveryLedger()
        let firstAuthorization = delivery.beginAuthorization(
            requestID: "watch-enrollment-request-0001"
        )
        let duplicateAuthorization = delivery.beginAuthorization(
            requestID: "watch-enrollment-request-0001"
        )
        #expect(firstAuthorization)
        #expect(!duplicateAuthorization)
        delivery.stage(
            acknowledgement,
            requestID: "watch-enrollment-request-0001"
        )
        let inactiveTransfer = delivery.beginTransfer(
            requestID: "watch-enrollment-request-0001",
            sessionIsActivated: false
        )
        #expect(inactiveTransfer == nil)
        let activeTransferValue = delivery.beginTransfer(
            requestID: "watch-enrollment-request-0001",
            sessionIsActivated: true
        )
        let activeTransfer = try #require(activeTransferValue)
        #expect(activeTransfer.reply == acknowledgement)
        delivery.finishTransfer(
            activeTransfer,
            succeeded: false
        )
        let retryTransferValue = delivery.beginTransfer(
            requestID: "watch-enrollment-request-0001",
            sessionIsActivated: true
        )
        let retryTransfer = try #require(retryTransferValue)
        #expect(retryTransfer.reply == acknowledgement)
        let invalidated = delivery.reset()
        #expect(invalidated == ["watch-enrollment-request-0001"])

        let restartedAuthorization = delivery.beginAuthorization(
            requestID: "watch-enrollment-request-0001"
        )
        #expect(restartedAuthorization)
        delivery.stage(acknowledgement, requestID: "watch-enrollment-request-0001")
        let restartedTransferValue = delivery.beginTransfer(
            requestID: "watch-enrollment-request-0001",
            sessionIsActivated: true
        )
        let restartedTransfer = try #require(restartedTransferValue)
        delivery.finishTransfer(retryTransfer, succeeded: true)
        delivery.finishTransfer(restartedTransfer, succeeded: false)
        let retryAfterStaleCallback = delivery.beginTransfer(
            requestID: "watch-enrollment-request-0001",
            sessionIsActivated: true
        )
        #expect(retryAfterStaleCallback?.reply == acknowledgement)
        _ = delivery.reset()

        let completedRequestID = "watch-enrollment-request-complete-0001"
        let beganCompletedAuthorization = delivery.beginAuthorization(
            requestID: completedRequestID
        )
        #expect(beganCompletedAuthorization)
        delivery.stage(acknowledgement, requestID: completedRequestID)
        let completedTransferValue = delivery.beginTransfer(
            requestID: completedRequestID,
            sessionIsActivated: true
        )
        let completedTransfer = try #require(completedTransferValue)
        delivery.finishTransfer(completedTransfer, succeeded: true)
        #expect(delivery.beginAuthorization(requestID: completedRequestID) == false)
        #expect(delivery.beginTransfer(
            requestID: completedRequestID,
            sessionIsActivated: true
        ) != nil)
        let firstAcknowledgement = delivery.acknowledge(requestID: completedRequestID)
        #expect(firstAcknowledgement)
        let duplicateAfterAcknowledgement = delivery.beginAuthorization(requestID: completedRequestID)
        #expect(!duplicateAfterAcknowledgement)
        let repeatedAcknowledgement = delivery.acknowledge(requestID: completedRequestID)
        #expect(repeatedAcknowledgement)
    }

    @Test func pendingWatchFrameIsResentOnlyUntilTheServerAcceptsItsSequence() throws {
        #expect(try WatchPendingFrameReconciliation.disposition(
            pendingSequence: 8,
            pendingFrameID: "watch-frame-accepted-0001",
            serverSequence: 7,
            serverFrameID: nil
        ) == .send)
        #expect(try WatchPendingFrameReconciliation.disposition(
            pendingSequence: 8,
            pendingFrameID: "watch-frame-accepted-0001",
            serverSequence: 8,
            serverFrameID: "watch-frame-accepted-0001"
        ) == .accepted)
        #expect(throws: WatchCompanionValidationError.self) {
            try WatchPendingFrameReconciliation.disposition(
                pendingSequence: 8,
                pendingFrameID: "watch-frame-accepted-0001",
                serverSequence: 8,
                serverFrameID: "different-frame-0001"
            )
        }
    }

    private func jsonObject<Value: Encodable>(_ value: Value) throws -> NSDictionary {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }
}
