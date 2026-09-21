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

    /// Every plural entry must carry at least `one` and `other` for English.
    ///
    /// When translations land (Phase 2) this test grows to assert each
    /// language's own categories — and it must read them from the
    /// platform's CLDR data at test time, never from a table written out
    /// by hand. Commit `0febcf7` amended the spec specifically to disown
    /// such a table: it goes stale between CLDR releases, and one wrong
    /// row means a language ships missing a plural form. Do not reinstate
    /// one here.
    func testEnglishPluralEntriesHaveBothCategories() throws {
        let data = try Data(contentsOf: Self.catalogURL(named: "Localizable"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(json["strings"] as? [String: Any])

        // Anchor on the walking-skeleton entry by name before drilling into
        // the general loop below. Without this, a corruption that turns the
        // plural entry into a flat stringUnit (or a catalog that regresses
        // to zero entries) just gets skipped by the loop's `guard ... else
        // { continue }` — the very failure this test exists to catch.
        let notificationTitleKey = "%lld images shrunk"
        let notificationTitleEntry = try XCTUnwrap(
            strings[notificationTitleKey] as? [String: Any],
            "the walking-skeleton plural entry '\(notificationTitleKey)' is gone from the catalog"
        )
        let notificationTitlePlural = try XCTUnwrap(
            ((notificationTitleEntry["localizations"] as? [String: Any])?["en"] as? [String: Any])
                .flatMap { ($0["variations"] as? [String: Any])?["plural"] as? [String: Any] },
            "'\(notificationTitleKey)' has no English plural variations"
        )
        XCTAssertNotNil(notificationTitlePlural["one"], "\(notificationTitleKey) has no 'one' form for English")
        XCTAssertNotNil(notificationTitlePlural["other"], "\(notificationTitleKey) has no 'other' form for English")

        // General sweep over every plural entry, so later tasks' plurals
        // get covered without editing this test again. `examined` guards
        // against the same vacuous-pass risk the anchor above closes for
        // one key: if the catalog stopped declaring any plural entries at
        // all, this loop's body would run zero times and silently report
        // success. Do not remove this count in a later cleanup — a loop
        // with no assertions inside it that ever fired is not a passing
        // test, it's an untested one.
        var examined = 0
        for (key, entry) in strings {
            guard
                let entry = entry as? [String: Any],
                let localizations = entry["localizations"] as? [String: Any],
                let english = localizations["en"] as? [String: Any],
                let variations = english["variations"] as? [String: Any],
                let plural = variations["plural"] as? [String: Any]
            else { continue }

            examined += 1
            XCTAssertNotNil(plural["one"], "\(key) has no 'one' form for English")
            XCTAssertNotNil(plural["other"], "\(key) has no 'other' form for English")
        }
        XCTAssertGreaterThan(examined, 0, "no plural entries were examined — the test would have passed vacuously")
    }

    /// `errorDescription` is the CLI's. `main.swift` prints it to stderr at
    /// lines 196 and 382, and scripts parse that output, so it must stay
    /// English whatever the app is running in. The app reads
    /// `localizedMessage` instead.
    func testErrorDescriptionStaysEnglishForTheCLI() {
        let error = ShrinkError.unsupportedFormat("tiff")

        XCTAssertEqual(
            error.errorDescription,
            "Only SVG, PNG, GIF, JPEG, WebP, AVIF, HEIC and HEIF are supported (got \"tiff\").",
            "errorDescription is the CLI's contract — see the localization spec's 'The Core seam'"
        )
    }

    /// One sample of every `ShrinkError` case, including both shapes of
    /// `compressorFailed` — the tool said something, and the tool said
    /// nothing — because those resolve through two different catalog
    /// entries rather than one with a Swift-built separator.
    static let everyShrinkErrorCase: [ShrinkError] = [
        .unsupportedFormat("tiff"),
        .helperMissing("cjpeg"),
        .compressorFailed(tool: "cjpeg", code: 1, message: "bad"),
        .compressorFailed(tool: "cjpeg", code: 1, message: ""),
        .javascriptFailed("boom"),
        .outputNotWritten(URL(fileURLWithPath: "/tmp/x.png")),
        .conversionFailed("boom"),
    ]

    /// The app's path is separate, and for English says the same thing —
    /// for *every* case, not one sampled case. `Compressor.swift` writes
    /// each of these sentences out twice, once for the CLI and once for the
    /// catalog, and a divergence between the two copies is invisible until
    /// someone reads them side by side. This is that reading.
    ///
    /// Skipped unless the app itself resolves to English. The comparison
    /// puts a *translated* value (`localizedMessage`) against an English
    /// one (`errorDescription`), so from Phase 2 on it would fail on a
    /// German machine for a reason that is not a defect — the seam working
    /// exactly as the spec's "The Core seam" intends.
    func testLocalizedMessageMatchesEnglishForEveryCase() throws {
        try XCTSkipUnless(
            Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true,
            "localizedMessage resolves through the catalog, so it only matches the English errorDescription when the app resolves to English. Running as: \(Bundle.main.preferredLocalizations)"
        )

        for error in Self.everyShrinkErrorCase {
            XCTAssertEqual(
                error.localizedMessage,
                error.errorDescription,
                "the catalog's English and the CLI's English have drifted apart for \(error)"
            )
        }
    }

    /// Every ShrinkError case must answer both, or the app will silently
    /// fall back to English for one of them. Unlike the test above this one
    /// is locale-independent: it asserts only that neither form is empty.
    func testEveryShrinkErrorCaseHasBothForms() {
        for error in Self.everyShrinkErrorCase {
            XCTAssertFalse(error.localizedMessage.isEmpty, "\(error) has no localizedMessage")
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "\(error) has no errorDescription")
        }
    }

    /// Nothing may ship needing review. In this phase that means every entry
    /// has English; in Phase 2 this same test covers all 36 languages.
    func testNoEntryIsLeftNeedingReview() throws {
        let data = try Data(contentsOf: Self.catalogURL(named: "Localizable"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(json["strings"] as? [String: Any])

        XCTAssertFalse(strings.isEmpty, "the catalog is empty — did extraction run?")

        for (key, entry) in strings {
            guard let entry = entry as? [String: Any] else { continue }
            if let state = entry["extractionState"] as? String {
                XCTAssertNotEqual(state, "stale", "\(key) is stale — it is in the catalog but no longer in the source")
            }
            let localizations = entry["localizations"] as? [String: Any]
            XCTAssertNotNil(localizations?["en"], "\(key) has no English")
        }
    }

    /// The catalog and the build must agree in BOTH directions.
    ///
    /// Nothing may sit in the catalog once the source that produced it is
    /// gone: Phase 2 translates this catalog into 36 languages, so an
    /// orphaned entry is a fragment someone pays to translate 36 times for
    /// no reason. And nothing the build emits may be missing from the
    /// catalog, which is the more expensive direction of the two — an
    /// orphan wastes 36 translations, a missing key ships a string the
    /// user can actually see untranslated in all 36 languages. Catching
    /// either here is what keeps the cost from compounding release over
    /// release.
    ///
    /// The `extractionState == "stale"` assertion above can never actually
    /// fire in this pipeline: marking an entry stale is an Xcode.app IDE
    /// behaviour, and the catalog is merged by `scripts/sync-catalog.py`
    /// instead, which never writes that state. So this test drives the
    /// real script — which does its own orphan comparison against a real
    /// build's `.stringsdata` — rather than re-implementing that
    /// comparison here in Swift, where the two could quietly drift apart.
    /// `--check` guarantees the run cannot mutate the catalog as a side
    /// effect of merely checking it.
    ///
    /// This needs a previous `xcodebuild build` to have produced
    /// `.stringsdata` under DerivedData — there is no way to trigger a
    /// fresh build from inside a test without this test's own xcodebuild
    /// recursively invoking itself. When no prior build is found, the
    /// comparison is genuinely inconclusive rather than trivially green,
    /// so it is skipped rather than reported as passing.
    func testCatalogMatchesTheBuildsExtractedKeys() throws {
        let script = Self.repoRoot().appendingPathComponent("scripts/sync-catalog.py")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path, "--check"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        // The script's exit codes are a vocabulary, not a boolean: each
        // one says something different about the catalog, and collapsing
        // them would report a broken tool as a catalog finding.
        let report = "\n\(stdout)\(stderr)"
        switch process.terminationStatus {
        case 0:
            break
        case 1:
            XCTFail("sync-catalog.py --check found ORPHANED catalog entries — keys in Localizable.xcstrings the build no longer produces. Run `python3 scripts/sync-catalog.py --prune`.\(report)")
        case 2:
            // An environment gap, not a catalog defect: no prior build to
            // compare against at all (see the script's own docstring).
            throw XCTSkip("No prior ShrinkerPro build found under DerivedData, so sync-catalog.py --check has nothing to compare the catalog against. Run `xcodebuild build -scheme ShrinkerPro` first.\(report)")
        case 3:
            XCTFail("sync-catalog.py --check found keys the build emits that are MISSING from Localizable.xcstrings — those strings would ship untranslated in all 36 languages. Run `python3 scripts/sync-catalog.py`.\(report)")
        case 4:
            XCTFail("sync-catalog.py itself failed — this is a tooling defect, not a catalog finding, and the catalog is UNCHECKED until it is fixed.\(report)")
        default:
            XCTFail("sync-catalog.py could not be run (exit \(process.terminationStatus)) — is python3 on PATH? The catalog is unchecked.\(report)")
        }
    }

    /// The glossary names English terms that must render consistently. A term
    /// that no longer appears anywhere in the catalog is guidance about a
    /// string that no longer exists — which is how a glossary quietly rots
    /// into being wrong rather than merely stale.
    func testEveryGlossaryTermStillAppearsInTheCatalog() throws {
        let glossary = try String(
            contentsOf: Self.repoRoot().appendingPathComponent("docs/localization-glossary.md"),
            encoding: .utf8
        )
        let terms = glossary
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard line.hasPrefix("- **"),
                      let close = line.range(of: "**", range: line.index(line.startIndex, offsetBy: 4)..<line.endIndex)
                else { return nil }
                return String(line[line.index(line.startIndex, offsetBy: 4)..<close.lowerBound])
            }
        XCTAssertFalse(terms.isEmpty, "parsed no terms — has the glossary's format changed?")

        let data = try Data(contentsOf: Self.catalogURL(named: "Localizable"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let keys = try XCTUnwrap(json["strings"] as? [String: Any]).keys.joined(separator: "\n").lowercased()

        for term in terms {
            XCTAssertTrue(
                keys.contains(term.lowercased()),
                "glossary term '\(term)' appears in no catalog key — remove it or fix the term"
            )
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
