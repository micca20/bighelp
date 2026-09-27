#if DEBUG && targetEnvironment(simulator)
import Foundation
import SwiftUI

/// `-test-models-page`: the Models page against a synthetic host, so UI tests can
/// check the profile default, auxiliary task and Mixture of Agents pickers.
enum ModelAdministrationFixture {
    static let launchArgument = "-test-models-page"

    @MainActor
    static func rootView() -> some View {
        let owner = WorkspaceOwner(
            authority: try! .direct(endpointIdentity: "https://models.example", providerID: "basic", userID: "person"),
            authenticationGeneration: UUID(),
            connectionGeneration: UUID()
        )
        let client = DirectHermesModelAdministrationClient(
            rpc: FixtureRPC(), http: FixtureHTTP(), owner: owner, currentOwner: { owner }
        )
        return NavigationStack {
            ModelAdministrationView(hostName: "Demo host", profileID: "default", client: client)
        }
        .environment(\.bighelpUIV3Enabled, true)
    }

    private final class FixtureRPC: DirectHermesRPC {
        var onEvent: ((DirectHermesEvent) -> Void)?
        func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
            throw WorkspaceClientError.unavailable(.policyRestricted)
        }
        func disconnect() async {}
    }

    /// Answers the Models page's reads and remembers assignments.
    @MainActor
    private final class FixtureHTTP: DirectHermesAuthenticatedHTTP {
        private var main = (provider: "openai", model: "gpt-5.6")
        private var tasks: [(task: String, provider: String, model: String)] = [
            ("vision", "auto", ""), ("compression", "anthropic", "claude-haiku-4-5"), ("title_generation", "auto", "")
        ]

        func request(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
            switch request.path {
            case "/api/model/options":
                return .object(["providers": .array([
                    provider("openai", "OpenAI", ["gpt-5.6", "gpt-5.6-mini"], current: main.provider == "openai"),
                    provider("anthropic", "Anthropic", ["claude-sonnet-5", "claude-haiku-4-5"], current: main.provider == "anthropic"),
                    provider("nous", "Nous Research", ["Hermes-4-405B", "Hermes-4-70B"], current: main.provider == "nous"),
                ])])
            case "/api/model/info":
                return .object([
                    "provider": .string(main.provider), "model": .string(main.model),
                    "auto_context_length": .integer(400_000), "config_context_length": .integer(0),
                    "effective_context_length": .integer(400_000), "capabilities": .null,
                ])
            case "/api/model/auxiliary":
                return .object([
                    "main": .object(["provider": .string(main.provider), "model": .string(main.model)]),
                    "tasks": .array(tasks.map {
                        .object(["task": .string($0.task), "provider": .string($0.provider), "model": .string($0.model),
                                 "base_url": .string(""), "local_endpoint": .boolean(false)])
                    }),
                ])
            case "/api/model/moa":
                return .object([
                    "default_preset": .string("balanced"), "active_preset": .string(""),
                    "presets": .object(["balanced": .object([
                        "reference_models": .array([
                            .object(["provider": .string("openai"), "model": .string("gpt-5.6")]),
                            .object(["provider": .string("anthropic"), "model": .string("claude-sonnet-5")]),
                        ]),
                        "aggregator": .object(["provider": .string("nous"), "model": .string("Hermes-4-405B")]),
                        "degraded_reference_policy": .string("loud"), "enabled": .boolean(true),
                    ])]),
                ])
            case "/api/model/set":
                let body = request.body ?? [:]
                let provider = body["provider"]?.string ?? "", model = body["model"]?.string ?? ""
                if body["scope"]?.string == "main" {
                    main = (provider, model)
                } else if let task = body["task"]?.string, let index = tasks.firstIndex(where: { $0.task == task }) {
                    tasks[index] = (task, provider, model)
                }
                return .object(["ok": .boolean(true)])
            default:
                throw WorkspaceClientError.unavailable(.policyRestricted)
            }
        }

        private func provider(_ slug: String, _ name: String, _ models: [String], current: Bool) -> BighelpJSONValue {
            .object(["slug": .string(slug), "name": .string(name), "models": .array(models.map { .string($0) }),
                     "is_current": .boolean(current)])
        }
    }
}
#endif
