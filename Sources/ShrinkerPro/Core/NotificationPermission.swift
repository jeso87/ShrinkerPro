import Foundation
import UserNotifications

/// Whether macOS will actually deliver the notifications the "Enable
/// notifications" setting promises.
///
/// Spec: "If the user denies it, the toggle reflects the denial and links to
/// System Settings rather than silently doing nothing." Authorization is
/// still requested lazily (a user who never enables the setting is never
/// prompted), so this exists to answer the *other* question — has the system
/// already said no? — which is the only case where the toggle would sit
/// there switched on while nothing ever appears.
enum NotificationPermission: Equatable {
    /// Never asked, or the user dismissed the system prompt without
    /// deciding. Not a problem to surface: the next notification will ask.
    case notDetermined
    case allowed
    case denied

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .denied:
            self = .denied
        // `.ephemeral` is deliberately absent: it is unavailable on
        // macOS (App Clips only), so naming it here does not compile.
        // It would fall to `@unknown default` anyway.
        case .authorized, .provisional:
            self = .allowed
        case .notDetermined:
            self = .notDetermined
        @unknown default:
            // A status this build doesn't know about is not evidence of a
            // denial, and claiming one would put a scary, wrong warning in
            // Settings. Treat it as "no finding".
            self = .notDetermined
        }
    }

    /// The one combination where the UI would otherwise lie to the user:
    /// the toggle is on, so the app is promising notifications, and the
    /// system has already refused to deliver them. `.notDetermined`
    /// deliberately shows nothing — that state resolves itself the first
    /// time a notification is actually posted.
    func showsDeniedNotice(toggleIsOn: Bool) -> Bool {
        toggleIsOn && self == .denied
    }

    static func current() async -> NotificationPermission {
        NotificationPermission(
            await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        )
    }

    /// Deep link to System Settings ▸ Notifications. The identifier is the
    /// bundle id of /System/Library/ExtensionKit/Extensions/
    /// NotificationsSettings.appex, which is how the modern (Ventura and
    /// later) Settings app addresses its panes.
    static let systemSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
    )!
}
