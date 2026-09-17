import XCTest
@testable import ShrinkerPro

/// Pins the update-check schedule in the built `Info.plist`.
///
/// Automatic checking used to be a Settings toggle, which meant it was
/// covered by `SettingsTests` for free. It isn't a setting any more —
/// Shrinker Pro always checks, once a day — so the only surviving statement
/// of that policy is a pair of Sparkle keys in a plist, and a typo in a
/// plist key produces no build warning and no error. It produces an app
/// that quietly never checks, which nobody notices until a release goes
/// uncollected.
///
/// Reads the *built* bundle rather than the source plist, via
/// `ArchitectureGuardTests.builtAppURL()` — the `AppIconTests` pattern — so
/// what is asserted is what actually ships, not what a source file intends.
final class UpdateSchedulingTests: XCTestCase {

    private func builtInfoPlist() throws -> [String: Any] {
        let appURL = try ArchitectureGuardTests.builtAppURL()
        let url = appURL.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dict = plist as? [String: Any] else {
            throw XCTSkip("could not parse \(url.path) as a dictionary")
        }
        return dict
    }

    /// Sparkle's own default is 86400, so this pins a value rather than
    /// changing one — which is exactly why it is worth pinning. With the
    /// toggle gone, this interval is the entire update policy, and a default
    /// nobody has written down is a default somebody eventually "tidies".
    func testScheduledCheckIntervalIsOnceADay() throws {
        let plist = try builtInfoPlist()
        XCTAssertEqual(
            (plist["SUScheduledCheckInterval"] as? NSNumber)?.intValue, 86_400,
            "SUScheduledCheckInterval is not 86400 seconds in the built Info.plist — "
                + "Shrinker Pro is meant to check for updates once a day"
        )
    }

    func testAutomaticChecksAreEnabled() throws {
        let plist = try builtInfoPlist()
        XCTAssertEqual(
            plist["SUEnableAutomaticChecks"] as? Bool, true,
            "SUEnableAutomaticChecks is not true in the built Info.plist — "
                + "automatic update checking is no longer optional in this app"
        )
    }

    /// The line the user drew: check automatically, install on request.
    /// Sparkle defaults `SUAutomaticallyUpdate` to false, so the assertion
    /// is that nothing has turned it on — an absent key is the correct,
    /// passing state.
    func testUpdatesAreNeverInstalledWithoutAsking() throws {
        let plist = try builtInfoPlist()
        XCTAssertNotEqual(
            plist["SUAutomaticallyUpdate"] as? Bool, true,
            "SUAutomaticallyUpdate is true in the built Info.plist — "
                + "Shrinker Pro checks for updates on its own, but never installs one silently"
        )
    }
}
