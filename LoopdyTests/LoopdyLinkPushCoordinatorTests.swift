import Foundation
import Testing
import XCTest
@testable import Loopdy

@MainActor
struct LoopdyLinkPushCoordinatorTests {
    @Test func earlyAPNSFailureReplaysOnceOnInstall() {
        let center = LoopdyAPNSTokenHookCenter()
        var failures = 0
        center.receiveFailure(URLError(.notConnectedToInternet))
        center.installFailure { _ in failures += 1 }
        #expect(failures == 1)
        center.installFailure { _ in failures += 1 }
        #expect(failures == 1)
    }

    @Test func wakeWithoutHandlerReportsFailureButInstalledHandlerDoesNot() async {
        let center = LoopdyLinkWakeCenter()
        let payload: [AnyHashable: Any] = [
            "aps": ["content-available": 1],
            "loopdy_link": ["version": 2, "type": "wake", "frameId": "fixture_frame_0001"]
        ]
        #expect(await center.receive(payload) == .failed)
        center.install { false }
        #expect(await center.receive(payload) == .noData)
    }

    @Test func earlyAPNSTokenReplaysLatestExactBytesOnlyOnce() {
        let center = LoopdyAPNSTokenHookCenter()
        var received: [Data] = []
        center.receive(Data([0, 1, 128, 255]))
        let latest = Data([255, 0, 129, 42, 10])
        center.receive(latest)
        center.install { received.append($0) }
        #expect(received == [latest])
        center.install { received.append($0) }
        #expect(received == [latest])
    }

    @Test func installedAPNSHookReceivesEachExactTokenSynchronously() {
        let center = LoopdyAPNSTokenHookCenter()
        var received: [Data] = []
        center.install { received.append($0) }
        let token = Data([0, 255, 128, 1, 10])
        center.receive(token)
        #expect(received == [token])
        let rotated = Data([255, 0, 1])
        center.receive(rotated)
        #expect(received == [token, rotated])
    }

    @Test func acceptsOnlyTheContentFreeLoopdyLinkBackgroundWakeMarker() {
        let backgroundPayloadIsWake = LoopdyBuzzKitWakePayload.isWake([
            "aps": ["content-available": 1],
            "loopdy_link": ["version": 2, "type": "wake", "frameId": "fixture_frame_0001"]
        ])
        let alertPayloadIsWake = LoopdyBuzzKitWakePayload.isWake([
            "aps": ["alert": ["body": "private text"]],
            "loopdy_link": ["version": 2, "type": "wake", "frameId": "fixture_frame_0001"]
        ])
        let wrongMarkerIsWake = LoopdyBuzzKitWakePayload.isWake([
            "aps": ["content-available": 1],
            "loopdy_link": ["version": 1, "type": "message"]
        ])
        #expect(backgroundPayloadIsWake)
        #expect(alertPayloadIsWake == false)
        #expect(wrongMarkerIsWake == false)
    }

    @Test func notificationParsersPreserveFoundationBridgingPolicy() {
        let grant = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let cases: [(Any?, Bool)] = [
            (2, true), (NSNumber(value: 2.0), true), (NSNumber(value: 2.5), false),
            (NSNumber(value: true), false), ("2", false), (NSNull(), false), (nil, false),
            (NSNumber(value: Double.infinity), false), (NSNumber(value: Double.nan), false)
        ]
        for (version, accepted) in cases {
            var open: [String: Any] = ["eventId": grant + ":" + String(repeating: "a", count: 64),
                                       "eventType": "channel.message", "grantId": grant]
            var wake: [String: Any] = ["type": "wake", "frameId": "fixture_frame_0001"]
            open["version"] = version
            wake["version"] = version
            for foundationDictionary in [false, true] {
                let openPayload: Any = foundationDictionary ? open as NSDictionary : open
                let wakePayload: Any = foundationDictionary ? wake as NSDictionary : wake
                #expect((LoopdyProactiveNotificationOpen(userInfo: ["loopdy": openPayload]) != nil) == accepted)
                #expect(LoopdyBuzzKitWakePayload.isWake([
                    "aps": ["content-available": NSNumber(value: true)] as NSDictionary,
                    "loopdy_link": wakePayload
                ]) == accepted)
            }
        }
        let mixedKeys: NSDictionary = [1: "not a string key", "version": 2,
                                      "eventId": grant + ":" + String(repeating: "a", count: 64),
                                      "eventType": "channel.message", "grantId": grant,
                                      "type": "wake", "frameId": "fixture_frame_0001"]
        let openAcceptsMixedKeys = LoopdyProactiveNotificationOpen(userInfo: ["loopdy": mixedKeys]) != nil
        let wakeAcceptsMixedKeys = LoopdyBuzzKitWakePayload.isWake([
            "aps": ["content-available": 1], "loopdy_link": mixedKeys
        ])
        #expect(!openAcceptsMixedKeys)
        #expect(!wakeAcceptsMixedKeys)
    }

    @Test func wakeCenterStartsAndDrainsLinkBeforeCompletingBackgroundFetch() async {
        let center = LoopdyLinkWakeCenter()
        var wakeCount = 0
        center.install {
            wakeCount += 1
            return true
        }

        let result = await center.receive([
            "aps": ["content-available": 1],
            "loopdy_link": ["version": 2, "type": "wake", "frameId": "fixture_frame_0001"]
        ])

        #expect(result == .newData)
        #expect(wakeCount == 1)
        #expect(await center.receive(["aps": ["content-available": 1]]) == .noData)
        #expect(wakeCount == 1)
    }

    @Test func decryptedNotificationProjectsToAnIdempotentNativeRequestAndTapRoute() throws {
        let event = try JSONDecoder().decode(
            LoopdyLinkNotificationEvent.self,
            from: Data(
                """
                {
                  "version": 1,
                  "type": "notification.event",
                  "eventId": "channel.message:fixture_0001",
                  "eventType": "channel.message",
                  "agentId": "default",
                  "agentName": "Juno",
                  "sessionId": "session_fixture_0001",
                  "title": "Juno just messaged you!",
                  "body": "The forecast is ready.",
                  "sentAt": 1788000001
                }
                """.utf8
            )
        )

        let request = try #require(LoopdyProactiveNotificationRequest(event: event))

        #expect(request.identifier == event.eventID)
        #expect(request.title == event.title)
        #expect(request.body == event.body)
        #expect(request.threadIdentifier == event.sessionID)
        #expect(request.categoryIdentifier == "LOOPDY_AGENT_UPDATE")
        #expect(request.userInfo["loopdy_event_id"] == event.eventID)
        #expect(request.userInfo["loopdy_session_id"] == event.sessionID)
        #expect(request.userInfo["loopdy_agent_id"] == event.agentID)
        #expect(LoopdyProactiveNotificationOpen(userInfo: request.userInfo)?.eventID == event.eventID)
        #expect(LoopdyProactiveNotificationOpen(userInfo: request.userInfo)?.eventType == event.eventType)
        #expect(LoopdyProactiveNotificationOpen(userInfo: [:]) == nil)
    }

    @Test func lifecycleNoiseCannotBecomeLocalBannersButInboxClarifyAndApprovalCan() throws {
        let lifecycle = try JSONDecoder().decode(
            LoopdyLinkNotificationEvent.self,
            from: Data(
                """
                {
                  "version": 1,
                  "type": "notification.event",
                  "eventId": "job.completed:fixture_0001",
                  "eventType": "job.completed",
                  "agentId": "default",
                  "agentName": "Juno",
                  "title": "Scheduled task completed",
                  "body": "From Juno",
                  "sentAt": 1788000001
                }
                """.utf8
            )
        )
        let message = try JSONDecoder().decode(
            LoopdyLinkNotificationEvent.self,
            from: Data(
                """
                {
                  "version": 1,
                  "type": "notification.event",
                  "eventId": "channel.message:fixture_0002",
                  "eventType": "channel.message",
                  "agentId": "default",
                  "agentName": "Juno",
                  "title": "Morning weather",
                  "body": "Rain starts at 3 PM",
                  "sentAt": 1788000002
                }
                """.utf8
            )
        )
        let clarification = try JSONDecoder().decode(
            LoopdyLinkNotificationEvent.self,
            from: Data(
                """
                {
                  "version": 1,
                  "type": "notification.event",
                  "eventId": "attention.required:clarify_0001",
                  "eventType": "attention.required",
                  "agentId": "default",
                  "agentName": "Juno",
                  "sessionId": "session_fixture_0001",
                  "title": "Clarification needed",
                  "body": "Which environment should I deploy to?",
                  "sentAt": 1788000003
                }
                """.utf8
            )
        )
        let approval = try JSONDecoder().decode(
            LoopdyLinkNotificationEvent.self,
            from: Data(
                """
                {
                  "version": 1,
                  "type": "notification.event",
                  "eventId": "approval.required:approval_0001",
                  "eventType": "approval.required",
                  "agentId": "default",
                  "agentName": "Juno",
                  "sessionId": "session_fixture_0001",
                  "title": "Approval requested",
                  "body": "Restart the Hermes gateway",
                  "sentAt": 1788000004
                }
                """.utf8
            )
        )

        let lifecycleRequest: LoopdyProactiveNotificationRequest? =
            LoopdyProactiveNotificationRequest(event: lifecycle)
        let messageRequest: LoopdyProactiveNotificationRequest? =
            LoopdyProactiveNotificationRequest(event: message)
        let clarificationRequest = LoopdyProactiveNotificationRequest(event: clarification)
        let approvalRequest = LoopdyProactiveNotificationRequest(event: approval)

        #expect(lifecycleRequest == nil)
        #expect(messageRequest?.identifier == "channel.message:fixture_0002")
        #expect(clarificationRequest?.identifier == "attention.required:clarify_0001")
        #expect(approvalRequest?.identifier == "approval.required:approval_0001")
    }

    @Test func operationalGatewayChannelMessagesCannotBecomeLocalBanners() throws {
        let event = try JSONDecoder().decode(
            LoopdyLinkNotificationEvent.self,
            from: Data(
                """
                {
                  "version": 1,
                  "type": "notification.event",
                  "eventId": "channel.message:gateway-restart",
                  "eventType": "channel.message",
                  "agentId": "default",
                  "agentName": "Juno",
                  "title": "Gateway status",
                  "body": "♻️ Gateway restarted — current work will resume.",
                  "sentAt": 1788000002
                }
                """.utf8
            )
        )

        #expect(LoopdyProactiveNotificationRequest(event: event) == nil)
    }

    @Test func notificationTapCenterOpensOnlyValidatedLoopdyInboxEvents() async {
        let center = LoopdyProactiveNotificationOpenCenter()
        var opened: [LoopdyProactiveNotificationOpen] = []
        center.install { opened.append($0) }
        await center.activate()

        await center.receive([
            "loopdy_notification_version": "1",
            "loopdy_event_id": "channel.message:fixture_0001",
            "loopdy_agent_id": "default",
            "loopdy_session_id": "session_fixture_0001",
        ])
        await center.receive(["loopdy_event_id": "untrusted"])

        #expect(opened.map(\.eventID) == ["channel.message:fixture_0001"])
        #expect(opened.map(\.sessionID) == ["session_fixture_0001"])
    }

    @Test func retiredSchemaV1RelayDeepLinkIsRejected() {
        let open = LoopdyProactiveNotificationOpen(userInfo: [
            "aps": ["alert": ["title": "Generic", "body": "Open Loopdy"]],
            "loopdy": [
                "schema_version": 1,
                "event_id": "channel.message:fixture_0002",
                "type": "channel.message",
                "deep_link": "loopdy:///dashboard?eventId=channel.message%3Afixture_0002",
            ],
        ])

        #expect(open == nil)
    }

    @Test func managedColdLaunchUsesOnlyManagedHandlerAndPreservesExactCoordinates() async throws {
        let center = LoopdyProactiveNotificationOpenCenter()
        let grant = "11111111-1111-4111-8111-111111111111"
        let event = grant + ":" + String(repeating: "a", count: 64)
        var local: [LoopdyProactiveNotificationOpen] = []
        var managed: [LoopdyProactiveNotificationOpen] = []
        center.install { local.append($0) }
        center.installManaged { managed.append($0) }
        let payload: [AnyHashable: Any] = ["loopdy": [
            "version": 2, "eventId": event, "eventType": "session.completed", "grantId": grant
        ]]
        await center.receive(payload)
        #expect(managed.isEmpty)
        await center.activate()
        await center.activate()
        #expect(local.isEmpty)
        #expect(managed.map(\.eventID) == [event])
        #expect(managed.map(\.hostGrantID) == [grant])
        #expect(managed.map(\.eventType) == ["session.completed"])
        #expect(managed.map(\.sessionID) == [nil])
    }

    @Test func malformedManagedPayloadsCannotFallBackToLocalRouting() async {
        let center = LoopdyProactiveNotificationOpenCenter()
        var opened: [LoopdyProactiveNotificationOpen] = []
        center.install { opened.append($0) }
        center.installManaged { opened.append($0) }
        await center.activate()
        let grant = "11111111-1111-4111-8111-111111111111"
        let event = grant + ":" + String(repeating: "a", count: 64)
        let valid: [String: Any] = ["version": 2, "eventId": event,
                                  "eventType": "session.completed", "grantId": grant]
        for (field, invalid) in [("version", 1 as Any), ("grantId", "other" as Any),
                                 ("eventId", event + "a" as Any),
                                 ("eventId", grant + ":" + String(repeating: "A", count: 64) as Any),
                                 ("eventType", "unknown.event" as Any)] {
            var payload = valid
            payload[field] = invalid
            await center.receive(["loopdy": payload] as [AnyHashable: Any])
        }
        for field in ["version", "grantId", "eventId", "eventType"] {
            var payload = valid
            payload.removeValue(forKey: field)
            await center.receive(["loopdy": payload] as [AnyHashable: Any])
        }
        #expect(opened.isEmpty)
    }

    @Test func coldLaunchTapWaitsForRootActivationInsteadOfBeingDiscarded() async {
        let center = LoopdyProactiveNotificationOpenCenter()
        var opened: [String] = []

        await center.receive([
            "loopdy_notification_version": "1",
            "loopdy_event_id": "channel.message:cold-launch",
            "loopdy_agent_id": "default",
        ])
        center.install { opened.append($0.eventID) }

        #expect(opened.isEmpty)
        await center.activate()
        #expect(opened == ["channel.message:cold-launch"])
    }

    private static let phone = LoopdyLinkDevice(
        id: "phone-1",
        name: "This iPhone",
        kind: .phone,
        isCurrentDevice: true,
        connection: .online,
        pushState: nil,
        pushRevision: 4,
        lastSeenAt: Date(timeIntervalSince1970: 1_788_000_000),
        revision: 1
    )
}

@MainActor
final class NotificationDelegateAPNSTapTests: XCTestCase {
    func testNotificationDelegateRoutesManagedV2AndRejectsRetiredRelay() async {
        let grant = "11111111-1111-4111-8111-111111111111"
        let event = grant + ":" + String(repeating: "a", count: 64)
        var opened: [LoopdyProactiveNotificationOpen] = []
        var local: [LoopdyProactiveNotificationOpen] = []
        LoopdyProactiveNotificationOpenCenter.shared.install { local.append($0) }
        LoopdyProactiveNotificationOpenCenter.shared.installManaged { opened.append($0) }
        await LoopdyProactiveNotificationOpenCenter.shared.activate()

        let delegate = LoopdyLinkApplicationDelegate()
        await delegate.receiveNotificationTap(userInfo: [
            "aps": ["alert": ["title": "Generic", "body": "Open Loopdy"]],
            "loopdy": ["version": 2, "eventId": event,
                       "eventType": "session.completed", "grantId": grant],
        ])
        await delegate.receiveNotificationTap(userInfo: [
            "aps": ["alert": ["title": "Generic", "body": "Open Loopdy"]],
            "loopdy": [
                "schema_version": 1,
                "event_id": "channel.message:delegate-tap",
                "type": "channel.message",
                "deep_link": "loopdy:///dashboard?eventId=channel.message%3Adelegate-tap",
            ],
        ])
        XCTAssertEqual(opened.map(\.eventID), [event])
        XCTAssertEqual(opened.map(\.hostGrantID), [grant])
        XCTAssertEqual(opened.map(\.eventType), ["session.completed"])
        XCTAssertEqual(opened.map(\.sessionID), [nil])
        XCTAssertTrue(local.isEmpty)
    }
}
