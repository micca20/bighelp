import CryptoKit
import Foundation
import Testing
@testable import Bighelp

struct BighelpLinkCryptoTests {
    @Test func authenticatedPayloadDecodeDiagnosticsExposeOnlySafeMetadata() throws {
        struct BrokenPayload: Decodable {
            let result: String
        }

        let plaintext = Data(
            #"{"type":"assistant.message","result":123,"secret":"must not log"}"#.utf8
        )
        let decodingError: DecodingError
        do {
            _ = try JSONDecoder().decode(BrokenPayload.self, from: plaintext)
            Issue.record("Expected the diagnostic fixture to fail decoding")
            return
        } catch let error as DecodingError {
            decodingError = error
        } catch {
            Issue.record("Expected a DecodingError, got \(error)")
            return
        }

        let diagnostic = BighelpLinkPayloadDecodeDiagnostic(
            plaintext: plaintext,
            error: decodingError
        )

        #expect(diagnostic.payloadType == "assistant.message")
        #expect(diagnostic.byteCount == plaintext.count)
        #expect(diagnostic.category == "typeMismatch")
        #expect(diagnostic.codingPath == ["result"])
        #expect(
            diagnostic.logDescription
                == "payload_type=assistant.message bytes=65 decoder=typeMismatch path=result"
        )
        #expect(!diagnostic.logDescription.contains("secret"))
        #expect(!diagnostic.logDescription.contains("must not log"))
        #expect(!diagnostic.logDescription.contains("123"))
    }

    @Test func accountCipherReportsAuthenticatedPayloadDecodeFailuresWithoutPayloadValues() throws {
        struct BrokenEnvelope: Encodable {
            let type: String
            let result: Int
            let secret: String
        }
        struct BrokenPayload: Decodable {
            let result: String
        }

        let cipher = try BighelpLinkAccountCipher(key: Data(repeating: 7, count: 32))
        let envelope = try cipher.seal(
            BrokenEnvelope(type: "assistant.message", result: 123, secret: "must not log")
        )
        var observed: BighelpLinkPayloadDecodeDiagnostic?

        do {
            let _: BrokenPayload = try cipher.open(envelope) { diagnostic in
                observed = diagnostic
            }
            Issue.record("Expected the authenticated payload to fail decoding")
        } catch let error as BighelpLinkCryptoError {
            #expect(error == .invalidPlaintext)
        } catch {
            Issue.record("Expected BighelpLinkCryptoError, got \(error)")
        }

        let diagnostic = try #require(observed)
        #expect(diagnostic.payloadType == "assistant.message")
        #expect(diagnostic.category == "typeMismatch")
        #expect(diagnostic.codingPath == ["result"])
        #expect(!diagnostic.logDescription.contains("secret"))
        #expect(!diagnostic.logDescription.contains("must not log"))
        #expect(!diagnostic.logDescription.contains("123"))
    }

    @Test func deviceRequestUsesTheSharedCanonicalContractAndRawP256Signature() throws {
        let privateBytes = Data(repeating: 0, count: 31) + Data([1])
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: privateBytes)
        let signer = BighelpLinkDeviceSigner(
            deviceID: "mobile_fixture",
            authorizationEpoch: 3,
            privateKey: privateKey
        )

        let signed = try signer.headers(
            method: "patch",
            path: "/v1/devices/mobile_fixture/name",
            body: #"{"expectedRevision":2}"#,
            timestamp: 1_788_000_000,
            nonce: "bm9uY2UtZml4dHVyZS12YWx1ZS0wMDAx"
        )

        #expect(signed.canonical == [
            "loopdy-link-device-v1",
            "PATCH",
            "/v1/devices/mobile_fixture/name",
            "mobile_fixture",
            "1788000000",
            "bm9uY2UtZml4dHVyZS12YWx1ZS0wMDAx",
            "3",
            BighelpLinkBase64URL.encode(Data(SHA256.hash(data: Data(#"{"expectedRevision":2}"#.utf8))))
        ].joined(separator: "\n"))
        #expect(try BighelpLinkBase64URL.decode(signed.headers["x-loopdy-signature"]!).count == 64)
        #expect(signer.publicKeySPKI.hasPrefix("MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQg"))
        #expect(
            privateKey.publicKey.isValidSignature(
                try P256.Signing.ECDSASignature(
                    rawRepresentation: BighelpLinkBase64URL.decode(
                        signed.headers["x-loopdy-signature"]!
                    )
                ),
                for: Data(signed.canonical.utf8)
            )
        )
    }

    @Test func accountCipherAndDeviceNamesRoundTripWithoutPlaintextInTheEnvelope() throws {
        let key = Data((0..<32).map(UInt8.init))
        let cipher = try BighelpLinkAccountCipher(key: key)
        let payload = BighelpLinkUserMessage(
            messageID: "message_fixture_0001",
            sessionID: "session_fixture_0001",
            agentID: "finance",
            actorID: "user_fixture",
            actorName: "Alex",
            deviceName: "Travel iPhone",
            text: "Hello from bighelp",
            sentAt: 1_788_000_000
        )

        let envelope = try cipher.seal(payload, nonce: Data(repeating: 7, count: 12))
        let opened: BighelpLinkUserMessage = try cipher.open(envelope)
        let encryptedName = try cipher.sealDeviceName(
            "Travel iPhone",
            nonce: Data(repeating: 8, count: 12)
        )

        #expect(opened == payload)
        #expect(!envelope.contains("Hello"))
        #expect(try cipher.openDeviceName(encryptedName) == "Travel iPhone")
        #expect(!encryptedName.contains("Travel"))
    }

    @Test func accountCipherAllowsLargeAvatarWorkspaceRouteButRejectsLargeGenericPayload() throws {
        struct WorkspaceEnvelope: Codable, Equatable {
            let version: Int
            let type: String
            let requestId: String
            let operation: String
            let payload: [String: BighelpJSONValue]
            let sentAt: Int
        }
        struct GenericEnvelope: Encodable {
            let type: String
            let value: String
        }

        let dataURL = "data:image/png;base64," + String(repeating: "A", count: 2_666_668)
        let request = WorkspaceEnvelope(
            version: 1,
            type: "workspace.request",
            requestId: "workspace_avatar_set_0001",
            operation: "agents.avatar.set",
            payload: [
                "agentId": .string("default"),
                "avatar": .object([
                    "mimeType": .string("image/png"),
                    "byteCount": .integer(2_000_000),
                    "sha256": .string("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"),
                    "data": .string(dataURL),
                ]),
            ],
            sentAt: 1_788_000_000
        )
        let cipher = try BighelpLinkAccountCipher(key: Data(repeating: 7, count: 32))

        let envelope = try cipher.seal(request, nonce: Data(repeating: 6, count: 12))
        let opened: WorkspaceEnvelope = try cipher.open(envelope)

        #expect(opened == request)
        #expect(envelope.utf8.count < 4_000_000)
        #expect(throws: BighelpLinkCryptoError.self) {
            try cipher.seal(GenericEnvelope(
                type: "assistant.message",
                value: String(repeating: "A", count: 200_000)
            ))
        }
    }

    @Test func passkeyPRFWrappingRecoversOneStableAccountKey() throws {
        let wrappingKey = Data((0..<32).map(UInt8.init))
        let accountKey = Data((32..<64).map(UInt8.init))

        let envelope = try BighelpLinkAccountKeyEnvelope.seal(
            accountKey: accountKey,
            wrappingKey: wrappingKey,
            nonce: Data(repeating: 9, count: 12)
        )

        #expect(!envelope.contains(BighelpLinkBase64URL.encode(accountKey)))
        #expect(
            try BighelpLinkAccountKeyEnvelope.open(
                envelope,
                wrappingKey: wrappingKey
            ) == accountKey
        )
    }

    @Test func hostGrantMatchesTheX25519HKDFAESContract() throws {
        let hostPrivate = Curve25519.KeyAgreement.PrivateKey()
        let accountKey = Data(repeating: 0xAB, count: 32)
        let envelope = try BighelpLinkHostGrant.seal(
            accountKey: accountKey,
            flowID: "flow_fixture_0123456789012345",
            deviceID: "host_fixture",
            hostAgreementPublicKey: hostPrivate.publicKey.rawRepresentation,
            ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey(),
            nonce: Data(repeating: 0x0A, count: 12)
        )

        let opened = try BighelpLinkHostGrant.open(
            envelope,
            flowID: "flow_fixture_0123456789012345",
            deviceID: "host_fixture",
            hostAgreementPrivateKey: hostPrivate
        )

        #expect(opened == accountKey)
    }

    @Test func generativeUIDecodeDiagnosticsRetainOnlySafeRoutingCoordinates() throws {
        struct BrokenPayload: Decodable {
            let card: String
        }

        let plaintext = Data(
            #"{"type":"generative.ui","sessionId":"session_diag_0001","agentId":"finance","card":123,"secret":"must not surface"}"#.utf8
        )
        let decodingError: Error
        do {
            _ = try JSONDecoder().decode(BrokenPayload.self, from: plaintext)
            Issue.record("Expected the diagnostic fixture to fail decoding")
            return
        } catch {
            decodingError = error
        }

        let diagnostic = BighelpLinkPayloadDecodeDiagnostic(
            plaintext: plaintext,
            error: decodingError
        )

        #expect(diagnostic.payloadType == "generative.ui")
        #expect(diagnostic.sessionID == "session_diag_0001")
        #expect(diagnostic.agentID == "finance")
        #expect(!diagnostic.logDescription.contains("session_diag_0001"))
        #expect(!diagnostic.logDescription.contains("must not surface"))
    }
}
