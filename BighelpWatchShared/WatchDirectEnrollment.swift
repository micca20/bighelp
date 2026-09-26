import CryptoKit
import Foundation
import Security

struct WatchBighelpEnrollmentRequest: Codable, Equatable, Sendable {
    let requestID: String
    let deviceID: String
    let publicKeySPKI: String
    let agreementPublicKey: String
    let deviceName: String
    let deliveryVersion: Int

    private enum CodingKeys: String, CodingKey {
        case requestID
        case deviceID
        case publicKeySPKI
        case agreementPublicKey
        case deviceName
        case deliveryVersion
    }

    init(
        requestID: String,
        deviceID: String,
        publicKeySPKI: String,
        agreementPublicKey: String,
        deviceName: String,
        deliveryVersion: Int = 2
    ) throws {
        guard Self.coordinate(requestID, minimum: 16, maximum: 128),
              Self.coordinate(deviceID, minimum: 16, maximum: 96),
              let signingKey = try? BighelpLinkBase64URL.decode(publicKeySPKI),
              signingKey.count == 91,
              let agreementKey = try? BighelpLinkBase64URL.decode(agreementPublicKey),
              agreementKey.count == 32,
              !deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              deviceName.count <= 64,
              !deviceName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              (1...2).contains(deliveryVersion)
        else { throw WatchCompanionValidationError.invalidPayload }
        self.requestID = requestID
        self.deviceID = deviceID
        self.publicKeySPKI = publicKeySPKI
        self.agreementPublicKey = agreementPublicKey
        self.deviceName = deviceName
        self.deliveryVersion = deliveryVersion
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            requestID: container.decode(String.self, forKey: .requestID),
            deviceID: container.decode(String.self, forKey: .deviceID),
            publicKeySPKI: container.decode(String.self, forKey: .publicKeySPKI),
            agreementPublicKey: container.decode(String.self, forKey: .agreementPublicKey),
            deviceName: container.decode(String.self, forKey: .deviceName),
            deliveryVersion: try container.decodeIfPresent(Int.self, forKey: .deliveryVersion) ?? 1
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(deviceID, forKey: .deviceID)
        try container.encode(publicKeySPKI, forKey: .publicKeySPKI)
        try container.encode(agreementPublicKey, forKey: .agreementPublicKey)
        try container.encode(deviceName, forKey: .deviceName)
        try container.encode(deliveryVersion, forKey: .deliveryVersion)
    }

    var usesDurableGrantDelivery: Bool { deliveryVersion >= 2 }

    private static func coordinate(_ value: String, minimum: Int, maximum: Int) -> Bool {
        (minimum...maximum).contains(value.count) && value.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
        }
    }
}

struct WatchBighelpEnrollmentGrant: Codable, Equatable, Sendable {
    let requestID: String
    let deviceID: String
    let baseURL: String
    let authorizationEpoch: Int
    let grantEnvelope: String

    init(
        requestID: String,
        deviceID: String,
        baseURL: String,
        authorizationEpoch: Int,
        grantEnvelope: String
    ) throws {
        guard (16...128).contains(requestID.count),
              (16...96).contains(deviceID.count),
              authorizationEpoch > 0,
              let url = URL(string: baseURL),
              url.scheme == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              !grantEnvelope.isEmpty,
              grantEnvelope.count <= 512
        else { throw WatchCompanionValidationError.invalidPayload }
        self.requestID = requestID
        self.deviceID = deviceID
        self.baseURL = baseURL
        self.authorizationEpoch = authorizationEpoch
        self.grantEnvelope = grantEnvelope
    }

    func openCredentials(
        signingPrivateKey: P256.Signing.PrivateKey,
        agreementPrivateKey: Curve25519.KeyAgreement.PrivateKey
    ) throws -> BighelpLinkRuntimeCredentials {
        let accountKey = try BighelpLinkHostGrant.open(
            grantEnvelope,
            flowID: requestID,
            deviceID: deviceID,
            hostAgreementPrivateKey: agreementPrivateKey
        )
        return BighelpLinkRuntimeCredentials(
            deviceID: deviceID,
            authorizationEpoch: authorizationEpoch,
            signingPrivateKey: signingPrivateKey,
            accountKey: accountKey
        )
    }
}

struct WatchPendingEnrollmentRecord: Codable, Equatable, Sendable {
    let request: WatchBighelpEnrollmentRequest
    private let signingPrivateKey: String
    private let agreementPrivateKey: String

    private enum CodingKeys: String, CodingKey {
        case request
        case signingPrivateKey
        case agreementPrivateKey
    }

    init(
        request: WatchBighelpEnrollmentRequest,
        signingPrivateKey: Data,
        agreementPrivateKey: Data
    ) throws {
        let signingKey = try P256.Signing.PrivateKey(rawRepresentation: signingPrivateKey)
        let agreementKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: agreementPrivateKey)
        let publicKey = BighelpLinkDeviceSigner(
            deviceID: request.deviceID,
            authorizationEpoch: 1,
            privateKey: signingKey
        ).publicKeySPKI
        guard publicKey == request.publicKeySPKI,
              BighelpLinkBase64URL.encode(agreementKey.publicKey.rawRepresentation)
                == request.agreementPublicKey else {
            throw WatchCompanionValidationError.invalidPayload
        }
        self.request = request
        self.signingPrivateKey = BighelpLinkBase64URL.encode(signingPrivateKey)
        self.agreementPrivateKey = BighelpLinkBase64URL.encode(agreementPrivateKey)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let request = try container.decode(WatchBighelpEnrollmentRequest.self, forKey: .request)
        try self.init(
            request: request,
            signingPrivateKey: BighelpLinkBase64URL.decode(
                try container.decode(String.self, forKey: .signingPrivateKey)
            ),
            agreementPrivateKey: BighelpLinkBase64URL.decode(
                try container.decode(String.self, forKey: .agreementPrivateKey)
            )
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(request, forKey: .request)
        try container.encode(signingPrivateKey, forKey: .signingPrivateKey)
        try container.encode(agreementPrivateKey, forKey: .agreementPrivateKey)
    }

    func openCredentials(from grant: WatchBighelpEnrollmentGrant) throws -> BighelpLinkRuntimeCredentials {
        guard grant.requestID == request.requestID,
              grant.deviceID == request.deviceID else {
            throw WatchCompanionValidationError.invalidPayload
        }
        return try grant.openCredentials(
            signingPrivateKey: P256.Signing.PrivateKey(
                rawRepresentation: BighelpLinkBase64URL.decode(signingPrivateKey)
            ),
            agreementPrivateKey: Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: BighelpLinkBase64URL.decode(agreementPrivateKey)
            )
        )
    }
}

struct WatchEnrollmentTransferTicket: Equatable {
    let generation: UInt64
    let requestID: String
    let reply: WatchCompanionReply
}

struct WatchEnrollmentDeliveryLedger {
    private var generation: UInt64 = 0
    private var authorizingRequestIDs: Set<String> = []
    private var stagedReplies: [String: WatchCompanionReply] = [:]
    private var queuedRequestIDs: Set<String> = []
    private var completedRequestIDs: Set<String> = []
    private var completedRequestOrder: [String] = []

    mutating func beginAuthorization(requestID: String) -> Bool {
        guard !completedRequestIDs.contains(requestID) else { return false }
        return authorizingRequestIDs.insert(requestID).inserted
    }

    mutating func stage(_ reply: WatchCompanionReply, requestID: String) {
        stagedReplies[requestID] = reply
    }

    mutating func beginTransfer(
        requestID: String,
        sessionIsActivated: Bool
    ) -> WatchEnrollmentTransferTicket? {
        guard sessionIsActivated,
              !queuedRequestIDs.contains(requestID),
              let reply = stagedReplies[requestID] else { return nil }
        queuedRequestIDs.insert(requestID)
        return WatchEnrollmentTransferTicket(
            generation: generation,
            requestID: requestID,
            reply: reply
        )
    }

    mutating func finishTransfer(_ ticket: WatchEnrollmentTransferTicket, succeeded: Bool) {
        guard ticket.generation == generation,
              queuedRequestIDs.remove(ticket.requestID) != nil else { return }
        _ = succeeded
    }

    @discardableResult
    mutating func acknowledge(requestID: String) -> Bool {
        if completedRequestIDs.contains(requestID) { return true }
        guard stagedReplies.removeValue(forKey: requestID) != nil else { return false }
        queuedRequestIDs.remove(requestID)
        authorizingRequestIDs.remove(requestID)
        if completedRequestIDs.insert(requestID).inserted {
            completedRequestOrder.append(requestID)
        }
        if completedRequestOrder.count > 32 {
            completedRequestIDs.remove(completedRequestOrder.removeFirst())
        }
        return true
    }

    mutating func reset() -> Set<String> {
        generation &+= 1
        let requestIDs = authorizingRequestIDs
            .union(stagedReplies.keys)
            .union(queuedRequestIDs)
            .union(completedRequestIDs)
        authorizingRequestIDs.removeAll()
        stagedReplies.removeAll()
        queuedRequestIDs.removeAll()
        completedRequestIDs.removeAll()
        completedRequestOrder.removeAll()
        return requestIDs
    }

    var stagedRequestIDs: [String] {
        Array(stagedReplies.keys)
    }

    static func requestID(for reply: WatchCompanionReply) -> String? {
        switch reply {
        case .enrollmentAccepted(let requestID):
            requestID
        case .directEnrollment(let grant):
            grant.requestID
        case .failed(let attemptID, _, _):
            attemptID
        default:
            nil
        }
    }
}

@MainActor
final class WatchPendingEnrollmentKeychainVault {
    private let service: String
    private let account = "pending-enrollment-v1"

    init(service: String = "app.loopdy.mobile.watch.pending-enrollment") {
        self.service = service
    }

    func load() throws -> WatchPendingEnrollmentRecord? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw VaultError.keychain(status)
        }
        return try JSONDecoder().decode(WatchPendingEnrollmentRecord.self, from: data)
    }

    func save(_ record: WatchPendingEnrollmentRecord) throws {
        let data = try JSONEncoder().encode(record)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        let addStatus = SecItemAdd(
            query.merging(attributes) { _, new in new } as CFDictionary,
            nil
        )
        if addStatus == errSecSuccess { return }
        guard addStatus == errSecDuplicateItem else { throw VaultError.keychain(addStatus) }
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard updateStatus == errSecSuccess else { throw VaultError.keychain(updateStatus) }
    }

    func delete() throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VaultError.keychain(status)
        }
    }

    private enum VaultError: Error {
        case keychain(OSStatus)
    }
}
