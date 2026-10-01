import Foundation
import Testing
import UserNotifications
@testable import Bighelp

/// bighelp's alerts used to stack one per chat, so a busy day left 20 or 30 to
/// clear. They now stack per agent, a chat keeps only its newest reply, and a
/// helper finishing arrives quietly.
struct NotificationGroupingTests {
    @Test func alertsStackPerAgentNotPerChat() {
        let avery = BighelpNotificationGrouping.thread(agentName: "Avery Park")
        #expect(avery == BighelpNotificationGrouping.thread(agentName: "  avery park "))
        #expect(avery != BighelpNotificationGrouping.thread(agentName: "Juno"))
        #expect(avery.hasPrefix("bighelp.agent."))
        #expect(BighelpNotificationGrouping.thread(agentName: nil) == "bighelp")
        #expect(BighelpNotificationGrouping.thread(agentName: "bighelp") == "bighelp")
    }

    @Test func aNewerReplyReplacesTheChatsEarlierOnes() {
        let delivered: [BighelpNotificationGrouping.Delivered] = [
            .init(identifier: "reply-1", chat: "chat-a", eventType: "session.completed"),
            .init(identifier: "failed-1", chat: "chat-a", eventType: "session.failed"),
            .init(identifier: "question", chat: "chat-a", eventType: "clarification.required"),
            .init(identifier: "other-chat", chat: "chat-b", eventType: "session.completed"),
            .init(identifier: "reply-2", chat: "chat-a", eventType: "session.completed"),
        ]
        let old = BighelpNotificationGrouping.superseded(by: "session.completed", chat: "chat-a",
                                                          among: delivered, except: "reply-2")
        #expect(old == ["reply-1", "failed-1"], "A question still waiting and another chat's reply stay")
    }

    @Test func questionsAndApprovalsReplaceNothing() {
        let delivered: [BighelpNotificationGrouping.Delivered] = [
            .init(identifier: "reply-1", chat: "chat-a", eventType: "session.completed"),
        ]
        #expect(BighelpNotificationGrouping.superseded(by: "approval.required", chat: "chat-a",
                                                        among: delivered, except: "approval").isEmpty)
    }

    @Test func aHelperFinishingArrivesQuietly() {
        let helper = UNMutableNotificationContent()
        BighelpNotificationGrouping.apply(to: helper, eventType: "subagent.completed", agentName: "Avery Park")
        #expect(helper.interruptionLevel == .passive)
        #expect(helper.threadIdentifier == BighelpNotificationGrouping.thread(agentName: "Avery Park"))

        let reply = UNMutableNotificationContent()
        reply.interruptionLevel = .active
        BighelpNotificationGrouping.apply(to: reply, eventType: "session.completed", agentName: "Avery Park")
        #expect(reply.interruptionLevel == .active)
        #expect(reply.relevanceScore < 1)

        let question = UNMutableNotificationContent()
        BighelpNotificationGrouping.apply(to: question, eventType: "clarification.required", agentName: "Avery Park")
        #expect(question.relevanceScore == 1)
    }

    @Test func theChatComesFromThePushData() {
        let userInfo: [AnyHashable: Any] = ["loopdy": ["sessionReference": "chat-a", "eventType": "session.completed"]]
        #expect(BighelpNotificationGrouping.chat(of: userInfo) == "chat-a")
        #expect(BighelpNotificationGrouping.eventType(of: userInfo) == "session.completed")
        #expect(BighelpNotificationGrouping.chat(of: ["loopdy": ["sessionReference": ""]]) == nil)
    }
}

/// The Live Activity's progress comes from the phase Hermes reports, never a guess.
struct LiveActivityStepsTests {
    @Test func stepsFollowThePhase() {
        #expect(BighelpActivitySteps.reached(.thinking) == 1)
        #expect(BighelpActivitySteps.reached(.usingTool) == 2)
        #expect(BighelpActivitySteps.reached(.waiting) == 2)
        #expect(BighelpActivitySteps.reached(.responding) == 3)
        #expect(BighelpActivitySteps.reached(.completed) == 4)
        #expect(BighelpActivitySteps.reached(.failed) == 4)
    }
}
