import Foundation

enum ConversationFixtureError: Error {
    case unavailable
}

@MainActor
class ConversationFixtureClient: AttachmentConversationClient {
    private(set) var receivedAttachments: [ChatAttachment] = []
    private var responseSequence = 1
    private let shouldFail: Bool
    private let canonicalAgentID: String
    private let agentSnapshot: TimelineSenderSnapshot

    init(
        shouldFail: Bool = false,
        canonicalAgentID: String = "default",
        agentDisplayName: String = "Assistant",
        agentAvatarFileName: String? = nil
    ) {
        self.shouldFail = shouldFail
        self.canonicalAgentID = canonicalAgentID
        agentSnapshot = TimelineSenderSnapshot(name: agentDisplayName, avatarFileName: agentAvatarFileName)
    }

    func send(message: String, conversationID: String) async throws -> ConversationResponse {
        guard !shouldFail else { throw ConversationFixtureError.unavailable }

        return ConversationResponse(items: [
            assistantItem(
                conversationID: conversationID,
                content: .message("Here’s the latest fixture update. Your priorities are on track, and I’ll keep the plan current as new work arrives.")
            )
        ])
    }

    func send(message: String, attachments: [ChatAttachment], conversationID: String,
              onDraft: @escaping (TimelineItem) -> Void) async throws -> ConversationResponse {
        receivedAttachments = attachments
        if let streaming = self as? any StreamingConversationClient {
            return try await streaming.send(message: message, conversationID: conversationID, onDraft: onDraft)
        }
        return try await send(message: message, conversationID: conversationID)
    }

    func perform(action: QuickAction, conversationID: String) async throws -> ConversationResponse {
        guard !shouldFail else { throw ConversationFixtureError.unavailable }

        let content: TimelineContent = switch action {
        case .weatherAndTasks:
            .weatherAndTasks(ConversationFixtures.weatherAndTasks)
        case .budgetAndPlan:
            .budgetSummary(ConversationFixtures.budgetSummary)
        case .vendorApproval:
            .approvalRequest(.vendorFixture)
        }

        return ConversationResponse(items: [
            assistantItem(conversationID: conversationID, content: content)
        ])
    }

    private func assistantItem(
        conversationID: String,
        content: TimelineContent
    ) -> TimelineItem {
        defer { responseSequence += 1 }
        return TimelineItem(
            id: "fixture-\(conversationID)-response-\(responseSequence)",
            role: .assistant,
            sender: .agent(id: canonicalAgentID, snapshot: agentSnapshot),
            content: content,
            metadata: TimelineMetadata(source: "Loopdy demo data", freshness: "Updated just now")
        )
    }
}

@MainActor
final class MidSessionConversationFixtureClient: ConversationFixtureClient, MidSessionConversationClient {
    func sendMidSession(
        message: String,
        attachments: [ChatAttachment],
        conversationID: String,
        behavior: MidSessionChatBehavior,
        onDraft: @escaping (TimelineItem) -> Void
    ) async throws -> MidSessionSubmissionOutcome {
        .accepted
    }
}

enum ConversationFixtures {
    /// Explicit simulator preview data, never inserted into an authenticated account.
    static var uiV3Preview: SessionRecord {
        let sessionID = "demo-finance"
        let agent = TimelineSender.agent(id: "finance", snapshot: .init(name: "Avery Park"))
        let items = [
            TimelineItem(id: "v3-sample-user-2", role: .human, sender: .user(snapshot: .init(name: "You")),
                         content: .message("A calmer chat, with all of our tools."),
                         metadata: .init(source: "UI preview", sourceOrder: 3)),
            TimelineItem(id: "v3-sample-assistant-2", role: .assistant, sender: agent,
                         content: .message("**Room for the conversation.**\n\nYour model, rich drafts, files, and voice stay close. Project Changes and grouped activity are still right here."),
                         metadata: .init(source: "Sample conversation", sourceOrder: 6))
        ]
        let activity = ["Reviewing layout", "Checking controls"].enumerated().map { index, title in
            ChatActivityEvent(eventID: "v3-sample-tool-\(index)", sessionID: sessionID,
                              turnID: "v3-sample-turn", kind: .tool, lifecycle: .succeeded,
                              title: title, summary: "Sample completed activity", detail: nil,
                              occurredAt: 4 + index, toolCallID: "v3-sample-call-\(index)",
                              toolName: "preview_check", arguments: "{\"sample\":true}",
                              result: "{\"sample\":true}", sourceOrder: 4 + index)
        }
        return SessionRecord(id: sessionID, kind: .direct, agentIDs: ["finance"], title: "UI V3 Preview",
                             workspaceID: "demo-loopdy", workspaceName: "Loopdy",
                             sessionRuntime: .init(model: "gpt-5.6", provider: "openai", observedAt: Date()),
                             items: items, activityEvents: activity, hasAcceptedMessage: true)
    }

    #if DEBUG
    static var nativeReactionPreview: SessionRecord {
        let agent = TimelineSender.agent(id: "finance", snapshot: .init(name: "Avery Park"))
        let items = [
            TimelineItem(id: "native-reaction-fixture:row:101", role: .human,
                         sender: .user(snapshot: .init(name: "You")),
                         content: .message("A calmer chat, with all of our tools."),
                         metadata: .init(source: "UI preview", sourceOrder: 1)),
            TimelineItem(id: "native-reaction-fixture:row:102", role: .assistant,
                         sender: agent,
                         content: .message("**Room for the conversation.**\n\nYour model, rich drafts, files, and voice stay close."),
                         metadata: .init(source: "UI preview", sourceOrder: 2)),
        ]
        return SessionRecord(
            id: "demo-finance",
            kind: .direct,
            agentIDs: ["finance"],
            title: "Reaction interaction preview",
            workspaceID: "demo-loopdy",
            workspaceName: "Loopdy",
            sessionRuntime: .init(model: "gpt-5.6", provider: "openai", observedAt: Date()),
            items: items,
            hasAcceptedMessage: true
        )
    }

    static var simpleChatPreview: SessionRecord {
        let agent = TimelineSender.agent(id: "finance", snapshot: .init(name: "Avery Park"))
        let now = Date()
        let entries: [(String, TimelineRole, String)] = [
            ("simple-welcome", .assistant, "Hey there! I’m Avery.\nI can help you brainstorm ideas, plan your day, answer questions, and more."),
            ("simple-question", .human, "Can you help me plan a 3-day trip to Kyoto?"),
            ("simple-answer", .assistant, "Absolutely! Here’s a high-level itinerary for a 3-day trip to Kyoto, with a mix of culture, food, and hidden gems."),
            ("simple-followup", .human, "This is perfect! Can you add a few local food spots?")
        ]
        let items = entries.enumerated().map { index, entry in
            TimelineItem(id: entry.0, role: entry.1,
                sender: entry.1 == .assistant ? agent : .user(snapshot: .init(name: "You")),
                content: .message(entry.2),
                metadata: .init(source: "UI preview", timestamp: now.addingTimeInterval(Double(index - 3) * 60), sourceOrder: index))
        }
        return SessionRecord(id: "demo-finance", kind: .direct, agentIDs: ["finance"], title: "Kyoto trip",
            workspaceID: "demo-loopdy", workspaceName: "Loopdy",
            sessionContext: .init(sessionId: "demo-finance", model: "gpt-5.6", contextUsed: 29100,
                contextMax: 1000000, contextPercent: 3, compressions: 0, isCompacting: false,
                updatedAt: Int(now.timeIntervalSince1970)),
            sessionRuntime: .init(model: "gpt-5.6", provider: "openai", observedAt: now),
            items: items, hasAcceptedMessage: true)
    }
    #endif

    #if DEBUG
    static var toolDisclosureScrollPreview: SessionRecord {
        var session = uiV3Preview
        session.items += (0..<8).map { index in
            TimelineItem(id: "tool-review-history-\(index)", role: .assistant,
                sender: .agent(id: "finance", snapshot: .init(name: "Avery Park")),
                content: .message(String(repeating: "History \(index) after the completed tool.\n", count: 4)),
                metadata: .init(source: "UI fixture", sourceOrder: 10 + index))
        }
        return session
    }

    static var completedTurnContextPreview: SessionRecord {
        let sessionID = "demo-finance"
        let agent = TimelineSender.agent(id: "finance", snapshot: .init(name: "Avery Park"))
        let messages: [(String, String, Int)] = [
            ("fold-preamble", "I checked the release options.", 2),
            ("fold-context", "TestFlight keeps this build private. Public release makes it available to everyone.", 4),
            ("fold-answer", "The compatibility flag must stay enabled for existing clients.", 6),
            ("fold-verification", "Verification confirmed that recommendation.", 8),
        ]
        let items = [TimelineItem(id: "fold-user", role: .human, sender: .user(snapshot: .init(name: "You")),
                                  content: .message("Review the release options."), metadata: .init(sourceOrder: 1))]
            + messages.map { id, text, order in
                TimelineItem(id: id, role: .assistant, sender: agent, content: .message(text),
                             metadata: .init(sourceOrder: order, turnDurationMilliseconds: order == 8 ? 10_000 : nil))
            }
        let activity = [("fold-inspection", "Inspecting release", 3), ("fold-verifier", "Verifying compatibility", 7)].map { id, title, order in
            ChatActivityEvent(eventID: id, sessionID: sessionID, turnID: "fold-preview-turn",
                              kind: .tool, lifecycle: .succeeded, title: title, summary: "Completed", detail: nil,
                              occurredAt: order, toolCallID: "call-\(id)", toolName: "preview_check",
                              arguments: "{\"preview\":true}", result: "Verified preview", sourceOrder: order)
        }
        return SessionRecord(id: sessionID, kind: .direct, agentIDs: ["finance"], title: "Completed Turn Context",
                             items: items, activityEvents: activity,
                             activityVisibility: .init(showReasoning: true, showToolCalls: true), hasAcceptedMessage: true)
    }
    #endif

    static func initialItems(
        conversationID: String,
        agentID: String = "default",
        agentName: String = "Assistant",
        agentAvatarFileName: String? = nil
    ) -> [TimelineItem] {
        let sender = TimelineSender.agent(
            id: agentID,
            snapshot: .init(name: agentName, avatarFileName: agentAvatarFileName)
        )
        return [
            TimelineItem(
                id: "fixture-\(conversationID)-welcome",
                role: .assistant,
                sender: sender,
                content: .message("Good morning. I’ve gathered your fixture priorities, spending, and schedule in one place."),
                metadata: TimelineMetadata(source: "Loopdy demo data", freshness: "Updated 2 min ago")
            ),
            TimelineItem(
                id: "fixture-\(conversationID)-budget",
                role: .assistant,
                sender: sender,
                content: .budgetSummary(budgetSummary),
                metadata: TimelineMetadata(source: "Demo finance workspace", freshness: "Updated 2 min ago")
            )
        ]
    }

    static func weatherFixture(senderID: String) -> TimelineItem {
        TimelineItem(
            id: "fixture-weather-\(senderID)",
            role: .assistant,
            sender: .agent(id: senderID, snapshot: .init(name: "Assistant")),
            content: .weatherAndTasks(weatherAndTasks),
            metadata: .init(source: "Loopdy demo data", freshness: "Updated just now")
        )
    }

    static let budgetSummary = BudgetSummary(
        period: "August 2026",
        spent: "$6,320",
        budget: "$9,500",
        remaining: "$3,180 remaining",
        percentUsed: 67,
        plan: [
            PlanItem(
                id: "plan-finance-review",
                title: "Review vendor payment",
                detail: "Confirm the Acme Software invoice before its due date.",
                time: "9:30 AM"
            ),
            PlanItem(
                id: "plan-focus-block",
                title: "Protect focus time",
                detail: "Keep the afternoon clear for the quarterly brief.",
                time: "1:00 PM"
            ),
            PlanItem(
                id: "plan-weekly-wrap",
                title: "Weekly wrap-up",
                detail: "Send the completed-items summary to your team.",
                time: "4:30 PM"
            )
        ]
    )

    static let weatherAndTasks = WeatherAndTasks(
        city: "San Francisco",
        condition: "Sunny",
        currentTemperature: 61,
        highTemperature: 65,
        lowTemperature: 52,
        hourly: [
            HourlyWeather(id: "weather-now", time: "Now", condition: "Sunny", temperature: 61, systemImage: "sun.max.fill"),
            HourlyWeather(id: "weather-10", time: "10 AM", condition: "Sunny", temperature: 62, systemImage: "sun.max.fill"),
            HourlyWeather(id: "weather-12", time: "12 PM", condition: "Sunny", temperature: 64, systemImage: "sun.max.fill"),
            HourlyWeather(id: "weather-2", time: "2 PM", condition: "Sunny", temperature: 65, systemImage: "sun.max.fill")
        ],
        tasks: [
            PrioritizedTask(
                id: "task-payment",
                priority: "Important",
                title: "Review Acme Software payment",
                detail: "Invoice #INV-04521 is ready for your decision."
            ),
            PrioritizedTask(
                id: "task-brief",
                priority: "Next",
                title: "Finish quarterly brief",
                detail: "Your protected focus block begins at 1:00 PM."
            ),
            PrioritizedTask(
                id: "task-follow-up",
                priority: "Later",
                title: "Send team follow-up",
                detail: "Share the completed-items summary before 5:00 PM."
            )
        ]
    )
}

extension ApprovalRequest {
    static let vendorFixture = ApprovalRequest(
        id: "approval-acme-inv-04521",
        action: "Pay vendor invoice",
        requester: "Finance Agent",
        vendor: "Acme Software",
        amount: "$4,850.00 USD",
        dueDate: "May 15, 2025",
        category: "Software & Tools",
        sourceInvoice: "#INV-04521",
        consequence: "Approving schedules the payment and records it against the Software & Tools budget."
    )
}
