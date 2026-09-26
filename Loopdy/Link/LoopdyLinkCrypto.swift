import CryptoKit
import Foundation
import Security

enum LoopdyLinkCryptoError: Error, Equatable {
    case invalidBase64URL
    case invalidKey
    case invalidEnvelope
    case invalidPlaintext
}

/// Metadata for an authenticated payload that could not be decoded.
///
/// This intentionally keeps only protocol shape information. In particular,
/// it never retains or formats the payload's values, ciphertext, frame
/// identity, or account material.
struct LoopdyLinkPayloadDecodeDiagnostic: Equatable, Sendable {
    let payloadType: String
    let byteCount: Int
    let category: String
    let codingPath: [String]
    /// Authenticated routing coordinates are retained only so a recoverable
    /// diagnostic can be attached to the correct open session. They are never
    /// included in the diagnostic's log representation.
    let sessionID: String?
    let agentID: String?

    init(plaintext: Data, error: Error) {
        payloadType = Self.payloadType(in: plaintext)
        byteCount = plaintext.count
        category = Self.category(for: error)
        codingPath = Self.codingPath(for: error)
        let metadata = Self.routingMetadata(in: plaintext)
        sessionID = metadata.sessionID
        agentID = metadata.agentID
    }

    var logDescription: String {
        let path = codingPath.isEmpty ? "<root>" : codingPath.joined(separator: ".")
        return "payload_type=\(payloadType) bytes=\(byteCount) decoder=\(category) path=\(path)"
    }

    private static func payloadType(in plaintext: Data) -> String {
        guard
            let object = try? JSONSerialization.jsonObject(with: plaintext),
            let dictionary = object as? [String: Any],
            let type = dictionary["type"] as? String
        else {
            return "<missing>"
        }
        return safeComponent(type, fallback: "<invalid>")
    }

    private static func routingMetadata(in plaintext: Data) -> (
        sessionID: String?,
        agentID: String?
    ) {
        guard
            let object = try? JSONSerialization.jsonObject(with: plaintext),
            let dictionary = object as? [String: Any]
        else { return (nil, nil) }

        return (
            safeOpaque(dictionary["sessionId"], minimum: 16, maximum: 180),
            safeOpaque(dictionary["agentId"], minimum: 1, maximum: 96)
        )
    }

    private static func safeOpaque(
        _ value: Any?,
        minimum: Int,
        maximum: Int
    ) -> String? {
        guard
            let value = value as? String,
            (minimum...maximum).contains(value.count),
            value.allSatisfy({
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
            })
        else { return nil }
        return value
    }

    private static func category(for error: Error) -> String {
        guard let error = error as? DecodingError else {
            return error is LoopdyLinkWireError ? "wire.invalidValue" : "other"
        }
        switch error {
        case .keyNotFound:
            return "keyNotFound"
        case .typeMismatch:
            return "typeMismatch"
        case .valueNotFound:
            return "valueNotFound"
        case .dataCorrupted:
            return "dataCorrupted"
        @unknown default:
            return "unknown"
        }
    }

    private static func codingPath(for error: Error) -> [String] {
        guard let error = error as? DecodingError else { return [] }
        let path: [any CodingKey]
        switch error {
        case let .keyNotFound(_, context):
            path = context.codingPath
        case let .typeMismatch(_, context):
            path = context.codingPath
        case let .valueNotFound(_, context):
            path = context.codingPath
        case let .dataCorrupted(context):
            path = context.codingPath
        @unknown default:
            path = []
        }
        return path.map { safeComponent($0.stringValue, fallback: "<unnamed>") }
    }

    private static func safeComponent(_ value: String, fallback: String) -> String {
        var component = ""
        for scalar in value.unicodeScalars {
            guard component.unicodeScalars.count < 64 else { break }
            guard scalar.isASCII,
                  CharacterSet.alphanumerics.contains(scalar)
                    || "._-".unicodeScalars.contains(scalar)
            else { continue }
            component.unicodeScalars.append(scalar)
        }
        return component.isEmpty ? fallback : component
    }
}

enum LoopdyLinkBase64URL {
    private static let allowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    )

    static func encode(_ value: Data) -> String {
        value.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ value: String) throws -> Data {
        guard
            !value.isEmpty,
            value.unicodeScalars.allSatisfy(allowed.contains),
            value.count % 4 != 1
        else {
            throw LoopdyLinkCryptoError.invalidBase64URL
        }
        let normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        guard let decoded = Data(base64Encoded: padded) else {
            throw LoopdyLinkCryptoError.invalidBase64URL
        }
        return decoded
    }
}

struct LoopdyLinkSignedRequest {
    let canonical: String
    let headers: [String: String]
}

struct LoopdyLinkDeviceSigner {
    let deviceID: String
    let authorizationEpoch: Int
    let privateKey: P256.Signing.PrivateKey

    var publicKeySPKI: String {
        // id-ecPublicKey + prime256v1 SubjectPublicKeyInfo prefix, followed by
        // CryptoKit's uncompressed SEC1/X9.63 public point.
        let prefix = Data([
            0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86,
            0x48, 0xCE, 0x3D, 0x02, 0x01, 0x06, 0x08, 0x2A,
            0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03,
            0x42, 0x00,
        ])
        return LoopdyLinkBase64URL.encode(prefix + privateKey.publicKey.x963Representation)
    }

    func headers(
        method: String,
        path: String,
        body: String,
        timestamp: Int = Int(Date().timeIntervalSince1970),
        nonce: String = LoopdyLinkBase64URL.encode(Self.randomBytes(count: 24))
    ) throws -> LoopdyLinkSignedRequest {
        guard
            !deviceID.isEmpty,
            authorizationEpoch > 0,
            timestamp > 0,
            (try? LoopdyLinkBase64URL.decode(nonce).count) != nil
        else {
            throw LoopdyLinkCryptoError.invalidKey
        }
        let bodyDigest = LoopdyLinkBase64URL.encode(
            Data(SHA256.hash(data: Data(body.utf8)))
        )
        let canonical = [
            "loopdy-link-device-v1",
            method.uppercased(),
            path,
            deviceID,
            String(timestamp),
            nonce,
            String(authorizationEpoch),
            bodyDigest,
        ].joined(separator: "\n")
        let signature = try privateKey.signature(for: Data(canonical.utf8))
        return LoopdyLinkSignedRequest(
            canonical: canonical,
            headers: [
                "x-loopdy-device-id": deviceID,
                "x-loopdy-timestamp": String(timestamp),
                "x-loopdy-nonce": nonce,
                "x-loopdy-authorization-epoch": String(authorizationEpoch),
                "x-loopdy-signature": LoopdyLinkBase64URL.encode(signature.rawRepresentation),
            ]
        )
    }

    private static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}

struct LoopdyLinkAccountCipher {
    private static let frameAAD = Data("loopdy-link-frame-v1".utf8)
    private static let deviceNameAAD = Data("loopdy-link-device-name-v1".utf8)
    private static let profileAvatarAAD = Data("loopdy-link-profile-avatar-v1".utf8)
    private let key: SymmetricKey

    private static let standardFramePlaintextBytes = 196_608
    private static let avatarFramePlaintextBytes = 2_800_000

    init(key: Data) throws {
        guard key.count == 32 else { throw LoopdyLinkCryptoError.invalidKey }
        self.key = SymmetricKey(data: key)
    }

    func seal<Value: Encodable>(_ value: Value, nonce: Data? = nil) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let plaintext = try encoder.encode(value)
        return try sealData(
            plaintext,
            aad: Self.frameAAD,
            nonce: nonce,
            maximumPlaintextBytes: Self.framePlaintextLimit(for: plaintext)
        )
    }

    func seal<Value: Encodable>(
        _ value: Value,
        targetHostID: String?,
        nonce: Data? = nil
    ) throws -> String {
        guard let targetHostID else { return try seal(value, nonce: nonce) }
        guard
            !targetHostID.isEmpty,
            targetHostID.utf8.count <= 96,
            targetHostID.allSatisfy({
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
            })
        else { throw LoopdyLinkCryptoError.invalidPlaintext }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(value)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              object["targetHostId"] == nil else {
            throw LoopdyLinkCryptoError.invalidPlaintext
        }
        object["targetHostId"] = targetHostID
        let plaintext = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return try sealData(
            plaintext,
            aad: Self.frameAAD,
            nonce: nonce,
            maximumPlaintextBytes: Self.framePlaintextLimit(for: plaintext)
        )
    }

    func open<Value: Decodable>(
        _ envelope: String,
        onPayloadDecodeFailure: ((LoopdyLinkPayloadDecodeDiagnostic) -> Void)? = nil
    ) throws -> Value {
        let plaintext = try openData(
            envelope,
            aad: Self.frameAAD,
            maximumPlaintextBytes: Self.avatarFramePlaintextBytes
        )
        guard plaintext.count <= Self.framePlaintextLimit(for: plaintext) else {
            throw LoopdyLinkCryptoError.invalidPlaintext
        }
        do {
            return try JSONDecoder().decode(Value.self, from: plaintext)
        } catch {
            onPayloadDecodeFailure?(
                LoopdyLinkPayloadDecodeDiagnostic(plaintext: plaintext, error: error)
            )
            throw LoopdyLinkCryptoError.invalidPlaintext
        }
    }

    /// Re-envelops an already authenticated frame payload with a fresh nonce.
    /// This is used only when reconnect reconciliation must assign a new outer
    /// sequence; the encrypted plaintext is never interpreted by the relay.
    func reencrypt(_ envelope: String) throws -> String {
        let plaintext = try openData(
            envelope,
            aad: Self.frameAAD,
            maximumPlaintextBytes: Self.avatarFramePlaintextBytes
        )
        let limit = Self.framePlaintextLimit(for: plaintext)
        guard plaintext.count <= limit else { throw LoopdyLinkCryptoError.invalidPlaintext }
        return try sealData(
            plaintext,
            aad: Self.frameAAD,
            nonce: nil,
            maximumPlaintextBytes: limit
        )
    }

    func sealDeviceName(_ value: String, nonce: Data? = nil) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !normalized.isEmpty,
            normalized.unicodeScalars.count <= 64,
            !normalized.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw LoopdyLinkCryptoError.invalidPlaintext
        }
        return try sealData(Data(normalized.utf8), aad: Self.deviceNameAAD, nonce: nonce)
    }

    func sealProfileAvatar(_ value: Data, nonce: Data? = nil) throws -> String {
        guard (1...2_000_000).contains(value.count) else {
            throw LoopdyLinkCryptoError.invalidPlaintext
        }
        return try sealData(
            value,
            aad: Self.profileAvatarAAD,
            nonce: nonce,
            maximumPlaintextBytes: 2_000_000
        )
    }

    func openDeviceName(_ envelope: String) throws -> String {
        let plaintext = try openData(envelope, aad: Self.deviceNameAAD)
        guard let value = String(data: plaintext, encoding: .utf8) else {
            throw LoopdyLinkCryptoError.invalidPlaintext
        }
        return value
    }

    func openProfileAvatar(_ envelope: String) throws -> Data {
        let plaintext = try openData(
            envelope,
            aad: Self.profileAvatarAAD,
            maximumPlaintextBytes: 2_000_000
        )
        guard (1...2_000_000).contains(plaintext.count) else {
            throw LoopdyLinkCryptoError.invalidPlaintext
        }
        return plaintext
    }

    private func sealData(
        _ plaintext: Data,
        aad: Data,
        nonce: Data?,
        maximumPlaintextBytes: Int = 196_608
    ) throws -> String {
        guard plaintext.count <= maximumPlaintextBytes else {
            throw LoopdyLinkCryptoError.invalidPlaintext
        }
        let selectedNonce: AES.GCM.Nonce
        if let nonce {
            guard nonce.count == 12 else { throw LoopdyLinkCryptoError.invalidEnvelope }
            selectedNonce = try AES.GCM.Nonce(data: nonce)
        } else {
            selectedNonce = AES.GCM.Nonce()
        }
        let box = try AES.GCM.seal(
            plaintext,
            using: key,
            nonce: selectedNonce,
            authenticating: aad
        )
        guard let combined = box.combined else { throw LoopdyLinkCryptoError.invalidEnvelope }
        return LoopdyLinkBase64URL.encode(combined)
    }

    private func openData(
        _ envelope: String,
        aad: Data,
        maximumPlaintextBytes: Int = 196_608
    ) throws -> Data {
        let combined = try LoopdyLinkBase64URL.decode(envelope)
        guard
            combined.count >= 29,
            combined.count <= maximumPlaintextBytes + 29
        else { throw LoopdyLinkCryptoError.invalidEnvelope }
        do {
            let plaintext = try AES.GCM.open(
                AES.GCM.SealedBox(combined: combined),
                using: key,
                authenticating: aad
            )
            guard plaintext.count <= maximumPlaintextBytes else {
                throw LoopdyLinkCryptoError.invalidPlaintext
            }
            return plaintext
        } catch let error as LoopdyLinkCryptoError {
            throw error
        } catch {
            throw LoopdyLinkCryptoError.invalidEnvelope
        }
    }

    private static func framePlaintextLimit(for plaintext: Data) -> Int {
        guard plaintext.count > standardFramePlaintextBytes else {
            return standardFramePlaintextBytes
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
            let type = object["type"] as? String,
            let operation = object["operation"] as? String,
            (type == "workspace.request" && operation == "agents.avatar.set")
                || (type == "workspace.result" && operation == "agents.avatar.get")
        else { return standardFramePlaintextBytes }
        return avatarFramePlaintextBytes
    }
}

enum LoopdyLinkAccountKeyEnvelope {
    private static let aad = Data("loopdy-link-account-key-envelope-v1".utf8)

    static func seal(
        accountKey: Data,
        wrappingKey: Data,
        nonce: Data? = nil
    ) throws -> String {
        guard accountKey.count == 32, wrappingKey.count == 32 else {
            throw LoopdyLinkCryptoError.invalidKey
        }
        let selectedNonce = try nonce.map(AES.GCM.Nonce.init(data:)) ?? AES.GCM.Nonce()
        let box = try AES.GCM.seal(
            accountKey,
            using: SymmetricKey(data: wrappingKey),
            nonce: selectedNonce,
            authenticating: aad
        )
        guard let combined = box.combined else { throw LoopdyLinkCryptoError.invalidEnvelope }
        return LoopdyLinkBase64URL.encode(combined)
    }

    static func open(_ envelope: String, wrappingKey: Data) throws -> Data {
        guard wrappingKey.count == 32 else { throw LoopdyLinkCryptoError.invalidKey }
        do {
            let plaintext = try AES.GCM.open(
                AES.GCM.SealedBox(combined: LoopdyLinkBase64URL.decode(envelope)),
                using: SymmetricKey(data: wrappingKey),
                authenticating: aad
            )
            guard plaintext.count == 32 else { throw LoopdyLinkCryptoError.invalidEnvelope }
            return plaintext
        } catch let error as LoopdyLinkCryptoError {
            throw error
        } catch {
            throw LoopdyLinkCryptoError.invalidEnvelope
        }
    }
}

enum LoopdyLinkHostGrant {
    private static let info = Data("loopdy-link-host-grant-v1".utf8)

    private struct Payload: Codable {
        let version: Int
        let deviceId: String
        let accountKey: String
    }

    static func seal(
        accountKey: Data,
        flowID: String,
        deviceID: String,
        hostAgreementPublicKey: Data,
        ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey = .init(),
        nonce: Data? = nil
    ) throws -> String {
        guard accountKey.count == 32 else { throw LoopdyLinkCryptoError.invalidKey }
        let hostKey = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: hostAgreementPublicKey
        )
        let shared = try ephemeralPrivateKey.sharedSecretFromKeyAgreement(with: hostKey)
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(flowID.utf8),
            sharedInfo: info,
            outputByteCount: 32
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let plaintext = try encoder.encode(
            Payload(
                version: 1,
                deviceId: deviceID,
                accountKey: LoopdyLinkBase64URL.encode(accountKey)
            )
        )
        let selectedNonce = try nonce.map(AES.GCM.Nonce.init(data:)) ?? AES.GCM.Nonce()
        let box = try AES.GCM.seal(
            plaintext,
            using: key,
            nonce: selectedNonce,
            authenticating: Data(flowID.utf8)
        )
        guard let combined = box.combined else { throw LoopdyLinkCryptoError.invalidEnvelope }
        return LoopdyLinkBase64URL.encode(
            ephemeralPrivateKey.publicKey.rawRepresentation + combined
        )
    }

    static func open(
        _ envelope: String,
        flowID: String,
        deviceID: String,
        hostAgreementPrivateKey: Curve25519.KeyAgreement.PrivateKey
    ) throws -> Data {
        let raw = try LoopdyLinkBase64URL.decode(envelope)
        guard raw.count >= 61 else { throw LoopdyLinkCryptoError.invalidEnvelope }
        let ephemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw.prefix(32))
        let shared = try hostAgreementPrivateKey.sharedSecretFromKeyAgreement(with: ephemeral)
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(flowID.utf8),
            sharedInfo: info,
            outputByteCount: 32
        )
        do {
            let plaintext = try AES.GCM.open(
                AES.GCM.SealedBox(combined: raw.dropFirst(32)),
                using: key,
                authenticating: Data(flowID.utf8)
            )
            let payload = try JSONDecoder().decode(Payload.self, from: plaintext)
            guard payload.version == 1, payload.deviceId == deviceID else {
                throw LoopdyLinkCryptoError.invalidEnvelope
            }
            let accountKey = try LoopdyLinkBase64URL.decode(payload.accountKey)
            guard accountKey.count == 32 else { throw LoopdyLinkCryptoError.invalidEnvelope }
            return accountKey
        } catch let error as LoopdyLinkCryptoError {
            throw error
        } catch {
            throw LoopdyLinkCryptoError.invalidEnvelope
        }
    }
}
