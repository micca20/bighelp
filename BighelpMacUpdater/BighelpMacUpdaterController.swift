import AppKit
import Sparkle

/// bighelp for Mac's updates. Sparkle is AppKit-only, so it lives in this macOS
/// bundle, which the Catalyst app loads from Contents/PlugIns and drives through
/// the Objective-C runtime (`BighelpMacUpdates` in the app). Keep the `@objc`
/// names below in step with it.
///
/// Sparkle's own windows make the offer: release notes, Install Update, Remind Me
/// Later, Skip This Version, then download progress and Install and Relaunch.
/// Info.plist holds the feed, the EdDSA public key and the schedule; nothing
/// installs without the person saying so.
@objc(BighelpMacUpdaterController)
@MainActor
final class BighelpMacUpdaterController: NSObject, SPUUpdaterDelegate {
    /// A test feed in place of Info.plist's SUFeedURL. The app checks it first.
    @objc var feedURLOverride: String?
    /// Off for Debug builds, which share the release's app ID: they never offer to
    /// replace themselves unless asked.
    @objc var checksInBackground = true

    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil
    )
    private var checkedSinceLaunch = false

    @objc func start() {
        controller.startUpdater()
    }

    @objc func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        feedURLOverride
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if updateCheck == .updatesInBackground, !checksInBackground {
            throw CocoaError(.userCancelled)
        }
        checkedSinceLaunch = true
    }

    /// Sparkle checks only once its interval has passed since the last check; bighelp
    /// also checks each time it opens. Sparkle schedules right after it starts, so the
    /// first schedule without a check means this launch hasn't checked yet.
    func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        guard !checkedSinceLaunch, checksInBackground else { return }
        checkedSinceLaunch = true
        // After Sparkle finishes scheduling; it ignores a check while a session runs.
        Task { @MainActor in
            guard !updater.sessionInProgress else { return }
            updater.checkForUpdatesInBackground()
        }
    }
}
