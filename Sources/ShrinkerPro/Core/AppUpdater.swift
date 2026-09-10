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

    init(settings: Settings) {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // Wire to the existing "Check for updates" setting rather than
        // trusting Info.plist's SUEnableAutomaticChecks (which is only a
        // bootstrap default — see the comment on that key) or Sparkle's own
        // separately-persisted preference.
        controller.updater.automaticallyChecksForUpdates = settings.updateCheck
    }

    /// Target of the "Check for Updates…" command in ShrinkerProApp.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    /// Called whenever the "Check for updates" toggle in Settings changes,
    /// so Sparkle's background polling tracks that one toggle live instead
    /// of only being read once at launch.
    func setAutomaticChecksEnabled(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }
}
