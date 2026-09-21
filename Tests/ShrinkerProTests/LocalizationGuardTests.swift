import XCTest
@testable import ShrinkerPro

/// Guards the localization contract described in
/// `docs/design/specs/2026-09-20-localization-design.md`.
///
/// In the style of `ArchitectureGuardTests`: these assert facts about the
/// built product and the checked-in catalogs, not about one function's
/// return value.
final class LocalizationGuardTests: XCTestCase {

    /// The 36 languages the app declares, matching Sparkle's own set so the
    /// app and its update dialog are never in different languages.
    static let expectedRegions: Set<String> = [
        "en", "ar", "ca", "cs", "da", "de", "el", "es", "fa", "fi", "fr",
        "he", "hr", "hu", "is", "it", "ja", "ko", "nb", "nl", "nn", "pl",
        "pt-BR", "pt-PT", "ro", "ru", "sk", "sl", "sv", "th", "tr", "uk",
        "vi", "zh-Hans", "zh-Hant", "zh-HK",
    ]

    func testDeclaresAllThirtySixRegions() throws {
        let yaml = try String(contentsOf: Self.repoRoot().appendingPathComponent("project.yml"), encoding: .utf8)
        guard let range = yaml.range(of: #"KNOWN_REGIONS:\s*\[[^\]]*\]"#, options: .regularExpression) else {
            return XCTFail("project.yml has no KNOWN_REGIONS")
        }
        let declared = Set(
            yaml[range]
                .replacingOccurrences(of: "KNOWN_REGIONS:", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " \n[]"))
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        )
        XCTAssertEqual(declared, Self.expectedRegions)
    }

    /// The CLI must never gain the regions — that omission is what keeps
    /// `shrinker`'s stderr English. See the spec's "Build configuration".
    ///
    /// Bounded to the `shrinker` TARGET's own block: "\n  shrinker:" also
    /// matches the `shrinker` scheme further down in project.yml, so an
    /// unbounded slice from the first match to end-of-file would silently
    /// scan past the target into the schemes section too. Cutting at the
    /// next top-level YAML key (a line starting at column 0, e.g.
    /// "schemes:") keeps this test scoped to the target it's meant to
    /// guard.
    func testCLITargetHasNoRegions() throws {
        let yaml = try String(contentsOf: Self.repoRoot().appendingPathComponent("project.yml"), encoding: .utf8)
        guard let cliRange = yaml.range(of: "\n  shrinker:") else {
            return XCTFail("project.yml has no shrinker target")
        }
        let afterTargetStart = yaml[cliRange.lowerBound...]
        guard let nextTopLevelKey = afterTargetStart.range(
            of: #"\n[^\s\n]"#,
            options: .regularExpression,
            range: afterTargetStart.index(after: afterTargetStart.startIndex)..<afterTargetStart.endIndex
        ) else {
            return XCTFail("could not find the end of the shrinker target block in project.yml")
        }
        let cliSection = afterTargetStart[afterTargetStart.startIndex..<nextTopLevelKey.lowerBound]

        // Sanity check: make sure we actually sliced the shrinker target's
        // own block, not an empty or wrong range — a test that slices an
        // empty string would pass vacuously.
        XCTAssertTrue(
            cliSection.contains("sources:"),
            "sliced section doesn't look like the shrinker target block: \(cliSection.prefix(200))"
        )

        XCTAssertFalse(
            cliSection.contains("KNOWN_REGIONS"),
            "the shrinker target must stay English — see the localization spec"
        )
    }

    func testBothCatalogsExistAndDeclareEnglishAsSource() throws {
        for name in ["Localizable", "InfoPlist"] {
            let data = try Data(contentsOf: Self.catalogURL(named: name))
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(json?["sourceLanguage"] as? String, "en", "\(name).xcstrings")
            XCTAssertNotNil(json?["strings"], "\(name).xcstrings has no strings object")
        }
    }

    // MARK: - Helpers

    static func catalogURL(named name: String) throws -> URL {
        repoRoot()
            .appendingPathComponent("Sources/ShrinkerPro/Resources")
            .appendingPathComponent("\(name).xcstrings")
    }

    /// Mirrors `OverwriteGuardTests`' and `ArchitectureGuardTests`' own
    /// repo-root lookup: SRCROOT is only set for Xcode build phases, not
    /// for the test runner's runtime environment, so the real fallback
    /// resolves from this file's own location (`#filePath`) rather than
    /// walking up from the xctest bundle — the bundle lives deep under
    /// DerivedData, which never contains `project.yml`, so a bundle-based
    /// walk-up never finds the repo root and silently falls through to
    /// `FileManager.default.currentDirectoryPath` (observed to be `/` under
    /// `xcodebuild test`). This file lives at
    /// `Tests/ShrinkerProTests/LocalizationGuardTests.swift`, so walking up
    /// three directories reaches the repo root regardless of where the test
    /// executable happens to run from.
    static func repoRoot() -> URL {
        ProcessInfo.processInfo.environment["SRCROOT"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // Tests/ShrinkerProTests
                .deletingLastPathComponent()  // Tests
                .deletingLastPathComponent()  // repo root
    }
}
