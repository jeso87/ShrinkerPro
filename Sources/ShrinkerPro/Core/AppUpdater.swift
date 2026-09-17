import Foundation
import Sparkle

/// Thin wrapper around Sparkle's `SPUStandardUpdaterController` — owns the
/// updater for the app's lifetime and is the target of ShrinkerProApp's
/// "Check for Updates…" command. Replaces the old `UpdateChecker`/
/// `UpdateBannerView` stub entirely: Sparkle now owns feed polling, the
/// update-found dialog, download progress, and install-and-relaunch, none
/// of which this app implements itself anymore.
///
/// `startingUpdater: true` means Sparkle's own background-check scheduling
/// starts immediately at construction (matching `SUFeedURL`/`SUPublicEDKey`
/// in Info.plist). Both delegates are nil — no customization hook is used;
/// Sparkle's default standard UI covers everything this app needs.
///
/// Checking is unconditional and daily. It used to follow a "Check for
/// updates" toggle in Settings, which is gone: Shrinker Pro is open source
/// and releases keep adding things people asked for, so an install that
/// never hears about them is the failure case. What is *not* automatic is
/// installing — `automaticallyDownloadsUpdates` is left alone (false), so a
/// new version is still something the user is told about and agrees to.
///
/// The "Check for Updates…" menu item is left permanently enabled rather
/// than reactively tracking `SPUUpdater.canCheckForUpdates` via KVO:
/// Sparkle's own UI already handles a repeat click while a check is in
/// flight (it re-shows the existing window rather than starting a second
/// check), and bridging an ObjC KVO callback into this `@MainActor` type
/// without inviting a Swift 6 strict-concurrency Sendable-closure warning
/// is not worth it for what would only ever be cosmetic here.
@MainActor
final class AppUpdater {
    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // Set explicitly rather than trusting Info.plist's
        // SUEnableAutomaticChecks/SUScheduledCheckInterval (bootstrap
        // defaults — see the comment on those keys) or Sparkle's own
        // separately-persisted preference, which is what a user who turned
        // the old toggle off would still be carrying.
        controller.updater.automaticallyChecksForUpdates = true
        // Sparkle's own default is also 86400. Stating it is the point: with
        // the Settings toggle gone, this one number is the entire update
        // policy, and a policy that exists only as somebody else's default
        // is one nobody knows they are relying on.
        controller.updater.updateCheckInterval = 86_400
    }

    /// Target of the "Check for Updates…" command in ShrinkerProApp.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
