import SwiftUI
import Testing
import UIKit
@testable import Loopdy

@MainActor
struct WorkspaceManagementLayoutTests {
    @Test(arguments: [
        CGSize(width: 320, height: 640),
        CGSize(width: 852, height: 393),
        CGSize(width: 768, height: 1_024),
        CGSize(width: 1_024, height: 768)
    ])
    func hubUsesNativeListAndFitsPhoneAndTablet(_ size: CGSize) async {
        let controller = UIHostingController(rootView:
            NavigationStack {
                WorkspaceHubView(hostName: "Demo Hermes", profileName: "Research", onOpen: { _ in })
            }
            .environment(\.dynamicTypeSize, .accessibility3)
            .environment(\.colorScheme, .dark)
        )
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        await Task.yield()
        controller.view.layoutIfNeeded()
        #expect(controller.view.bounds.width == size.width)
        #expect(controller.view.bounds.height == size.height)
        #expect(findScrollView(controller.view) != nil)
        #expect(allFramesAreFinite(controller.view))
    }

    @Test(arguments: [WorkspaceDestination.projects, .models, .files, .memory, .keys, .config, .webhooks])
    func managementViewsMountTheirRealFixtureContent(_ destination: WorkspaceDestination) async {
        let store = WorkspaceManagementStore(hostName: "Demo Hermes", profileName: "Research",
            client: FixtureWorkspaceManagementClient(), isCurrent: { true })
        await store.load(destination)
        let controller = UIHostingController(rootView:
            NavigationStack { WorkspaceManagementView(store: store, destination: destination) }
                .environment(\.dynamicTypeSize, .accessibility3)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        await Task.yield()
        controller.view.layoutIfNeeded()
        #expect(store.content != nil)
        #expect(store.errorMessage == nil)
        #expect(allFramesAreFinite(controller.view))
    }

    private func findScrollView(_ view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView { return scrollView }
        return view.subviews.lazy.compactMap { findScrollView($0) }.first
    }

    private func allFramesAreFinite(_ view: UIView) -> Bool {
        let rect = view.frame
        return rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
            && view.subviews.allSatisfy(allFramesAreFinite)
    }
}
