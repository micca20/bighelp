import Foundation
import SwiftUI
import UIKit
import Testing
@testable import Bighelp

@MainActor
struct ChatAttributionTests {
    @Test func v3WorkTrailUsesTheExactV2Rendering() throws {
        let event = ChatActivityEvent(eventID: "style-tool", sessionID: "style-session", turnID: "style-turn",
            kind: .tool, lifecycle: .succeeded, title: "Read file", summary: "Complete", detail: nil, occurredAt: 1)
        func render(v3: Bool) throws -> Data {
            let renderer = ImageRenderer(content: ChatWorkTrailCard(turn: .init(id: "style-turn", events: [event]))
                .frame(width: 320)
                .environment(\.bighelpUIV2Enabled, true)
                .environment(\.bighelpUIV3Enabled, v3)
                .environment(\.colorScheme, .light))
            return try #require(renderer.uiImage?.pngData())
        }
        let identical = try render(v3: false) == render(v3: true)
        #expect(identical, "V3 must reuse V2's actual grouped tool-call rendering")
    }

    @Test func messageMetadataShowsOnlyThePersistedLocalDateAndTime() throws {
        let timestamp = Date(timeIntervalSince1970: 1_788_332_940)
        let metadata = TimelineMetadata(
            source: "Hermes · loopdy",
            freshness: "Just now",
            delivery: "Saved",
            timestamp: timestamp
        )
        let timeZone = try #require(TimeZone(identifier: "America/Chicago"))
        let label = try #require(TimelineMetadataPresentation.timestampLabel(
            for: metadata,
            locale: Locale(identifier: "en_US"),
            timeZone: timeZone
        ))

        #expect(label.contains("2026"))
        #expect(label.contains(":"))
        #expect(!label.contains("Source"))
        #expect(!label.contains("Hermes"))
        #expect(!label.contains("Saved"))
    }

    @Test func messageTimestampSurvivesTimelinePersistence() throws {
        let timestamp = Date(timeIntervalSince1970: 1_788_332_940)
        let item = TimelineItem(
            id: "persisted-time",
            role: .assistant,
            sender: .agent(id: "juno", snapshot: .init(name: "Juno")),
            content: .message("Retain the original landing time."),
            metadata: .init(timestamp: timestamp)
        )

        let restored = try JSONDecoder().decode(
            TimelineItem.self,
            from: JSONEncoder().encode(item)
        )

        #expect(restored.metadata.timestamp == timestamp)
    }

    @Test func legacyMetadataWithoutTimestampStillDecodes() throws {
        let data = Data(
            #"{"source":"Hermes","freshness":"Saved","delivery":"Saved","sourceOrder":4}"#.utf8
        )

        let restored = try JSONDecoder().decode(TimelineMetadata.self, from: data)

        #expect(restored.timestamp == nil)
        #expect(restored.source == "Hermes")
        #expect(restored.delivery == "Saved")
        #expect(restored.sourceOrder == 4)
    }

    @Test func turnsCarryStableSenderIdentity() async {
        let model = ChatModel(
            conversationID: "attribution",
            client: ConversationFixtureClient(canonicalAgentID: "finance"),
            userIdentity: UserIdentity(name: "Alex", avatarFileName: "alex.jpg"),
            agentID: "finance",
            initialItems: []
        )
        model.draft = "Hello"

        await model.send()

        #expect(model.items.first(where: { $0.role == .human })?.sender.id == UserIdentity.stableID)
        #expect(model.items.first(where: { $0.role == .human })?.sender.snapshot.name == "Alex")
        #expect(model.items.first(where: { $0.role == .assistant })?.sender.id == "finance")
    }

    @Test func mismatchedAssistantSenderIsNotAcceptedIntoTheSessionTimeline() async {
        let model = ChatModel(
            conversationID: "mismatched-agent",
            client: ConversationFixtureClient(),
            agentID: "finance",
            initialItems: []
        )
        model.draft = "Hello"

        await model.send()

        #expect(model.items.map(\.role) == [.human])
        #expect(model.failureMessage == "Response identities conflict with this conversation. Try once more.")
    }

    @Test func generatedCardRemainsOneAttributedTurn() async {
        let model = ChatModel(
            conversationID: "weather",
            client: ConversationFixtureClient(canonicalAgentID: "finance"),
            agentID: "finance",
            initialItems: []
        )

        await model.perform(.weatherAndTasks)

        #expect(model.items.map(\.id) == ["weather-human-1", "fixture-weather-response-1"])
        #expect(model.items.last?.sender.id == "finance")
        #expect(model.items.last?.content.kind == .weatherAndTasks)
    }

    @Test func financeChatInitialFixturesUseTheSessionCanonicalAgentID() {
        let model = ChatModel(
            conversationID: "finance-initial",
            client: ConversationFixtureClient(canonicalAgentID: "finance"),
            agentID: "finance"
        )

        #expect(model.items.map(\.sender.id) == ["finance", "finance"])
        #expect(model.items.map(\.role) == [.assistant, .assistant])
    }

    @Test func currentIdentityResolvesByStableIDAndSnapshotSurvivesMissingIdentity() async throws {
        let defaults = isolatedDefaults()
        let user = UserIdentityStore(defaults: defaults)
        user.identity = UserIdentity(name: "Alex Current", avatarFileName: "alex.png")
        let agents = AgentDirectoryStore(
            client: AgentDirectoryFixtureClient(profiles: [.financeFixture]),
            defaults: defaults
        )
        try await agents.load()
        let resolver = TimelineSenderResolver(userIdentity: user, agents: agents)
        let sender = TimelineSender.agent(
            id: "finance",
            snapshot: TimelineSenderSnapshot(name: "Finance then", avatarFileName: "then.png")
        )

        #expect(resolver.display(for: sender).name == AgentProfile.financeFixture.name)

        let unavailable = TimelineSender.agent(
            id: "deleted-agent",
            snapshot: TimelineSenderSnapshot(name: "Former agent", avatarFileName: "former.png")
        )
        #expect(resolver.display(for: unavailable).name == "Former agent")
        #expect(resolver.display(for: unavailable).imageURL == nil)
    }

    @Test func profileEditsPropagateToHistoricalTurnsWithoutChangingTheirIdentity() {
        let defaults = isolatedDefaults()
        let user = UserIdentityStore(defaults: defaults)
        let item = TimelineItem(
            id: "historic-user-turn",
            role: .human,
            sender: .user(snapshot: .init(name: "Original name", avatarFileName: "original.png")),
            content: .message("Keep this turn"),
            metadata: .init()
        )
        let resolver = TimelineSenderResolver(userIdentity: user)

        user.identity = UserIdentity(name: "Edited name", avatarFileName: "edited.png")

        #expect(item.id == "historic-user-turn")
        #expect(item.sender.id == UserIdentity.stableID)
        #expect(item.sender.snapshot.name == "Original name")
        #expect(resolver.display(for: item.sender).name == "Edited name")
    }

    @Test func senderMetadataRoundTripsAndSenderlessItemRequiresSessionMigration() throws {
        let item = TimelineItem(
            id: "one",
            role: .assistant,
            sender: .agent(id: "finance", snapshot: .init(name: "Finance", avatarFileName: "finance.png")),
            content: .message("Update"),
            metadata: .init()
        )
        let data = try JSONEncoder().encode(item)
        let restored = try JSONDecoder().decode(TimelineItem.self, from: data)
        let legacyData = Data(#"{"id":"legacy","role":"human","content":{"message":"Retained"},"metadata":{}}"#.utf8)

        #expect(restored.sender == item.sender)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TimelineItem.self, from: legacyData)
        }
    }

    @Test func financeSessionMigratesLegacyAssistantToItsCanonicalAgentWithoutChangingTimelineCoordinates() throws {
        let record = try JSONDecoder().decode(
            SessionRecord.self,
            from: Data(#"{"id":"legacy-finance","kind":"direct","agentIDs":["finance"],"title":"Finance","draft":"","items":[{"id":"legacy-assistant","role":"assistant","content":{"message":"Retained assistant"},"metadata":{}}],"createdAt":0,"updatedAt":0,"hasAcceptedMessage":true}"#.utf8)
        )

        #expect(record.items.map(\.id) == ["legacy-assistant"])
        #expect(record.items.map(\.content) == [.message("Retained assistant")])
        #expect(record.items.first?.sender == .agent(id: "finance", snapshot: .init(name: "Assistant")))
    }

    @Test func legacyAssistantWithoutCanonicalAgentBecomesExplicitUnknownSystemSender() throws {
        let record = try JSONDecoder().decode(
            SessionRecord.self,
            from: Data(#"{"id":"legacy-unknown","kind":"direct","agentIDs":[],"title":"Unknown","draft":"","items":[{"id":"legacy-assistant","role":"assistant","content":{"message":"Retained assistant"},"metadata":{}}],"createdAt":0,"updatedAt":0,"hasAcceptedMessage":true}"#.utf8)
        )

        #expect(record.items.first?.sender == TimelineSender(
            id: "unknown-sender",
            kind: .system,
            snapshot: .init(name: "Unknown sender")
        ))
    }

    @Test func unavailableAgentUsesOnlyASafeSnapshotAvatarPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "BighelpAttributionTests")
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let agents = AgentDirectoryStore(
            client: AgentDirectoryFixtureClient(profiles: []),
            defaults: isolatedDefaults(),
            avatarDirectory: directory
        )
        let resolver = TimelineSenderResolver(agents: agents)
        let safe = TimelineSender.agent(
            id: "missing",
            snapshot: .init(name: "Former agent", avatarFileName: "former.png")
        )
        let unsafe = TimelineSender.agent(
            id: "missing",
            snapshot: .init(name: "Former agent", avatarFileName: "../outside.png")
        )

        #expect(resolver.display(for: safe).imageURL == directory.appending(path: "former.png"))
        #expect(resolver.display(for: unsafe).imageURL == nil)
    }

    @Test func accessibleSpeakerCopyUsesResolvedName() {
        let item = TimelineItem(
            id: "spoken",
            role: .assistant,
            sender: .agent(id: "finance", snapshot: .init(name: "Finance snapshot")),
            content: .message("Budget is ready."),
            metadata: .init()
        )
        let resolver = TimelineSenderResolver()

        #expect(resolver.accessibilityDescription(for: item) == "Finance snapshot: Budget is ready.")
    }
}

struct ChatMessagePresentationTests {
    @Test func toolActivityDisclosureAnnouncesItsExpandedState() {
        #expect(ChatActivityDisclosureAccessibility.value(isExpanded: false) == "Collapsed")
        #expect(ChatActivityDisclosureAccessibility.value(isExpanded: true) == "Expanded")
    }

    @MainActor
    @Test func collaborationTurnsSeparateHandoffsAndThinkingFromOrdinaryWorkTrail() throws {
        let handoff = ChatActivityEvent(
            eventID: "handoff-event",
            sessionID: "session",
            turnID: "turn",
            kind: .botHandoff,
            lifecycle: .running,
            title: "Contacting Nova",
            summary: "Message sent",
            detail: nil,
            occurredAt: 2,
            botRunID: "run",
            memberID: "nova",
            fromMemberID: "default"
        )
        let reasoning = ChatActivityEvent(
            eventID: "reason-event",
            sessionID: "session",
            turnID: "turn",
            kind: .reasoning,
            lifecycle: .succeeded,
            title: "Reasoning",
            summary: "Ready",
            detail: nil,
            occurredAt: 1
        )

        let presentation = ChatActivityTurnPresentation(
            turn: ChatActivityTurn(id: "turn", events: [reasoning, handoff])
        )

        #expect(presentation.collaborations == [handoff])
        #expect(presentation.workTrail == nil)
        #expect(presentation.segments.map(\.id) == ["thinking:\(reasoning.id)", "collaboration:\(handoff.id)"])
    }

    @Test func collaborationMotionHonorsLifecycleAndReducedMotion() {
        #expect(ChatCollaborationMotionPolicy.animates(lifecycle: .running, reduceMotion: false))
        #expect(!ChatCollaborationMotionPolicy.animates(lifecycle: .running, reduceMotion: true))
        #expect(!ChatCollaborationMotionPolicy.animates(lifecycle: .succeeded, reduceMotion: false))
        #expect(!ChatCollaborationMotionPolicy.animates(lifecycle: .failed, reduceMotion: false))
    }

    @Test func restoredAgentReturnLabelsBoundedSenderOutputAsAReplyExcerpt() {
        let returnEvent = ChatActivityEvent(
            eventID: "agent-return",
            sessionID: "session",
            turnID: "turn",
            kind: .botHandoff,
            lifecycle: .succeeded,
            title: "Agent reply",
            summary: "@nova replied",
            detail: nil,
            occurredAt: 3,
            result: "Bounded sender-side output",
            botRunID: "proc-1",
            memberID: "default",
            fromMemberID: "nova"
        )

        #expect(
            ChatCollaborationTranscriptPresentation.resultLabel(
                for: returnEvent,
                fromName: "Nova",
                toName: "Juno"
            ) == "Reply excerpt from Nova"
        )
    }

    @Test func genericSkillActivityUsesTheAuthenticatedSkillName() {
        let event = ChatActivityEvent(
            eventID: "skill-event",
            sessionID: "skill-session",
            turnID: "skill-turn",
            kind: .tool,
            lifecycle: .running,
            title: "Using skill view",
            summary: "Loading skill",
            detail: nil,
            occurredAt: 1,
            toolCallID: "skill-call",
            arguments: #"{"name":"email:email-inbox-triage"}"#
        )

        #expect(event.presentationTitle == "Reading a skill…")
        #expect(event.presentationDetail == "email:email-inbox-triage")
    }

    @Test func genericCommandActivityUsesOnlyTheAuthenticatedExecutableBasename() {
        let event = ChatActivityEvent(
            eventID: "command-event",
            sessionID: "command-session",
            turnID: "command-turn",
            kind: .tool,
            lifecycle: .running,
            title: "Running a command",
            summary: "Starting",
            detail: nil,
            occurredAt: 1,
            toolCallID: "command-call",
            arguments: #"{"command":"/usr/local/bin/swift test --filter ChatModelTests --token super-secret"}"#
        )

        #expect(event.presentationTitle == "Running a command…")
        #expect(event.presentationDetail == "swift")
        #expect(!event.collapsedAccessibilityLabel(status: nil).contains("super-secret"))
    }

    @Test func genericExecuteActivityNeverExposesAuthenticatedCodeInItsCollapsedTitle() {
        let event = ChatActivityEvent(
            eventID: "execute-event",
            sessionID: "execute-session",
            turnID: "execute-turn",
            kind: .tool,
            lifecycle: .running,
            title: "Using execute code",
            summary: "Starting",
            detail: nil,
            occurredAt: 1,
            toolCallID: "execute-call",
            arguments: #"{"code":"const apiToken = 'super-secret';\ntext(apiToken);"}"#
        )

        #expect(event.presentationTitle == "Running code…")
        #expect(event.presentationDetail == nil)
        #expect(!event.collapsedAccessibilityLabel(status: nil).contains("super-secret"))
    }

    @Test func genericToolCallActivityUsesTheAuthenticatedNestedToolName() {
        let event = ChatActivityEvent(
            eventID: "tool-event",
            sessionID: "tool-session",
            turnID: "tool-turn",
            kind: .tool,
            lifecycle: .running,
            title: "Using tool call",
            summary: "Starting",
            detail: nil,
            occurredAt: 1,
            toolCallID: "tool-call",
            arguments: #"{"name":"loopdy_render_weather_forecast","arguments":{"location":"Kansas City"}}"#
        )

        #expect(event.canonicalToolName == "loopdy_render_weather_forecast")
        #expect(event.presentationTitle == "Making a card…")
        #expect(!event.collapsedAccessibilityLabel(status: nil).contains("Kansas City"))
    }

    @Test func unknownToolActivityNeverExposesAnArbitraryServerTitle() {
        let event = ChatActivityEvent(
            eventID: "unknown-tool-event",
            sessionID: "unknown-tool-session",
            turnID: "unknown-tool-turn",
            kind: .tool,
            lifecycle: .running,
            title: "Authorization bearer server-secret must never be collapsed",
            summary: "server-secret summary",
            detail: "server-secret detail",
            occurredAt: 1,
            toolCallID: "unknown-tool-call"
        )

        #expect(event.presentationTitle == "Using tools…")
        #expect(event.presentationDetail == nil)
        #expect(event.collapsedPresentationSummary == nil)
        #expect(event.collapsedAccessibilityLabel(status: "Failed") == "Using tools…, Failed")
        #expect(!event.collapsedAccessibilityLabel(status: "Failed").contains("server-secret"))
        #expect(!ChatActivityPresentation.step(for: event).label.contains("server-secret"))
    }

    @Test func oneTokenServerTitleNeverReachesCollapsedTextOrVoiceOver() {
        let event = ChatActivityEvent(
            eventID: "one-token-tool-event",
            sessionID: "one-token-tool-session",
            turnID: "one-token-tool-turn",
            kind: .tool,
            lifecycle: .running,
            title: "server_secret",
            summary: "server-secret-summary",
            detail: "server-secret-detail",
            occurredAt: 1,
            toolCallID: "one-token-tool-call"
        )

        #expect(event.presentationTitle == "Using tools…")
        #expect(event.canonicalToolName == nil)
        #expect(event.collapsedAccessibilityLabel(status: nil) == "Using tools…")
        #expect(!event.collapsedAccessibilityLabel(status: nil).contains("server_secret"))
    }

    @Test func authenticatedHistoryToolNameIsSanitizedIntoTheCollapsedTitle() {
        let event = ChatActivityEvent(
            eventID: "history-tool-event",
            sessionID: "history-tool-session",
            turnID: "history-tool-turn",
            kind: .tool,
            lifecycle: .succeeded,
            title: "server_secret",
            summary: "Completed",
            detail: nil,
            occurredAt: 1,
            toolCallID: "history-tool-call",
            toolName: "loopdy_render_weather_forecast"
        )

        #expect(event.presentationTitle == "Made a card")
        #expect(event.presentationDetail == nil)
    }

    @Test func authenticatedActivityIdentifiersAreBoundedForCollapsedRows() {
        let longIdentifier = String(repeating: "a", count: 160)
        let event = ChatActivityEvent(
            eventID: "bounded-skill-event",
            sessionID: "bounded-skill-session",
            turnID: "bounded-skill-turn",
            kind: .tool,
            lifecycle: .running,
            title: "Using skill view",
            summary: "Loading skill",
            detail: nil,
            occurredAt: 1,
            toolCallID: "bounded-skill-call",
            arguments: #"{"name":"\#(longIdentifier)"}"#
        )

        #expect(event.presentationDetail == String(repeating: "a", count: 80))
    }

    @Test func humanMessagesUseContentFitTrailingAccentBubbles() {
        let presentation = ChatMessagePresentation.resolve(
            role: .human,
            delivery: "Sent just now"
        )

        #expect(presentation.alignment == .trailing)
        #expect(presentation.chrome == .accentBubble)
        #expect(presentation.textTone == .primary)
        #expect(presentation.maximumWidthFraction == 0.78)
        #expect(presentation.contentFitsWidth)
    }

    @Test func finalAssistantMessagesUseAiryOpenProse() {
        let presentation = ChatMessagePresentation.resolve(
            role: .assistant,
            delivery: "Delivered"
        )

        #expect(presentation.alignment == .leading)
        #expect(presentation.chrome == .openProse)
        #expect(presentation.textTone == .primary)
        #expect(presentation.contentOpacity == 1)
        #expect(presentation.maximumWidthFraction == 0.94)
        #expect(!presentation.contentFitsWidth)
        #expect(presentation.proseLineSpacing == 4)
    }

    @Test func interimAssistantMessagesRemainOpenChatProseWithSubduedText() {
        let presentation = ChatMessagePresentation.resolve(
            role: .assistant,
            delivery: "Streaming"
        )

        #expect(presentation.alignment == .leading)
        #expect(presentation.chrome == .openProse)
        #expect(presentation.textTone == .interim)
        #expect(presentation.contentOpacity == 0.68)
        #expect(presentation.proseLineSpacing == 4)
    }

    @Test func userMessagesDoNotReceiveAssistantProseLineSpacing() {
        let presentation = ChatMessagePresentation.resolve(role: .human, delivery: "Sent")

        #expect(presentation.proseLineSpacing == 0)
    }

    @Test func toolVisualStateUsesNeutralRunningAndTerminalOutcomeTones() {
        #expect(ChatActivityVisualState(lifecycle: .running).tone == .neutral)
        #expect(ChatActivityVisualState(lifecycle: .running).shimmers)
        #expect(ChatActivityVisualState(lifecycle: .succeeded).tone == .success)
        #expect(ChatActivityVisualState(lifecycle: .failed).tone == .failure)
        #expect(ChatActivityVisualState(lifecycle: .cancelled).tone == .secondary)
        #expect(!ChatActivityVisualState(lifecycle: .succeeded).shimmers)
    }

    @Test func contentFitWidthUsesIntrinsicWidthUntilTheRoleLimit() {
        #expect(ChatBubbleLayoutMetrics.resolvedWidth(
            idealWidth: 132,
            containerWidth: 390,
            maximumWidthFraction: 0.78
        ) == 132)
        #expect(ChatBubbleLayoutMetrics.resolvedWidth(
            idealWidth: 480,
            containerWidth: 390,
            maximumWidthFraction: 0.78
        ) == 304.2)
    }
}
