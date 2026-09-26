import SwiftUI
import Testing
import UIKit
import WidgetKit
@testable import Bighelp

/// Renders each widget layout with representative data so a layout that
/// compiles but collapses or clips is caught, and saves PNGs for review.
@MainActor
struct BighelpWidgetRenderTests {
    static let sizes: [(String, CGSize)] = [("small", .init(width: 170, height: 170)),
                                            ("medium", .init(width: 364, height: 170)),
                                            ("large", .init(width: 364, height: 382))]

    @Test func everyWidgetRendersNonEmptyAtItsSizes() throws {
        let snapshot = BighelpWidgetSnapshot(defaultAgentID: "default", defaultAgentName: "Juno", sessions: [
            .init(id: "a", title: "Fix the bighelp build", agentName: "Juno", status: "Running tests",
                  preview: nil, isRunning: true, updatedAt: .now.addingTimeInterval(-40)),
            .init(id: "b", title: "Weekend plans", agentName: "Juno", status: "Replied",
                  preview: "Saturday looks clear after 2 PM.", isRunning: false, updatedAt: .now.addingTimeInterval(-900)),
        ], tasks: [.init(id: "t", name: "Morning brief", agentName: "Juno", schedule: "Every day at 7:00 AM",
                         nextRun: .now.addingTimeInterval(3600), lastResult: nil)], generatedAt: .now)
        let out = ProcessInfo.processInfo.environment["BIGHELP_WIDGET_RENDER_DIR"].map(URL.init(fileURLWithPath:))
        for (name, size) in Self.sizes {
            // widgetFamily is read-only outside WidgetKit, so this renders each
            // view's default (small) branch; the feed renders its list at every size.
            let views: [(String, AnyView)] = [
                ("sessions", AnyView(BighelpActiveSessionsView(snapshot: snapshot))),
                ("tasks", AnyView(BighelpScheduledTasksView(snapshot: snapshot))),
                ("newchat", AnyView(BighelpNewChatView(snapshot: snapshot))),
                ("feed", AnyView(BighelpActivityFeedView(snapshot: snapshot))),
            ]
            for (kind, view) in views {
                let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height)
                    .padding(16).background(Color(uiColor: .secondarySystemBackground)))
                renderer.scale = 2
                let image = try #require(renderer.uiImage, "\(kind) \(name) did not render")
                #expect(image.size.width >= size.width && image.size.height >= size.height)
                if let out, let data = image.pngData() {
                    try data.write(to: out.appendingPathComponent("widget-\(kind)-\(name).png"))
                }
            }
        }
    }

    /// The agent widget and recent chats at every Home Screen size, in the
    /// app's light and dark colors, saved for review.
    @Test func agentWidgetRendersEveryFamilyInBothModes() throws {
        let snapshot = BighelpWidgetSnapshot.preview
        let quiet = BighelpWidgetSnapshot(defaultAgentID: "default", defaultAgentName: "Juno", sessions: [],
                                         tasks: [], generatedAt: .now, feed: snapshot.feed, goals: snapshot.goals)
        let out = ProcessInfo.processInfo.environment["BIGHELP_WIDGET_RENDER_DIR"].map(URL.init(fileURLWithPath:))
        let families: [(String, WidgetFamily, CGSize)] = [("small", .systemSmall, Self.sizes[0].1),
                                                          ("medium", .systemMedium, Self.sizes[1].1),
                                                          ("large", .systemLarge, Self.sizes[2].1)]
        for scheme in [ColorScheme.light, .dark] {
            let colors = BighelpWidgetColors(snapshot: snapshot, scheme: scheme, isFullColor: true)
            for (name, family, size) in families {
                let views: [(String, AnyView)] = [
                    ("agent", AnyView(BighelpAgentWidgetView(snapshot: snapshot, familyOverride: family))),
                    ("agent-quiet", AnyView(BighelpAgentWidgetView(snapshot: quiet, familyOverride: family))),
                    ("recent", AnyView(BighelpActivityFeedView(snapshot: snapshot, familyOverride: family))),
                    ("sessions", AnyView(BighelpActiveSessionsView(snapshot: snapshot))),
                    ("tasks", AnyView(BighelpScheduledTasksView(snapshot: snapshot))),
                    ("newchat", AnyView(BighelpNewChatView(snapshot: snapshot))),
                ]
                for (kind, view) in views {
                    if ["sessions", "tasks", "newchat"].contains(kind), family != .systemSmall { continue }
                    let content = view
                        .padding(16)
                        .frame(width: size.width, height: size.height)
                        .environment(\.bighelpWidgetColors, colors)
                        .environment(\.colorScheme, scheme)
                        .foregroundStyle(colors.primary)
                        .background(colors.canvas)
                        .clipShape(.rect(cornerRadius: 22))
                    let renderer = ImageRenderer(content: content)
                    renderer.scale = 2
                    let image = try #require(renderer.uiImage, "\(kind) \(name) did not render")
                    #expect(image.size.width >= size.width && image.size.height >= size.height)
                    if let out, let data = image.pngData() {
                        try data.write(to: out.appendingPathComponent("widget2-\(kind)-\(name)-\(scheme == .dark ? "dark" : "light").png"))
                    }
                }
            }
        }
    }
}
