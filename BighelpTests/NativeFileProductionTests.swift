import Foundation
import XCTest
@testable import Bighelp

final class NativeFileProductionTests: XCTestCase {
    @MainActor
    func testNativeFileUploadBudgetAndMessageReferencesAgainstStockHost() async throws {
        guard let path = ProcessInfo.processInfo.environment["DIRECT_PROBE_CONFIG"] else {
            throw XCTSkip("Requires the isolated stock Hermes fixture.")
        }
        let config = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let vault = DirectHermesKeychainVault(service: "app.loopdy.native-file-proof." + UUID().uuidString)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? vault.delete(); try? FileManager.default.removeItem(at: root) }
        let transport = try await DirectHermesClient.connect(
            address: XCTUnwrap(config["address"]), auth: .token(XCTUnwrap(config["token"])),
            allowPrivateHTTP: true, vault: vault
        )
        defer { Task { await transport.disconnect() } }
        let created = try await transport.request("session.create", params: ["profile": .string("default")])
        let runtime = try XCTUnwrap(created.object?["session_id"]?.string)
        let stored = try XCTUnwrap(created.object?["stored_session_id"]?.string)
        let large = try ChatAttachment(
            id: "attachment_large_live_fixture", fileName: "large-upload.txt", mimeType: "text/plain",
            data: Data(repeating: 65, count: ChatAttachment.maximumBytes)
        )
        try DirectHermesFileAttachments.validate([large], message: "")
        let uploaded = try await transport.request("file.attach",
                                                    params: DirectHermesFileAttachments.payload(large, runtimeID: runtime))
        XCTAssertFalse(try DirectHermesFileAttachments.reference(uploaded).isEmpty)
        let uploadedPath = try XCTUnwrap(uploaded.object?["path"]?.string)
        let uploadedURL = URL(fileURLWithPath: uploadedPath).resolvingSymlinksInPath()
        let fixtureAttachments = URL(fileURLWithPath: path).deletingLastPathComponent()
            .appending(path: "home/attachments").resolvingSymlinksInPath()
        XCTAssertEqual(uploadedURL.deletingLastPathComponent().pathComponents, fixtureAttachments.pathComponents)
        guard uploadedURL.deletingLastPathComponent().pathComponents == fixtureAttachments.pathComponents else { return }
        XCTAssertEqual(try Data(contentsOf: uploadedURL), large.data, "Independent fixture observation must confirm all uploaded bytes.")
        let epoch = try await transport.request("session.events.since", params: [
            "session_id": .string(runtime), "last_seen": .integer(0)
        ])
        let observer = FileRPCObserver(transport)
        let client = try DirectHermesConversationClient(
            rpc: observer, hostIdentity: transport.savedConnection.identity, profile: "default",
            runtimeID: runtime, storedID: stored, title: "Native files",
            epoch: XCTUnwrap(epoch.object?["epoch"]?.string), drafts: DirectHermesDraftStore(root: root)
        )
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let prompt = "Read the attached file and finish this direct fixture. NATIVE_PROBE_" + nonce
        let attachment = try ChatAttachment(
            id: "attachment_small_live_fixture", fileName: "context file.txt", mimeType: "text/plain",
            data: Data(("FILE_CONTENT_" + nonce).utf8)
        )
        let model = ChatModel(conversationID: client.conversationID, client: client, agentID: "default",
                              initialItems: [], initialDraft: prompt)
        client.model = model
        transport.onEvent = { [weak client] event in client?.receive(event) }
        try model.addDraftAttachment(attachment)
        XCTAssertTrue(observer.methods.isEmpty)
        await model.send()
        let expected = "Direct streaming fixture complete. NATIVE_PROBE_" + nonce
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while !model.items.contains(where: { $0.content == .message(expected) }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.items.contains { $0.content == .message(expected) })
        XCTAssertEqual(observer.methods.filter { $0 == "file.attach" }.count, 1)
        XCTAssertEqual(observer.methods.filter { $0 == "prompt.submit" }.count, 1)
        XCTAssertTrue(observer.submittedText?.hasPrefix(prompt + "\n@file:") == true)
        XCTAssertEqual(model.items.first(where: { $0.role == .human })?.content, .message(prompt))
        XCTAssertEqual(model.items.first(where: { $0.role == .human })?.attachments, [attachment])
        XCTAssertFalse(observer.receivedPathParameter)
        client.suspend()
        await transport.disconnect()
    }

    @MainActor
    private final class FileRPCObserver: DirectHermesRPC {
        let base: DirectHermesClient
        var onEvent: ((DirectHermesEvent) -> Void)?
        var methods: [String] = []
        var submittedText: String?
        var receivedPathParameter = false
        init(_ base: DirectHermesClient) { self.base = base }
        func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
            methods.append(method)
            if method == "file.attach" { receivedPathParameter = params["path"] != nil }
            if method == "prompt.submit" { submittedText = params["text"]?.string }
            return try await base.request(method, params: params)
        }
        func disconnect() async { await base.disconnect() }
    }
}
