# Localization Phase 1 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put Shrinker Pro's user-facing text into a String Catalog and remove
every place where English grammar is compiled into Swift — with no change to
what an English user sees.

**Architecture:** Add `Localizable.xcstrings` and `InfoPlist.xcstrings` to the
`ShrinkerPro` target only, so the `shrinker` CLI stays English. Replace
hand-built plurals (`count == 1 ? :`) with catalog plural variations, replace
mid-sentence string concatenation with single catalog entries, and split
`Core`'s error text into a CLI-facing English `errorDescription` and an
app-facing `localizedMessage`. No translations land in this phase.

**Tech Stack:** Swift 6.4, SwiftUI, XcodeGen 2.46, XCTest, String Catalogs
(`.xcstrings`).

**Spec:** `docs/design/specs/2026-09-20-localization-design.md`

## Global Constraints

- **English output must not change.** `OverwriteRequestCopyTests`,
  `AppModelTests` and `RecentHeaderFormatterTests` pin exact wording. They
  pass **unmodified** except where this plan says otherwise and says why.
- **The `shrinker` CLI stays English.** Never add `KNOWN_REGIONS`,
  `DEVELOPMENT_LANGUAGE` or `SWIFT_EMIT_LOC_STRINGS` to the `shrinker` target.
  Never make `errorDescription` or `helpText` locale-dependent.
- **Source language is `en`.** `DEVELOPMENT_LANGUAGE: en`,
  `CFBundleDevelopmentRegion` stays `en`.
- **American spelling for "center"** (`center`, `centered`). The rest of the
  repo stays British ("optimised", "pluralisation") — do not "fix" those.
- **No translations in this phase.** Only `en` localizations in either catalog.
- **`UserDefaults` keys are a compatibility surface.** Never rename one.
- **Run tests with:** `xcodebuild test -project ShrinkerPro.xcodeproj -scheme ShrinkerPro -destination 'platform=macOS'`
- **After editing `project.yml`, always run `xcodegen generate` before building.**

---

### Task 1: Catalog infrastructure

Create both catalogs and declare the 36 regions. Nothing is translated yet —
this task's deliverable is "the app still builds and behaves identically, and
now has somewhere to put strings".

**Files:**
- Create: `Sources/ShrinkerPro/Resources/Localizable.xcstrings`
- Create: `Sources/ShrinkerPro/Resources/InfoPlist.xcstrings`
- Modify: `project.yml` (the `ShrinkerPro` target's `settings`, near `INFOPLIST_FILE` at line 165)
- Test: `Tests/ShrinkerProTests/LocalizationGuardTests.swift` (create)

**Interfaces:**
- Consumes: nothing.
- Produces: two catalogs at the paths above, both with `"sourceLanguage": "en"`.
  Later tasks add entries to `Localizable.xcstrings`.
  `LocalizationGuardTests.catalogURL(named:)` — `static func catalogURL(named: String) throws -> URL`,
  returns the repo-relative catalog path, used by later tasks' tests.

- [ ] **Step 1: Create the two catalogs**

An `.xcstrings` file is JSON. Create both with an empty `strings` object —
Xcode populates them on build.

`Sources/ShrinkerPro/Resources/Localizable.xcstrings`:

```json
{
  "sourceLanguage" : "en",
  "strings" : {

  },
  "version" : "1.0"
}
```

`Sources/ShrinkerPro/Resources/InfoPlist.xcstrings`: identical content.

- [ ] **Step 2: Declare the regions in `project.yml`**

In the `ShrinkerPro` target's `settings:` block only — **not** the `shrinker`
target — add:

```yaml
        DEVELOPMENT_LANGUAGE: en
        SWIFT_EMIT_LOC_STRINGS: YES
        KNOWN_REGIONS: [en, ar, ca, cs, da, de, el, es, fa, fi, fr, he, hr,
                        hu, is, it, ja, ko, nb, nl, nn, pl, pt-BR, pt-PT, ro,
                        ru, sk, sl, sv, th, tr, uk, vi, zh-Hans, zh-Hant,
                        zh-HK]
```

The catalogs sit under `Sources/ShrinkerPro`, which the target already
globs (`project.yml:33`), so they are picked up as resources with no extra
`sources:` entry. The existing `excludes: ["Resources/Info.plist"]` is
unaffected — do not add the catalogs to it.

- [ ] **Step 3: Regenerate and build**

Run: `xcodegen generate && xcodebuild build -project ShrinkerPro.xcodeproj -scheme ShrinkerPro -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Write the guard test**

Create `Tests/ShrinkerProTests/LocalizationGuardTests.swift`:

```swift
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
    func testCLITargetHasNoRegions() throws {
        let yaml = try String(contentsOf: Self.repoRoot().appendingPathComponent("project.yml"), encoding: .utf8)
        guard let cliRange = yaml.range(of: "\n  shrinker:") else {
            return XCTFail("project.yml has no shrinker target")
        }
        let cliSection = yaml[cliRange.lowerBound...]
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

    /// Mirrors `OverwriteGuardTests`' own repo-root lookup, which reads
    /// SRCROOT from the environment and falls back to walking up from the
    /// test bundle.
    static func repoRoot() -> URL {
        if let srcroot = ProcessInfo.processInfo.environment["SRCROOT"] {
            return URL(fileURLWithPath: srcroot)
        }
        var candidate = Bundle(for: LocalizationGuardTests.self).bundleURL
        while candidate.pathComponents.count > 1 {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("project.yml").path) {
                return candidate
            }
            candidate = candidate.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}
```

- [ ] **Step 5: Regenerate so the new test file is in the project, then run the full suite**

Run: `xcodegen generate && xcodebuild test -project ShrinkerPro.xcodeproj -scheme ShrinkerPro -destination 'platform=macOS'`
Expected: all tests PASS, including the four new ones. Every pre-existing
test must still pass — this task changes no behavior.

- [ ] **Step 6: Commit**

```bash
git add project.yml Sources/ShrinkerPro/Resources/Localizable.xcstrings \
        Sources/ShrinkerPro/Resources/InfoPlist.xcstrings \
        Tests/ShrinkerProTests/LocalizationGuardTests.swift
git commit -m "Give the app somewhere to put its strings"
```

---

### Task 2: Walking skeleton — one real plural

`AppModel.notificationTitle` is the smallest plural in the app and is pinned
by two existing tests. Localizing it first proves the whole mechanism —
catalog authoring, plural selection, English preservation — before six other
tasks depend on it. **If plural selection does not work here, stop and report
rather than continuing to Task 3.**

**Files:**
- Modify: `Sources/ShrinkerPro/AppModel.swift:607-611`
- Modify: `Sources/ShrinkerPro/Resources/Localizable.xcstrings`
- Test: `Tests/ShrinkerProTests/AppModelTests.swift:339,352` (must pass unmodified)

**Interfaces:**
- Consumes: `LocalizationGuardTests.catalogURL(named:)` from Task 1.
- Produces: `AppModel.notificationTitle(count: Int) -> String` — signature
  unchanged. Catalog key `"%lld images shrunk"` with `en` plural variations.

- [ ] **Step 1: Run the two existing tests to confirm the baseline**

Run: `xcodebuild test -project ShrinkerPro.xcodeproj -scheme ShrinkerPro -destination 'platform=macOS' -only-testing:ShrinkerProTests/AppModelTests/testNotificationTitleIsSingularForOneFile`
Expected: PASS. These tests are the contract; they must still pass at Step 5.

- [ ] **Step 2: Replace the ternary**

In `Sources/ShrinkerPro/AppModel.swift`, replace:

```swift
    /// "Image shrunk" for one file, matching upstream's wording, and a count
    /// for a batch.
    static func notificationTitle(count: Int) -> String {
        count == 1 ? "Image shrunk" : "\(count) images shrunk"
    }
```

with:

```swift
    /// "Image shrunk" for one file, matching upstream's wording, and a count
    /// for a batch.
    ///
    /// The singular/plural split lives in the string catalog rather than in
    /// a ternary here. English needs two forms; Arabic needs six and
    /// Japanese needs one, and a `count == 1 ? :` can only ever express
    /// English's shape. See the localization spec's "Plural forms".
    static func notificationTitle(count: Int) -> String {
        String(localized: "\(count) images shrunk",
               comment: "Notification title after a batch finishes. The one-file form reads 'Image shrunk' with no number.")
    }
```

- [ ] **Step 3: Author the plural variations in the catalog**

The interpolation generates the key `"%lld images shrunk"`. Add this entry to
`Localizable.xcstrings`'s `strings` object. Note the `one` form deliberately
contains **no** `%lld` — English says "Image shrunk", not "1 image shrunk",
and that is what `AppModelTests:339` pins.

```json
    "%lld images shrunk" : {
      "comment" : "Notification title after a batch finishes. The one-file form reads 'Image shrunk' with no number.",
      "extractionState" : "manual",
      "localizations" : {
        "en" : {
          "variations" : {
            "plural" : {
              "one" : {
                "stringUnit" : { "state" : "translated", "value" : "Image shrunk" }
              },
              "other" : {
                "stringUnit" : { "state" : "translated", "value" : "%lld images shrunk" }
              }
            }
          }
        }
      }
    }
```

- [ ] **Step 4: Add a guard test for the plural categories**

Append to `Tests/ShrinkerProTests/LocalizationGuardTests.swift`, inside the class:

```swift
    /// Every plural entry must carry at least `one` and `other` for English.
    /// When translations land (Phase 2) this test grows to assert the
    /// per-language categories — six for Arabic, four for Polish, Russian,
    /// Ukrainian, Czech, Slovak and Slovenian, three for Croatian, Romanian
    /// and Hebrew.
    func testEnglishPluralEntriesHaveBothCategories() throws {
        let data = try Data(contentsOf: Self.catalogURL(named: "Localizable"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(json["strings"] as? [String: Any])

        for (key, entry) in strings {
            guard
                let entry = entry as? [String: Any],
                let localizations = entry["localizations"] as? [String: Any],
                let english = localizations["en"] as? [String: Any],
                let variations = english["variations"] as? [String: Any],
                let plural = variations["plural"] as? [String: Any]
            else { continue }

            XCTAssertNotNil(plural["one"], "\(key) has no 'one' form for English")
            XCTAssertNotNil(plural["other"], "\(key) has no 'other' form for English")
        }
    }
```

- [ ] **Step 5: Run the suite — the existing tests are the proof**

Run: `xcodegen generate && xcodebuild test -project ShrinkerPro.xcodeproj -scheme ShrinkerPro -destination 'platform=macOS'`
Expected: PASS, **including `AppModelTests:339` and `:352` unmodified**. If
`notificationTitle(count: 1)` no longer returns exactly `"Image shrunk"`, the
plural entry is wrong — fix the catalog, not the test.

- [ ] **Step 6: Commit**

```bash
git add Sources/ShrinkerPro/AppModel.swift \
        Sources/ShrinkerPro/Resources/Localizable.xcstrings \
        Tests/ShrinkerProTests/LocalizationGuardTests.swift
git commit -m "Move the notification title's plural into the catalog"
```

---

### Task 3: The Core seam

`Core` compiles into both targets. `AppModel` shows `errorDescription` in the
window's alert and `main.swift` prints the same property to stderr. Split
them so the app can translate without the CLI following.

**Files:**
- Modify: `Sources/ShrinkerPro/Core/Compressor.swift:29-57`
- Modify: `Sources/ShrinkerPro/AppModel.swift:460,590`
- Modify: `Sources/ShrinkerPro/Resources/Localizable.xcstrings`
- Test: `Tests/ShrinkerProTests/LocalizationGuardTests.swift`

**Interfaces:**
- Consumes: Task 1's catalog, Task 2's plural-entry conventions.
- Produces:
  - `protocol AppDisplayableError { var localizedMessage: String { get } }` in `Compressor.swift`.
  - `ShrinkError: AppDisplayableError` — `var localizedMessage: String`.
  - `ShrinkError.errorDescription` unchanged, still English.

- [ ] **Step 1: Write the failing test**

Append to `LocalizationGuardTests`:

```swift
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

    /// The app's path is separate, and for English says the same thing.
    func testLocalizedMessageExistsAndMatchesEnglish() {
        let error = ShrinkError.unsupportedFormat("tiff")

        XCTAssertEqual(error.localizedMessage, error.errorDescription)
    }

    /// Every ShrinkError case must answer both, or the app will silently
    /// fall back to English for one of them.
    func testEveryShrinkErrorCaseHasBothForms() {
        let cases: [ShrinkError] = [
            .unsupportedFormat("tiff"),
            .helperMissing("cjpeg"),
            .compressorFailed(tool: "cjpeg", code: 1, message: "bad"),
            .javascriptFailed("boom"),
            .outputNotWritten(URL(fileURLWithPath: "/tmp/x.png")),
            .conversionFailed("boom"),
        ]
        for error in cases {
            XCTAssertFalse(error.localizedMessage.isEmpty, "\(error) has no localizedMessage")
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "\(error) has no errorDescription")
        }
    }
```

- [ ] **Step 2: Run it to watch it fail**

Run: `xcodebuild test -project ShrinkerPro.xcodeproj -scheme ShrinkerPro -destination 'platform=macOS' -only-testing:ShrinkerProTests/LocalizationGuardTests`
Expected: FAIL — `value of type 'ShrinkError' has no member 'localizedMessage'`.

- [ ] **Step 3: Add the protocol and conformance**

In `Sources/ShrinkerPro/Core/Compressor.swift`, directly above `enum ShrinkError`:

```swift
/// An error that carries a separate, translated message for the app's alert.
///
/// `Core` compiles into both the app and the `shrinker` CLI, so
/// `LocalizedError.errorDescription` cannot be translated: `main.swift`
/// prints it to stderr and scripts parse that. This protocol is the app's
/// half of that split — `AppModel` prefers `localizedMessage`, the CLI never
/// reads it.
///
/// The duplication is deliberate. Relying instead on `String(localized:)`
/// falling back to its key because the CLI's `Bundle.main` has no catalog
/// would produce English today, but only by accident of bundle layout.
/// See `docs/design/specs/2026-09-20-localization-design.md`.
protocol AppDisplayableError {
    var localizedMessage: String { get }
}
```

Then extend `ShrinkError` — leave `errorDescription` exactly as it is:

```swift
extension ShrinkError: AppDisplayableError {
    var localizedMessage: String {
        switch self {
        case .unsupportedFormat(let ext):
            return String(localized: "Only SVG, PNG, GIF, JPEG, WebP, AVIF, HEIC and HEIF are supported (got \"\(ext)\").",
                          comment: "Alert body when a dropped file is a format the app cannot read.")
        case .helperMissing(let name):
            return String(localized: "The bundled \(name) tool is missing. The app may be damaged — try reinstalling.",
                          comment: "Alert body when a bundled compressor binary is absent. The placeholder is a tool name such as cjpeg.")
        case .compressorFailed(let tool, let code, let message):
            let detail = message.isEmpty ? "" : ": \(message)"
            return String(localized: "\(tool) failed with exit code \(code)\(detail)",
                          comment: "Alert body when a compressor exits non-zero. Placeholders: tool name, exit code, optional detail.")
        case .javascriptFailed(let message):
            return String(localized: "SVG optimization failed: \(message)",
                          comment: "Alert body when svgo fails.")
        case .outputNotWritten(let url):
            return String(localized: "No output was written to \(url.lastPathComponent).",
                          comment: "Alert body when a compressor reported success but produced no file.")
        case .conversionFailed(let message):
            return String(localized: "Image conversion failed: \(message)",
                          comment: "Alert body when an ImageIO decode or encode step fails.")
        }
    }
}
```

- [ ] **Step 4: Point the app at the new property**

In `Sources/ShrinkerPro/AppModel.swift`, at **both** line 460 and line 590,
replace:

```swift
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
```

with:

```swift
                // AppDisplayableError first: errorDescription is the CLI's
                // English, this is the app's translated text. See the
                // localization spec's "The Core seam".
                errorMessage = (error as? AppDisplayableError)?.localizedMessage
                    ?? (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
```

- [ ] **Step 5: Add the six catalog entries**

Add each `String(localized:)` key from Step 3 to `Localizable.xcstrings`
with its English value. Interpolations become `%@` (strings) or `%lld`
(the `Int32` exit code becomes `%d`). For example:

```json
    "Only SVG, PNG, GIF, JPEG, WebP, AVIF, HEIC and HEIF are supported (got \"%@\")." : {
      "comment" : "Alert body when a dropped file is a format the app cannot read.",
      "extractionState" : "manual",
      "localizations" : {
        "en" : {
          "stringUnit" : { "state" : "translated", "value" : "Only SVG, PNG, GIF, JPEG, WebP, AVIF, HEIC and HEIF are supported (got \"%@\")." }
        }
      }
    }
```

Repeat for the other five. If unsure of a generated key, build once and read
what Xcode writes into the catalog — do not guess.

- [ ] **Step 6: Run the tests**

Run: `xcodegen generate && xcodebuild test -project ShrinkerPro.xcodeproj -scheme ShrinkerPro -destination 'platform=macOS'`
Expected: PASS, including `ShrinkerCLITests` unmodified.

- [ ] **Step 7: Commit**

```bash
git add Sources/ShrinkerPro/Core/Compressor.swift Sources/ShrinkerPro/AppModel.swift \
        Sources/ShrinkerPro/Resources/Localizable.xcstrings \
        Tests/ShrinkerProTests/LocalizationGuardTests.swift
git commit -m "Split Core's error text so the CLI keeps its English"
```

---

### Task 4: The overwrite sheet

The data-loss guard rail. `OverwriteRequestCopyTests` pins its wording
thoroughly, which is what makes this tractable — those tests are the proof
that English survives. **They pass unmodified.**

**Files:**
- Modify: `Sources/ShrinkerPro/Core/OverwritePrompt.swift:64-112`
- Modify: `Sources/ShrinkerPro/Resources/Localizable.xcstrings`
- Test: `Tests/ShrinkerProTests/OverwriteGuardTests.swift:377-500` (unmodified)

**Interfaces:**
- Consumes: Task 2's plural conventions.
- Produces: `OverwriteRequest.title`, `.message`, `.skipButtonTitle` —
  all `String`, signatures unchanged.

- [ ] **Step 1: Run the copy tests to confirm the baseline**

Run: `xcodebuild test -project ShrinkerPro.xcodeproj -scheme ShrinkerPro -destination 'platform=macOS' -only-testing:ShrinkerProTests/OverwriteRequestCopyTests`
Expected: PASS. Note the exact expectations — they do not change.

- [ ] **Step 2: Localize the separator and the truncation tail**

Replace the `names` property:

```swift
    private var names: String {
        let all = displayNames
        let listed = all.prefix(Self.listedNameLimit).joined(separator: ", ")
        let rest = all.count - Self.listedNameLimit
        return rest > 0 ? "\(listed), …and \(rest) more" : listed
    }
```

with:

```swift
    private var names: String {
        let all = displayNames
        // Deliberately not ListFormatter: in English it would insert an
        // "and" this list does not have, and the truncated case would read
        // "…, and 5.png, …and 3 more". This is a truncated enumeration, not
        // a grammatical list. The separator is a catalog entry so CJK can
        // use "、" without English changing.
        let separator = String(localized: "filename list separator",
                               defaultValue: ", ",
                               comment: "Separates filenames in the overwrite sheet's list. English uses a comma and a space; CJK languages use 、")
        let listed = all.prefix(Self.listedNameLimit).joined(separator: separator)
        let rest = all.count - Self.listedNameLimit
        guard rest > 0 else { return listed }
        return String(localized: "\(listed), …and \(rest) more",
                      comment: "Tail of a truncated filename list. First placeholder is the listed names, second is how many were not listed.")
    }
```

- [ ] **Step 3: Localize the title's plurals**

Replace the `title` property with one catalog entry per category and count.
The count must live **inside** the entry, not be composed outside it —
in several languages the surrounding words inflect with the number.

```swift
    var title: String {
        guard let folder = sharedParent else {
            switch category {
            case .original:
                return String(localized: "Replace \(paths.count) originals?",
                              comment: "Overwrite sheet title when the user's own originals would be destroyed and they are not all in one folder.")
            case .existingFile:
                return String(localized: "Replace \(paths.count) files?",
                              comment: "Overwrite sheet title when existing files would be replaced and they are not all in one folder.")
            }
        }
        let name = folder.lastPathComponent
        switch category {
        case .original:
            return String(localized: "Replace \(paths.count) originals in “\(name)”?",
                          comment: "Overwrite sheet title for originals sharing one folder. Second placeholder is the folder name.")
        case .existingFile:
            return String(localized: "Replace \(paths.count) files in “\(name)”?",
                          comment: "Overwrite sheet title for existing files sharing one folder. Second placeholder is the folder name.")
        }
    }
```

- [ ] **Step 4: Localize the message and the Skip button**

```swift
    var message: String {
        var lines: [String] = []
        switch category {
        case .original:
            lines.append(String(localized: "\(names) will be overwritten and cannot be recovered.",
                                comment: "Overwrite sheet body for originals. Placeholder is the filename list. Plural on the file count."))
        case .existingFile:
            lines.append(String(localized: "\(names) is already there and will be replaced.",
                                comment: "Overwrite sheet body for existing files. Placeholder is the filename list. Plural on the file count."))
        }
        if unaffectedCount > 0 {
            lines.append(String(localized: "The other \(unaffectedCount) files are unaffected.",
                                comment: "Reassurance that the rest of the batch still runs."))
        }
        return lines.joined(separator: "\n\n")
    }

    /// Not "Cancel": it does not cancel the drop, it declines these files.
    var skipButtonTitle: String {
        String(localized: "Skip These",
               comment: "Overwrite sheet's cancel-role button. Declines these files; the rest of the batch still runs.")
    }
```

**Note on the message's plurals.** English's two forms here are not just
singular/plural of one sentence — they put the names in different places
("photo.jpg will be overwritten…" vs "These will be overwritten…: a, b, c").
So the count must still drive the selection, which means interpolating it
even though neither English form prints it. Write each line as:

```swift
            lines.append(String(localized: "\(paths.count) originals will be overwritten: \(names)",
                                comment: "Overwrite sheet body for originals. First placeholder is the file count and drives the plural; it is not shown in English. Second is the filename list."))
```

A plural variation is free to ignore an argument, so English's `one` form is
`%2$@ will be overwritten and cannot be recovered.` and its `other` form is
`These will be overwritten and cannot be recovered: %2$@` — neither prints
`%1$lld`, and both still select correctly. A language that *does* want the
number has it available.

- [ ] **Step 5: Author the catalog entries**

Add plural variations for each new key, following Task 2's JSON shape. The
English forms must reproduce exactly what the tests expect:

| Key | `one` | `other` |
|---|---|---|
| `Replace %lld originals?` | `Replace 1 original?` | `Replace %lld originals?` |
| `Replace %lld files?` | `Replace 1 file?` | `Replace %lld files?` |
| `Replace %1$lld originals in “%2$@”?` | `Replace 1 original in “%2$@”?` | `Replace %1$lld originals in “%2$@”?` |
| `Replace %1$lld files in “%2$@”?` | `Replace 1 file in “%2$@”?` | `Replace %1$lld files in “%2$@”?` |
| `The other %lld files are unaffected.` | `The other file is unaffected.` | `The other %lld files are unaffected.` |
| `Skip These` | `Skip This` | `Skip These` |
| `%1$@, …and %2$lld more` | (n/a) | `%1$@, …and %2$lld more` |
| `filename list separator` | (n/a) | `, ` |

Note the `one` forms that drop the number entirely (`Replace 1 original?`
uses a literal 1 because that is what `OverwriteGuardTests:386` expects;
`The other file is unaffected.` drops it). This is English's business and the
catalog is where it belongs.

- [ ] **Step 6: Run the copy tests — unmodified**

Run: `xcodegen generate && xcodebuild test -project ShrinkerPro.xcodeproj -scheme ShrinkerPro -destination 'platform=macOS' -only-testing:ShrinkerProTests/OverwriteRequestCopyTests`
Expected: PASS with **no edits to the test file**. Any failure means the
catalog's English is wrong. Fix the catalog.

- [ ] **Step 7: Run the whole suite**

Run: `xcodebuild test -project ShrinkerPro.xcodeproj -scheme ShrinkerPro -destination 'platform=macOS'`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/ShrinkerPro/Core/OverwritePrompt.swift \
        Sources/ShrinkerPro/Resources/Localizable.xcstrings
git commit -m "Move the overwrite sheet's plurals into the catalog"
```

---

### Task 5: The Recent header

`aggregateParts` returns `(prefix, size, suffix)` so the view can accent only
the size run. That three-way split hardcodes English word order — `" saved"`
can only ever follow the number. Replace it with one localized sentence plus
a located range.

**Files:**
- Modify: `Sources/ShrinkerPro/Views/RecentHeaderView.swift:6-46,90-96`
- Modify: `Sources/ShrinkerPro/Resources/Localizable.xcstrings`
- Test: `Tests/ShrinkerProTests/RecentHeaderFormatterTests.swift` (rewritten — see Step 1)

**Interfaces:**
- Consumes: Task 2's plural conventions.
- Produces:
  - `RecentHeaderFormatter.fileCountLabel(_ count: Int) -> String` — unchanged signature.
  - `RecentHeaderFormatter.aggregate(for session: SessionSummary) -> AttributedString`
    — **replaces** `aggregateParts(for:)`. The size run carries
    `.foregroundColor = Theme.savingsAccent` and `.font` weight semibold.

- [ ] **Step 1: Rewrite the formatter tests**

This is the one test file this plan changes, and the reason is structural
rather than cosmetic: `aggregateParts` returns three fragments, and the
replacement returns one attributed string, so assertions on `parts.suffix`
have nothing to address. The *behavior* asserted is preserved exactly —
each old assertion gets an equivalent below.

Replace the `aggregateParts` section of
`Tests/ShrinkerProTests/RecentHeaderFormatterTests.swift` with:

```swift
    // MARK: - aggregate

    /// The old `aggregateParts` returned (prefix, size, suffix) so the view
    /// could colour the middle run. That shape put " saved" permanently
    /// after the number, which is English's word order and not everyone's.
    /// The replacement returns one localized sentence with the size run
    /// attributed, so a language may put the words in any order.

    func testAggregateReadsAsSavedForPositiveSavings() {
        var session = SessionSummary()
        session.record(originalBytes: 5_000_000, shrunkBytes: 1_000_000)

        let text = String(RecentHeaderFormatter.aggregate(for: session).characters)

        XCTAssertEqual(text, "1 file · \(expectedMagnitude(4_000_000)) saved")
    }

    func testAggregatePluralisesMultipleFiles() {
        var session = SessionSummary()
        session.record(originalBytes: 3_000_000, shrunkBytes: 1_000_000)
        session.record(originalBytes: 2_000_000, shrunkBytes: 500_000)

        let text = String(RecentHeaderFormatter.aggregate(for: session).characters)

        XCTAssertTrue(text.hasPrefix("2 files · "), text)
    }

    /// A net-growth session must format the magnitude and swap the word, so
    /// it never reads "you saved -1.2 MB".
    func testAggregateForNegativeSavingsReportsLargerWithPositiveMagnitude() {
        var session = SessionSummary()
        session.record(originalBytes: 100, shrunkBytes: 1_300_100)

        let text = String(RecentHeaderFormatter.aggregate(for: session).characters)

        XCTAssertEqual(session.bytesSaved, -1_300_000)
        XCTAssertEqual(text, "1 file · \(expectedMagnitude(1_300_000)) larger")
        XCTAssertFalse(text.contains("-"), "must never show a bare minus sign")
    }

    func testAggregateForZeroSavingsReadsAsSaved() {
        var session = SessionSummary()
        session.record(originalBytes: 1_000, shrunkBytes: 1_000)

        let text = String(RecentHeaderFormatter.aggregate(for: session).characters)

        XCTAssertTrue(text.hasSuffix(" saved"), "a wash is not a regression")
    }

    /// The size run — and only the size run — is accented, whatever order
    /// the language puts the words in.
    func testOnlyTheSizeRunIsAccented() {
        var session = SessionSummary()
        session.record(originalBytes: 5_000_000, shrunkBytes: 1_000_000)

        let attributed = RecentHeaderFormatter.aggregate(for: session)
        let accented = attributed.runs
            .filter { $0.foregroundColor == Theme.savingsAccent }
            .map { String(attributed[$0.range].characters) }

        XCTAssertEqual(accented, [expectedMagnitude(4_000_000)])
    }
```

- [ ] **Step 2: Run them to watch them fail**

Run: `xcodebuild test -project ShrinkerPro.xcodeproj -scheme ShrinkerPro -destination 'platform=macOS' -only-testing:ShrinkerProTests/RecentHeaderFormatterTests`
Expected: FAIL — `type 'RecentHeaderFormatter' has no member 'aggregate'`.

- [ ] **Step 3: Replace the formatter**

In `RecentHeaderView.swift`, replace `fileCountLabel` and `aggregateParts`
with:

```swift
    /// `"1 file"` / `"6 files"`. The plural lives in the catalog.
    static func fileCountLabel(_ count: Int) -> String {
        String(localized: "\(count) files",
               comment: "File count in the Recent header's trailing aggregate.")
    }

    /// The Recent header's trailing aggregate, as one localized sentence
    /// with the size run accented.
    ///
    /// This used to return (prefix, size, suffix) so the view could colour
    /// the middle. That worked, but it fixed " saved" after the number —
    /// English's word order, and not every language's. Now the whole
    /// sentence is one catalog entry and the size run is located within the
    /// result, so a translation may put the words wherever its grammar wants
    /// and the right run is still the accented one.
    ///
    /// `SessionSummary.bytesSaved` can be negative when this session's
    /// outputs grew overall (summed honestly rather than clamped — see
    /// `SessionSummary.record`). Pairing a bare minus sign with "saved"
    /// reads as nonsense, so a net-growth session formats the *magnitude*
    /// and swaps the word: "1.2 MB larger".
    static func aggregate(for session: SessionSummary) -> AttributedString {
        let grew = session.bytesSaved < 0
        let size = formatMagnitude(abs(session.bytesSaved))
        let files = fileCountLabel(session.fileCount)

        let sentence = grew
            ? String(localized: "\(files) · \(size) larger",
                     comment: "Recent header aggregate when this session's outputs grew overall. First placeholder is a file count such as '3 files', second is a size such as '1.2 MB'.")
            : String(localized: "\(files) · \(size) saved",
                     comment: "Recent header aggregate. First placeholder is a file count such as '3 files', second is a size such as '1.2 MB'.")

        var attributed = AttributedString(sentence)
        // The size is our own substring, so locating it is exact rather than
        // a guess. `.last` because a file count can never contain a byte
        // size, but a size could in principle repeat.
        if let range = attributed.range(of: size, options: .backwards) {
            attributed[range].foregroundColor = Theme.savingsAccent
            attributed[range].font = .system(size: 11.5, weight: .semibold)
        }
        return attributed
    }
```

Leave `formatMagnitude` exactly as it is.

- [ ] **Step 4: Update the view**

Replace `aggregateText`:

```swift
    private var aggregateText: Text {
        Text(RecentHeaderFormatter.aggregate(for: session))
            .foregroundColor(.secondary)
    }
```

`Text(AttributedString)` keeps the per-run attributes, so the accented size
survives the `.secondary` applied to the rest.

- [ ] **Step 5: Add the catalog entries**

Three entries. `%lld files` needs plural variations (`one` → `1 file`); the
two sentences do not.

```json
    "%lld files" : {
      "comment" : "File count in the Recent header's trailing aggregate.",
      "extractionState" : "manual",
      "localizations" : {
        "en" : {
          "variations" : {
            "plural" : {
              "one" : { "stringUnit" : { "state" : "translated", "value" : "1 file" } },
              "other" : { "stringUnit" : { "state" : "translated", "value" : "%lld files" } }
            }
          }
        }
      }
    }
```

Plus `"%1$@ · %2$@ saved"` → `%1$@ · %2$@ saved` and
`"%1$@ · %2$@ larger"` → `%1$@ · %2$@ larger`, both plain `stringUnit`
entries with the same English text.

- [ ] **Step 6: Run the tests**

Run: `xcodegen generate && xcodebuild test -project ShrinkerPro.xcodeproj -scheme ShrinkerPro -destination 'platform=macOS'`
Expected: PASS. `fileCountLabel` tests pass unmodified — `"1 file"`,
`"0 files"`, `"2 files"`, `"6 files"`.

- [ ] **Step 7: Commit**

```bash
git add Sources/ShrinkerPro/Views/RecentHeaderView.swift \
        Sources/ShrinkerPro/Resources/Localizable.xcstrings \
        Tests/ShrinkerProTests/RecentHeaderFormatterTests.swift
git commit -m "Let the Recent header's aggregate choose its own word order"
```

---

### Task 6: The session bar's prose

Three helper strings. One is split mid-sentence around an interpolation and
genuinely cannot be translated as-is; the others split at sentence
boundaries, which is only line-wrapping and becomes one entry each.

**Files:**
- Modify: `Sources/ShrinkerPro/Views/SessionBarView.swift:93-97,162-166,696-709`
- Modify: `Sources/ShrinkerPro/Resources/Localizable.xcstrings`
- Test: `Tests/ShrinkerProTests/SessionBarStateTests.swift` (check first — see Step 1)

**Interfaces:**
- Consumes: Task 2's conventions.
- Produces: `maxSizeSupersededHelp(crop:)`, `growthWarningHelp(for:)`,
  `cropHelp` — all `String`, signatures unchanged.

- [ ] **Step 1: Check what the tests already pin**

Run: `grep -n "supersede\|growthWarning\|cropHelp" Tests/ShrinkerProTests/SessionBarStateTests.swift`
If any test asserts this wording, it must pass **unmodified** after this
task, exactly as in Task 4. If none does, add one for
`maxSizeSupersededHelp` at Step 2 — a string being rewritten deserves a test
that notices.

- [ ] **Step 2: Fix the mid-sentence split**

`maxSizeSupersededHelp` splits one sentence across an interpolation:

```swift
        return "The crop already sets the size — every image comes out "
            + "\(crop.width)×\(crop.height). Switch the crop to a ratio, or clear it, "
            + "to use a max size."
```

A translator handed those three fragments has no sentence to place them in.
Replace with a single entry:

```swift
        return String(localized: "The crop already sets the size — every image comes out \(crop.width)×\(crop.height). Switch the crop to a ratio, or clear it, to use a max size.",
                      comment: "Help text when a pixel crop makes the max size field irrelevant. Placeholders are the crop's width and height in pixels.")
```

- [ ] **Step 3: Fix the growth warning**

```swift
            ? "PNG is lossless — photos will usually get larger."
            : ""
```

becomes:

```swift
            ? String(localized: "PNG is lossless — photos will usually get larger.",
                     comment: "Warning when the session's format override is PNG, which usually grows photographs.")
            : ""
```

- [ ] **Step 4: Fix the crop help**

These split at sentence boundaries, so each group becomes one entry and the
composition stays:

```swift
    private var cropHelp: String {
        let shared = String(localized: "Both sides are needed. The shape is used exactly as typed, so a portrait photo cropped to 16:9 comes out as a landscape strip. SVG is unaffected. Not saved — it resets when you quit.",
                            comment: "Shared tail of both crop help texts.")
        switch model.sessionCropMode {
        case .pixels:
            return String(localized: "Crops the center of each image to this shape, then scales it down to this size. Images already smaller are cropped but never enlarged, so a mixed batch may not come out all one size. This sets the output size outright, so the max size above does not apply.",
                          comment: "Crop help in pixel mode, where the crop states the output size outright.") + " " + shared
        case .ratio:
            return String(localized: "Crops the center of each image to this shape and leaves the size alone. The session's max size, if set, still applies.",
                          comment: "Crop help in ratio mode, where the crop sets shape but not size.") + " " + shared
        }
    }
```

The `switch model.sessionCropMode` is the existing condition — preserve it
exactly. Note "center" is American here per the repo's rule and stays that
way.

- [ ] **Step 5: Localize the two remaining inline strings**

At line 509 and line 523, wrap in `String(localized:)` with comments,
keeping the English identical:

- `"Shrinks images so the longest side is at most this many pixels. Smaller images are left alone. SVG is unaffected."`
- `"A crop needs both sides. Fill in the other number, or clear this one — files cannot be shrunk until you do."`
- `"Finish the crop, or clear it, before closing."` (line 730)

- [ ] **Step 6: Add the catalog entries**

One plain `stringUnit` entry per key from Steps 2–5, English text identical
to what it replaced. No plurals here.

- [ ] **Step 7: Run the suite**

Run: `xcodegen generate && xcodebuild test -project ShrinkerPro.xcodeproj -scheme ShrinkerPro -destination 'platform=macOS'`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/ShrinkerPro/Views/SessionBarView.swift \
        Sources/ShrinkerPro/Resources/Localizable.xcstrings \
        Tests/ShrinkerProTests/SessionBarStateTests.swift
git commit -m "Give the session bar's sentences to the translator whole"
```

---

### Task 7: Right-to-left

Three places assume left-to-right. Arabic, Hebrew and Persian are in the
declared set, so these are real defects even though nothing is translated yet.

**Files:**
- Modify: `Sources/ShrinkerPro/AppModel.swift:13-18` (`ResultRow.sizeSummary`)
- Modify: `Sources/ShrinkerPro/Views/DropZoneView.swift:23` (`.tracking`)
- Modify: `Sources/ShrinkerPro/Views/SessionBarView.swift:46,62-66` (unit strings)
- Modify: `Sources/ShrinkerPro/Resources/Localizable.xcstrings`
- Test: `Tests/ShrinkerProTests/ResultRowTests.swift`

**Interfaces:**
- Consumes: Task 2's conventions.
- Produces: `ResultRow.sizeSummary: String` — unchanged signature.

- [ ] **Step 1: Write the failing test**

Append to `Tests/ShrinkerProTests/ResultRowTests.swift`:

```swift
    /// The arrow encodes reading direction, so it cannot be hardcoded
    /// around the interpolation — a right-to-left language needs it the
    /// other way. English is unchanged.
    func testSizeSummaryKeepsItsEnglishForm() {
        let row = ResultRow(output: URL(fileURLWithPath: "/tmp/a.png"),
                            originalBytes: 3_100_000,
                            shrunkBytes: 1_200_000,
                            savedPercent: 61)

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let before = formatter.string(fromByteCount: 3_100_000)
        let after = formatter.string(fromByteCount: 1_200_000)

        XCTAssertEqual(row.sizeSummary, "\(before) → \(after)")
    }
```

- [ ] **Step 2: Run it**

Run: `xcodebuild test -project ShrinkerPro.xcodeproj -scheme ShrinkerPro -destination 'platform=macOS' -only-testing:ShrinkerProTests/ResultRowTests`
Expected: PASS (it documents current behavior). It must **still** pass after
Step 3 — that is the point.

- [ ] **Step 3: Make the arrow the catalog's business**

```swift
    /// `"3.1 MB → 1.2 MB"`, built with `ByteCountFormatter`'s `.file` count
    /// style so the numbers match what Finder would show for the same files.
    ///
    /// The arrow is part of the catalog entry rather than hardcoded between
    /// the placeholders: it encodes reading direction, and in a
    /// right-to-left language it must point the other way.
    var sizeSummary: String {
        String(localized: "\(Self.formatBytes(originalBytes)) → \(Self.formatBytes(shrunkBytes))",
               comment: "A result row's before-and-after sizes. The arrow points from the original size to the shrunk size; in right-to-left languages it should point the other way (←).")
    }
```

- [ ] **Step 4: Stop the tracking from breaking cursive scripts**

In `DropZoneView.swift`, the headline applies `.tracking(-0.16)`. Negative
letter-spacing damages glyph joining in Arabic and Persian. Replace:

```swift
                Text("Drag files here")
                    .font(.system(size: 16, weight: .semibold))
                    .tracking(-0.16)
```

with:

```swift
                Text("Drag files here")
                    .font(.system(size: 16, weight: .semibold))
                    // Latin-only: negative letter-spacing breaks the glyph
                    // joining that Arabic and Persian depend on.
                    .tracking(Self.isCursiveScript ? 0 : -0.16)
```

and add to `DropZoneView`:

```swift
    /// Arabic, Persian and Urdu join their letters; tightening the tracking
    /// pulls the joins apart. Hebrew does not join, but has no need of the
    /// tightening either.
    private static var isCursiveScript: Bool {
        guard let code = Locale.current.language.languageCode?.identifier else { return false }
        return ["ar", "fa", "ur", "he"].contains(code)
    }
```

- [ ] **Step 5: Localize the session bar's unit strings**

Two more places put a unit against a number, which is not universal. In
`SessionBarView.swift`, replace `cropFragment` (line 62):

```swift
    static func cropFragment(_ crop: CropTarget) -> String {
        switch crop.mode {
        case .pixels:
            return String(localized: "Crop \(crop.width)×\(crop.height)",
                          comment: "Collapsed session-bar summary of a pixel crop. Placeholders are width and height in pixels; the × is the same glyph the field shows.")
        case .ratio:
            return String(localized: "Crop \(crop.width):\(crop.height)",
                          comment: "Collapsed session-bar summary of a ratio crop. Placeholders are the two sides of the ratio.")
        }
    }
```

and at line 46, the max-size fragment:

```swift
            maxDimension.map {
                String(localized: "Max \($0)px",
                       comment: "Collapsed session-bar summary of the max size. Placeholder is a pixel count; 'px' placement varies by language.")
            } ?? String(localized: "No limit",
                        comment: "Collapsed session-bar summary when no max size is set.")
```

- [ ] **Step 6: Add the catalog entries**

`"%1$@ → %2$@"` as a plain `stringUnit` with English value `%1$@ → %2$@`,
plus `"Crop %1$lld×%2$lld"`, `"Crop %1$lld:%2$lld"`, `"Max %lldpx"` and
`"No limit"` — each a plain `stringUnit` whose English value is identical to
the string it replaced. No plurals among these.

- [ ] **Step 7: Run the suite**

Run: `xcodegen generate && xcodebuild test -project ShrinkerPro.xcodeproj -scheme ShrinkerPro -destination 'platform=macOS'`
Expected: PASS, including the Step 1 test.

- [ ] **Step 8: Commit**

```bash
git add Sources/ShrinkerPro/AppModel.swift Sources/ShrinkerPro/Views/DropZoneView.swift \
        Sources/ShrinkerPro/Views/SessionBarView.swift \
        Sources/ShrinkerPro/Resources/Localizable.xcstrings \
        Tests/ShrinkerProTests/ResultRowTests.swift
git commit -m "Stop three bits of layout assuming left-to-right"
```

---

### Task 8: Sweep and verify

Everything left is a bare `Text("…")`, which SwiftUI already resolves through
the catalog. This task makes sure each one is actually *in* the catalog, and
proves the phase preserved English.

**Files:**
- Modify: `Sources/ShrinkerPro/Resources/Localizable.xcstrings`
- Modify: `Sources/ShrinkerPro/Resources/InfoPlist.xcstrings`
- Modify: `Tests/ShrinkerProTests/LocalizationGuardTests.swift`

**Interfaces:**
- Consumes: every prior task's catalog entries.
- Produces: a complete English catalog.

- [ ] **Step 1: Let Xcode extract the remaining keys**

`SWIFT_EMIT_LOC_STRINGS: YES` (Task 1) makes the build write every
`Text("…")` key into the catalog automatically.

Run: `xcodegen generate && xcodebuild build -project ShrinkerPro.xcodeproj -scheme ShrinkerPro -destination 'platform=macOS'`
Then: `git diff --stat Sources/ShrinkerPro/Resources/Localizable.xcstrings`
Expected: the catalog has grown with keys from `SettingsView`,
`ContentView`, `ShrinkerProApp`, `ResultsListView`, `Theme` and the rest.

- [ ] **Step 2: Localize the Info.plist strings**

Add to `InfoPlist.xcstrings` the one user-facing bundle string — the
document type name `"Image"`, shown by Finder in "Open With" and Get Info:

```json
    "CFBundleTypeName" : {
      "comment" : "How Finder names the file kind this app opens.",
      "extractionState" : "manual",
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Image" } }
      }
    }
```

**Do not** add `CFBundleName` or `CFBundleDisplayName` — "Shrinker Pro" is a
product name, not a phrase.

- [ ] **Step 3: Add the completeness guard**

Append to `LocalizationGuardTests`:

```swift
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
```

- [ ] **Step 4: Pseudolocalization — find the truncation now**

Run the app with doubled, accented strings to catch layouts that will break
under German or Finnish before any translation exists.

Run: `xcodebuild -project ShrinkerPro.xcodeproj -scheme ShrinkerPro -destination 'platform=macOS' -showBuildSettings | grep -m1 BUILT_PRODUCTS_DIR`
Then launch the built app with:
`"<BUILT_PRODUCTS_DIR>/Shrinker Pro.app/Contents/MacOS/Shrinker Pro" -AppleLocale en_US -NSDoubleLocalizedStrings YES`

**Ask before launching the GUI** — it takes over the screen.

Check the session bar, Settings and the overwrite sheet. Record anything
clipped in the commit message; fixing layout is Phase 3's job unless
something is unusable.

- [ ] **Step 5: Full suite, one last time**

Run: `xcodebuild test -project ShrinkerPro.xcodeproj -scheme ShrinkerPro -destination 'platform=macOS'`
Expected: PASS — all 28 pre-existing test files plus `LocalizationGuardTests`.

Confirm explicitly that these passed **unmodified**:
`OverwriteRequestCopyTests`, `AppModelTests`, `SettingsViewTests`,
`ShrinkerCLITests`, `ArchitectureGuardTests`.

- [ ] **Step 6: Verify the CLI really is untouched**

Run: `xcodebuild build -project ShrinkerPro.xcodeproj -scheme shrinker -destination 'platform=macOS'`
Then, against the built tool:
`LANG=ar_SA.UTF-8 <path-to-shrinker> --help | head -5`
Expected: English, identical to `LANG=en_US.UTF-8` output. Diff them to be sure.

- [ ] **Step 7: Commit**

```bash
git add Sources/ShrinkerPro/Resources/Localizable.xcstrings \
        Sources/ShrinkerPro/Resources/InfoPlist.xcstrings \
        Tests/ShrinkerProTests/LocalizationGuardTests.swift
git commit -m "Complete the English catalog and prove the phase changed nothing"
```

---

## Done when

- Both catalogs exist, English-complete, no `stale` entries.
- All 36 regions declared on `ShrinkerPro`; none on `shrinker`.
- No `count == 1 ? :` remains in user-facing text. Verify:
  `grep -rn 'count == 1 ?' Sources/ShrinkerPro/` returns nothing in `Views`,
  `AppModel.swift` or `OverwritePrompt.swift`.
- No mid-sentence `+` concatenation of display strings remains.
- Every pre-existing test passes, and the only test file changed is
  `RecentHeaderFormatterTests` (Task 5, Step 1, for the reason given there).
- `shrinker --help` and its stderr are byte-identical under any `LANG`.

## Not in this phase

Translations, the glossary, per-language plural guards, RTL screenshots, and
the README/website updates. Those are Phases 2 and 3 of the spec.
