import XCTest
import SwiftUI
@testable import Loopdy

final class NativeAgentCreationVisualTests: XCTestCase {
    @MainActor
    func testNativeCreationShowsOnlySupportedOptionsAndSeparateName() async throws {
        let suite = "NativeAgentCreationVisualTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AgentDirectoryStore(
            client: AgentDirectoryFixtureClient(profiles: [.defaultFixture, .financeFixture]),
            defaults: defaults
        )
        try await store.load()
        let model = AgentEditorModel.creating(store: store, processor: AvatarImageProcessor(),
                                               profileCloneSupport: .nativeBundleOnly)
        model.setSkipBundledSkills(true)
        model.selectCloneSource(AgentProfile.financeFixture.id)
        XCTAssertFalse(model.draft.skipBundledSkills)
        XCTAssertTrue(model.draft.name.isEmpty)
        XCTAssertTrue(model.cloneSources.contains { $0.id == AgentProfile.financeFixture.id })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        func content() -> some View {
            AgentEditorView(
                model: model,
                onCompleted: { _ in }
            )
            .environment(\.loopdyUIV3Enabled, true)
            .environment(\.nerdModeEnabled, true)
            .environment(\.appAppearance, LoopdyAppearanceContext(appearance: .light, themeID: .loopdy))
            .environment(\.colorScheme, .light)
        }
        let host = UIHostingController(rootView: content())
        host.safeAreaRegions = []
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        capture(window, name: "native-creation-required-name-and-avatar")
        let basicForm = try XCTUnwrap(viewHierarchy(in: host.view).compactMap { $0 as? UICollectionView }.first)
        XCTAssertEqual(basicForm.numberOfSections, 3)
        let advancedIndexPath = IndexPath(item: 0, section: 2)
        basicForm.scrollToItem(at: advancedIndexPath, at: .bottom, animated: false)
        basicForm.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNotNil(basicForm.cellForItem(at: advancedIndexPath), "The Advanced route must be reachable in the mounted editor form.")
        basicForm.delegate?.collectionView?(basicForm, didSelectItemAt: advancedIndexPath)
        for _ in 0..<20 where advancedNavigationTitle(in: host) != "Advanced" {
            try await Task.sleep(for: .milliseconds(50))
            host.view.layoutIfNeeded()
        }
        XCTAssertEqual(advancedNavigationTitle(in: host), "Advanced")
        let advancedForm = try XCTUnwrap(
            viewHierarchy(in: host.view).compactMap { $0 as? UICollectionView }.first {
                $0.numberOfSections == 2
                    && $0.numberOfItems(inSection: 0) == 4
                    && $0.numberOfItems(inSection: 1) == 1
            }
        )
        XCTAssertTrue(viewHierarchy(in: advancedForm).contains { $0 is UISwitch })
        capture(window, name: "native-creation-clone-and-skip-bundled-skills")
        XCTAssertTrue(model.draft.name.isEmpty)
        XCTAssertEqual(store.profiles.first { $0.id == AgentProfile.financeFixture.id }, .financeFixture)
    }

    @MainActor
    private func viewHierarchy(in root: UIView) -> [UIView] {
        [root] + root.subviews.flatMap { viewHierarchy(in: $0) }
    }

    @MainActor
    private func advancedNavigationTitle(in root: UIViewController) -> String? {
        func navigationController(in controller: UIViewController) -> UINavigationController? {
            if let navigation = controller as? UINavigationController { return navigation }
            return controller.children.lazy.compactMap(navigationController).first
        }
        return navigationController(in: root)?.topViewController?.navigationItem.title
    }

    @MainActor
    private func capture(_ window: UIWindow, name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
