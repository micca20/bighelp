import Foundation
import Security

enum LoopdyLinkAPIError: Error, Equatable {
    case invalidConfiguration
    case invalidResponse
    case pairingIdentityMismatch
    case requestFailed(status: Int, code: String)
}

struct LoopdyLinkAccountSession: Equatable, Sendable {
    let accessToken: String
    let expiresAt: Int
    let authorizationEpoch: Int
}

struct LoopdyLinkPasskeyOptions {
    let flowID: String
    let options: [String: Any]
}


@MainActor
protocol LoopdyLinkAccountAPI: AnyObject {
    func passkeyOptions(registration: Bool) async throws -> LoopdyLinkPasskeyOptions
    func verifyPasskey(
        registration: Bool,
        flowID: String,
        response: [String: Any]
    ) async throws -> LoopdyLinkAccountSession
    func storeAccountKeyEnvelope(_ envelope: String, accessToken: String) async throws
    func loadAccountKeyEnvelope(accessToken: String) async throws -> String
    func saveAccountProfile(
        displayName: String,
        avatar: UserProfileAvatar?,
        expectedRevision: Int,
        credentials: LoopdyLinkRuntimeCredentials
    ) async throws -> LoopdyLinkAccountProfile
    func loadAccountProfile(
        credentials: LoopdyLinkRuntimeCredentials
    ) async throws -> LoopdyLinkAccountProfile?
    func registerDevice(
        accessToken: String,
        credentials: LoopdyLinkRuntimeCredentials,
        name: String,
        kind: LoopdyLinkDeviceKind
    ) async throws -> LoopdyLinkDevice
    func registerExternalDevice(
        accessToken: String,
        deviceID: String,
        publicKeySPKI: String,
        accountKey: Data,
        name: String,
        kind: LoopdyLinkDeviceKind
    ) async throws -> LoopdyLinkDevice
    func revokeCurrentDevice(credentials: LoopdyLinkRuntimeCredentials) async throws
    func deleteAccount(accessToken: String) async throws
}

extension LoopdyLinkAccountAPI {
    func registerExternalDevice(
        accessToken: String,
        deviceID: String,
        publicKeySPKI: String,
        accountKey: Data,
        name: String,
        kind: LoopdyLinkDeviceKind
    ) async throws -> LoopdyLinkDevice {
        throw LoopdyLinkAPIError.invalidConfiguration
    }
}

@MainActor
protocol LoopdyLinkDeviceAPI: AnyObject {
    func listDevices(credentials: LoopdyLinkRuntimeCredentials) async throws -> [LoopdyLinkDevice]
    func renameDevice(
        id: String,
        name: String,
        expectedRevision: Int,
        credentials: LoopdyLinkRuntimeCredentials
    ) async throws -> LoopdyLinkDevice
    func unpairDevice(
        id: String,
        expectedRevision: Int,
        credentials: LoopdyLinkRuntimeCredentials
    ) async throws
    func approvePairing(
        reference: LoopdyLinkPairingReference,
        hostName: String,
        credentials: LoopdyLinkRuntimeCredentials
    ) async throws -> LoopdyLinkDevice
}

@MainActor
protocol LoopdyLinkHTTPTransport: AnyObject {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

@MainActor
final class LoopdyLinkURLSessionTransport: LoopdyLinkHTTPTransport {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw LoopdyLinkAPIError.invalidResponse
        }
        return (data, response)
    }
}

@MainActor
final class LoopdyLinkAPI: LoopdyLinkAccountAPI, LoopdyLinkDeviceAPI {
    private struct PublicDevice: Decodable {
        let deviceId: String
        let encryptedName: String
        let role: String
        let kind: String
        let lifecycle: String
        let revision: Int
        let authorizationEpoch: Int
        let connection: String
        let pushState: String?
        let pushRevision: Int
        let createdAt: Int
        let revokedAt: Int?
        let lastSeenBucket: Int?
    }

    private let baseURL: URL?
    private let transport: any LoopdyLinkHTTPTransport
    private let now: () -> Date
    private let nonce: () -> String
    private let managedNotificationTransport: any LoopdyLinkHTTPTransport

    /// Retained until the notification service drops its account-boundary hook.
    /// BuzzKit owns registration state, so there is no Link readiness to clear.
    func invalidateManagedNotificationReadiness() {
    }

    init(
        baseURL: URL?,
        transport: any LoopdyLinkHTTPTransport = LoopdyLinkURLSessionTransport(),
        now: @escaping () -> Date = Date.init,
        nonce: @escaping () -> String = {
            LoopdyLinkBase64URL.encode(LoopdyLinkAPI.randomBytes(count: 24))
        },
        managedNotificationTransport: any LoopdyLinkHTTPTransport = LoopdyManagedAccountTransport()
    ) {
        precondition(baseURL == nil || (baseURL?.scheme == "https" && baseURL?.host != nil))
        self.baseURL = baseURL
        self.transport = transport
        self.now = now
        self.nonce = nonce
        self.managedNotificationTransport = managedNotificationTransport
    }

    func listDevices(credentials: LoopdyLinkRuntimeCredentials) async throws -> [LoopdyLinkDevice] {
        let value = try await signedJSON(
            path: "/v1/devices",
            method: "GET",
            body: nil,
            credentials: credentials
        )
        guard let rawDevices = value["devices"] as? [Any] else {
            throw LoopdyLinkAPIError.invalidResponse
        }
        let data = try JSONSerialization.data(withJSONObject: rawDevices)
        let devices = try JSONDecoder().decode([PublicDevice].self, from: data)
        let cipher = try LoopdyLinkAccountCipher(key: credentials.accountKey)
        return try devices.map { device in
            guard
                device.lifecycle == "active",
                device.authorizationEpoch > 0,
                device.revision > 0,
                device.pushState == nil,
                device.pushRevision == 0,
                let kind = Self.deviceKind(device.kind),
                let connection = LoopdyLinkConnectionState(rawValue: device.connection)
            else { throw LoopdyLinkAPIError.invalidResponse }
            return LoopdyLinkDevice(
                id: device.deviceId,
                name: try cipher.openDeviceName(device.encryptedName),
                kind: kind,
                isCurrentDevice: device.deviceId == credentials.deviceID,
                connection: connection,
                pushState: nil,
                pushRevision: 0,
                lastSeenAt: device.lastSeenBucket.map {
                    Date(timeIntervalSince1970: TimeInterval($0))
                },
                revision: device.revision,
                authorizationEpoch: device.authorizationEpoch
            )
        }
    }

    func renameDevice(
        id: String,
        name: String,
        expectedRevision: Int,
        credentials: LoopdyLinkRuntimeCredentials
    ) async throws -> LoopdyLinkDevice {
        let cipher = try LoopdyLinkAccountCipher(key: credentials.accountKey)
        let value = try await signedJSON(
            path: "/v1/devices/\(id)/name",
            method: "PATCH",
            body: [
                "expectedRevision": expectedRevision,
                "encryptedName": try cipher.sealDeviceName(name),
            ],
            credentials: credentials
        )
        return try parseDevice(value["device"], credentials: credentials, cipher: cipher)
    }


    func unpairDevice(
        id: String,
        expectedRevision: Int,
        credentials: LoopdyLinkRuntimeCredentials
    ) async throws {
        _ = try await signedJSON(
            path: "/v1/devices/\(id)",
            method: "DELETE",
            body: ["expectedRevision": expectedRevision],
            credentials: credentials
        )
    }


    func approvePairing(
        reference: LoopdyLinkPairingReference,
        hostName: String,
        credentials: LoopdyLinkRuntimeCredentials
    ) async throws -> LoopdyLinkDevice {
        var inspectionBody: [String: Any] = ["code": reference.code]
        if let flowID = reference.flowID { inspectionBody["flowId"] = flowID }
        let inspected = try await signedJSON(
            path: "/v1/pairing/challenges/inspect",
            method: "POST",
            body: inspectionBody,
            credentials: credentials
        )
        guard
            let flowID = inspected["flowId"] as? String,
            let deviceID = inspected["deviceId"] as? String,
            let signingPublicKey = inspected["signingPublicKeySPKI"] as? String,
            let agreement = inspected["agreementPublicKey"] as? String,
            let expiresAt = inspected["expiresAt"] as? Int,
            expiresAt > Int(now().timeIntervalSince1970),
            reference.flowID == nil || reference.flowID == flowID
        else { throw LoopdyLinkAPIError.invalidResponse }
        let actualCommitment = LoopdyLinkPairingKeyCommitment.make(
            flowID: flowID,
            deviceID: deviceID,
            signingPublicKeySPKI: signingPublicKey,
            agreementPublicKey: agreement
        )
        guard reference.verifies(actualCommitment) else {
            throw LoopdyLinkAPIError.pairingIdentityMismatch
        }
        let agreementKey = try LoopdyLinkBase64URL.decode(agreement)
        let cipher = try LoopdyLinkAccountCipher(key: credentials.accountKey)
        let value = try await signedJSON(
            path: "/v1/pairing/challenges/\(flowID)/approve",
            method: "POST",
            body: [
                "code": reference.code,
                "encryptedName": try cipher.sealDeviceName(hostName),
                "grantEnvelope": try LoopdyLinkHostGrant.seal(
                    accountKey: credentials.accountKey,
                    flowID: flowID,
                    deviceID: deviceID,
                    hostAgreementPublicKey: agreementKey
                ),
            ],
            credentials: credentials
        )
        return try parseDevice(value["device"], credentials: credentials, cipher: cipher)
    }

    func registerDevice(
        accessToken: String,
        credentials: LoopdyLinkRuntimeCredentials,
        name: String,
        kind: LoopdyLinkDeviceKind
    ) async throws -> LoopdyLinkDevice {
        try await registerExternalDevice(
            accessToken: accessToken,
            deviceID: credentials.deviceID,
            publicKeySPKI: credentials.signer.publicKeySPKI,
            accountKey: credentials.accountKey,
            name: name,
            kind: kind
        )
    }

    func registerExternalDevice(
        accessToken: String,
        deviceID: String,
        publicKeySPKI: String,
        accountKey: Data,
        name: String,
        kind: LoopdyLinkDeviceKind
    ) async throws -> LoopdyLinkDevice {
        guard
            (16...96).contains(deviceID.count),
            deviceID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }),
            let publicKey = try? LoopdyLinkBase64URL.decode(publicKeySPKI),
            publicKey.count == 91
        else { throw LoopdyLinkAPIError.invalidConfiguration }
        let cipher = try LoopdyLinkAccountCipher(key: accountKey)
        let value = try await bearerJSON(
            path: "/v1/devices",
            method: "POST",
            body: [
                "deviceId": deviceID,
                "publicKeySPKI": publicKeySPKI,
                "role": "mobile",
                "kind": Self.wireKind(kind),
                "encryptedName": try cipher.sealDeviceName(name),
                "revision": 1,
            ],
            accessToken: accessToken
        )
        return try parseDevice(
            value["device"],
            currentDeviceID: deviceID,
            cipher: cipher
        )
    }

    func revokeCurrentDevice(credentials: LoopdyLinkRuntimeCredentials) async throws {
        guard let current = try await listDevices(credentials: credentials).first(where: \.isCurrentDevice) else {
            return
        }
        try await unpairDevice(
            id: current.id,
            expectedRevision: current.revision,
            credentials: credentials
        )
    }

    func storeAccountKeyEnvelope(_ envelope: String, accessToken: String) async throws {
        _ = try await bearerJSON(
            path: "/v1/accounts/key-envelope",
            method: "PUT",
            body: ["envelope": envelope],
            accessToken: accessToken
        )
    }

    func loadAccountKeyEnvelope(accessToken: String) async throws -> String {
        let value = try await bearerJSON(
            path: "/v1/accounts/key-envelope",
            method: "GET",
            body: nil,
            accessToken: accessToken
        )
        guard let envelope = value["envelope"] as? String else {
            throw LoopdyLinkAPIError.invalidResponse
        }
        return envelope
    }

    func saveAccountProfile(
        displayName: String,
        avatar: UserProfileAvatar?,
        expectedRevision: Int,
        credentials: LoopdyLinkRuntimeCredentials
    ) async throws -> LoopdyLinkAccountProfile {
        guard expectedRevision >= 0 else { throw LoopdyLinkAPIError.invalidConfiguration }
        let cipher = try LoopdyLinkAccountCipher(key: credentials.accountKey)
        var body: [String: Any] = [
            "expectedRevision": expectedRevision,
            "encryptedDisplayName": try cipher.sealDeviceName(displayName),
            "updatedAt": Int(now().timeIntervalSince1970),
        ]
        body["avatar"] = avatar.map(Self.avatarBody) ?? NSNull()
        let value = try await signedJSON(
            path: "/v1/accounts/profile",
            method: "PUT",
            body: body,
            credentials: credentials
        )
        return try accountProfile(value["profile"], cipher: cipher)
    }

    func loadAccountProfile(
        credentials: LoopdyLinkRuntimeCredentials
    ) async throws -> LoopdyLinkAccountProfile? {
        let value = try await signedJSON(
            path: "/v1/accounts/profile",
            method: "GET",
            body: nil,
            credentials: credentials
        )
        guard value.keys.contains("profile") else {
            throw LoopdyLinkAPIError.invalidResponse
        }
        guard !(value["profile"] is NSNull) else { return nil }
        let cipher = try LoopdyLinkAccountCipher(key: credentials.accountKey)
        return try accountProfile(value["profile"], cipher: cipher)
    }

    func deleteAccount(accessToken: String) async throws {
        let value = try await bearerJSON(
            path: "/v1/accounts/current",
            method: "DELETE",
            body: nil,
            accessToken: accessToken
        )
        guard value["state"] as? String == "deleted" else {
            throw LoopdyLinkAPIError.invalidResponse
        }
    }

    func passkeyOptions(registration: Bool) async throws -> LoopdyLinkPasskeyOptions {
        let kind = registration ? "registration" : "authentication"
        let value = try await unsignedJSON(
            path: "/v1/accounts/\(kind)/options",
            method: "POST",
            body: [:]
        )
        guard
            let flowID = value["flowId"] as? String,
            let options = value["options"] as? [String: Any]
        else { throw LoopdyLinkAPIError.invalidResponse }
        return LoopdyLinkPasskeyOptions(flowID: flowID, options: options)
    }

    func verifyPasskey(
        registration: Bool,
        flowID: String,
        response: [String: Any]
    ) async throws -> LoopdyLinkAccountSession {
        let kind = registration ? "registration" : "authentication"
        let value = try await unsignedJSON(
            path: "/v1/accounts/\(kind)/verify",
            method: "POST",
            body: ["flowId": flowID, "response": response]
        )
        guard
            let session = value["session"] as? [String: Any],
            let accessToken = session["accessToken"] as? String,
            let expiresAt = session["expiresAt"] as? Int,
            let authorizationEpoch = session["authorizationEpoch"] as? Int,
            authorizationEpoch > 0
        else { throw LoopdyLinkAPIError.invalidResponse }
        return LoopdyLinkAccountSession(
            accessToken: accessToken,
            expiresAt: expiresAt,
            authorizationEpoch: authorizationEpoch
        )
    }

    /// Managed notifications retain their original request bytes across retries.
    /// Explicit credentials are captured by the caller before any await. This is
    /// mobile proof, not an account bearer and never a request to a Hermes host.
    func managedNotificationRequest(path: String, method: String, body: Data?,
                                    credentials: LoopdyLinkRuntimeCredentials) async throws -> LoopdyJSONValue {
        guard let baseURL, baseURL.scheme == "https", baseURL.host == "link.loopdy.app",
              baseURL.port == nil || baseURL.port == 443,
              baseURL.user == nil, baseURL.password == nil,
              baseURL.path.isEmpty || baseURL.path == "/",
              baseURL.query == nil, baseURL.fragment == nil,
              path == "/v1/notifications/host-grants" || path.hasPrefix("/v1/notifications/host-grants/"),
              path.utf8.count <= 512, !path.contains(".."), !path.contains("%"), !path.contains("?"), !path.contains("#"),
              path.utf8.allSatisfy({ (33...126).contains($0) }),
              ["GET", "POST", "PUT", "DELETE"].contains(method) else {
            throw LoopdyLinkAPIError.invalidConfiguration
        }
        let bytes = body ?? Data()
        guard bytes.count <= 262_144, method != "GET" || bytes.isEmpty,
              let text = String(data: bytes, encoding: .utf8) else { throw LoopdyLinkAPIError.invalidConfiguration }
        if !bytes.isEmpty { try DirectHermesWire.validateNesting(bytes) }
        let proof = try credentials.signer.headers(method: method, path: path, body: text,
            timestamp: Int(now().timeIntervalSince1970), nonce: nonce())
        var request = try makeRequest(path: path, method: method, body: bytes)
        proof.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await managedNotificationTransport.data(for: request)
        guard response.url == request.url, !(300...399).contains(response.statusCode), data.count <= 262_144 else {
            throw LoopdyLinkAPIError.invalidResponse
        }
        try DirectHermesWire.validateNesting(data)
        let value = try JSONDecoder().decode(LoopdyJSONValue.self, from: data)
        guard value.object?["version"]?.integer == 1 else { throw LoopdyLinkAPIError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            // Never propagate host/service body text to presentation or logs.
            throw LoopdyLinkAPIError.requestFailed(
                status: response.statusCode,
                code: Self.managedNotificationErrorCode(value) ?? "managed_notification_request_failed"
            )
        }
        return value
    }

    /// Error codes are stable protocol coordinates. Keep only a bounded token
    /// from the v1 error envelope; response messages are never retained.
    private static func managedNotificationErrorCode(_ value: LoopdyJSONValue) -> String? {
        guard let error = value.object?["error"] else { return nil }
        let candidate = error.string ?? error.object?["code"]?.string
        guard let candidate, !candidate.isEmpty, candidate.utf8.count <= 128,
              candidate.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...90).contains(byte)
                      || (97...122).contains(byte) || [45, 46, 95].contains(byte)
              }) else { return nil }
        return candidate
    }

    private func signedJSON(
        path: String,
        method: String,
        body: [String: Any]?,
        credentials: LoopdyLinkRuntimeCredentials
    ) async throws -> [String: Any] {
        let bodyData = try body.map(Self.jsonData) ?? Data()
        let bodyText = String(decoding: bodyData, as: UTF8.self)
        let signed = try credentials.signer.headers(
            method: method,
            path: path,
            body: bodyText,
            timestamp: Int(now().timeIntervalSince1970),
            nonce: nonce()
        )
        var request = try makeRequest(path: path, method: method, body: bodyData)
        signed.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        return try await perform(request)
    }

    private func bearerJSON(
        path: String,
        method: String,
        body: [String: Any]?,
        accessToken: String
    ) async throws -> [String: Any] {
        var request = try makeRequest(
            path: path,
            method: method,
            body: try body.map(Self.jsonData) ?? Data()
        )
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "authorization")
        return try await perform(request)
    }

    private func unsignedJSON(
        path: String,
        method: String,
        body: [String: Any]
    ) async throws -> [String: Any] {
        try await perform(
            makeRequest(path: path, method: method, body: Self.jsonData(body))
        )
    }

    private func makeRequest(path: String, method: String, body: Data) throws -> URLRequest {
        guard let baseURL else { throw LoopdyLinkAPIError.invalidConfiguration }
        guard
            path.hasPrefix("/"),
            !path.contains("?"),
            let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
            url.host == baseURL.host
        else { throw LoopdyLinkAPIError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 20
        if !body.isEmpty {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await transport.data(for: request)
        guard
            data.count <= 3_000_000,
            let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            value["version"] as? Int == 1
        else { throw LoopdyLinkAPIError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw LoopdyLinkAPIError.requestFailed(
                status: response.statusCode,
                code: (value["error"] as? String) ?? "request_failed"
            )
        }
        return value
    }

    private func parseDevice(
        _ raw: Any?,
        credentials: LoopdyLinkRuntimeCredentials,
        cipher: LoopdyLinkAccountCipher
    ) throws -> LoopdyLinkDevice {
        try parseDevice(raw, currentDeviceID: credentials.deviceID, cipher: cipher)
    }

    private func parseDevice(
        _ raw: Any?,
        currentDeviceID: String,
        cipher: LoopdyLinkAccountCipher
    ) throws -> LoopdyLinkDevice {
        let data = try JSONSerialization.data(withJSONObject: raw as Any)
        let device = try JSONDecoder().decode(PublicDevice.self, from: data)
        guard
            device.lifecycle == "active", device.authorizationEpoch > 0, device.revision > 0,
            device.pushState == nil, device.pushRevision == 0,
            let kind = Self.deviceKind(device.kind),
            let connection = LoopdyLinkConnectionState(rawValue: device.connection)
        else { throw LoopdyLinkAPIError.invalidResponse }
        return LoopdyLinkDevice(
            id: device.deviceId,
            name: try cipher.openDeviceName(device.encryptedName),
            kind: kind,
            isCurrentDevice: device.deviceId == currentDeviceID,
            connection: connection,
            pushState: nil,
            pushRevision: 0,
            lastSeenAt: device.lastSeenBucket.map {
                Date(timeIntervalSince1970: TimeInterval($0))
            },
            revision: device.revision,
            authorizationEpoch: device.authorizationEpoch
        )
    }

    private static func jsonData(_ body: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(body) else {
            throw LoopdyLinkAPIError.invalidConfiguration
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    private static func avatarBody(_ avatar: UserProfileAvatar) -> [String: Any] {
        [
            "mimeType": avatar.mimeType,
            "byteCount": avatar.byteCount,
            "sha256": avatar.sha256,
            "encryptedData": avatar.encryptedData,
        ]
    }

    private func accountProfile(
        _ raw: Any?,
        cipher: LoopdyLinkAccountCipher
    ) throws -> LoopdyLinkAccountProfile {
        guard
            let source = raw as? [String: Any],
            let revision = source["revision"] as? Int,
            revision >= 0,
            let encryptedDisplayName = source["encryptedDisplayName"] as? String,
            let updatedAt = source["updatedAt"] as? Int,
            updatedAt > 0
        else { throw LoopdyLinkAPIError.invalidResponse }
        let avatar: UserProfileAvatar?
        if source["avatar"] is NSNull || source["avatar"] == nil {
            avatar = nil
        } else if let rawAvatar = source["avatar"] as? [String: Any] {
            avatar = try Self.userProfileAvatar(rawAvatar)
        } else {
            throw LoopdyLinkAPIError.invalidResponse
        }
        return LoopdyLinkAccountProfile(
            revision: revision,
            displayName: try cipher.openDeviceName(encryptedDisplayName),
            avatar: avatar,
            updatedAt: updatedAt
        )
    }

    private static func userProfileAvatar(_ source: [String: Any]) throws -> UserProfileAvatar {
        guard
            Set(source.keys) == Set(["mimeType", "byteCount", "sha256", "encryptedData"]),
            let mimeType = source["mimeType"] as? String,
            ["image/png", "image/jpeg", "image/webp"].contains(mimeType),
            let byteCount = source["byteCount"] as? Int,
            (1...2_000_000).contains(byteCount),
            let sha256 = source["sha256"] as? String,
            (16...128).contains(sha256.count),
            let encryptedData = source["encryptedData"] as? String,
            (16...2_800_000).contains(encryptedData.count)
        else { throw LoopdyLinkAPIError.invalidResponse }
        return UserProfileAvatar(
            mimeType: mimeType,
            byteCount: byteCount,
            sha256: sha256,
            encryptedData: encryptedData
        )
    }

    private static func deviceKind(_ value: String) -> LoopdyLinkDeviceKind? {
        switch value {
        case "phone": .phone
        case "tablet": .tablet
        case "computer": .computer
        case "hermes_host": .hermesHost
        default: nil
        }
    }

    private static func wireKind(_ value: LoopdyLinkDeviceKind) -> String {
        switch value {
        case .phone: "phone"
        case .tablet: "tablet"
        case .computer: "computer"
        case .hermesHost: "hermes_host"
        }
    }


    private static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}
