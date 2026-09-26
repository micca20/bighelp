import Foundation
import Testing
@testable import Loopdy

struct LoopdyRelayAlertCryptoTests {
    @Test func decryptedRoutingDiscardsUntrustedOuterNavigationFields() {
        let content = LoopdyRelayAlertContent(eventID: "event-safe", eventType: "approval.required",
            title: "Approval needed", body: "Open Loopdy to review.")
        let routed = LoopdyRelayAlertRouting.userInfo(preserving: [
            "loopdy_session_id": "unrelated-session", "loopdy_agent_id": "other-profile",
            "loopdy_host_id": "unrelated-host", "loopdy_grant_id": "unverified-grant"
        ], decrypted: content)
        #expect(routed["loopdy_session_id"] == nil)
        #expect(routed["loopdy_agent_id"] == nil)
        #expect(routed["loopdy_host_id"] == nil)
        #expect(routed["loopdy_grant_id"] == nil)
        #expect(routed["loopdy_event_id"] as? String == "event-safe")
    }

    @Test func decryptsTheCanonicalRelayVectorOnlyWithPinnedSenderAndRecipientKeys() throws {
        let pins = RelayPinFixture(
            value: LoopdyRelaySenderKeySet(
                revision: 1,
                current: LoopdyRelaySenderKey(
                    keyID: "YX4396SNMKY95u_qpE-qSDLgbBfQAOVJnTxYdswiUIA",
                    publicKey: "BOJTSjUy0I-7oC3eZZ7mK9ADH-LbeFWW71CTAkRrAwhS4PFXWkxjPMcZ3-5f2oYtdk78lsPzDuAFXELCPxhO2MY",
                    state: .current,
                    notBefore: 1_735_689_000,
                    notAfter: 1_735_691_000
                ),
                previous: nil
            )
        )
        let recipients = RecipientKeyFixture(
            value: Data(repeating: 0, count: 31) + Data([2])
        )
        let decryptor = LoopdyRelayAlertDecryptor(
            senderKeyPins: pins,
            recipientKeys: recipients,
            now: { 1_735_689_600 }
        )
        let payload = Self.payload()

        let content = try decryptor.decrypt(userInfo: payload)

        #expect(content.eventID == "approval.required:fixture-event-01")
        #expect(content.eventType == "approval.required")
        #expect(content.title == "Builder needs approval")
        #expect(content.body == "Approve running the test suite?")

        let routed = LoopdyRelayAlertRouting.userInfo(
            preserving: payload,
            decrypted: content
        )
        #expect(routed["loopdy_notification_version"] as? String == "1")
        #expect(routed["loopdy_event_id"] as? String == content.eventID)
        #expect(routed["loopdy_event_type"] as? String == content.eventType)
        #expect(routed["loopdy"] != nil)
        #expect(routed["loopdy_card"] == nil)

        var tampered = payload
        var loopdy = try #require(tampered["loopdy"] as? [String: Any])
        var envelope = try #require(loopdy["envelope"] as? [String: Any])
        envelope["signature"] = String(repeating: "A", count: 86)
        loopdy["envelope"] = envelope
        tampered["loopdy"] = loopdy
        #expect(throws: LoopdyRelayAlertError.self) {
            try decryptor.decrypt(userInfo: tampered)
        }
    }

    private static func payload() -> [AnyHashable: Any] {
        [
            "loopdy": [
                "version": 1,
                "tenant_id": "TENANT_EXAMPLE",
                "device_id": "device_fixture_01",
                "envelope": [
                    "v": 1,
                    "kind": "alert",
                    "delivery_id": "delivery_fixture_0001",
                    "event_ref": "NxBERXAd5KngKRqPZBOzNd8IQBEQ7OfJd1wsa2WYIJQ",
                    "recipient_key_id": "qfMA61lg6JEzr3NiARoeJvDi6i423EAqBK9sGSuJGow",
                    "sender_key_id": "YX4396SNMKY95u_qpE-qSDLgbBfQAOVJnTxYdswiUIA",
                    "issued": 1_735_689_600,
                    "expires": 1_735_690_500,
                    "ephemeral_public_key": "BF7L5NGmMwpEyPfvlR1L8WXmxrch762phftBZhvG5_1shzRkDEmY_343SwbOGmSi7NgqsDY4T7g9mnmxJ6J9UDI",
                    "salt": "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
                    "nonce": "ICEiIyQlJicoKSor",
                    "ciphertext": "X8FbnHbOpNkJIGbdKMm3dF4lyDm3Wu9Mytl4cZXCJh82cp-stXFKXjOaQqkQhs0QB9ldssr6zjiyWBeVWVgRshCkHpmT3JPZFGeOB5E_7O4V8Nn_ycY7BX_y_A8e6NFJpBw_MkKsXJ-gNSwUQS19m7g9uw",
                    "tag": "BWxqfQ6N5c43dOV0i1cR7Q",
                    "signature": "0R0AwmbXNj0j3MqjkH9cGk1uPsyesxAFaLqmIapld_dpNvBj5Pht_dRVRCH3JjAdpbpx7FuFF7SzC2HFk_v7BQ",
                ],
            ],
        ]
    }
}

private final class RelayPinFixture: LoopdyRelaySenderKeyPinStoring {
    let value: LoopdyRelaySenderKeySet

    init(value: LoopdyRelaySenderKeySet) { self.value = value }
    func load() throws -> LoopdyRelaySenderKeySet? { value }
    func save(_ value: LoopdyRelaySenderKeySet) throws { }
}

private final class RecipientKeyFixture: LoopdyNotificationRecipientKeyLoading {
    let value: Data

    init(value: Data) { self.value = value }
    func load() throws -> Data? { value }
}
