import Foundation
#if targetEnvironment(macCatalyst)
import Observation
import OSLog
import SwiftUI
import UIKit
#endif

/// Where bighelp for Mac looks for updates. Builds read the public feed from
/// Info.plist's `SUFeedURL`; a test points one at a local feed with the launch
/// argument `-bighelp.mac.update-feed-url <url>`. The feed must be signed and every
/// update must carry an EdDSA signature that matches `SUPublicEDKey`, so a
/// different feed can't install anything bighelp didn't sign.
enum BighelpMacUpdateFeed {
    static let overrideKey = "bighelp.mac.update-feed-url"

    /// The override, if it's usable: HTTPS, or plain HTTP to this Mac only.
    static func overrideURL(_ value: String?) -> URL? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              value.utf8.count <= 2048, let url = URL(string: value),
              let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil
        else { return nil }
        switch url.scheme?.lowercased() {
        case "https": return url
        case "http": return ["127.0.0.1", "localhost", "::1"].contains(host) ? url : nil
        default: return nil
        }
    }

    /// "2.3.0 (60)", from an Info.plist.
    static func versionLabel(_ info: [String: Any]?) -> String {
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty || build == version ? version : "\(version) (\(build))"
    }
}

#if targetEnvironment(macCatalyst)
/// Sparkle in bighelp for Mac. Sparkle is AppKit-only, so it lives in
/// BighelpMacUpdater.bundle (Contents/PlugIns), loaded here at launch and driven
/// through the Objective-C runtime; the Catalyst app never links it.
@MainActor
@Observable
final class BighelpMacUpdates {
    static let shared = BighelpMacUpdates()

    /// False when the updater bundle is missing or didn't load: the menu item and
    /// the Settings button turn off instead of doing nothing.
    private(set) var isAvailable = false
    @ObservationIgnored private var updater: NSObject?
    @ObservationIgnored private var willRelaunch: NSObjectProtocol?
    @ObservationIgnored private let log = Logger(subsystem: "app.loopdy.mobile", category: "MacUpdates")

    /// Starts Sparkle's schedule: a check now and every few hours after.
    func start() {
        guard updater == nil else { return }
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("BighelpMacUpdater.bundle"),
              let bundle = Bundle(url: url)
        else {
            log.error("The updater bundle is missing.")
            return
        }
        do {
            try bundle.loadAndReturnError()
        } catch {
            log.error("The updater bundle didn't load: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let type = bundle.principalClass as? NSObject.Type else {
            log.error("The updater bundle has no principal class.")
            return
        }
        let updater = type.init()
        guard updater.responds(to: Self.startSelector), updater.responds(to: Self.checkSelector) else {
            log.error("The updater bundle doesn't match this app.")
            return
        }
        let override = BighelpMacUpdateFeed.overrideURL(
            UserDefaults.standard.string(forKey: BighelpMacUpdateFeed.overrideKey)
        )
        updater.setValue(override?.absoluteString, forKey: "feedURLOverride")
        #if DEBUG
        // Debug builds share the release's app ID; they check by themselves only for a test feed.
        updater.setValue(override != nil, forKey: "checksInBackground")
        #endif
        // Install and Relaunch asks the app to quit, and an open sheet (Settings is one)
        // blocks quitting on the Mac. Sparkle posts this just before it asks.
        willRelaunch = NotificationCenter.default.addObserver(
            forName: Notification.Name("SUUpdaterWillRestartNotificationName"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { Self.closeSheets() }
        }
        updater.perform(Self.startSelector)
        self.updater = updater
        isAvailable = true
    }

    /// Sparkle's window: the offer with release notes, or "You're up to date".
    func checkForUpdates() {
        updater?.perform(Self.checkSelector)
    }

    private static func closeSheets() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows where window.rootViewController?.presentedViewController != nil {
                window.rootViewController?.dismiss(animated: false)
            }
        }
    }

    private static let startSelector = NSSelectorFromString("start")
    private static let checkSelector = NSSelectorFromString("checkForUpdates")
}

/// Settings › Help & feedback on the Mac: the version, with Check for Updates.
struct BighelpMacUpdatesRow: View {
    var body: some View {
        LabeledContent {
            Button("Check for Updates") { BighelpMacUpdates.shared.checkForUpdates() }
                .disabled(!BighelpMacUpdates.shared.isAvailable)
                .accessibilityIdentifier("settings.mac-updates.check")
        } label: {
            Text("Version")
            Text(BighelpMacUpdateFeed.versionLabel(Bundle.main.infoDictionary))
                .accessibilityIdentifier("settings.mac-updates.version")
        }
    }
}
#endif
