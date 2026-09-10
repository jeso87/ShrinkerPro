import Foundation
import UserNotifications

/// Posts completion notifications. Authorization is requested the first time a
/// notification would actually be posted rather than at launch, so a user who
/// never enables the setting is never prompted.
///
/// An `actor` rather than a `final class`: `didRequestAuthorization` is mutated by
/// `ensureAuthorized()` with no lock, so the type is only safe to call from
/// multiple tasks concurrently if the isolation is structural, not a
/// caller-side convention (e.g. "AppModel happens to await this
/// sequentially today"). Actor isolation makes that guarantee the compiler
/// checks rather than something a future caller — e.g. Task 13's async
/// update-check path — has to notice and preserve. `notify`/
/// `ensureAuthorized` were already `async`, so no call site changes.
actor Notifier {

    /// Whether the system prompt has already been shown this launch. Only
    /// the *asking* is remembered, not the answer: caching a `false` (as an
    /// earlier version did) meant that a user who granted permission in
    /// System Settings kept getting nothing until they relaunched the app,
    /// and it also hid the denial from Settings. The live answer comes from
    /// `notificationSettings()` on every call, which is cheap.
    private var didRequestAuthorization = false

    func notify(title: String, body: String) async {
        guard await ensureAuthorized() else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // Upstream posts with silent: true.
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func ensureAuthorized() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch NotificationPermission(await center.notificationSettings().authorizationStatus) {
        case .allowed:
            return true
        case .denied:
            // Nothing to do here — SettingsView surfaces the denial and
            // offers a link to System Settings. Re-requesting would be a
            // no-op anyway: once denied, the system never shows the prompt
            // again.
            return false
        case .notDetermined:
            guard !didRequestAuthorization else { return false }
            didRequestAuthorization = true
            return (try? await center.requestAuthorization(options: [.alert])) ?? false
        }
    }
}
