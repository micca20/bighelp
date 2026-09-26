import Foundation
import Testing
import UIKit
@testable import Loopdy

/// Agent `MEDIA:` deliveries resolve through the plugin's provenance-bound route.
@MainActor
struct DirectHermesNativeAttachmentTests {
    @Test func assistantMediaResolvesThroughPluginInBoundedChunksAndStripsTheDirective() async throws {
        let owner = try makeOwner()
        let http = AttachmentHTTP(features: ["native-agent-attachments-v1"])
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 10, height: 10)).pdfData { $0.beginPage() }
        http.file = pdf
        http.chunk = 40
        let workspace = DirectHermesWorkspaceClient(rpc: NoRPC(), http: http, owner: owner,
                                                    capabilities: .init(owner: owner), currentOwner: { owner })
        let resolver = DirectHermesGeneratedMediaClient(workspace: workspace, owner: owner, currentOwner: { owner })
        let text = "Here is the report. MEDIA://Users/me/Downloads/Report.pdf"
        let result = try #require(try await resolver.resolve(agentID: "default", storedID: "stored",
                                                             items: [.init(id: "m1", text: text)]).first)
        #expect(result.text == "Here is the report.")
        #expect(result.attachments.map(\.fileName) == ["Report.pdf"])
        #expect(result.attachments.first?.data == pdf)
        #expect(result.attachments.first?.mimeType == "application/pdf")
        let paths = http.requests.map(\.path).filter { !$0.hasSuffix("/context") }
        #expect(paths.first == "/api/plugins/loopdy/native/attachments/resolve")
        #expect(paths.dropFirst().allSatisfy { $0 == "/api/plugins/loopdy/native/attachments/fetch" })
        #expect(paths.count == 1 + (pdf.count + 39) / 40)
        #expect(!http.requests.contains { $0.path == "/api/media" || $0.path == "/api/files/read" })
    }

    @Test func refusedResolutionKeepsTheOriginalTextReadable() async throws {
        let owner = try makeOwner()
        let http = AttachmentHTTP(features: ["native-agent-attachments-v1"])
        http.file = nil
        let workspace = DirectHermesWorkspaceClient(rpc: NoRPC(), http: http, owner: owner,
                                                    capabilities: .init(owner: owner), currentOwner: { owner })
        let resolver = DirectHermesGeneratedMediaClient(workspace: workspace, owner: owner, currentOwner: { owner })
        let text = "MEDIA:/etc/passwd.txt"
        let result = try #require(try await resolver.resolve(agentID: "default", storedID: "stored",
                                                             items: [.init(id: "m1", text: text)]).first)
        #expect(result.text == text)
        #expect(result.attachments.isEmpty)
    }

    @Test func hostsWithoutThePluginRouteFallBackToStockMediaReads() async throws {
        let owner = try makeOwner()
        let http = AttachmentHTTP(features: [])
        let workspace = DirectHermesWorkspaceClient(rpc: NoRPC(), http: http, owner: owner,
                                                    capabilities: .init(owner: owner), currentOwner: { owner })
        let resolver = DirectHermesGeneratedMediaClient(workspace: workspace, owner: owner, currentOwner: { owner })
        _ = try? await resolver.resolve(agentID: "default", storedID: "stored",
                                        items: [.init(id: "m1", text: "MEDIA:/host/.hermes/cache/images/a.png")])
        #expect(http.requests.contains { $0.path == "/api/media" })
        #expect(!http.requests.contains { $0.path.contains("/attachments/") })
    }

    @Test func inlineAndGluedDirectivesScheduleResolution() {
        #expect(DirectHermesGeneratedMediaClient.hasAttachmentDirectives("See MEDIA:/a/b.pdf now", role: .assistant))
        #expect(DirectHermesGeneratedMediaClient.hasAttachmentDirectives("MEDIA://a/b.mov", role: .assistant))
        #expect(!DirectHermesGeneratedMediaClient.hasAttachmentDirectives("No files here", role: .assistant))
        #expect(!DirectHermesGeneratedMediaClient.hasAttachmentDirectives("MEDIA:/a/b.pdf", role: .human))
    }

    private func makeOwner() throws -> WorkspaceOwner {
        WorkspaceOwner(authority: try .direct(endpointIdentity: "https://fixture.example.test", providerID: "test", userID: "files"),
                       authenticationGeneration: UUID(), connectionGeneration: UUID())
    }
}

@MainActor
private final class NoRPC: DirectHermesRPC {
    var onEvent: ((DirectHermesEvent) -> Void)?
    func request(_ method: String, params: [String: LoopdyJSONValue]) async throws -> LoopdyJSONValue {
        throw WorkspaceClientError.invalidRequest
    }
    func disconnect() async {}
}

@MainActor
private final class AttachmentHTTP: DirectHermesAuthenticatedHTTP, DirectHermesNativeHTTP {
    let features: [String]
    var file: Data?
    var chunk = 1_024
    var requests: [DirectHermesHTTPRequest] = []
    init(features: [String]) { self.features = features }

    func request(_ request: DirectHermesHTTPRequest) async throws -> LoopdyJSONValue {
        requests.append(request)
        throw WorkspaceClientError.transportUnavailable
    }

    func nativeResponse(_ request: DirectHermesHTTPRequest,
                        requestGuard: DirectHermesNativeRequestGuard?) async throws -> DirectHermesHTTP.Response {
        requests.append(request)
        let etag = "\"sha256:" + String(repeating: "b", count: 64) + "\""
        var headers = ["ETag": etag, "Cache-Control": "no-store"]
        let object: [String: LoopdyJSONValue]
        if request.path.hasSuffix("/context") {
            object = ["schemaVersion": .integer(1), "pluginVersion": .string("test"), "runtimeId": .string("rt"),
                      "servingProfileId": .string("default"),
                      "principal": .object(["provider": .string("test"), "userId": .string("files"), "displayName": .null]),
                      "features": .array((["native-context-v1", "serving-profile-v1"] + features).map(LoopdyJSONValue.string))]
        } else {
            headers["X-Loopdy-Request-ID"] = try #require(requestGuard).requestIDHeader
            let body = try #require(request.body)
            if request.path.hasSuffix("/resolve") {
                let item = try #require(body["items"]?.array?.first?.object)
                let attachments: [LoopdyJSONValue] = file.map { data in
                    [.object(["id": .string(String(repeating: "c", count: 32)), "fileName": .string("Report.pdf"),
                              "mimeType": .string("application/pdf"), "byteCount": .integer(data.count)])]
                } ?? []
                object = ["items": .array([.object(["itemId": item["itemId"]!,
                    "text": .string(file == nil ? item["text"]!.string! : "Here is the report."),
                    "attachments": .array(attachments)])])]
            } else {
                let data = try #require(file)
                let offset = try #require(body["offset"]?.integer)
                let end = min(data.count, offset + chunk)
                object = ["attachmentId": body["attachmentId"]!, "offset": .integer(offset), "byteCount": .integer(data.count),
                          "mimeType": .string("application/pdf"),
                          "data": .string(data[offset..<end].base64EncodedString()),
                          "nextOffset": end < data.count ? .integer(end) : .null]
            }
        }
        let url = try #require(URL(string: "https://fixture.example.test" + request.path))
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers))
        return .init(http: response, body: try JSONEncoder().encode(LoopdyJSONValue.object(object)))
    }
}
