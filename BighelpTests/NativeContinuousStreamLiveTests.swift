import Foundation
import XCTest
@testable import Bighelp

/// Uses an isolated stock Hermes server and the real Apple WebSocket client.
/// The model is explicitly synthetic and local; it cannot use paid inference.
final class NativeContinuousStreamLiveTests: XCTestCase {
    @MainActor
    func testRuntimeForceRefreshKeepsReceivingWithoutNavigationOrResend() async throws {
        guard let path = ProcessInfo.processInfo.environment["DIRECT_PROBE_CONFIG"] else {
            throw XCTSkip("Run with DirectHermesNativeProbe.py --ios-tests")
        }
        let pipe = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? pipe.close() }
        let config = try JSONDecoder().decode([String: String].self, from: pipe.readToEnd() ?? Data())
        guard config["isolated_fixture"] == "true",
              let address = config["address"], URL(string: address)?.host == "127.0.0.1" else {
            throw XCTSkip("Only the isolated loopback fixture is authorized")
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = "app.loopdy.continuous-stream." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let hosts = BighelpHostRegistry(root: directory.appending(path: "hosts"), keychainService: suite,
            independentRoot: directory.appending(path: "independent"), defaults: preferences)
        defer {
            hosts.onNativeEvent = nil
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        hosts.useIndependentWorkspace()
        let (pendingID, hostWorkspace) = try hosts.makePendingWorkspace()
        defer { hosts.discardPending(pendingID) }
        try await hostWorkspace.connect(address: address,
            auth: .password(username: XCTUnwrap(config["username"]), password: XCTUnwrap(config["password"])),
            allowPrivateHTTP: true)
        print("NATIVE_STAGE connected")
        XCTAssertTrue(hostWorkspace.isConnected)
        let configured = try hosts.commit(pendingID, workspace: hostWorkspace, name: "Isolated streaming fixture")
        defer { try? hosts.remove(configured) }
        let connections = WorkspaceConnectionStore(hosts: hosts)
        let owner = try XCTUnwrap(connections.owner)
        print("NATIVE_STAGE constructing-runtime")
        let runtime = try NativeWorkspaceRuntime(connections: connections, authority: owner.authority,
            settings: SettingsStore(defaults: preferences, legacyThemeLogoDirectory: directory.appending(path: "logos")),
            userIdentity: UserIdentityStore(defaults: preferences, avatarDirectory: directory.appending(path: "avatars")),
            directory: directory.appending(path: "runtime"))
        defer {
            runtime.retire()
            UserDefaults(suiteName: "app.loopdy.native-workspace." + owner.authority.cacheScopeID)?
                .removePersistentDomain(forName: "app.loopdy.native-workspace." + owner.authority.cacheScopeID)
        }
        var liveTextSequences: [Int] = []
        hosts.onNativeEvent = { _, event in
            if event.type == "message.delta", let sequence = event.sequence { liveTextSequences.append(sequence) }
            runtime.receive(event)
        }
        print("NATIVE_STAGE refreshing-runtime")
        await runtime.refresh()
        XCTAssertTrue(runtime.isReady)
        print("NATIVE_STAGE creating-session ready=\(runtime.isReady) owner-current=\(connections.owner == owner)")
        let record = try await runtime.sessions.createDirect(agentID: "default")
        print("NATIVE_STAGE preparing-chat")
        let route = AppRoute.chat(conversationID: record.id)
        XCTAssertTrue(runtime.features.prepareNewChat(route))
        // NativeWorkspaceRuntime.newChat uses prepareNewChat directly: creation
        // already prepared the stream. Saved-navigation hydration requires its own admission.
        guard case .chat(let model)? = runtime.features.preparedModel(for: route) else { return XCTFail("Missing production chat") }
        let client = try XCTUnwrap(model.nativeConversationClient)
        print("NATIVE_STAGE starting-turn")
        model.draft = "hold direct streaming acceptance"
        let send = Task { await model.send() }
        defer { send.cancel() }
        try await eventually { client.projection.running && !liveTextSequences.isEmpty }
        model.draft = "Keep this unsent draft through refresh"
        let attachment = try ChatAttachment(id: UUID().uuidString, fileName: "unsent.txt",
            mimeType: "text/plain", data: Data("Unsent fixture attachment".utf8))
        try model.addDraftAttachment(attachment)
        let beforeAttachments = model.orderedDraftAttachments.map(\.id)
        XCTAssertEqual(beforeAttachments.count, 1)
        let beforeIDs = model.items.map(\.id)
        let beforeJournal = client.journal.unresolved.map(\.id)
        let transport = hostWorkspace.nativeClient
        let refreshSource = try XCTUnwrap(runtime.sessions.session(id: record.id))
        print("NATIVE_STAGE force-refresh owner=\(connections.owner == owner) reference=\(model.ownsReferenceSession(refreshSource)) warm=\(runtime.features.canReturnToWarmSession(id: record.id)) bridge=\(runtime.bridge.isWarmSession(refreshSource, model: model)) recoverable=\(runtime.bridge.canRecoverRetainedSession(refreshSource, model: model))")
        try await runtime.features.forceRefreshSession(id: record.id)
        let afterRefreshSequence = client.projection.lastSequence
        XCTAssertTrue(hostWorkspace.nativeClient === transport)
        XCTAssertEqual(model.draft, "Keep this unsent draft through refresh")
        XCTAssertEqual(model.orderedDraftAttachments.map(\.id), beforeAttachments)
        XCTAssertEqual(client.journal.unresolved.map(\.id), beforeJournal)
        try await eventually { !client.projection.running && liveTextSequences.filter { $0 > afterRefreshSequence }.count >= 2 }
        await send.value
        guard case .chat(let retained)? = runtime.features.preparedModel(for: route) else { return XCTFail("Lost production chat") }
        XCTAssertTrue(retained === model)
        XCTAssertTrue(beforeIDs.allSatisfy { id in model.items.contains { $0.id == id } })
        XCTAssertEqual(model.items.filter { $0.role == .assistant && $0.content == .message("Direct streaming fixture complete.") }.count, 1)
        XCTAssertEqual(model.items.filter { $0.role == .human }.count, 1)
        XCTAssertEqual(model.draft, "Keep this unsent draft through refresh")
        XCTAssertEqual(model.orderedDraftAttachments.map(\.id), beforeAttachments)
        XCTAssertTrue(client.journal.unresolved.isEmpty)
        XCTAssertTrue(client.isReadyForSubmission)
        XCTAssertTrue(model.canSend)
        XCTAssertEqual(connections.owner, owner)
        print("NATIVE_CONTINUOUS_STREAM_VERIFIED post_refresh_deltas=\(liveTextSequences.filter { $0 > afterRefreshSequence }.count) retained_model=true retained_attachment=true user_rows=1")
    }

    @MainActor private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !predicate() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate(), "Expected live state within the bounded fixture interval")
        if !predicate() { throw DirectHermesError.notConnected }
    }
}
