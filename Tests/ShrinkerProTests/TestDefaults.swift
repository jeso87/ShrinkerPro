import XCTest

extension XCTestCase {

    /// A `UserDefaults` suite private to one test, emptied when that test
    /// finishes.
    ///
    /// Three tests files used to build a suite inline —
    /// `UserDefaults(suiteName: "appmodel-\(UUID())")` and friends — and
    /// nothing ever removed it. `UserDefaults` persists a suite to
    /// `~/Library/Preferences/<suite>.plist` on first write, so every run
    /// of the suite left 9 plists behind, permanently, in the developer's
    /// real preferences directory. 810 of them had accumulated before it
    /// was noticed: 357 `shrinker-tests-`, 357 `appmodel-`, 96
    /// `appdelegate-`.
    ///
    /// The leak was invisible from inside the suite — tests passed either
    /// way, because the defect is in what a test leaves behind rather
    /// than in what it asserts. The fix is structural for the same
    /// reason: a teardown registered *here*, where the suite is created,
    /// cannot be forgotten by whoever adds the next test.
    ///
    /// ## What this does and does not achieve
    ///
    /// It stops written values persisting: a full run now leaves 9 empty
    /// 42-byte files rather than 9 files holding real settings (378
    /// bytes total, down from 855).
    ///
    /// It does **not** reduce the file count. A teardown block runs while
    /// the test case object is still alive, so the `Settings` (and any
    /// `AppModel` holding it) still has the suite open, and `cfprefsd`
    /// writes an empty plist straight back out after the removal. Three
    /// approaches were measured against a purged directory and all three
    /// left exactly 9 empty files: this teardown; this teardown plus an
    /// explicit unlink of the plist; and an `XCTestObservation` doing
    /// both at `testBundleDidFinish`, by which point every test case has
    /// been released. The simplest of the three is kept, since the extra
    /// machinery bought nothing.
    ///
    /// Eliminating the last 9 means not handing tests a real
    /// `UserDefaults` at all — `Settings` would take a small key-value
    /// protocol that an in-memory double satisfies. That is a change to
    /// production code to serve a test-hygiene problem, so it is
    /// deliberately not done here.
    ///
    /// - Parameter label: A short prefix identifying the calling suite in
    ///   the (transient) domain name. Purely diagnostic.
    func makeTestDefaults(_ label: String = "shrinker-tests") -> UserDefaults {
        let suite = "\(label)-\(UUID().uuidString)"
        // Force-unwrapped deliberately: `UserDefaults(suiteName:)` returns
        // nil only for a name matching the app's own domain or one of the
        // reserved global domains, and a UUID-suffixed label is neither.
        // A nil here would mean this helper's own naming scheme has
        // broken, so failing loudly beats handing back a store that
        // silently isn't isolated.
        let defaults = UserDefaults(suiteName: suite)!
        // A fresh UUID cannot collide with an existing domain; this is
        // belt-and-braces against a suite left over from a crashed run
        // that somehow reused the name.
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock {
            // Addressed by name rather than by capturing `defaults`:
            // `UserDefaults` is not `Sendable`, and capturing the
            // instance is rejected outright under Swift 6 strict
            // concurrency ("sending value of non-Sendable type
            // 'UserDefaults' risks causing data races"). Every
            // `UserDefaults` for a given suite name is a handle onto the
            // same underlying store, so the name is all this needs.
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        return defaults
    }
}
