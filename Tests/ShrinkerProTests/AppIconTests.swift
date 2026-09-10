import XCTest

/// A generated icon's artwork isn't unit-testable — there is no assertion
/// that can judge "does this read as a compression metaphor at 16px". What
/// *is* testable, and has actually bitten this project before (see the
/// brief for Task 14), is the icon being silently unwired: an asset catalog
/// that compiles cleanly but never reaches the shipped bundle, or an
/// `AppIcon` set that exists on disk but isn't hooked up via
/// `ASSETCATALOG_COMPILER_APPICON_NAME`, in which case the app falls back
/// to the generic system icon with no build error or warning at all.
///
/// These assertions are chosen to be falsifiable: deleting
/// `AppIcon.appiconset` from sources, or removing
/// `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` from project.yml, makes
/// one of them fail. Reuses `ArchitectureGuardTests.builtAppURL()`, which
/// already knows how to locate the built app bundle from this hosted test
/// target (walking up to the first `.app` ancestor, with an `XCTSkip`
/// fallback naming the build command when nothing has been built yet).
final class AppIconTests: XCTestCase {

    /// The asset catalog must actually be compiled into the shipped bundle,
    /// not merely present in source. Catches: the catalog failing to
    /// register as a build input (e.g. added without `xcodegen generate`,
    /// per this project's known glob-at-generation-time pitfall).
    func testAssetCatalogIsCompiledIntoBundle() throws {
        let appURL = try ArchitectureGuardTests.builtAppURL()
        let assetsCar = appURL.appendingPathComponent("Contents/Resources/Assets.car")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: assetsCar.path),
            "no Assets.car at \(assetsCar.path) — the asset catalog did not compile into the app bundle"
        )
    }

    /// The compiled Info.plist must actually name "AppIcon" as the app
    /// icon. This is the specific failure mode the brief warns about: a
    /// well-formed asset catalog that simply isn't wired via
    /// ASSETCATALOG_COMPILER_APPICON_NAME produces no build warning and no
    /// error — just a silent fallback to the generic app icon at runtime.
    /// Checking Info.plist (not just that Assets.car exists) is what makes
    /// this test able to catch that specific case: Assets.car would still
    /// be emitted even if no app icon were configured at all.
    func testInfoPlistNamesAppIconAsBundleIcon() throws {
        let appURL = try ArchitectureGuardTests.builtAppURL()
        let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: infoPlistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dict = plist as? [String: Any] else {
            XCTFail("could not parse \(infoPlistURL.path) as a dictionary")
            return
        }
        XCTAssertEqual(
            dict["CFBundleIconName"] as? String, "AppIcon",
            "CFBundleIconName is not \"AppIcon\" in the built Info.plist — "
                + "ASSETCATALOG_COMPILER_APPICON_NAME may not be wired, "
                + "which silently falls back to the generic system icon"
        )
    }

    /// The asset catalog on disk must declare every size macOS expects for
    /// a mac app icon set, so a partial catalog (which actool may compile
    /// without warning) doesn't ship with missing resolutions.
    func testAppIconContentsJSONDeclaresAllExpectedSizes() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/ShrinkerProTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let contentsJSON = repoRoot.appendingPathComponent(
            "Sources/ShrinkerPro/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json"
        )
        let data = try Data(contentsOf: contentsJSON)
        let plist = try JSONSerialization.jsonObject(with: data)
        guard let dict = plist as? [String: Any], let images = dict["images"] as? [[String: Any]] else {
            XCTFail("could not parse \(contentsJSON.path) as expected")
            return
        }

        let expected: Set<String> = [
            "16x16@1x", "16x16@2x", "32x32@1x", "32x32@2x",
            "128x128@1x", "128x128@2x", "256x256@1x", "256x256@2x",
            "512x512@1x", "512x512@2x",
        ]
        let declared = Set(images.compactMap { image -> String? in
            guard let size = image["size"] as? String, let scale = image["scale"] as? String else { return nil }
            return "\(size)@\(scale)"
        })
        XCTAssertEqual(declared, expected, "AppIcon.appiconset/Contents.json is missing expected mac icon sizes")

        // Every declared filename must exist alongside Contents.json.
        let iconsetDir = contentsJSON.deletingLastPathComponent()
        for image in images {
            guard let filename = image["filename"] as? String else {
                XCTFail("an entry in Contents.json has no filename: \(image)")
                continue
            }
            let path = iconsetDir.appendingPathComponent(filename).path
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), "declared icon file missing: \(path)")
        }
    }
}
