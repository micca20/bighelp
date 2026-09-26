import CryptoKit
import Foundation
import Testing
@testable import Bighelp

struct WatchCompanionV2Tests {
    @Test @MainActor func connectivityErrorCallbackCanEnterFromAUtilityQueue() async {
        let delivered = await withCheckedContinuation { continuation in
            let callback = WatchCompanionCallbacks.failure { packet in
                MainActor.assertIsolated()
                continuation.resume(returning: packet == nil)
            }
            DispatchQueue.global(qos: .utility).async { callback(URLError(.notConnectedToInternet)) }
        }
        #expect(delivered)
    }

    @Test @MainActor func connectivityReplyIsDecodedOffActorAndDeliveredOnMainActor() async {
        let expectedID = UUID()
        let delivered = await withCheckedContinuation { continuation in
            let callback = WatchCompanionCallbacks.reply { packet in
                MainActor.assertIsolated()
                if case .refresh(let id, _) = packet { continuation.resume(returning: id == expectedID) }
                else { continuation.resume(returning: false) }
            }
            DispatchQueue.global(qos: .utility).async {
                callback((try? WatchCompanionWire.encode(.refresh(expectedID, reconnect: false))) ?? [:])
            }
        }
        #expect(delivered)
    }
    @Test func actionsAndPendingReceiptsRoundTripWithoutBecomingCommitted() throws {
        let authority = UUID()
        let request = WatchCompanionActionRequest(id: UUID(), authorityID: authority, offerID: UUID(), createdAt: .now, action: .voice(sessionID: "session-1", text: "A spoken request"))
        let encoded = try WatchCompanionWire.encode(.action(request))
        guard case .action(let decoded) = try WatchCompanionWire.decode(encoded) else {
            Issue.record("Expected correlated action"); return
        }
        #expect(decoded == request)
        let pending = WatchCompanionReceipt(id: request.id, authorityID: authority, targetID: "session-1", phase: .pending, message: "Awaiting phone", completedAt: .now)
        guard case .receipt(let receipt) = try WatchCompanionWire.decode(WatchCompanionWire.encode(.receipt(pending))) else {
            Issue.record("Expected receipt"); return
        }
        #expect(!receipt.isTerminal)
        #expect(receipt.phase != .committed)
    }

    @Test func interruptedJournalEntriesAreUnconfirmedRatherThanResubmitted() {
        var journal = WatchCompanionJournal()
        let pendingID = UUID()
        journal.receipts = [WatchCompanionReceipt(id: pendingID, authorityID: journal.authorityID, targetID: "session-1", phase: .pending, message: "Pending", completedAt: .now)]
        journal.recover()
        #expect(journal.receipts.count == 1)
        #expect(journal.receipts.first?.id == pendingID)
        #expect(journal.receipts.first?.phase == .unconfirmed)
    }

    @Test func oversizedAndUncorrelatedVoiceReceiptsAreRejected() {
        #expect(throws: (any Error).self) {
            _ = try WatchCompanionWire.decode([WatchCompanionWire.key: Data(repeating: 0, count: WatchCompanionWire.maximumBytes + 1)])
        }
        let receipt = WatchCompanionReceipt(id: UUID(), authorityID: UUID(), targetID: "session-1", phase: .committed, message: "Done", completedAt: .now,
            voice: WatchVoiceResult(attemptID: "wrong-attempt", speaker: "Agent", text: "Reply", errorMessage: nil))
        #expect(throws: (any Error).self) { _ = try WatchCompanionWire.encode(.receipt(receipt)) }
    }
}

struct WatchCompanionTransportTests {
    @Test func snapshotRoundTripsAllFourWatchSurfaces() throws {
        var snapshot = WatchCompanionSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_788_448_000),
            weather: WatchWeatherSummary(
                city: "Chicago",
                temperature: 72,
                condition: "Sunny",
                systemImage: "sun.max.fill"
            ),
            inbox: [
                WatchInboxItem(
                    id: "attention-1",
                    kind: .clarification,
                    title: "Clarify needed",
                    detail: "Should I confirm the 3:30 PM flight?",
                    agentName: "Avery Park",
                    agentRole: "Travel Agent",
                    createdAt: Date(timeIntervalSince1970: 1_788_448_000),
                    choices: ["Yes", "No"],
                    allowsCustomResponse: true
                )
            ],
            approvals: [approval],
            sessions: [
                WatchSessionSummary(
                    id: "session-1",
                    title: "Trip planning",
                    agentName: "Avery Park",
                    preview: "The flight is still on time.",
                    updatedAt: Date(timeIntervalSince1970: 1_788_448_000),
                    isActive: true
                )
            ],
            selectedSessionID: "session-1",
            transcript: [
                WatchTranscriptItem(
                    id: "message-1",
                    speaker: "bighelp",
                    text: "The flight is still on time.",
                    timestamp: Date(timeIntervalSince1970: 1_788_448_000),
                    isUser: false
                )
            ]
        )
        snapshot.voiceResult = WatchVoiceResult(
            attemptID: "attempt-voice-1",
            speaker: "Avery Park",
            text: "I moved the meeting.",
            errorMessage: nil
        )

        let context = try WatchCompanionCodec.encodeSnapshotContext(snapshot)
        #expect(try WatchCompanionCodec.decodeSnapshotContext(context) == snapshot)
        #expect(Set(context.keys) == [WatchCompanionCodec.payloadKey])
    }

    @Test func commandsRoundTripWithoutGrantingBackendAuthority() throws {
        let enrollmentSigningKey = P256.Signing.PrivateKey()
        let enrollmentAgreementKey = Curve25519.KeyAgreement.PrivateKey()
        let enrollmentDeviceID = "watch_device_fixture_0001"
        let commands: [WatchCompanionCommand] = [
            .refresh,
            .enrollDirectClient(try WatchBighelpEnrollmentRequest(
                requestID: "watch-enrollment-request-0001",
                deviceID: enrollmentDeviceID,
                publicKeySPKI: BighelpLinkDeviceSigner(
                    deviceID: enrollmentDeviceID,
                    authorizationEpoch: 1,
                    privateKey: enrollmentSigningKey
                ).publicKeySPKI,
                agreementPublicKey: BighelpLinkBase64URL.encode(
                    enrollmentAgreementKey.publicKey.rawRepresentation
                ),
                deviceName: "Apple Watch"
            )),
            .selectSession(id: "session-1"),
            .dismissInbox(id: "event-1"),
            .respondToClarification(itemID: "event-2", response: "Confirm it"),
            .approval(.init(requestID: "approval-1", decision: .once, attemptID: "attempt-1")),
            .voiceTurn(sessionID: "session-1", transcript: "Move my meeting", attemptID: "attempt-2"),
        ]

        for command in commands {
            let payload = try WatchCompanionCodec.encodeCommand(command)
            #expect(try WatchCompanionCodec.decodeCommand(payload) == command)
            #expect(Set(payload.keys) == [WatchCompanionCodec.payloadKey])
        }
    }

    @Test func approvalRepliesRemainBoundToTheirRequestAndAttempt() throws {
        let snapshot = WatchCompanionSnapshot(
            generatedAt: .now,
            weather: nil,
            inbox: [],
            approvals: [],
            sessions: [],
            selectedSessionID: nil,
            transcript: []
        )
        let reply = WatchCompanionReply.approval(
            requestID: "approval-1",
            attemptID: "attempt-1",
            decision: .once,
            snapshot: snapshot
        )
        let payload = try WatchCompanionCodec.encodeReply(reply)
        #expect(try WatchCompanionCodec.decodeReply(payload) == reply)
    }

    @Test func malformedAndOversizedCompanionPayloadsAreRejected() {
        #expect(throws: WatchCompanionValidationError.self) {
            try WatchCompanionCodec.encodeCommand(
                .voiceTurn(
                    sessionID: "session-1",
                    transcript: String(repeating: "x", count: 10_001),
                    attemptID: "attempt-1"
                )
            )
        }
        #expect(throws: WatchCompanionValidationError.self) {
            try WatchCompanionCodec.decodeCommand(["unexpected": Data()])
        }
    }

    @Test func phoneProjectionKeepsOnlyBoundedDisplayData() throws {
        let clarification = DashboardClarificationRequest(
            eventID: "attention-1",
            requestID: "clarify-1",
            sessionID: "session-1",
            question: "Should I confirm the 3:30 PM flight?",
            choices: ["Confirm", "Do not confirm"],
            allowsCustomResponse: true,
            isMultiSelect: false,
            expiresAt: nil
        )
        let dashboard = DashboardSnapshot(
            weather: DashboardWeather(
                city: "Chicago",
                condition: "Sunny",
                temperature: 72,
                high: 76,
                low: 61,
                systemImage: "sun.max.fill"
            ),
            inbox: [],
            attentionItems: [
                DashboardAttentionItem(
                    id: "attention-1",
                    title: "Clarify needed",
                    detail: clarification.question,
                    urgency: .important,
                    sessionID: "session-1",
                    agentID: "agent-1",
                    interaction: .clarification(clarification),
                    createdAt: Date(timeIntervalSince1970: 1_788_448_000)
                )
            ],
            completedItems: [],
            agents: []
        )
        let session = SessionRecord(
            id: "session-1",
            kind: .direct,
            agentIDs: ["agent-1"],
            title: "Trip planning",
            items: [
                TimelineItem(
                    id: "human-1",
                    role: .human,
                    sender: .user(snapshot: .init(name: "You")),
                    content: .message("Check if my flight is delayed."),
                    metadata: .init(timestamp: Date(timeIntervalSince1970: 1_788_447_940))
                ),
                TimelineItem(
                    id: "agent-1",
                    role: .assistant,
                    sender: .agent(id: "agent-1", snapshot: .init(name: "Avery Park")),
                    content: .message("The flight is still on time."),
                    metadata: .init(timestamp: Date(timeIntervalSince1970: 1_788_448_000))
                ),
            ],
            isActive: true,
            hasAcceptedMessage: true
        )

        let projected = WatchCompanionProjection.make(
            dashboard: dashboard,
            sessions: [session],
            selectedSessionID: "session-1",
            agentNamesByID: ["agent-1": "Avery Park"],
            agentRolesByID: ["agent-1": "Travel Agent"],
            publishedApprovals: [approval],
            generatedAt: Date(timeIntervalSince1970: 1_788_448_000)
        )

        #expect(projected.weather?.city == "Chicago")
        #expect(projected.inbox.first?.kind == .clarification)
        #expect(projected.inbox.first?.choices == clarification.choices)
        #expect(projected.approvals == [approval])
        #expect(projected.sessions.first?.agentName == "Avery Park")
        #expect(projected.selectedSessionID == "session-1")
        #expect(projected.transcript.map(\.text) == [
            "Check if my flight is delayed.",
            "The flight is still on time.",
        ])
    }

    private var approval: WatchApprovalRequest {
        WatchApprovalRequest(
            requestID: "approval-1",
            action: "Approve grocery order for tonight?",
            requester: "Home Agent",
            vendor: "",
            amount: "",
            dueDate: "Tonight",
            category: "Home",
            consequence: "Places the order.",
            allowedDecisions: [.once, .deny]
        )
    }
}

@MainActor
struct WatchVoiceTurnTests {
    @Test func explicitWatchTranscriptUsesTheExistingVoiceConversationPath() async {
        let client = WatchVoiceClientFixture()
        let model = VoiceModel(
            conversationID: "session-1",
            agentName: "Avery Park",
            client: client
        )
        model.toggleAgentAudio()

        #expect(model.submitTranscript("Move my meeting") == true)
        await model.waitUntilTurnSettles()

        #expect(client.transcripts == ["Move my meeting"])
        #expect(model.transcriptRows.map(\.text) == [
            "Move my meeting",
            "I can do that.",
        ])
        #expect(model.turnErrorMessage == nil)
    }

    @Test func explicitWatchTranscriptRejectsEmptyAndOverlappingSteeringTurns() async {
        let client = WatchVoiceClientFixture()
        let model = VoiceModel(
            conversationID: "session-1",
            agentName: "Avery Park",
            client: client
        )
        model.toggleAgentAudio()

        #expect(model.submitTranscript("   ") == false)
        #expect(model.submitTranscript("First turn") == true)
        #expect(model.submitTranscript("Guide the active turn") == true)
        #expect(model.submitTranscript("Overlapping guidance") == false)
        await model.waitUntilTurnSettles()
        #expect(client.transcripts == ["First turn"])
        #expect(client.steeringTranscripts == ["Guide the active turn"])
    }
}

@MainActor
private final class WatchVoiceClientFixture: VoiceSessionClient {
    private(set) var transcripts: [String] = []
    private(set) var steeringTranscripts: [String] = []

    func steer(_ transcript: String, conversationID: String) async throws {
        steeringTranscripts.append(transcript)
        await Task.yield()
    }

    func respond(
        to transcript: String,
        conversationID: String,
        onDraft: @escaping (String) -> Void
    ) async throws -> VoiceAgentReply {
        transcripts.append(transcript)
        await Task.yield()
        onDraft("I can")
        return VoiceAgentReply(speaker: "Avery Park", text: "I can do that.", timelineItems: [])
    }

    func endSession(conversationID: String) async throws {}
}
