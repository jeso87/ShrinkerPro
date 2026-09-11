import XCTest
import UserNotifications
@testable import ShrinkerPro

@MainActor
final class SettingsTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        makeTestDefaults()
    }

    func testDefaultsMatchUpstream() {
        let settings = Settings(defaults: makeDefaults())
        XCTAssertTrue(settings.notification)
        XCTAssertTrue(settings.saveInSameFolder)
        XCTAssertFalse(settings.clearList)
        XCTAssertTrue(settings.keepOriginal)
        XCTAssertTrue(settings.updateCheck)
        XCTAssertFalse(settings.useSubfolder)
        XCTAssertNil(settings.savePath)
    }

    func testValuesPersist() {
        let defaults = makeDefaults()
        let first = Settings(defaults: defaults)
        first.keepOriginal = false
        first.useSubfolder = true
        first.savePath = URL(fileURLWithPath: "/tmp/shrinker-dest")

        let second = Settings(defaults: defaults)
        XCTAssertFalse(second.keepOriginal)
        XCTAssertTrue(second.useSubfolder)
        XCTAssertEqual(second.savePath?.path, "/tmp/shrinker-dest")
    }

    // MARK: - Conversion rules (spec: one rule per convertible input format)

    /// Everything defaults to "keep original" except HEIC/HEIF → JPEG —
    /// the spec's one opinionated default. SVG and GIF have no rule at
    /// all, so there's nothing to assert a default for.
    func testConversionRuleDefaultsMatchSpec() {
        let settings = Settings(defaults: makeDefaults())
        XCTAssertEqual(settings.pngConversion, .keep)
        XCTAssertEqual(settings.jpegConversion, .keep)
        XCTAssertEqual(settings.webpConversion, .keep)
        XCTAssertEqual(settings.avifConversion, .keep)
        XCTAssertEqual(settings.heicConversion, .jpeg, "HEIC/HEIF is the one format that defaults to converting")
    }

    /// Someone may already have "keep" persisted for HEIC from before that
    /// option was removed — `conversionHEIC` used to hold a
    /// `ConversionTarget` rawValue, and `"keep"` was a legitimate value to
    /// write. Reading it back today must land on JPEG (the spec default),
    /// not crash (`ConversionFormat(rawValue: "keep")` is `nil` — there is
    /// no such case) and not silently fall through to some other,
    /// surprising format.
    func testStoredKeepForHEICMigratesToJPEGRatherThanCrashing() {
        let defaults = makeDefaults()
        // Written directly, bypassing `Settings`, to simulate a value a
        // previous version of this app actually persisted — `Settings`
        // itself can no longer write "keep" for HEIC at all, which is
        // exactly the guarantee under test.
        defaults.set("keep", forKey: "conversionHEIC")

        let settings = Settings(defaults: defaults)

        XCTAssertEqual(settings.heicConversion, .jpeg)
    }

    func testConversionRuleValuesPersist() {
        let defaults = makeDefaults()
        let first = Settings(defaults: defaults)
        first.pngConversion = .webp
        first.jpegConversion = .avif
        first.heicConversion = .webp
        first.webpConversion = .jpeg
        first.avifConversion = .webp

        let second = Settings(defaults: defaults)
        XCTAssertEqual(second.pngConversion, .webp)
        XCTAssertEqual(second.jpegConversion, .avif)
        XCTAssertEqual(second.heicConversion, .webp)
        XCTAssertEqual(second.webpConversion, .jpeg)
        XCTAssertEqual(second.avifConversion, .webp)
    }

    /// Same guard as `testExplicitValueMatchingDefaultStillPersists`
    /// above, for the conversion rules: setting HEIC's rule to its own
    /// registered default (.jpeg) is still an explicit write a fresh
    /// `Settings` instance must read back, not something that falls
    /// through to some other stored/derived value.
    func testExplicitConversionRuleMatchingDefaultStillPersists() {
        let defaults = makeDefaults()
        let first = Settings(defaults: defaults)
        first.heicConversion = .jpeg // registered default; still an explicit write
        first.pngConversion = .avif // sibling key, forces a fresh read below

        let second = Settings(defaults: defaults)
        XCTAssertEqual(second.heicConversion, .jpeg)
        XCTAssertEqual(second.pngConversion, .avif)
    }

    func testOutputSettingsProjectionCarriesConversionRules() {
        let settings = Settings(defaults: makeDefaults())
        settings.pngConversion = .webp
        settings.jpegConversion = .avif
        settings.heicConversion = .webp
        settings.webpConversion = .jpeg
        settings.avifConversion = .webp

        let rules = settings.outputSettings.conversionRules
        XCTAssertEqual(rules.png, .webp)
        XCTAssertEqual(rules.jpeg, .avif)
        XCTAssertEqual(rules.heic, .webp)
        XCTAssertEqual(rules.webp, .jpeg)
        XCTAssertEqual(rules.avif, .webp)
    }

    /// A `ConversionRules()` built without naming any field — the default
    /// used by every existing `OutputSettings` call site that doesn't
    /// care about conversion — must reproduce pre-conversion-feature
    /// behavior exactly for every format that has a "keep" to default to.
    /// HEIC has none (`ConversionFormat` has no `.keep` case at all — see
    /// its doc comment) and defaults straight to `.jpeg`, the spec's one
    /// opinionated default, baked into the type rather than layered on by
    /// `Settings.outputSettings`.
    func testBareConversionRulesDefaultsToKeepExceptHEICWhichHasNoKeepAtAll() {
        let rules = ConversionRules()
        XCTAssertEqual(rules.png, .keep)
        XCTAssertEqual(rules.jpeg, .keep)
        XCTAssertEqual(rules.heic, .jpeg)
        XCTAssertEqual(rules.webp, .keep)
        XCTAssertEqual(rules.avif, .keep)
    }

    func testOutputSettingsProjection() {
        let settings = Settings(defaults: makeDefaults())
        settings.saveInSameFolder = false
        settings.savePath = URL(fileURLWithPath: "/tmp/dest")
        settings.useSubfolder = true
        settings.keepOriginal = false

        let projected = settings.outputSettings
        XCTAssertFalse(projected.saveInSameFolder)
        XCTAssertEqual(projected.savePath?.path, "/tmp/dest")
        XCTAssertTrue(projected.useSubfolder)
        XCTAssertFalse(projected.keepOriginal)
    }

    /// Guards against a boolean write being mistaken for "unset" — setting a
    /// value to the same value as its registered default must still persist
    /// as an explicit write, not silently fall through to the default.
    func testExplicitValueMatchingDefaultStillPersists() {
        let defaults = makeDefaults()
        let first = Settings(defaults: defaults)
        // clearList's registered default is false; set it to false explicitly
        // (a no-op value-wise) then flip a sibling key to force a fresh
        // Settings instance to actually read the persisted domain rather than
        // reusing in-memory state.
        first.clearList = false
        first.notification = false

        let second = Settings(defaults: defaults)
        XCTAssertFalse(second.clearList)
        XCTAssertFalse(second.notification)
    }

    // MARK: - Notification permission (spec: a denial must be visible)

    /// The mapping is the whole safety of the feature: anything that maps
    /// to `.denied` puts a warning in Settings, and anything that maps to
    /// `.notDetermined` deliberately shows nothing (the next notification
    /// will prompt). Getting `.provisional`/`.ephemeral` wrong would warn a
    /// user whose notifications work fine. (`.ephemeral` is not covered
    /// because it is unavailable on macOS — App Clips only — and naming it
    /// does not compile here.)
    func testNotificationPermissionMapsAuthorizationStatuses() {
        XCTAssertEqual(NotificationPermission(.denied), .denied)
        XCTAssertEqual(NotificationPermission(.authorized), .allowed)
        XCTAssertEqual(NotificationPermission(.provisional), .allowed)
        XCTAssertEqual(NotificationPermission(.notDetermined), .notDetermined)
    }

    /// Before this, `Notifier` cached a `false` and returned, and the
    /// toggle stayed on with nothing to explain the silence. The notice
    /// must appear in exactly one situation — the app is promising
    /// notifications and the system has already refused — and nowhere else,
    /// or Settings grows a permanent scary warning for users who simply
    /// turned the feature off.
    func testDeniedNoticeShowsOnlyWhenToggleIsOnAndSystemDenied() {
        XCTAssertTrue(NotificationPermission.denied.showsDeniedNotice(toggleIsOn: true))
        XCTAssertFalse(NotificationPermission.denied.showsDeniedNotice(toggleIsOn: false))
        XCTAssertFalse(NotificationPermission.allowed.showsDeniedNotice(toggleIsOn: true))
        XCTAssertFalse(NotificationPermission.notDetermined.showsDeniedNotice(toggleIsOn: true))
    }

    /// The link is only useful if it actually opens the Notifications pane.
    /// The identifier is checked against the extension bundle that ships
    /// with the OS rather than being asserted as a bare string, so a
    /// renamed pane fails here instead of silently opening nothing.
    func testSystemSettingsLinkTargetsTheInstalledNotificationsPane() throws {
        let url = NotificationPermission.systemSettingsURL
        XCTAssertEqual(url.scheme, "x-apple.systempreferences")
        XCTAssertEqual(url.absoluteString.split(separator: ":").last.map(String.init),
                       "com.apple.Notifications-Settings.extension")

        let paneInfo = URL(fileURLWithPath:
            "/System/Library/ExtensionKit/Extensions/NotificationsSettings.appex/Contents/Info.plist")
        guard let plist = NSDictionary(contentsOf: paneInfo),
              let identifier = plist["CFBundleIdentifier"] as? String else {
            return XCTFail("could not read \(paneInfo.path) to confirm the Settings pane identifier")
        }
        XCTAssertEqual(
            identifier, "com.apple.Notifications-Settings.extension",
            "the Notifications settings pane identifier changed — NotificationPermission."
                + "systemSettingsURL now opens nothing"
        )
    }
}

// MARK: - Metadata policy, and the "Keep original files" rename

@MainActor
final class MetadataPolicySettingTests: XCTestCase {

    func testDefaultsToKeepingEverything() {
        let settings = Settings(defaults: makeTestDefaults())
        XCTAssertEqual(
            settings.metadataPolicy, .all,
            "any other default would start deleting EXIF from files JPEG -> JPEG round-trips intact today"
        )
    }

    func testThePolicyPersists() {
        let defaults = makeTestDefaults()
        let first = Settings(defaults: defaults)
        first.metadataPolicy = .copyright

        XCTAssertEqual(Settings(defaults: defaults).metadataPolicy, .copyright)
    }

    /// Same contract as `readTarget`: a value written by a future version of
    /// the app, naming a policy this build has never heard of, must come
    /// back as the default rather than crash on launch.
    func testAnUnrecognisedStoredPolicyFallsBackRatherThanCrashing() {
        let defaults = makeTestDefaults()
        defaults.set("some-future-policy", forKey: "metadata")

        XCTAssertEqual(Settings(defaults: defaults).metadataPolicy, .all)
    }

    /// `.stripped` is spelled that way in Swift to avoid colliding with
    /// `Optional.none`, but the *stored* value is still "none" — which is
    /// what a reader of the defaults database sees, and what any already
    /// released build would have written.
    func testStrippedPersistsUnderItsPlainName() {
        let defaults = makeTestDefaults()
        Settings(defaults: defaults).metadataPolicy = .stripped

        XCTAssertEqual(defaults.string(forKey: "metadata"), "none")
        XCTAssertEqual(Settings(defaults: defaults).metadataPolicy, .stripped)
    }

    /// The rename from `addSuffix` to `keepOriginal` was a rename of the
    /// *property*, not of the stored key, precisely so that nobody's
    /// existing preference had to be migrated. A preference written by the
    /// previous build must still be read, and with the same meaning.
    func testKeepOriginalStillReadsThePreviousBuildsStoredPreference() {
        let defaults = makeTestDefaults()
        // Exactly what a build predating the rename would have left behind.
        defaults.set(false, forKey: "suffix")

        let settings = Settings(defaults: defaults)
        XCTAssertFalse(
            settings.keepOriginal,
            "polarity is unchanged: a stored false still means 'overwrite the original'"
        )

        settings.keepOriginal = true
        XCTAssertTrue(defaults.bool(forKey: "suffix"), "the key must stay \"suffix\"")
    }

    func testThePolicyReachesTheEngineSnapshot() {
        let settings = Settings(defaults: makeTestDefaults())
        settings.metadataPolicy = .copyright

        XCTAssertEqual(settings.outputSettings.metadataPolicy, .copyright)
    }

    /// The session override is not a setting. Nothing in `Settings` should
    /// ever produce one, because nothing should ever persist one.
    func testTheSnapshotCarriesNoSessionOverride() {
        let settings = Settings(defaults: makeTestDefaults())
        XCTAssertNil(settings.outputSettings.sessionFormat)
    }
}
