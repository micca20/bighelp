import XCTest
import SwiftUI
@testable import Bighelp

final class ProviderDisplayNameTests: XCTestCase {
    @MainActor
    func testDistinctCopilotProviderNamesRenderInPicker() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "hermes-model-options-provider-display-names", withExtension: "json"))
        let value = try JSONDecoder().decode(BighelpJSONValue.self, from: Data(contentsOf: url))
        let providers = Array(try DirectHermesAgentRuntimeDefaultsClient.decodeModelProviders(XCTUnwrap(value.object)).prefix(3))
        for provider in providers {
            XCTAssertEqual(AIProviderVisibleIdentity.resolve(providerID: provider.id, providerName: provider.name).visibleProviderName, provider.name)
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let content = BighelpModelPickerSheet(title: "Choose model", scopeLabel: "Current chat", providers: providers,
            currentProviderID: nil, currentModelID: nil, isLoading: false, isApplying: false,
            errorMessage: nil, onClearError: {}, onRetry: nil, onSelect: { _, _ in })
            .environment(\.bighelpUIV3Enabled, true)
            .environment(\.appAppearance, BighelpAppearanceContext(appearance: .light, themeID: .bighelp))
            .environment(\.colorScheme, .light)
        let host = UIHostingController(rootView: content)
        host.safeAreaRegions = []
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        await Task.yield()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "distinct-copilot-provider-names"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    @MainActor
    func testStockProviderNamesSurviveNativeDecoder() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "hermes-model-options-provider-display-names", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let nativeObject = try XCTUnwrap(JSONDecoder().decode(BighelpJSONValue.self, from: data).object)
        let native = try DirectHermesAgentRuntimeDefaultsClient.decodeModelProviders(nativeObject)
        let expected = ["GitHub Copilot", "GitHub Copilot ACP", "Copilot Adaptive", "Azure Foundry", "OpenCode Free", "litellm"]
        XCTAssertEqual(native.map(\.name), expected)
        XCTAssertEqual(Set(native.map(\.id)).count, expected.count)
        for provider in native.prefix(3) {
            XCTAssertEqual(AIProviderBrandRegistry.resolve(id: provider.id, name: provider.name), .githubCopilot)
        }
    }

    @MainActor
    func testAPIKeyRowsNameTheProviderAndTheSettingEvenWithoutAHostLabel() {
        func key(_ id: String, label: String? = "", provider: String? = "", isSet: Bool = false) -> DirectHermesProviderCredential {
            DirectHermesProviderCredential(id: id, providerID: provider, providerName: label, description: "",
                category: "provider", isSet: isSet, isSecret: true, isAdvanced: false, isCustom: false, isChannelManaged: false)
        }
        XCTAssertEqual(ProviderCredentialPresentation.title(key("ACTUAL_COMPUTER_API_KEY", label: "Actual Computer")),
                       "Actual Computer API key")
        XCTAssertEqual(ProviderCredentialPresentation.title(key("ACTUAL_COMPUTER_BASE_URL", label: "Actual Computer")),
                       "Actual Computer base URL")
        // Blank host label: named from the variable itself.
        XCTAssertEqual(ProviderCredentialPresentation.title(key("NOUS_BASE_URL")), "Nous base URL")
        XCTAssertEqual(ProviderCredentialPresentation.title(key("OPENROUTER_API_KEY", label: nil)), "OpenRouter API key")
        XCTAssertEqual(ProviderCredentialPresentation.title(key("KIMI_CN_API_KEY", label: "  ")), "Kimi China API key")
        XCTAssertEqual(ProviderCredentialPresentation.title(key("MODEL_API_KEY", label: "Meta Model API")),
                       "Meta Model API key")
        XCTAssertEqual(ProviderCredentialPresentation.title(key("CUSTOM_THING")), "Custom Thing")
        XCTAssertEqual(ProviderCredentialPresentation.subtitle(key("XAI_API_KEY", isSet: true)),
                       "XAI_API_KEY · Configured on Hermes")
        XCTAssertEqual(ProviderCredentialPresentation.sorted([key("XAI_API_KEY"), key("DEEPSEEK_API_KEY")]).map(\.id),
                       ["DEEPSEEK_API_KEY", "XAI_API_KEY"])
    }
}
