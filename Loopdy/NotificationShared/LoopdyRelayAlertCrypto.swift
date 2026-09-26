import CryptoKit
import Foundation

enum LoopdyRelayAlertError: Error, Equatable {
    case invalidPayload
    case expired
    case keyUnavailable
    case untrustedSender
    case authenticationFailed
    case invalidPlaintext
}

struct LoopdyRelayAlertContent: Equatable, Sendable {
    let eventID: String
    let eventType: String
    let title: String
    let body: String
    let hostGrant: LoopdyNotificationHostGrant?

    init(eventID: String, eventType: String, title: String, body: String,
         hostGrant: LoopdyNotificationHostGrant? = nil) {
        self.eventID = eventID
        self.eventType = eventType
        self.title = title
        self.body = body
        self.hostGrant = hostGrant
    }
}

enum LoopdyRelayAlertRouting {
    static func userInfo(
        preserving original: [AnyHashable: Any],
        decrypted: LoopdyRelayAlertContent
    ) -> [AnyHashable: Any] {
        // LP1 authenticates only event identity/type and display copy. Never
        // promote unrelated outer APNs navigation fields into trusted routing.
        var routed = original.filter { key, _ in
            guard let key = key as? String else { return true }
            return !key.hasPrefix("loopdy_")
        }
        routed["loopdy_notification_version"] = "1"
        routed["loopdy_event_id"] = decrypted.eventID
        routed["loopdy_event_type"] = decrypted.eventType
        if let grant = decrypted.hostGrant {
            routed["loopdy_grant_id"] = grant.grantID
        }
        return routed
    }
}

struct LoopdyRelayAlertDecryptor {
    private let senderKeyPins: any LoopdyRelaySenderKeyPinStoring
    private let recipientKeys: any LoopdyNotificationRecipientKeyLoading
    private let hostTrust: any LoopdyNotificationHostTrustLoading
    private let now: () -> Int

    init(
        senderKeyPins: any LoopdyRelaySenderKeyPinStoring = LoopdyRelaySenderKeychainPinStore(),
        recipientKeys: any LoopdyNotificationRecipientKeyLoading = LoopdyNotificationRecipientKeyStore(),
        hostTrust: any LoopdyNotificationHostTrustLoading = LoopdyNotificationHostTrustStore(),
        now: @escaping () -> Int = { Int(Date().timeIntervalSince1970) }
    ) {
        self.senderKeyPins = senderKeyPins
        self.recipientKeys = recipientKeys
        self.hostTrust = hostTrust
        self.now = now
    }

    func decrypt(userInfo: [AnyHashable: Any]) throws -> LoopdyRelayAlertContent {
        guard
            let content = Self.dictionary(userInfo["loopdy"]),
            Set(content.keys) == Set(["version", "tenant_id", "device_id", "envelope"]),
            Self.integer(content["version"]) == 1,
            let tenantID = Self.identifier(content["tenant_id"], maximum: 180),
            let deviceID = Self.identifier(content["device_id"], maximum: 180),
            let envelope = Self.dictionary(content["envelope"]),
            Set(envelope.keys) == Set([
                "v", "kind", "delivery_id", "event_ref", "recipient_key_id",
                "sender_key_id", "issued", "expires", "ephemeral_public_key", "salt",
                "nonce", "ciphertext", "tag", "signature",
            ]),
            Self.integer(envelope["v"]) == 1,
            envelope["kind"] as? String == "alert",
            let deliveryID = Self.identifier(envelope["delivery_id"], maximum: 180),
            let eventReference = Self.base64(envelope["event_ref"], count: 32),
            let recipientKeyID = Self.base64(envelope["recipient_key_id"], count: 32),
            let senderKeyID = Self.base64(envelope["sender_key_id"], count: 32),
            let issued = Self.integer(envelope["issued"]),
            let expires = Self.integer(envelope["expires"]),
            issued > 0,
            expires > issued,
            expires - issued <= 900,
            let ephemeralPublicKey = Self.base64(envelope["ephemeral_public_key"], count: 65),
            ephemeralPublicKey.first == 0x04,
            let salt = Self.base64(envelope["salt"], count: 32),
            let nonce = Self.base64(envelope["nonce"], count: 12),
            let ciphertext = Self.base64(envelope["ciphertext"], maximum: 1_200),
            !ciphertext.isEmpty,
            let tag = Self.base64(envelope["tag"], count: 16),
            let signatureBytes = Self.base64(envelope["signature"], count: 64)
        else { throw LoopdyRelayAlertError.invalidPayload }

        let timestamp = now()
        guard issued <= timestamp + 300, timestamp <= expires else {
            throw LoopdyRelayAlertError.expired
        }
        let senderID = LoopdyNotificationBase64URL.encode(senderKeyID)
        let legacyPin = try senderKeyPins.load()?.key(id: senderID, issuedAt: issued)
        // A managed host key is accepted only for a persisted account-approved
        // recipient and lifetime. Decryption below further binds the grant ID.
        let grants: [LoopdyNotificationHostGrant]
        if legacyPin == nil {
            grants = try hostTrust.load().filter {
                $0.matches(tenantID: tenantID, deviceID: deviceID,
                           senderKeyID: senderID, issuedAt: issued)
                    && timestamp <= $0.expiresAt
            }
        } else {
            grants = []
        }
        guard
            let senderPin = legacyPin ?? grants.first?.senderKey,
            let senderPublicData = LoopdyNotificationBase64URL.decodeCanonical(senderPin.publicKey),
            let senderPublic = try? P256.Signing.PublicKey(x963Representation: senderPublicData)
        else { throw LoopdyRelayAlertError.untrustedSender }
        guard
            let recipientRaw = try recipientKeys.load(),
            let recipientPrivate = try? P256.KeyAgreement.PrivateKey(rawRepresentation: recipientRaw),
            LoopdyNotificationBase64URL.encode(
                Data(SHA256.hash(data: recipientPrivate.publicKey.x963Representation))
            ) == LoopdyNotificationBase64URL.encode(recipientKeyID),
            let ephemeral = try? P256.KeyAgreement.PublicKey(x963Representation: ephemeralPublicKey)
        else { throw LoopdyRelayAlertError.keyUnavailable }

        let aad = [
            "loopdy-relay-alert-aad-v1",
            tenantID,
            deviceID,
            deliveryID,
            LoopdyNotificationBase64URL.encode(eventReference),
            "alert",
            LoopdyNotificationBase64URL.encode(recipientKeyID),
            LoopdyNotificationBase64URL.encode(senderKeyID),
            String(issued),
            String(expires),
        ].joined(separator: "\n").data(using: .utf8)!

        var signatureInput = Data("loopdy-relay-envelope-signature-v1\0".utf8)
        signatureInput.append(Data(SHA256.hash(data: aad)))
        signatureInput.append(ephemeralPublicKey)
        signatureInput.append(salt)
        signatureInput.append(nonce)
        signatureInput.append(Self.bigEndianUInt32(ciphertext.count))
        signatureInput.append(ciphertext)
        signatureInput.append(tag)
        guard
            let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signatureBytes),
            senderPublic.isValidSignature(signature, for: signatureInput)
        else { throw LoopdyRelayAlertError.authenticationFailed }

        do {
            let sharedSecret = try recipientPrivate.sharedSecretFromKeyAgreement(with: ephemeral)
            let info = Data("loopdy-relay-alert-key-v1\0".utf8) + Data(SHA256.hash(data: aad))
            let key = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: salt,
                sharedInfo: info,
                outputByteCount: 32
            )
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce),
                ciphertext: ciphertext,
                tag: tag
            )
            let plaintext = try AES.GCM.open(box, using: key, authenticating: aad)
            let content = try Self.parsePlaintext(
                plaintext,
                expectedEventReference: LoopdyNotificationBase64URL.encode(eventReference)
            )
            if legacyPin != nil { return content }
            let owners = grants.filter {
                $0.authorizes(tenantID: tenantID, deviceID: deviceID,
                              senderKeyID: senderID, issuedAt: issued, eventID: content.eventID,
                              eventType: content.eventType)
            }
            guard owners.count == 1, let grant = owners.first else {
                throw LoopdyRelayAlertError.untrustedSender
            }
            return LoopdyRelayAlertContent(eventID: content.eventID, eventType: content.eventType,
                title: content.title, body: content.body, hostGrant: grant)
        } catch let error as LoopdyRelayAlertError {
            throw error
        } catch {
            throw LoopdyRelayAlertError.authenticationFailed
        }
    }

    private static func parsePlaintext(
        _ data: Data,
        expectedEventReference: String
    ) throws -> LoopdyRelayAlertContent {
        guard data.count <= 1_200, data.prefix(3) == Data("LP1".utf8) else {
            throw LoopdyRelayAlertError.invalidPlaintext
        }
        var cursor = 3
        var fields: [Data] = []
        for _ in 0..<4 {
            guard cursor + 2 <= data.count else {
                throw LoopdyRelayAlertError.invalidPlaintext
            }
            let length = Int(data[cursor]) << 8 | Int(data[cursor + 1])
            cursor += 2
            guard cursor + length <= data.count else {
                throw LoopdyRelayAlertError.invalidPlaintext
            }
            fields.append(data.subdata(in: cursor..<(cursor + length)))
            cursor += length
        }
        guard
            cursor == data.count,
            fields.count == 4,
            let eventID = String(data: fields[0], encoding: .utf8),
            let eventType = String(data: fields[1], encoding: .utf8),
            let title = String(data: fields[2], encoding: .utf8),
            let body = String(data: fields[3], encoding: .utf8),
            identifier(eventID, maximum: 180) != nil,
            identifier(eventType, maximum: 64) != nil,
            fields[2].count <= 120,
            fields[3].count <= 800,
            title.precomposedStringWithCanonicalMapping == title,
            body.precomposedStringWithCanonicalMapping == body,
            LoopdyNotificationBase64URL.encode(Data(SHA256.hash(data: fields[0])))
                == expectedEventReference
        else { throw LoopdyRelayAlertError.invalidPlaintext }
        return LoopdyRelayAlertContent(
            eventID: eventID,
            eventType: eventType,
            title: title,
            body: body
        )
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        if let value = value as? [String: Any] { return value }
        guard let value = value as? NSDictionary else { return nil }
        var result: [String: Any] = [:]
        for (key, entry) in value {
            guard let key = key as? String else { return nil }
            result[key] = entry
        }
        return result
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        guard let number = value as? NSNumber else { return nil }
        let integer = number.intValue
        return number.doubleValue == Double(integer) ? integer : nil
    }

    private static func identifier(_ value: Any?, maximum: Int) -> String? {
        guard
            let value = value as? String,
            (1...maximum).contains(value.count),
            value.first?.isASCII == true,
            value.first?.isLetter == true || value.first?.isNumber == true,
            value.allSatisfy({
                $0.isASCII && ($0.isLetter || $0.isNumber || ".:_-".contains($0))
            })
        else { return nil }
        return value
    }

    private static func base64(
        _ value: Any?,
        count: Int? = nil,
        maximum: Int? = nil
    ) -> Data? {
        guard
            let value = value as? String,
            let decoded = LoopdyNotificationBase64URL.decodeCanonical(value),
            count == nil || decoded.count == count,
            maximum == nil || decoded.count <= maximum!
        else { return nil }
        return decoded
    }

    private static func bigEndianUInt32(_ value: Int) -> Data {
        let number = UInt32(value)
        return Data([
            UInt8((number >> 24) & 0xff),
            UInt8((number >> 16) & 0xff),
            UInt8((number >> 8) & 0xff),
            UInt8(number & 0xff),
        ])
    }
}
