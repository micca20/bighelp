import Foundation
import Testing
@testable import Loopdy

@MainActor
struct DirectHermesNativeContextTests {
    @Test func dashboardGrantCannotBeConfusedWithAProviderPerson() throws {
        let authority = try WorkspaceAuthority.dashboard(endpointIdentity: "https://host.example:9119")
        let dashboard = WorkspaceOwner(authority: authority, authenticationGeneration: UUID(), connectionGeneration: UUID())
        var value = context(); value["principal"] = .null
        let request = DirectHermesHTTPRequest(path: "/api/plugins/loopdy/native/context", method: .get)
        let response = try response(request, body: value)
        let decoded = try DirectHermesNativeContext(response: response, owner: dashboard)
        #expect(decoded.providerID == nil && decoded.userID == nil)
        #expect(throws: WorkspaceClientError.invalidResponse) { try DirectHermesNativeContext(response: response, owner: owner()) }
        let personResponse = try self.response(request, body: context())
        #expect(throws: WorkspaceClientError.invalidResponse) { try DirectHermesNativeContext(response: personResponse, owner: dashboard) }
    }

    @Test(arguments: [WorkspaceOperation.projectsGitCapabilities, .projectsGitStatus, .projectsGitDiff])
    func nativeGitReadsUseOnlyAdvertisedFixedRoutes(operation: WorkspaceOperation) async throws {
        let owner = try owner()
        let http = HTTP()
        var payload: [String: LoopdyJSONValue] = [
            "agentId": .string("default"), "sessionId": .string("full-native-stored-id"),
            "workspaceId": .string("registered-project")
        ]
        if operation == .projectsGitDiff {
            payload.merge(["path": .string("README.md"), "side": .string("worktree"),
                           "statusToken": .string(String(repeating: "a", count: 64)),
                           "offset": .integer(0), "limit": .integer(50)]) { _, value in value }
        }
        http.handler = { request, guardValue in
            if let guardValue {
                return try self.response(request, body: ["observed": .boolean(true)],
                                         headers: ["ETag": guardValue.etag, "X-Loopdy-Request-ID": guardValue.requestIDHeader])
            }
            return try self.response(request, body: self.context(features: [
                "native-context-v1", "serving-profile-v1", "native-project-git-read-v1"
            ]))
        }
        let client = DirectHermesNativePluginClient(http: http, owner: owner, currentOwner: { owner })
        _ = try await client.perform(operation, payload: payload)
        #expect(http.calls.count == 2)
        let suffix = try #require(operation.rawValue.split(separator: ".").last)
        #expect(http.calls[1].request.path == "/api/plugins/loopdy/native/projects/git/" + suffix)
        #expect(http.calls[1].request.method == .post)
        #expect(http.calls[1].request.maximumResponseBytes == 196_608)
        #expect(http.calls[1].request.body == payload)
        #expect(http.calls[1].guardValue?.etag == etag)
        #expect(!DirectHermesNativePluginClient.supports(.projectsGitPrepare))
        #expect(!DirectHermesNativePluginClient.supports(.projectsGitExecute))
    }

    @Test func verifiedContextBindsPrincipalAndDiscardsUnrecognizedFields() async throws {
        let owner = try owner()
        let http = HTTP()
        http.handler = { request, _ in
            var context = self.context()
            context["unrecognized_secret"] = .string("never projected")
            return try self.response(request, body: context)
        }
        let client = DirectHermesNativePluginClient(http: http, owner: owner, currentOwner: { owner })
        let result = try await client.loadContext()
        #expect(result.providerID == "basic")
        #expect(result.userID == "person")
        #expect(result.servingProfileID == "default")
        #expect(result.projection["unrecognized_secret"] == nil)
        #expect(http.calls.first?.request.maximumResponseBytes == 16_384)
        #expect(http.calls.first?.guardValue == nil)
    }

    @Test func missingAdvertisedFeatureNeverDispatchesAnOperation() async throws {
        let owner = try owner()
        let http = HTTP()
        http.handler = { request, _ in
            try self.response(request, body: self.context(features: ["native-context-v1", "serving-profile-v1"]))
        }
        let client = DirectHermesNativePluginClient(http: http, owner: owner, currentOwner: { owner })
        await #expect(throws: WorkspaceClientError.unavailable(.unsupportedOperation)) {
            try await client.perform(.wikiConnect, payload: ["agentId": .string("default")])
        }
        #expect(http.calls.count == 1)
    }

    @Test func templateReadUsesOnlyFixedPathAndExactContextHeaders() async throws {
        let owner = try owner()
        let http = HTTP()
        http.handler = { request, guardValue in
            if let guardValue {
                return try self.response(request, body: ["agentId": .string("default"), "templates": .array([])],
                                         headers: ["ETag": guardValue.etag, "X-Loopdy-Request-ID": guardValue.requestIDHeader])
            }
            return try self.response(request, body: self.context())
        }
        let client = DirectHermesNativePluginClient(http: http, owner: owner, currentOwner: { owner })
        _ = try await client.perform(.cardsTemplatesList, payload: ["agentId": .string("default")])
        #expect(http.calls.count == 2)
        #expect(http.calls[1].request.path == "/api/plugins/loopdy/native/cards/templates/list")
        #expect(http.calls[1].request.method == .post)
        let guardValue = try #require(http.calls[1].guardValue)
        #expect(guardValue.etag == etag)
        #expect(guardValue.requestIDHeader == guardValue.requestID.uuidString.lowercased())
    }

    @Test func contextPreconditionFailureRetiresContextWithoutReplayingMutation() async throws {
        let owner = try owner()
        let http = HTTP()
        http.handler = { request, guardValue in
            if guardValue != nil {
                return try self.response(request, status: 412,
                                         body: ["error": .object(["code": .string("context_changed")])], headers: [:])
            }
            return try self.response(request, body: self.context())
        }
        let client = DirectHermesNativePluginClient(http: http, owner: owner, currentOwner: { owner })
        await #expect(throws: WorkspaceClientError.conflict) {
            try await client.perform(.cardsTemplatesRemove, payload: ["agentId": .string("default")])
        }
        #expect(client.context == nil)
        #expect(http.calls.count == 2)
    }

    @Test func lostMutationReplyRemainsUnknownAndIsNotRetried() async throws {
        let owner = try owner()
        let http = HTTP()
        http.handler = { request, guardValue in
            if guardValue != nil { throw WorkspaceClientError.transportUnavailable }
            return try self.response(request, body: self.context())
        }
        let client = DirectHermesNativePluginClient(http: http, owner: owner, currentOwner: { owner })
        await #expect(throws: WorkspaceClientError.outcomeUnknown) {
            try await client.perform(.cardsTemplatesInstall, payload: ["agentId": .string("default")])
        }
        #expect(http.calls.count == 2)
    }

    @Test func successRequiresEchoedRequestAndContextWhileErrorsDoNotRequireETag() async throws {
        let owner = try owner()
        let http = HTTP()
        http.handler = { request, guardValue in
            if guardValue != nil { return try self.response(request, body: [:], headers: [:]) }
            return try self.response(request, body: self.context())
        }
        let client = DirectHermesNativePluginClient(http: http, owner: owner, currentOwner: { owner })
        await #expect(throws: WorkspaceClientError.outcomeUnknown) {
            try await client.perform(.cardsTemplatesInstall, payload: ["agentId": .string("default")])
        }
        #expect(client.context == nil)
        http.handler = { request, guardValue in
            if guardValue != nil {
                return try self.response(request, status: 404, body: [
                    "error": .object(["code": .string("WIKI_AUTHORITY_CONFLICT"), "message": .string("private details")]),
                ], headers: [:])
            }
            return try self.response(request, body: self.context())
        }
        await #expect(throws: WorkspaceClientError.rejected(code: "WIKI_AUTHORITY_CONFLICT")) {
            try await client.perform(.wikiRead, payload: ["agentId": .string("default")])
        }
    }

    @Test func changedOwnerOrByteDistinctPrincipalCannotAdoptContext() async throws {
        let owner = try owner()
        var current: WorkspaceOwner? = owner
        let http = HTTP()
        http.handler = { request, _ in
            current = nil
            return try self.response(request, body: self.context())
        }
        let client = DirectHermesNativePluginClient(http: http, owner: owner, currentOwner: { current })
        await #expect(throws: WorkspaceClientError.ownerChanged) { try await client.loadContext() }
        #expect(client.context == nil)
        let composed = try self.owner(userID: "caf\u{e9}")
        let mismatch = try response(.init(path: "/api/plugins/loopdy/native/context", method: .get),
                                    body: context(userID: "cafe\u{301}"))
        #expect(throws: WorkspaceClientError.invalidResponse) {
            try DirectHermesNativeContext(response: mismatch, owner: composed)
        }
    }

    @Test func contextGuardRejectsUnboundedOrMalformedHeaders() {
        for value in ["sha256:" + String(repeating: "a", count: 64), "\"sha256:bad\"", etag + "\r\nx: y"] {
            #expect(throws: WorkspaceClientError.invalidResponse) { try DirectHermesNativeRequestGuard(etag: value) }
        }
    }

    private var etag: String { "\"sha256:" + String(repeating: "a", count: 64) + "\"" }

    private func owner(userID: String = "person") throws -> WorkspaceOwner {
        WorkspaceOwner(authority: try .direct(endpointIdentity: "https://host.example", providerID: "basic", userID: userID),
                       authenticationGeneration: UUID(), connectionGeneration: UUID())
    }

    private func context(userID: String = "person", features: [String] = [
        "native-context-v1", "serving-profile-v1", "native-card-templates-v1", "native-wiki-v1",
    ]) -> [String: LoopdyJSONValue] {
        [
            "schemaVersion": .integer(1), "pluginVersion": .string("test"), "runtimeId": .string("runtime-test"),
            "servingProfileId": .string("default"),
            "principal": .object(["provider": .string("basic"), "userId": .string(userID), "displayName": .null]),
            "features": .array(features.map(LoopdyJSONValue.string)),
        ]
    }

    private func response(_ request: DirectHermesHTTPRequest, status: Int = 200,
                          body: [String: LoopdyJSONValue], headers: [String: String]? = nil) throws -> DirectHermesHTTP.Response {
        let url = try #require(URL(string: "https://host.example" + request.path))
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: headers ?? ["ETag": etag, "Cache-Control": "no-store"]
        ))
        return .init(http: response, body: try JSONEncoder().encode(LoopdyJSONValue.object(body)))
    }

    @MainActor private final class HTTP: DirectHermesNativeHTTP {
        struct Call {
            let request: DirectHermesHTTPRequest
            let guardValue: DirectHermesNativeRequestGuard?
        }
        var calls: [Call] = []
        var handler: ((DirectHermesHTTPRequest, DirectHermesNativeRequestGuard?) throws -> DirectHermesHTTP.Response)?
        func nativeResponse(_ request: DirectHermesHTTPRequest,
                            requestGuard: DirectHermesNativeRequestGuard?) async throws -> DirectHermesHTTP.Response {
            calls.append(Call(request: request, guardValue: requestGuard))
            guard let handler else { throw WorkspaceClientError.transportUnavailable }
            return try handler(request, requestGuard)
        }
    }
}
