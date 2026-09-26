import Foundation
import Testing
@testable import Loopdy

@MainActor
struct NativeLiveVoiceTests {
    @Test func distinctDelegationsKeepResultIDsBoundToTheirSerializedTurns() async throws {
        let fixture = VoiceFixture()
        let voice = fixture.makeSession()
        _ = try await voice.perform("voice.live.offer", fields: ["voiceId": .string("voice-one")])
        defer { fixture.reply?.resume(returning: "Fixture ended"); fixture.reply = nil }

        voice.receiveEvent(["kind": .string("delegation"), "id": .string("delegation-a"),
            "text": .string("First request")], voiceID: "voice-one")
        voice.receiveEvent(["kind": .string("delegation"), "id": .string("delegation-b"),
            "text": .string("Second request")], voiceID: "voice-one")
        for _ in 0..<100 where fixture.reply == nil { await Task.yield() }
        #expect(fixture.submitted == ["First request"])

        let first = try #require(fixture.reply)
        fixture.reply = nil
        first.resume(returning: "First result")
        for _ in 0..<100 where fixture.submitted.count < 2 { await Task.yield() }
        #expect(fixture.submitted == ["First request", "Second request"])

        let second = try #require(fixture.reply)
        fixture.reply = nil
        second.resume(returning: "Second result")
        for _ in 0..<100 where fixture.results.count < 2 { await Task.yield() }
        #expect(fixture.results == ["delegation-a", "delegation-b"])
        _ = try await voice.perform("voice.live.close", fields: ["voiceId": .string("voice-one")])
    }

    @Test func repeatedProviderRequestsShareOnePendingNativeTurn() async throws {
        let fixture = VoiceFixture()
        let voice = fixture.makeSession()
        _ = try await voice.perform("voice.live.offer", fields: ["voiceId": .string("voice-one")])
        defer { fixture.reply?.resume(returning: "Fixture ended"); fixture.reply = nil }
        voice.receiveEvent(["kind": .string("delegation"), "id": .string("one"), "text": .string("Check tomorrow")], voiceID: "voice-one")
        voice.receiveEvent(["kind": .string("delegation"), "id": .string("two"), "text": .string("Check tomorrow")], voiceID: "voice-one")
        voice.receiveEvent(["kind": .string("delegation"), "id": .string("one"), "text": .string("Check tomorrow")], voiceID: "voice-one")
        for _ in 0..<100 where fixture.reply == nil { await Task.yield() }
        #expect(fixture.submitted == ["Check tomorrow"])
        let pending = try #require(fixture.reply)
        fixture.reply = nil
        pending.resume(returning: "Three events")
        for _ in 0..<100 where fixture.results.count < 2 { await Task.yield() }
        #expect(Set(fixture.results) == ["one", "two"])
        #expect(fixture.submitted.count == 1)
        _ = try await voice.perform("voice.live.close", fields: ["voiceId": .string("voice-one")])
    }

    @Test func closingMediaDoesNotCancelSubmittedNativeWorkOrSendItsResultToAnotherCall() async throws {
        let fixture = VoiceFixture()
        let voice = fixture.makeSession()
        _ = try await voice.perform("voice.live.offer", fields: ["voiceId": .string("voice-one")])
        voice.receiveEvent(["kind": .string("delegation"), "id": .string("one"), "text": .string("Do work")], voiceID: "voice-one")
        for _ in 0..<100 where fixture.reply == nil { await Task.yield() }
        let pending = try #require(fixture.reply)
        fixture.reply = nil
        _ = try await voice.perform("voice.live.close", fields: ["voiceId": .string("voice-one")])
        _ = try await voice.perform("voice.live.offer", fields: ["voiceId": .string("voice-two")])
        pending.resume(returning: "Work completed in Hermes")
        for _ in 0..<100 { await Task.yield() }
        #expect(fixture.submitted == ["Do work"])
        #expect(!fixture.submitWasCancelled)
        #expect(fixture.results.isEmpty)
        _ = try await voice.perform("voice.live.close", fields: ["voiceId": .string("voice-two")])
    }

    @Test func ownerRetirementUsesPreparedCloseAfterOwnerFencing() async throws {
        let ownerState = OwnerState()
        var preparedCount = 0
        var preparedCloseCount = 0
        var ordinaryCloseCount = 0
        let voice = NativeLiveVoiceSession(
            owner: .init(hostID: "native", authorizationID: "auth", agentID: "default", sessionID: "stored"),
            operation: { operation, payload in
                switch operation {
                case .nativeVoiceOffer:
                    return ["voiceId": payload["voiceId"]!, "sdp": .string("fixture")]
                case .nativeVoiceClose:
                    ordinaryCloseCount += 1
                    return ["closed": .boolean(true)]
                default:
                    throw LiveVoiceControlError.unavailable
                }
            },
            isCurrent: { ownerState.isCurrent },
            closeCleanupFactory: { voiceID in
                preparedCount += 1
                guard voiceID == "voice-one" else { return nil }
                return { preparedCloseCount += 1 }
            },
            submit: { _ in "" }
        )
        let model = voice.makeModel(agentName: "Hermes")
        _ = try await voice.perform("voice.live.offer", fields: ["voiceId": .string("voice-one")])
        #expect(preparedCount == 1)

        ownerState.isCurrent = false
        model.invalidateOwner()
        for _ in 0..<100 where preparedCloseCount == 0 { await Task.yield() }

        #expect(preparedCount == 1)
        #expect(preparedCloseCount == 1)
        #expect(ordinaryCloseCount == 0)
    }

    @Test func ownerRetirementSuppressesOrdinaryCloseWhenNoPreparedHandleExists() async throws {
        let ownerState = OwnerState()
        var ordinaryCloseCount = 0
        let voice = NativeLiveVoiceSession(
            owner: .init(hostID: "native", authorizationID: "auth", agentID: "default", sessionID: "stored"),
            operation: { operation, payload in
                switch operation {
                case .nativeVoiceOffer:
                    return ["voiceId": payload["voiceId"]!, "sdp": .string("fixture")]
                case .nativeVoiceClose:
                    ordinaryCloseCount += 1
                    return ["closed": .boolean(true)]
                default:
                    throw LiveVoiceControlError.unavailable
                }
            },
            isCurrent: { ownerState.isCurrent },
            submit: { _ in "" }
        )
        let model = voice.makeModel(agentName: "Hermes")
        _ = try await voice.perform("voice.live.offer", fields: ["voiceId": .string("voice-one")])

        ownerState.isCurrent = false
        model.invalidateOwner()
        for _ in 0..<100 { await Task.yield() }

        #expect(ordinaryCloseCount == 0)
    }

    @MainActor private final class OwnerState {
        var isCurrent = true
    }

    @MainActor private final class VoiceFixture {
        var submitted: [String] = []
        var results: [String] = []
        var voiceID = ""
        var reply: CheckedContinuation<String, Never>?
        var submitWasCancelled = false
        func makeSession() -> NativeLiveVoiceSession {
            NativeLiveVoiceSession(owner: .init(hostID: "native", authorizationID: "auth", agentID: "default", sessionID: "stored"),
                operation: { operation, payload in
                    switch operation {
                    case .nativeVoiceStatus: return ["available": .boolean(true)]
                    case .nativeVoiceOffer:
                        self.voiceID = payload["voiceId"]!.string!
                        return ["voiceId": payload["voiceId"]!, "sdp": .string(NativeVoicePeer.sdp)]
                    case .nativeVoicePoll: return ["voiceId": payload["voiceId"]!, "events": .array([]), "next": payload["after"]!, "closed": .boolean(false)]
                    case .nativeVoiceClose: return ["closed": .boolean(true)]
                    case .nativeVoiceResult:
                        self.results.append(payload["delegationId"]!.string!)
                        return ["appended": .boolean(true)]
                    default: throw LiveVoiceControlError.unavailable
                    }
                }, isCurrent: { true }, submit: { text in
                    self.submitted.append(text)
                    let result = await withCheckedContinuation { self.reply = $0 }
                    self.submitWasCancelled = Task.isCancelled
                    return result
                })
        }
    }

    @Test func nativeDelegationStatusFollowsVerifiedResultReceipt() async throws {
        let fixture = VoiceFixture()
        let voice = fixture.makeSession()
        let peer = NativeVoicePeer()
        let model = voice.makeModel(agentName: "Hermes", makePeer: { peer })
        defer { model.end() }

        model.start()
        for _ in 0..<100 where fixture.voiceID.isEmpty { await Task.yield() }
        #expect(!fixture.voiceID.isEmpty)

        voice.receiveEvent(["kind": .string("delegation"), "id": .string("delegation-status"),
            "text": .string("Check tomorrow")], voiceID: fixture.voiceID)
        #expect(model.workStatus == .working)
        for _ in 0..<100 where fixture.reply == nil { await Task.yield() }
        let reply = try #require(fixture.reply)
        fixture.reply = nil
        reply.resume(returning: "Tomorrow is clear")
        for _ in 0..<100 where fixture.results.isEmpty { await Task.yield() }
        #expect(fixture.results == ["delegation-status"])
        #expect(model.workStatus == .resultSent)
    }

    @MainActor private final class NativeVoicePeer: LiveVoiceAudioPeer {
        static let sdp = "v=0\r\na=fingerprint:sha-256 00:11\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n"
        var onConnectionState: (@MainActor (LoopdyRealtimeAudioPeer.ConnectionState) -> Void)?
        var onAudioRoute: (@MainActor (String) -> Void)?
        var onInterruption: (@MainActor (Bool) -> Void)?
        func makeOffer() async throws -> String { Self.sdp }
        func applyAnswer(_ sdp: String) async throws {}
        func setMuted(_ muted: Bool) {}
        func setPlaybackMuted(_ muted: Bool) {}
        func setSpeakerEnabled(_ enabled: Bool) throws {}
        func setDefaultSpeakerOutput() throws {}
        func resumeAudio() throws {}
        func statistics() async throws -> LoopdyRealtimeAudioPeer.MediaStatistics { .init(audioDeviceRunning: true) }
        func close() {}
    }

    @Test func voiceDelegationUsesChatClientWithoutChangingComposerOrRetrying() async throws {
        let client = Reply()
        let chat = ChatModel(conversationID: "native", client: client, initialItems: [])
        chat.draft = "Keep my draft"
        let response = try await chat.sendNativeVoiceMessage("Check my calendar")
        #expect(client.messages == ["Check my calendar"])
        #expect(chat.draft == "Keep my draft")
        #expect(response.items.count == 1)
        #expect(!chat.isSending)
        #expect(chat.items.contains { $0.content == .message("Check my calendar") })
        client.fail = true
        await #expect(throws: WorkspaceClientError.outcomeUnknown) {
            _ = try await chat.sendNativeVoiceMessage("Uncertain work")
        }
        #expect(client.messages == ["Check my calendar", "Uncertain work"])
        #expect(!chat.isSending)
    }

    @Test func nativeVoiceOperationsHaveNativePluginRoutes() {
        for operation in [WorkspaceOperation.nativeVoiceStatus, .nativeVoiceOffer, .nativeVoicePoll,
                          .nativeVoiceResult, .nativeVoiceClose] {
            #expect(DirectHermesNativePluginClient.supports(operation))
        }
    }

    @MainActor private final class Reply: ConversationClient {
        var messages: [String] = []
        var fail = false
        func send(message: String, conversationID: String) async throws -> ConversationResponse {
            messages.append(message)
            if fail { throw WorkspaceClientError.outcomeUnknown }
            return ConversationResponse(items: [TimelineItem(id: "answer", role: .assistant,
                sender: .agent(id: "default", snapshot: .init(name: "Hermes")),
                content: .message("Tomorrow is clear."), metadata: .init(source: "Hermes", delivery: "Received"))])
        }
        func perform(action: QuickAction, conversationID: String) async throws -> ConversationResponse {
            throw LiveVoiceControlError.unavailable
        }
    }
}
