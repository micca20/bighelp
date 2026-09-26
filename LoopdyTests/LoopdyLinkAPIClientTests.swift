import CryptoKit
import Foundation
import Testing
@testable import Loopdy

@MainActor
struct LoopdyLinkAPIClientTests {
    @Test func signedDeviceListDecryptsNamesAndMarksOnlyTheLocalDeviceCurrent() async throws {
        let credentials = try Self.credentials()
        let cipher = try LoopdyLinkAccountCipher(key: credentials.accountKey)
        let localName = try cipher.sealDeviceName(
            "This iPhone",
            nonce: Data(repeating: 1, count: 12)
        )
        let hostName = try cipher.sealDeviceName(
            "Home Hermes",
            nonce: Data(repeating: 2, count: 12)
        )
        let transport = LinkHTTPTransportStub(responses: [
            .json(200, [
                "version": 1,
                "devices": [
                    Self.publicDevice(
                        id: credentials.deviceID,
                        encryptedName: localName,
                        role: "mobile",
                        kind: "phone",
                        connection: "online",
                        pushState: NSNull(),
                        pushRevision: 0
                    ),
                    Self.publicDevice(
                        id: "host_fixture",
                        encryptedName: hostName,
                        role: "host",
                        kind: "hermes_host",
                        connection: "recent",
                        pushState: NSNull(),
                        pushRevision: 0
                    ),
                ],
            ]),
        ])
        let api = LoopdyLinkAPI(
            baseURL: URL(string: "https://link.loopdy.example")!,
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_788_000_000) },
            nonce: { "bm9uY2UtZml4dHVyZS12YWx1ZS0wMDAx" }
        )

        let devices = try await api.listDevices(credentials: credentials)

        #expect(devices.map(\.name) == ["This iPhone", "Home Hermes"])
        #expect(devices.map(\.isCurrentDevice) == [true, false])
        #expect(devices[0].pushRevision == 0)
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/v1/devices")
        #expect(request.value(forHTTPHeaderField: "x-loopdy-device-id") == credentials.deviceID)
        #expect(request.value(forHTTPHeaderField: "x-loopdy-signature") != nil)
        #expect(request.value(forHTTPHeaderField: "authorization") == nil)
    }

    @Test func pairingInspectionAndApprovalBindTheGrantToTheInspectedHost() async throws {
        let credentials = try Self.credentials()
        let hostPrivate = Curve25519.KeyAgreement.PrivateKey()
        let hostSigningPublicKey = "host-signing-public-key-fixture"
        let flowID = "flow_fixture_0123456789012345"
        let commitment = LoopdyLinkPairingKeyCommitment.make(
            flowID: flowID,
            deviceID: "host_fixture",
            signingPublicKeySPKI: hostSigningPublicKey,
            agreementPublicKey: LoopdyLinkBase64URL.encode(hostPrivate.publicKey.rawRepresentation)
        ).encoded
        let encryptedHostName = try LoopdyLinkAccountCipher(key: credentials.accountKey)
            .sealDeviceName("Studio Hermes", nonce: Data(repeating: 3, count: 12))
        let transport = LinkHTTPTransportStub(responses: [
            .json(200, [
                "version": 1,
                "flowId": "flow_fixture_0123456789012345",
                "deviceId": "host_fixture",
                "signingPublicKeySPKI": hostSigningPublicKey,
                "agreementPublicKey": LoopdyLinkBase64URL.encode(
                    hostPrivate.publicKey.rawRepresentation
                ),
                "expiresAt": 1_788_000_300,
            ]),
            .json(200, [
                "version": 1,
                "state": "approved",
                "device": Self.publicDevice(
                    id: "host_fixture",
                    encryptedName: encryptedHostName,
                    role: "host",
                    kind: "hermes_host",
                    connection: "offline",
                    pushState: NSNull(),
                    pushRevision: 0
                ),
            ]),
        ])
        let api = LoopdyLinkAPI(
            baseURL: URL(string: "https://link.loopdy.example")!,
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_788_000_000) },
            nonce: { UUID().uuidString.replacingOccurrences(of: "-", with: "") }
        )
        let reference = LoopdyLinkPairingReference(
            flowID: flowID,
            code: "ABC234",
            keyCommitment: commitment
        )

        let host = try await api.approvePairing(
            reference: reference,
            hostName: "Studio Hermes",
            credentials: credentials
        )

        #expect(host.id == "host_fixture")
        #expect(host.name == "Studio Hermes")
        #expect(transport.requests.map { $0.url?.path } == [
            "/v1/pairing/challenges/inspect",
            "/v1/pairing/challenges/flow_fixture_0123456789012345/approve",
        ])
        let approvalBody = try #require(transport.requests[1].httpBody)
        let approval = try #require(
            JSONSerialization.jsonObject(with: approvalBody) as? [String: Any]
        )
        let grant = try #require(approval["grantEnvelope"] as? String)
        #expect(
            try LoopdyLinkHostGrant.open(
                grant,
                flowID: "flow_fixture_0123456789012345",
                deviceID: "host_fixture",
                hostAgreementPrivateKey: hostPrivate
            ) == credentials.accountKey
        )
    }

    @Test func pairingRefusesToReleaseTheAccountKeyWhenTheHostCommitmentDoesNotMatch() async throws {
        let credentials = try Self.credentials()
        let hostPrivate = Curve25519.KeyAgreement.PrivateKey()
        let transport = LinkHTTPTransportStub(responses: [
            .json(200, [
                "version": 1,
                "flowId": "flow_fixture_0123456789012345",
                "deviceId": "host_fixture",
                "signingPublicKeySPKI": "relay-substituted-signing-key",
                "agreementPublicKey": LoopdyLinkBase64URL.encode(
                    hostPrivate.publicKey.rawRepresentation
                ),
                "expiresAt": 1_788_000_300,
            ]),
        ])
        let api = LoopdyLinkAPI(
            baseURL: URL(string: "https://link.loopdy.example")!,
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_788_000_000) }
        )
        let hostCommitment = LoopdyLinkPairingKeyCommitment.make(
            flowID: "flow_fixture_0123456789012345",
            deviceID: "host_fixture",
            signingPublicKeySPKI: "actual-host-signing-key",
            agreementPublicKey: LoopdyLinkBase64URL.encode(hostPrivate.publicKey.rawRepresentation)
        )

        await #expect(throws: LoopdyLinkAPIError.pairingIdentityMismatch) {
            try await api.approvePairing(
                reference: .init(
                    flowID: "flow_fixture_0123456789012345",
                    code: "ABC234",
                    keyCommitment: hostCommitment.encoded
                ),
                hostName: "Studio Hermes",
                credentials: credentials
            )
        }
        #expect(transport.requests.count == 1)
    }

    @Test func runtimeCredentialsPersistOnlyInTheInjectedSecureVault() throws {
        let vault = LoopdyLinkMemoryCredentialVault()
        let credentials = try Self.credentials()

        try vault.save(credentials)

        #expect(try vault.load() == credentials)
        try vault.delete()
        #expect(try vault.load() == nil)
    }

    @Test func accountDeletionUsesOnlyTheFreshPasskeyBearerSession() async throws {
        let transport = LinkHTTPTransportStub(responses: [
            .json(200, ["version": 1, "state": "deleted"]),
        ])
        let api = LoopdyLinkAPI(
            baseURL: URL(string: "https://link.loopdy.example")!,
            transport: transport
        )

        try await api.deleteAccount(accessToken: "fresh-passkey-session-token")

        let request = try #require(transport.requests.first)
        #expect(request.url?.path == "/v1/accounts/current")
        #expect(request.httpMethod == "DELETE")
        #expect(
            request.value(forHTTPHeaderField: "authorization")
                == "Bearer fresh-passkey-session-token"
        )
        #expect(request.value(forHTTPHeaderField: "x-loopdy-device-id") == nil)
    }

    @Test func accountProfileAvatarUsesSignedAccountStorageWithoutBearerSession() async throws {
        let credentials = try Self.credentials()
        let encryptedDisplayName = try LoopdyLinkAccountCipher(key: credentials.accountKey)
            .sealDeviceName("Maya", nonce: Data(repeating: 0x7A, count: 12))
        let avatar = UserProfileAvatar(
            mimeType: "image/png",
            byteCount: 8,
            sha256: "sha256-user-avatar-0001",
            encryptedData: "encrypted-user-avatar-0001"
        )
        let transport = LinkHTTPTransportStub(responses: [
            .json(200, [
                "version": 1,
                "profile": [
                    "revision": 1,
                    "encryptedDisplayName": encryptedDisplayName,
                    "avatar": [
                        "mimeType": avatar.mimeType,
                        "byteCount": avatar.byteCount,
                        "sha256": avatar.sha256,
                        "encryptedData": avatar.encryptedData,
                    ],
                    "updatedAt": 1_788_000_001,
                ],
            ]),
            .json(200, [
                "version": 1,
                "profile": [
                    "revision": 1,
                    "encryptedDisplayName": encryptedDisplayName,
                    "avatar": [
                        "mimeType": avatar.mimeType,
                        "byteCount": avatar.byteCount,
                        "sha256": avatar.sha256,
                        "encryptedData": avatar.encryptedData,
                    ],
                    "updatedAt": 1_788_000_001,
                ],
            ]),
        ])
        let api = LoopdyLinkAPI(
            baseURL: URL(string: "https://link.loopdy.example")!,
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_788_000_001) },
            nonce: { "bm9uY2UtZml4dHVyZS12YWx1ZS0wMDAx" }
        )

        let saved = try await api.saveAccountProfile(
            displayName: "Maya",
            avatar: avatar,
            expectedRevision: 0,
            credentials: credentials
        )
        let loaded = try await api.loadAccountProfile(credentials: credentials)

        #expect(saved.avatar == avatar)
        #expect(loaded?.avatar == avatar)
        #expect(transport.requests.map(\.url?.path) == ["/v1/accounts/profile", "/v1/accounts/profile"])
        #expect(transport.requests.map(\.httpMethod) == ["PUT", "GET"])
        #expect(transport.requests[0].value(forHTTPHeaderField: "authorization") == nil)
        let bodyData = try #require(transport.requests[0].httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["expectedRevision"] as? Int == 0)
        #expect(body["encryptedDisplayName"] is String)
        let bodyAvatar = try #require(body["avatar"] as? [String: Any])
        #expect(bodyAvatar["mimeType"] as? String == avatar.mimeType)
        #expect(bodyAvatar["byteCount"] as? Int == avatar.byteCount)
        #expect(bodyAvatar["sha256"] as? String == avatar.sha256)
        #expect(bodyAvatar["encryptedData"] as? String == avatar.encryptedData)
        #expect(bodyAvatar.keys.sorted() == [
            "byteCount",
            "encryptedData",
            "mimeType",
            "sha256",
        ])
    }

    @Test func watchEnrollmentRegistersTheWatchCreatedSigningKey() async throws {
        let accountKey = Data(repeating: 0xCD, count: 32)
        let watchKey = P256.Signing.PrivateKey()
        let watchID = "watch_device_fixture_0001"
        let signer = LoopdyLinkDeviceSigner(
            deviceID: watchID,
            authorizationEpoch: 1,
            privateKey: watchKey
        )
        let encryptedName = try LoopdyLinkAccountCipher(key: accountKey)
            .sealDeviceName("Sam’s Apple Watch", nonce: Data(repeating: 4, count: 12))
        let transport = LinkHTTPTransportStub(responses: [
            .json(201, [
                "version": 1,
                "device": Self.publicDevice(
                    id: watchID,
                    encryptedName: encryptedName,
                    role: "mobile",
                    kind: "computer",
                    connection: "offline",
                    pushState: NSNull(),
                    pushRevision: 0
                ),
            ]),
        ])
        let api = LoopdyLinkAPI(
            baseURL: URL(string: "https://link.loopdy.example")!,
            transport: transport
        )

        let device = try await api.registerExternalDevice(
            accessToken: "fresh-passkey-session",
            deviceID: watchID,
            publicKeySPKI: signer.publicKeySPKI,
            accountKey: accountKey,
            name: "Sam’s Apple Watch",
            kind: .computer
        )

        #expect(device.id == watchID)
        #expect(device.isCurrentDevice)
        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer fresh-passkey-session")
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["deviceId"] as? String == watchID)
        #expect(body["publicKeySPKI"] as? String == signer.publicKeySPKI)
        #expect(body["role"] as? String == "mobile")
        #expect(body["kind"] as? String == "computer")
    }

    @Test func managedNotificationRequestRetainsBoundedServerErrorCode() async throws {
        let transport = LinkHTTPTransportStub(responses: [
            .json(404, [
                "version": 1,
                "error": "not_found",
                "message": "Loopdy Link route was not found; this text must not escape the client",
            ]),
        ])
        let api = LoopdyLinkAPI(
            baseURL: URL(string: "https://link.loopdy.app")!,
            managedNotificationTransport: transport
        )

        do {
            _ = try await api.managedNotificationRequest(
                path: "/v1/notifications/host-grants",
                method: "POST",
                body: nil,
                credentials: try Self.credentials()
            )
            Issue.record("Expected the non-success response to throw")
        } catch let error as LoopdyLinkAPIError {
            #expect(error == .requestFailed(status: 404, code: "not_found"))
        }
    }

    private static func credentials() throws -> LoopdyLinkRuntimeCredentials {
        LoopdyLinkRuntimeCredentials(
            deviceID: "mobile_fixture",
            authorizationEpoch: 1,
            signingPrivateKey: try P256.Signing.PrivateKey(
                rawRepresentation: Data(repeating: 0, count: 31) + Data([1])
            ),
            accountKey: Data(repeating: 0xCD, count: 32)
        )
    }

    private static func publicDevice(
        id: String,
        encryptedName: String,
        role: String,
        kind: String,
        connection: String,
        pushState: Any,
        pushRevision: Int
    ) -> [String: Any] {
        [
            "deviceId": id,
            "encryptedName": encryptedName,
            "role": role,
            "kind": kind,
            "lifecycle": "active",
            "revision": 1,
            "authorizationEpoch": 1,
            "connection": connection,
            "pushState": pushState,
            "pushRevision": pushRevision,
            "createdAt": 1_788_000_000,
            "revokedAt": NSNull(),
            "lastSeenBucket": 1_788_000_000,
        ]
    }
}

@MainActor
private final class LinkHTTPTransportStub: LoopdyLinkHTTPTransport {
    struct Response {
        let status: Int
        let data: Data

        static func json(_ status: Int, _ object: Any) -> Response {
            Response(
                status: status,
                data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            )
        }
    }

    private var responses: [Response]
    private(set) var requests: [URLRequest] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = responses.removeFirst()
        return (
            response.data,
            HTTPURLResponse(
                url: request.url!,
                statusCode: response.status,
                httpVersion: "HTTP/2",
                headerFields: ["content-type": "application/json"]
            )!
        )
    }
}
