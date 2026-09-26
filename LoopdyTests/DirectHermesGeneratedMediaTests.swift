import Foundation
import Network
import Testing
import UIKit
@testable import Loopdy

@MainActor
struct DirectHermesGeneratedMediaTests {
    @Test func nativeUploadedImageRestoresWithoutExposingHostPath() async throws {
        let (owner, transport, workspace) = try setup()
        let bytes = image()
        transport.result = .object(["data_url": .string("data:image/png;base64," + bytes.base64EncodedString())])
        let resolver = DirectHermesGeneratedMediaClient(workspace: workspace, owner: owner, currentOwner: { owner })
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let native = try DirectHermesConversationClient(rpc: transport, hostIdentity: "media-test", profile: "default",
            runtimeID: "runtime", storedID: "stored", title: "Media", epoch: "epoch",
            drafts: DirectHermesDraftStore(root: root), attachmentResolver: resolver)
        let model = ChatModel(conversationID: native.conversationID, client: native, initialItems: [])
        native.model = model
        let path = "/host/.hermes/images/upload_20260921_233208_1.png"
        native.applySnapshot(.object([
            "session_id": .string("runtime"), "stored_session_id": .string("stored"),
            "running": .boolean(false), "messages": .array([
                .object(["role": .string("user"), "text": .string("@image:" + path)])
            ])
        ]), epoch: "epoch")
        let ids = model.items.map(\.id)
        for _ in 0..<100 where model.items.first?.attachments.isEmpty != false {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.items.map(\.id) == ids)
        #expect(model.items.count == 1)
        #expect(model.items.first?.role == .human)
        #expect(model.items.first?.content == .message(""))
        #expect(model.items.first?.attachments.first?.data == bytes)
        #expect(native.projection.items.first?.attachments.first?.data == bytes)
        #expect(transport.requests.map(\.path) == ["/api/media"])
        #expect(transport.requests.first?.query == [.init(name: "path", value: path)])
    }

    @Test(arguments: [false, true])
    func nativePDFEnrichesLiveAndRestoredRows(history: Bool) async throws {
        let (owner, transport, workspace) = try setup()
        let bytes = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400)).pdfData { context in
            context.beginPage()
            ("Attachment regression" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: nil)
        }
        transport.result = .object(["data_url": .string("data:application/pdf;base64," + bytes.base64EncodedString())])
        let resolver = DirectHermesGeneratedMediaClient(workspace: workspace, owner: owner, currentOwner: { owner })
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let native = try DirectHermesConversationClient(rpc: transport, hostIdentity: "media-test", profile: "default",
            runtimeID: "runtime", storedID: "stored", title: "Media", epoch: "epoch",
            drafts: DirectHermesDraftStore(root: root), attachmentResolver: resolver)
        let model = ChatModel(conversationID: native.conversationID, client: native, initialItems: [])
        native.model = model
        let path = "/host/.hermes/attachments/report.pdf"
        let text = "Your report.\nMEDIA:" + path + "\nKeep this text."
        if history {
            native.applySnapshot(.object(["session_id": .string("runtime"), "stored_session_id": .string("stored"),
                "running": .boolean(false), "messages": .array([.object(["role": .string("assistant"), "text": .string(text)])])]), epoch: "epoch")
        } else {
            native.receive(.init(type: "message.start", sessionID: "runtime", payload: [:], sequence: 1))
            native.receive(.init(type: "message.complete", sessionID: "runtime", payload: ["text": .string(text)], sequence: 2))
        }
        let ids = model.items.map(\.id)
        for _ in 0..<100 where model.items.first?.attachments.isEmpty != false { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.items.map(\.id) == ids)
        #expect(model.items.count == 1)
        #expect(model.items.first?.content == .message("Your report.\nKeep this text."))
        #expect(model.items.first?.attachments.first?.data == bytes)
        #expect(model.items.first?.attachments.first?.mimeType == "application/pdf")
        #expect(transport.requests.map(\.path) == ["/api/files/read"])
        #expect(transport.requests.first?.query == [.init(name: "path", value: path)])
        #expect(DirectHermesHTTP.responseLimit(route: "/api/files/read", method: "GET", query: [.init(name: "path", value: path)])
            == DirectHermesHTTP.maximumMediaResponseBytes)
    }

    @Test func deliveredDocumentsValidateTypeBytesAndExactPathIdentity() throws {
        let plain = Data("Exact text bytes.\n".utf8)
        let text = try DirectHermesGeneratedMediaClient.attachment(
            .object(["data_url": .string("data:text/plain;base64," + plain.base64EncodedString())]),
            path: "/host/attachments/notes.txt", scope: "default")
        #expect(text.data == plain && text.mimeType == "text/plain")
        for mime in ["application/pdf", "image/png", "text/plain"] {
            #expect(throws: WorkspaceClientError.invalidResponse) {
                try DirectHermesGeneratedMediaClient.attachment(
                    .object(["data_url": .string("data:" + mime + ";base64," + plain.base64EncodedString())]),
                    path: "/host/attachments/report.pdf", scope: "default")
            }
        }
        let composed = "/host/attachments/caf\u{00E9}.pdf"
        let decomposed = "/host/attachments/cafe\u{0301}.pdf"
        let markers = DirectHermesGeneratedMediaClient.mediaMarkers("MEDIA:" + composed + "\nMEDIA:" + decomposed)
        #expect(markers.count == 2)
        #expect(markers.map { Data($0.path.utf8) } == [Data(composed.utf8), Data(decomposed.utf8)])
        for path in ["/host/../report.pdf", "/host/./report.pdf", "/host//report.pdf", "file:///report.pdf",
                     "https://provider.invalid/report.pdf", "/host/\u{202E}report.pdf", "/host/config.yaml", "/host/run.py"] {
            #expect(DirectHermesGeneratedMediaClient.mediaMarkers("MEDIA:" + path).isEmpty)
            #expect(DirectHermesHTTP.responseLimit(route: "/api/files/read", method: "GET", query: [.init(name: "path", value: path)])
                == DirectHermesWire.maximumMessageBytes)
        }
    }

    @Test func managedFileRefusalNeverFallsBackToBroaderFilesystemRoute() async throws {
        let (owner, transport, workspace) = try setup()
        transport.failure = WorkspaceClientError.invalidRequest
        let resolver = DirectHermesGeneratedMediaClient(workspace: workspace, owner: owner, currentOwner: { owner })
        await #expect(throws: (any Error).self) {
            try await resolver.resolve(agentID: "default", storedID: "stored",
                items: [.init(id: "answer", text: "MEDIA:/host/attachments/report.pdf")])
        }
        #expect(transport.requests.map(\.path) == ["/api/files/read"])
    }

    @Test func actualAuthenticatedHTTPReadsLargeDeliveredFileWithinRouteBudget() async throws {
        let bytes = Data(repeating: 65, count: DirectHermesWire.maximumMessageBytes)
        let body = try JSONEncoder().encode(LoopdyJSONValue.object([
            "data_url": .string("data:text/plain;base64," + bytes.base64EncodedString())]))
        #expect(body.count > DirectHermesWire.maximumMessageBytes)
        let server = try DeliveredFileHTTPFixture(body: body)
        let port = try await server.start()
        defer { server.stop() }
        let http = DirectHermesHTTP(endpoint: try DirectHermesEndpoint(address: "http://127.0.0.1:\(port)", allowPrivateHTTP: true))
        defer { http.invalidate() }
        let path = "/fixture/.hermes/attachments/notes.txt"
        let response = try await http.send(route: "/api/files/read", query: [.init(name: "path", value: path)],
            bearer: "fixture-media-reader", maximumResponseBytes: DirectHermesHTTP.maximumMediaResponseBytes)
        #expect(response.http.statusCode == 200)
        let attachment = try DirectHermesGeneratedMediaClient.attachment(response.value(), path: path, scope: "fixture")
        #expect(attachment.data == bytes)
        #expect(server.requestHeaders?.lowercased().contains("authorization: bearer fixture-media-reader") == true)
        #expect(server.requestHeaders?.hasPrefix("GET /api/files/read?path=") == true)
    }

    @Test(arguments: [
        ("pdf", "application/pdf"),
        ("doc", "application/msword"),
        ("docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document"),
        ("xls", "application/vnd.ms-excel"),
        ("xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
        ("ppt", "application/vnd.ms-powerpoint"),
        ("pptx", "application/vnd.openxmlformats-officedocument.presentationml.presentation"),
        ("txt", "text/plain"),
        ("md", "application/octet-stream"),
        ("csv", "text/csv"),
        ("tsv", "text/tab-separated-values"),
        ("rtf", "application/rtf"),
        ("odt", "application/vnd.oasis.opendocument.text"),
        ("ods", "application/vnd.oasis.opendocument.spreadsheet"),
        ("odp", "application/vnd.oasis.opendocument.presentation"),
        ("epub", "application/epub+zip"),
        ("zip", "application/zip"),
        ("mp3", "audio/mpeg"),
        ("m4a", "audio/mp4a-latm"),
        ("wav", "audio/x-wav"),
        ("ogg", "audio/ogg"),
        ("flac", "audio/x-flac"),
        ("aac", "audio/x-aac")
    ])
    func acceptsStockHostDocumentAndAudioMIMETypes(entry: (String, String)) throws {
        let bytes = entry.0 == "pdf" ? UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
            .pdfData { $0.beginPage() } : Data("Typed file transport fixture".utf8)
        let attachment = try DirectHermesGeneratedMediaClient.attachment(
            .object(["data_url": .string("data:" + entry.1 + ";base64," + bytes.base64EncodedString())]),
            path: "/fixture/output." + entry.0, scope: "fixture")
        #expect(attachment.data == bytes)
        #expect(attachment.mimeType == entry.1)
    }

    /// Media downloads, Feed pictures and Artifacts previews ask for more than
    /// the 4 MiB message cap; the transport must let exactly those through.
    @Test func pluginFileRoutesMayReturnTheirDeclaredBudgets() {
        let native = "/api/plugins/loopdy/native/"
        #expect(DirectHermesHTTP.responseLimit(route: native + "attachments/fetch", method: "POST", query: [])
                >= 4 * 1_024 * 1_024 + 65_536)
        #expect(DirectHermesHTTP.responseLimit(route: native + "board/media", method: "POST", query: [])
                >= 12 * 1_024 * 1_024)
        #expect(DirectHermesHTTP.responseLimit(route: native + "workspace-files/read", method: "POST", query: [])
                >= DirectHermesHTTP.maximumMediaResponseBytes)
        for route in [native + "attachments/recent", native + "board/list", native + "attachments/fetch"] {
            let method = route.hasSuffix("fetch") ? "GET" : "POST"
            #expect(DirectHermesHTTP.responseLimit(route: route, method: method, query: []) == DirectHermesWire.maximumMessageBytes)
        }
    }

    @Test func mediaHTTPBudgetDoesNotExpandOrdinaryOrInvalidRequests() {
        let path = [URLQueryItem(name: "path", value: "/host/cache/video.mp4")]
        #expect(DirectHermesHTTP.responseLimit(route: "/api/files/read", method: "GET", query: path) == DirectHermesHTTP.maximumMediaResponseBytes)
        #expect(DirectHermesHTTP.responseLimit(route: "/api/media", method: "GET", query: [.init(name: "path", value: "/host/cache/image.png")]) == DirectHermesHTTP.maximumMediaResponseBytes)
        for (route, method, query) in [("/api/media", "GET", path), ("/api/files/read", "POST", path),
            ("/api/sessions", "GET", path), ("/api/files/read", "GET", path + path),
            ("/api/files/read", "GET", [.init(name: "path", value: "/host/../private/video.mp4")])] {
            #expect(DirectHermesHTTP.responseLimit(route: route, method: method, query: query) == DirectHermesWire.maximumMessageBytes)
        }
    }

    @Test(arguments: [false, true])
    func nativeAssistantMediaEnrichesLiveAndRestoredRows(history: Bool) async throws {
        let (owner, transport, workspace) = try setup()
        let bytes = image()
        transport.result = .object(["data_url": .string("data:image/png;base64," + bytes.base64EncodedString())])
        let resolver = DirectHermesGeneratedMediaClient(workspace: workspace, owner: owner, currentOwner: { owner })
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let native = try DirectHermesConversationClient(rpc: transport, hostIdentity: "media-test", profile: "default",
            runtimeID: "runtime", storedID: "stored", title: "Media", epoch: "epoch",
            drafts: DirectHermesDraftStore(root: root), attachmentResolver: resolver)
        let model = ChatModel(conversationID: native.conversationID, client: native, initialItems: [])
        native.model = model
        let text = "Your image.\nMEDIA:/host/.hermes/cache/images/puppy.png\nKeep this text."
        if history {
            native.applySnapshot(.object(["session_id": .string("runtime"), "stored_session_id": .string("stored"),
                "running": .boolean(false), "messages": .array([.object(["role": .string("assistant"), "text": .string(text)])])]), epoch: "epoch")
        } else {
            native.receive(.init(type: "message.start", sessionID: "runtime", payload: [:], sequence: 1))
            native.receive(.init(type: "message.complete", sessionID: "runtime", payload: ["text": .string(text)], sequence: 2))
            native.receive(.init(type: "session.info", sessionID: "runtime", payload: ["running": .boolean(false)], sequence: 3))
        }
        let ids = model.items.map(\.id)
        for _ in 0..<100 where model.items.first?.attachments.isEmpty != false { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.items.map(\.id) == ids)
        #expect(model.items.count == 1)
        #expect(model.items.first?.content == .message("Your image.\nKeep this text."))
        #expect(model.items.first?.attachments.first?.data == bytes)
        #expect(native.projection.items.first?.attachments.first?.data == bytes)
        let restored = try JSONDecoder().decode([TimelineItem].self, from: JSONEncoder().encode(model.items))
        #expect(restored == model.items)
        #expect(transport.requests.count == 1)
    }

    @Test func suspendedNativeOwnerCannotEnrichItsOldFinalRow() async throws {
        let (owner, transport, workspace) = try setup()
        transport.result = .object(["data_url": .string("data:image/png;base64," + image().base64EncodedString())])
        let resolver = DirectHermesGeneratedMediaClient(workspace: workspace, owner: owner, currentOwner: { owner })
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let native = try DirectHermesConversationClient(rpc: transport, hostIdentity: "media-test", profile: "default",
            runtimeID: "runtime", storedID: "stored", title: "Media", epoch: "epoch",
            drafts: DirectHermesDraftStore(root: root), attachmentResolver: resolver)
        let model = ChatModel(conversationID: native.conversationID, client: native, initialItems: [])
        native.model = model
        transport.onRead = { native.suspend() }
        let text = "Keep this.\nMEDIA:/host/.hermes/cache/images/puppy.png"
        native.receive(.init(type: "message.start", sessionID: "runtime", payload: [:], sequence: 1))
        native.receive(.init(type: "message.complete", sessionID: "runtime", payload: ["text": .string(text)], sequence: 2))
        for _ in 0..<30 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(transport.requests.count == 1)
        #expect(model.items.first?.content == .message(text))
        #expect(model.items.first?.attachments.isEmpty == true)
    }

    @Test func nativeVideoUsesManagedPolicyAndRejectsInvalidBytes() async throws {
        let (owner, transport, workspace) = try setup()
        transport.result = .object(["data_url": .string("data:video/mp4;base64,bm90IGEgdmlkZW8=")])
        let resolver = DirectHermesGeneratedMediaClient(workspace: workspace, owner: owner, currentOwner: { owner })
        let event = ChatActivityEvent(eventID: "video", sessionID: "media-chat", turnID: "turn", kind: .tool,
            lifecycle: .succeeded, title: "video_generate", summary: nil, detail: nil, occurredAt: 1,
            toolCallID: "video-call", toolName: "video_generate",
            result: #"{"success":true,"video":"/host/.hermes/cache/videos/out.mp4"}"#, sourceOrder: 1)
        await #expect(throws: (any Error).self) {
            try await resolver.resolve(agentID: "default", storedID: "stored", event: event)
        }
        #expect(transport.requests.map(\.path) == ["/api/files/read"])
        #expect(DirectHermesGeneratedMediaClient.outputPaths(#"{"success":true,"video":"https://provider.test/video.mp4"}"#).isEmpty)
    }

    @Test func cachedUnavailableMediaRetriesOnceWithTheNewNativeResolver() async throws {
        let (owner, transport, client) = try setup()
        transport.result = .object(["data_url": .string("data:image/png;base64," + image().base64EncodedString())])
        let resolver = DirectHermesGeneratedMediaClient(workspace: client, owner: owner, currentOwner: { owner })
        let event = generation().updating(lifecycle: .succeeded, summary: nil, detail: nil, occurredAt: 2,
            result: #"{"success":true,"image":"/host/.hermes/cache/images/puppy.png"}"#)
            .resolvingGeneratedMedia(.init(state: .unavailable))
        let record = SessionRecord(id: "media-chat", kind: .direct, agentIDs: ["default"], title: "Media",
                                   remoteStoredID: "stored", remoteSource: "loopdy", activityEvents: [event])
        let model = ChatModel(conversationID: record.id, client: ConversationFixtureClient(), initialItems: [],
                              initialActivityEvents: [event], sourceSession: record, generatedMediaResolver: resolver)
        for _ in 0..<100 where model.activityLedger.event(id: event.id)?.generatedMedia?.state != .ready {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.activityLedger.event(id: event.id)?.generatedMedia?.state == .ready)
        #expect(transport.requests.count == 1)
    }

    @Test func nativeCompletionFetchesExactBytesIntoTheExistingCard() async throws {
        let (owner, transport, client) = try setup()
        let bytes = image()
        transport.result = .object(["data_url": .string("data:image/png;base64," + bytes.base64EncodedString())])
        let resolver = DirectHermesGeneratedMediaClient(workspace: client, owner: owner, currentOwner: { owner })
        let event = generation()
        let record = SessionRecord(id: "media-chat", kind: .direct, agentIDs: ["default"], title: "Media",
                                   remoteStoredID: "stored", remoteSource: "loopdy", activityEvents: [event])
        let model = ChatModel(conversationID: record.id, client: ConversationFixtureClient(), initialItems: [],
                              initialActivityEvents: [event], sourceSession: record, generatedMediaResolver: resolver)
        let rowIDs = model.transcriptEntries.map(\.id)
        model.acceptActivity(event.updating(lifecycle: .succeeded, summary: nil, detail: nil, occurredAt: 2,
            result: #"{"success":true,"image":"/host/.hermes/cache/images/puppy.png"}"#))
        for _ in 0..<100 where model.activityLedger.event(id: event.id)?.generatedMedia == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let resolution = try #require(model.activityLedger.event(id: event.id)?.generatedMedia)
        #expect(resolution.state == .ready)
        #expect(resolution.attachments.first?.data == bytes)
        #expect(model.transcriptEntries.map(\.id) == rowIDs)
        #expect(transport.requests.count == 1)
        #expect(transport.requests.first?.path == "/api/media")
        #expect(transport.requests.first?.query == [.init(name: "path", value: "/host/.hermes/cache/images/puppy.png")])
        let restored = try JSONDecoder().decode(GeneratedMediaResolution.self, from: JSONEncoder().encode(resolution))
        #expect(restored.attachments.first?.data == bytes)
    }

    @Test func retiredOwnerCannotPublishImageBytes() async throws {
        let owner = WorkspaceOwner(authority: try .fixture(id: "media-host"), authenticationGeneration: UUID(), connectionGeneration: UUID())
        var current: WorkspaceOwner? = owner
        let transport = MediaTransport()
        transport.result = .object(["data_url": .string("data:image/png;base64," + image().base64EncodedString())])
        transport.onRead = { current = nil }
        let workspace = DirectHermesWorkspaceClient(rpc: transport, http: transport, owner: owner,
                                                    capabilities: .init(owner: owner), currentOwner: { current })
        let resolver = DirectHermesGeneratedMediaClient(workspace: workspace, owner: owner, currentOwner: { current })
        await #expect(throws: WorkspaceClientError.ownerChanged) {
            try await resolver.resolve(agentID: "default", storedID: "stored", event: generation().updating(
                lifecycle: .succeeded, summary: nil, detail: nil, occurredAt: 2,
                result: #"{"success":true,"image":"/host/.hermes/cache/images/puppy.png"}"#))
        }
    }

    @Test func explicitMediaMarkersPreserveProseAndOnlyDisappearAfterDelivery() async throws {
        let (owner, transport, workspace) = try setup()
        transport.result = .object(["data_url": .string("data:image/png;base64," + image().base64EncodedString())])
        let resolver = DirectHermesGeneratedMediaClient(workspace: workspace, owner: owner, currentOwner: { owner })
        let original = "Your image.\nMEDIA:/host/.hermes/cache/images/puppy.png\nKeep this text."
        let result = try await resolver.resolve(agentID: "default", storedID: "stored", items: [.init(id: "answer", text: original)])
        #expect(result.first?.id == "answer")
        #expect(result.first?.text == "Your image.\nKeep this text.")
        #expect(result.first?.attachments.count == 1)
    }

    @Test func rejectsProviderURLsInputsTraversalAndInvalidImageBytes() throws {
        #expect(DirectHermesGeneratedMediaClient.outputPaths(#"{"success":true,"image":"https://provider.test/a.png"}"#).isEmpty)
        #expect(DirectHermesGeneratedMediaClient.outputPaths(#"{"success":true,"arguments":{"image":"/cache/input.png"}}"#).isEmpty)
        #expect(DirectHermesGeneratedMediaClient.outputPaths(#"{"success":false,"image":"/cache/a.png"}"#).isEmpty)
        #expect(!DirectHermesGeneratedMediaClient.isImagePath("/cache/../private.png"))
        #expect(DirectHermesGeneratedMediaClient.mediaMarkers("Example MEDIA:/cache/a.png").isEmpty)
        #expect(throws: WorkspaceClientError.invalidResponse) {
            try DirectHermesGeneratedMediaClient.attachment(.object(["data_url": .string("data:image/png;base64,bm90IGFuIGltYWdl")]),
                                                            path: "/cache/a.png", scope: "default")
        }
    }

    @Test(arguments: ["", "`", "\"", "'"])
    func uploadedImageReferencesPreserveQuotesCaptionAndExactPath(quote: String) async throws {
        let (owner, transport, workspace) = try setup()
        let bytes = image()
        transport.result = .object(["data_url": .string("data:image/png;base64," + bytes.base64EncodedString())])
        let resolver = DirectHermesGeneratedMediaClient(workspace: workspace, owner: owner, currentOwner: { owner })
        let path = quote.isEmpty ? "/host/images/cafe\u{0301}.png" : "/host/with spaces/images/cafe\u{0301}.png"
        let directive = "@image:" + quote + path + quote
        let text = "Keep this caption.\n\n" + directive + "\n" + directive + "\nAnd this text."
        let result = try await resolver.resolve(agentID: "default", storedID: "stored",
            items: [.init(id: "user-row", text: text, role: .human)])
        #expect(result.first?.text == "Keep this caption.\n\nAnd this text.")
        #expect(result.first?.attachments.count == 1)
        #expect(result.first?.attachments.first?.data == bytes)
        #expect(transport.requests.count == 1)
        #expect(transport.requests.first?.path == "/api/media")
        #expect(transport.requests.first?.query.first?.value?.utf8.elementsEqual(path.utf8) == true)
        #expect(DirectHermesGeneratedMediaClient.unresolvedMessageText(text, role: .human)
            == "Keep this caption.\n\nAttachment unavailable: cafe\u{0301}.png\nAttachment unavailable: cafe\u{0301}.png\nAnd this text.")
    }

    @Test func uploadedFilesUseManagedPolicyWithoutGuessingRelativePaths() async throws {
        let (owner, transport, workspace) = try setup()
        let bytes = Data("Exact uploaded text.".utf8)
        transport.result = .object(["data_url": .string("data:text/plain;base64," + bytes.base64EncodedString())])
        let resolver = DirectHermesGeneratedMediaClient(workspace: workspace, owner: owner, currentOwner: { owner })
        let path = "/host/attachments/my notes.txt"
        let result = try await resolver.resolve(agentID: "default", storedID: "stored", items: [
            .init(id: "user-row", text: "@file:`" + path + "`", role: .human)
        ])
        #expect(result.first?.text == "")
        #expect(result.first?.attachments.first?.data == bytes)
        #expect(transport.requests.map(\.path) == ["/api/files/read"])
        #expect(transport.requests.first?.query == [.init(name: "path", value: path)])
    }

    @Test func nativeReferenceRolesAndInvalidPathsNeverAuthorizeDownloads() async throws {
        let (owner, transport, workspace) = try setup()
        let resolver = DirectHermesGeneratedMediaClient(workspace: workspace, owner: owner, currentOwner: { owner })
        var items: [AgentAttachmentTextItem] = [
            .init(id: "assistant", text: "@image:/host/images/photo.png"),
            .init(id: "user", text: "MEDIA:/host/images/photo.png", role: .human)
        ]
        let invalid = ["@image:https://provider.invalid/photo.png", "@image:/host/../photo.png",
            "@image:/host//photo.png", "@image:/host/\u{202E}photo.png", "@image:/host/photo.svg",
            "@image:`/host/photo.png'", "@image:`/host/with`quote.png`", "@image:/host/a\tphoto.png",
            "@file:attachments/notes.txt", "@file:/host/notes.txt:1-2", "@file:`/host/notes.txt`:1",
            "@file:/host/images/photo.png", "Example @image:/host/images/photo.png",
            " @image:/host/images/photo.png"]
        items += invalid.enumerated().map { .init(id: String($0.offset), text: $0.element, role: .human) }
        let results = try await resolver.resolve(agentID: "default", storedID: "stored", items: items)
        #expect(results.map(\.text) == items.map(\.text))
        #expect(results.allSatisfy { $0.attachments.isEmpty })
        #expect(transport.requests.isEmpty)
    }

    @Test func refusedUserImageNeverFallsBackOrExposesHostPathInPresentation() async throws {
        let (owner, transport, workspace) = try setup()
        transport.failure = WorkspaceClientError.invalidRequest
        let resolver = DirectHermesGeneratedMediaClient(workspace: workspace, owner: owner, currentOwner: { owner })
        let text = "My caption.\n@image:/host/profiles/other/images/photo.png"
        await #expect(throws: (any Error).self) {
            try await resolver.resolve(agentID: "other", storedID: "stored",
                items: [.init(id: "user-row", text: text, role: .human)])
        }
        #expect(transport.requests.map(\.path) == ["/api/media"])
        #expect(DirectHermesGeneratedMediaClient.unresolvedMessageText(text, role: .human)
            == "My caption.\nAttachment unavailable: photo.png")
        #expect(DirectHermesGeneratedMediaClient.unresolvedMessageText(text, role: .assistant) == text)
    }

    @Test func uploadedMediaIdentityIncludesMessageAndRetiredOwnerCannotPublish() async throws {
        let (owner, transport, workspace) = try setup()
        transport.result = .object(["data_url": .string("data:image/png;base64," + image().base64EncodedString())])
        let resolver = DirectHermesGeneratedMediaClient(workspace: workspace, owner: owner, currentOwner: { owner })
        let text = "@image:/host/images/photo.png"
        let results = try await resolver.resolve(agentID: "default", storedID: "stored", items: [
            .init(id: "first-row", text: text, role: .human), .init(id: "second-row", text: text, role: .human)
        ])
        #expect(results.count == 2)
        #expect(results[0].attachments.first?.id != results[1].attachments.first?.id)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let native = try DirectHermesConversationClient(rpc: transport, hostIdentity: "media-test", profile: "default",
            runtimeID: "runtime", storedID: "stored", title: "Media", epoch: "epoch",
            drafts: DirectHermesDraftStore(root: root), attachmentResolver: resolver)
        let model = ChatModel(conversationID: native.conversationID, client: native, initialItems: [])
        native.model = model
        transport.onRead = { native.suspend() }
        native.applySnapshot(.object(["session_id": .string("runtime"), "stored_session_id": .string("stored"),
            "running": .boolean(false), "messages": .array([.object(["role": .string("user"), "text": .string(text)])])]), epoch: "epoch")
        for _ in 0..<30 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(transport.requests.count == 3)
        #expect(model.items.first?.content == .message(text))
        #expect(model.items.first?.attachments.isEmpty == true)
    }

    private func generation() -> ChatActivityEvent {
        .init(eventID: "image-event", sessionID: "media-chat", turnID: "turn", kind: .tool,
              lifecycle: .running, title: "image_generate", summary: nil, detail: nil, occurredAt: 1,
              toolCallID: "image-call", toolName: "image_generate", sourceOrder: 1)
    }

    private func image() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    private func setup() throws -> (WorkspaceOwner, MediaTransport, DirectHermesWorkspaceClient) {
        let owner = WorkspaceOwner(authority: try .fixture(id: "media-host"), authenticationGeneration: UUID(), connectionGeneration: UUID())
        let transport = MediaTransport()
        let workspace = DirectHermesWorkspaceClient(rpc: transport, http: transport, owner: owner,
                                                    capabilities: .init(owner: owner), currentOwner: { owner })
        return (owner, transport, workspace)
    }
}

@MainActor
private final class MediaTransport: DirectHermesRPC, DirectHermesAuthenticatedHTTP {
    var onEvent: ((DirectHermesEvent) -> Void)?
    var onRead: (() -> Void)?
    var result: LoopdyJSONValue = .object([:])
    var requests: [DirectHermesHTTPRequest] = []
    var failure: (any Error)?
    func request(_ method: String, params: [String: LoopdyJSONValue]) async throws -> LoopdyJSONValue {
        throw WorkspaceClientError.invalidRequest
    }
    func request(_ request: DirectHermesHTTPRequest) async throws -> LoopdyJSONValue {
        requests.append(request)
        if let failure { throw failure }
        onRead?()
        return result
    }
    func disconnect() async {}
}

/// Isolated loopback fixture. It never reads disk or forwards a request.
private final class DeliveredFileHTTPFixture: @unchecked Sendable {
    private let listener: NWListener
    private let body: Data
    private let queue = DispatchQueue(label: "loopdy.test.delivered-file-http")
    private let lock = NSLock()
    private var capturedHeaders: String?
    private var didResumeStart = false
    var requestHeaders: String? { lock.withLock { capturedHeaders } }

    init(body: Data) throws {
        self.body = body
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    guard lock.withLock({ if didResumeStart { return false }; didResumeStart = true; return true }) else { return }
                    continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error):
                    guard lock.withLock({ if didResumeStart { return false }; didResumeStart = true; return true }) else { return }
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [self] connection in
                connection.start(queue: queue)
                receive(connection, prefix: Data())
            }
            listener.start(queue: queue)
        }
    }

    private func receive(_ connection: NWConnection, prefix: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [self] data, _, complete, error in
            guard error == nil, let data else { connection.cancel(); return }
            let request = prefix + data
            guard request.count <= 16_384 else { connection.cancel(); return }
            guard request.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if complete { connection.cancel() } else { receive(connection, prefix: request) }
                return
            }
            let headers = String(decoding: request, as: UTF8.self)
            lock.withLock { capturedHeaders = headers }
            guard headers.hasPrefix("GET /api/files/read?path="),
                  headers.lowercased().contains("authorization: bearer fixture-media-reader") else {
                connection.cancel(); return
            }
            let header = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    func stop() {
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
    }
}
