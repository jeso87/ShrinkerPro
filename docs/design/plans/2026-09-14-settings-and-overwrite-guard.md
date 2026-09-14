# Settings Regroup and Overwrite Guard — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the "keep originals" switch findable, and stop both the app and the CLI from replacing a file without saying so.

**Architecture:** `ShrinkEngine`'s private `Plan` is promoted to a `ShrinkPlan` value the caller holds, carrying a destination resolved without touching the disk. That lets `AppModel` scan a whole batch for collisions before a byte is written, prompt once per category, and then execute the very plans it checked. The CLI gets the same choices as a flag instead of a sheet.

**Tech Stack:** Swift 6.0 (strict concurrency), SwiftUI, XCTest, XcodeGen, macOS 14 floor, arm64 only.

**Spec:** `docs/design/specs/2026-09-14-suffix-settings-and-overwrite-warning.md` — read it first; this plan argues from it and does not restate its reasoning.

## Global Constraints

- **Branch:** `1.2.1-settings-and-overwrite-warning`. Do not commit to `main`.
- **Swift 6.0 strict concurrency.** `Settings` and `AppModel` are `@MainActor`. Do not capture a `var` into a detached task; do not capture `UserDefaults` (not `Sendable`) into a teardown block — address it by suite name.
- **The `"suffix"` UserDefaults key must never be renamed or migrated.** Its polarity is unchanged. See `Settings.swift:14-19`.
- **New defaults key spelling is `"warnBeforeOverwrite"`, pinned by test.** Renaming it silently resets every user.
- **`--if-exists` defaults to `replace`, which must reproduce 1.2.0 byte for byte** — no extra stat, no extra stderr, identical stdout.
- **Exit codes and `--json` key order are a compatibility surface.** `.sortedKeys` and `.withoutEscapingSlashes` are part of the contract (`CommandLineOptions.swift:230`).
- **Any new `.swift` file requires `xcodegen generate` before it will build.** The `.xcodeproj` is committed and XcodeGen-driven.
- **No signed/notarized release build.** Version bump and changelog only; the user says when 1.2.1 ships.

**Canonical test command** (referred to below as *the test command*, always with the `-only-testing:` filter shown in that step):

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  -only-testing:ShrinkerProTests/<Class>/<testMethod>
```

Prerequisites, once per clean checkout: `./scripts/bootstrap.sh`, `./scripts/build-compressors.sh`, `./scripts/prepare-svgo.sh`, `./scripts/prepare-sparkle.sh`, `./scripts/make-icon.sh`, `xcodegen generate`.

## File Structure

**Create:**
- `Sources/ShrinkerPro/Core/OutputWarning.swift` — one pure function answering "does this combination actually put originals at risk?"
- `Sources/ShrinkerPro/Core/OverwritePrompt.swift` — the collision categories, the answer enum, and the request the window renders.
- `Tests/ShrinkerProTests/OverwriteGuardTests.swift` — the setting's contract, the pure warning function, classification, and unique naming.

**Modify:**
- `Sources/ShrinkerPro/Core/Settings.swift` — one new key.
- `Sources/ShrinkerPro/Views/SettingsView.swift` — five headed sections, radios, conditional warning.
- `Sources/ShrinkerPro/Core/OutputPathResolver.swift` — split pure path-building from directory creation; add unique naming.
- `Sources/ShrinkerPro/Core/ShrinkEngine.swift` — promote `Plan`; add `plan(_:settings:)` and `shrink(_ plan:)`.
- `Sources/ShrinkerPro/AppModel.swift` — pre-flight scan, two sheets, applied answers.
- `Sources/ShrinkerPro/Views/ContentView.swift` — the sheet presentation.
- `Sources/ShrinkerPro/Core/CommandLineOptions.swift` — `--if-exists`, help text, `ShrinkReport.status`.
- `Sources/shrinker/main.swift` — apply the mode.
- `Tests/ShrinkerProTests/{SettingsTests,OutputPathResolverTests,AppModelTests,CommandLineOptionsTests,ShrinkerCLITests}.swift`
- `README.md`, `CHANGELOG.md`, `project.yml`

**Why `ShrinkEngineTests` is not in that list:** all 22 of its `engine.shrink(input, settings:)` call sites keep compiling against the convenience overload retained in Task 6. Migrating them is not required and is not part of this plan.

---

### Task 1: The `warnBeforeOverwrite` setting

**Files:**
- Modify: `Sources/ShrinkerPro/Core/Settings.swift`
- Test: `Tests/ShrinkerProTests/OverwriteGuardTests.swift` (create)

**Interfaces:**
- Consumes: nothing.
- Produces: `Settings.warnBeforeOverwrite: Bool` (`@Published`, `@MainActor`), default `true`, stored under `"warnBeforeOverwrite"`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ShrinkerProTests/OverwriteGuardTests.swift`:

```swift
import XCTest
@testable import ShrinkerPro

/// The five-part contract every stored preference in this project gets —
/// with one deliberate inversion. The other keys prove they reach the
/// engine snapshot; this one proves it does NOT, because whether to ask a
/// question is a window concern and `OutputSettings` is what a headless
/// run consumes. See `testTheSnapshotCarriesNoSessionOverride` for the
/// same shape applied to the session override.
@MainActor
final class OverwriteWarningSettingTests: XCTestCase {

    func testDefaultsToWarning() {
        let settings = Settings(defaults: makeTestDefaults("warn"))
        XCTAssertTrue(
            settings.warnBeforeOverwrite,
            "the one default in this app that deliberately changes behaviour on upgrade"
        )
    }

    func testItPersists() {
        let defaults = makeTestDefaults("warn")
        Settings(defaults: defaults).warnBeforeOverwrite = false

        XCTAssertFalse(Settings(defaults: defaults).warnBeforeOverwrite)
    }

    func testItPersistsUnderItsPlainName() {
        let defaults = makeTestDefaults("warn")
        Settings(defaults: defaults).warnBeforeOverwrite = false

        XCTAssertEqual(
            defaults.object(forKey: "warnBeforeOverwrite") as? Bool, false,
            "the stored spelling is a compatibility surface — renaming it resets everyone"
        )
    }

    /// `defaults.bool(forKey:)` returns `false` for a value of the wrong
    /// type, and `false` here means "destroy files without asking". A
    /// corrupted store must fail towards the safe answer, which is the same
    /// argument `readQuality` makes about reading a corrupt store as
    /// "quality zero".
    func testACorruptStoredValueFallsBackToWarningRatherThanSilence() {
        let defaults = makeTestDefaults("warn")
        defaults.set("not-a-bool", forKey: "warnBeforeOverwrite")

        XCTAssertTrue(Settings(defaults: defaults).warnBeforeOverwrite)
    }

    /// It is a window concern, not an engine one. Nothing in `OutputSettings`
    /// should ever carry it, or the CLI would inherit a question it cannot ask.
    func testItNeverReachesTheEngineSnapshot() {
        let settings = Settings(defaults: makeTestDefaults("warn"))
        let mirror = Mirror(reflecting: settings.outputSettings)

        XCTAssertFalse(
            mirror.children.contains { $0.label == "warnBeforeOverwrite" },
            "OutputSettings must not carry a UI prompting policy"
        )
    }
}
```

- [ ] **Step 2: Run the tests and verify they fail**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  -only-testing:ShrinkerProTests/OverwriteWarningSettingTests
```

Expected: compile failure — `value of type 'Settings' has no member 'warnBeforeOverwrite'`. (Run `xcodegen generate` first: the test file is new.)

- [ ] **Step 3: Add the key**

In `Settings.swift`, inside `private enum Key`, after `static let quality = "quality"`:

```swift
        /// Ours, so camelCase like `conversionPNG` — not the lowercase
        /// Electron-era spellings above, which are inherited rather than chosen.
        static let warnBeforeOverwrite = "warnBeforeOverwrite"
```

After the `quality` property:

```swift
    /// Whether a batch that would replace an existing file stops to ask.
    ///
    /// Read through `object(forKey:) as? Bool` rather than `bool(forKey:)`,
    /// unlike every other Bool here, and the exception is deliberate:
    /// `bool(forKey:)` answers `false` for a value of the wrong type, and
    /// `false` for this key means "replace files without asking". A corrupt
    /// store must fail towards the safe answer.
    @Published var warnBeforeOverwrite: Bool {
        didSet { defaults.set(warnBeforeOverwrite, forKey: Key.warnBeforeOverwrite) }
    }
```

In the `defaults.register` dictionary, after the `quality` entry:

```swift
            Key.warnBeforeOverwrite: true,
```

In `init`, after `quality = Self.readQuality(...)`:

```swift
        warnBeforeOverwrite = (defaults.object(forKey: Key.warnBeforeOverwrite) as? Bool) ?? true
```

- [ ] **Step 4: Run the tests and verify they pass**

```bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  -only-testing:ShrinkerProTests/OverwriteWarningSettingTests
```

Expected: 5 tests, all PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ShrinkerPro/Core/Settings.swift Tests/ShrinkerProTests/OverwriteGuardTests.swift ShrinkerPro.xcodeproj
git commit -m "Add a warn-before-replacing preference"
```

---

### Task 2: `OutputWarning` — when originals are genuinely at risk

**Files:**
- Create: `Sources/ShrinkerPro/Core/OutputWarning.swift`
- Test: `Tests/ShrinkerProTests/OverwriteGuardTests.swift` (append)

**Interfaces:**
- Consumes: nothing.
- Produces: `OutputWarning.replacesOriginals(keepOriginal: Bool, saveInSameFolder: Bool, savePath: URL?, useSubfolder: Bool) -> Bool`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/ShrinkerProTests/OverwriteGuardTests.swift`:

```swift
// MARK: - Which combinations actually replace an original

/// Today's caption claims originals are overwritten whenever the suffix is
/// off. Three of the four combinations below make that a false alarm, and
/// the fourth is the only one that earns a warning.
final class OutputWarningTests: XCTestCase {

    private let elsewhere = URL(fileURLWithPath: "/tmp/shrunk")

    func testKeepingOriginalsNeverReplacesAnything() {
        for sameFolder in [true, false] {
            for subfolder in [true, false] {
                XCTAssertFalse(
                    OutputWarning.replacesOriginals(
                        keepOriginal: true, saveInSameFolder: sameFolder,
                        savePath: sameFolder ? nil : elsewhere, useSubfolder: subfolder
                    ),
                    ".min makes the name differ, whatever else is set"
                )
            }
        }
    }

    func testReplacingInTheSameFolderWithNoSubfolderIsTheOneRiskyCase() {
        XCTAssertTrue(
            OutputWarning.replacesOriginals(
                keepOriginal: false, saveInSameFolder: true, savePath: nil, useSubfolder: false
            )
        )
    }

    func testASubfolderTakesTheOutputOutOfHarmsWay() {
        XCTAssertFalse(
            OutputWarning.replacesOriginals(
                keepOriginal: false, saveInSameFolder: true, savePath: nil, useSubfolder: true
            ),
            "the result lands in minified/, so the original is untouched"
        )
    }

    func testAChosenSaveFolderTakesTheOutputOutOfHarmsWay() {
        XCTAssertFalse(
            OutputWarning.replacesOriginals(
                keepOriginal: false, saveInSameFolder: false, savePath: elsewhere, useSubfolder: false
            )
        )
    }

    /// The subtlety that makes a naive `!saveInSameFolder` check wrong:
    /// `OutputPathResolver` only redirects when a save path actually exists,
    /// and otherwise writes beside the original — so "somewhere else" with
    /// nothing chosen is still the original's own folder.
    func testNotSameFolderButNoFolderChosenStillReplacesTheOriginal() {
        XCTAssertTrue(
            OutputWarning.replacesOriginals(
                keepOriginal: false, saveInSameFolder: false, savePath: nil, useSubfolder: false
            ),
            "no savePath means the resolver falls back to the input's folder"
        )
    }
}
```

- [ ] **Step 2: Run the tests and verify they fail**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  -only-testing:ShrinkerProTests/OutputWarningTests
```

Expected: compile failure — `cannot find 'OutputWarning' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/ShrinkerPro/Core/OutputWarning.swift`:

```swift
import Foundation

/// Whether a given combination of output settings genuinely replaces the
/// user's own files.
///
/// Factored out of `SettingsView` for the same reason
/// `NotificationPermission.showsDeniedNotice(toggleIsOn:)` is: this project
/// carries no view-tree testing dependency, so a condition left inline in a
/// `body` is logic no test can reach — and this one decides whether a
/// destructive-action warning appears at all.
///
/// It mirrors `OutputPathResolver.destination`, which is the only reason it
/// can be trusted: the resolver redirects only when a save path actually
/// exists, appends `minified/` when asked, and appends `.min` when originals
/// are kept. Any of those three moves the output off the input's path.
enum OutputWarning {

    static func replacesOriginals(
        keepOriginal: Bool,
        saveInSameFolder: Bool,
        savePath: URL?,
        useSubfolder: Bool
    ) -> Bool {
        // `.min` alone guarantees a different name.
        if keepOriginal { return false }
        // minified/ is a different directory.
        if useSubfolder { return false }
        // A redirect only happens when there is somewhere to redirect to.
        if !saveInSameFolder, savePath != nil { return false }
        return true
    }
}
```

- [ ] **Step 4: Run the tests and verify they pass**

```bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  -only-testing:ShrinkerProTests/OutputWarningTests
```

Expected: 5 tests, all PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ShrinkerPro/Core/OutputWarning.swift Tests/ShrinkerProTests/OverwriteGuardTests.swift ShrinkerPro.xcodeproj
git commit -m "Say when originals are actually at risk, rather than always"
```

---

### Task 3: The Settings panel regroup

**Files:**
- Modify: `Sources/ShrinkerPro/Views/SettingsView.swift:13-64` (the two headerless sections)

**Interfaces:**
- Consumes: `Settings.warnBeforeOverwrite` (Task 1), `OutputWarning.replacesOriginals` (Task 2).
- Produces: no new API. Visual change only.

There is no unit test for this step — the logic it depends on is already covered by Tasks 1 and 2, and this project has no view-tree testing dependency. Verification is by eye, per Step 3.

- [ ] **Step 1: Replace the first two sections**

In `SettingsView.swift`, replace the whole first `Section { … }` (currently lines 14-41, ending with the `.foregroundStyle(.secondary)` / `.fixedSize` caption) and the second `Section { … }` (lines 42-64) with:

```swift
            Section {
                Picker("Where", selection: $settings.saveInSameFolder) {
                    Text("Same folder as original").tag(true)
                    Text("Choose folder…").tag(false)
                }
                .pickerStyle(.radioGroup)

                if !settings.saveInSameFolder {
                    HStack {
                        Text(settings.savePath?.path ?? "No folder chosen")
                            .font(.caption)
                            .foregroundStyle(settings.savePath == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer()
                        Button("Choose…", action: chooseFolder)
                    }
                }

                Toggle("Put them in a \"minified\" subfolder", isOn: $settings.useSubfolder)

                // A radio pair, not a checkbox: the defect being fixed is a
                // switch whose off-state you had to infer. Both branches now
                // state their own consequence. The binding and its "suffix"
                // key are unchanged — this is presentation only.
                Picker("Files", selection: $settings.keepOriginal) {
                    Text("Keep originals, save a .min copy").tag(true)
                    Text("Replace originals").tag(false)
                }
                .pickerStyle(.radioGroup)

                Toggle("Warn before replacing a file", isOn: $settings.warnBeforeOverwrite)

                // Only when the current combination genuinely puts originals
                // at risk. The old caption asserted this unconditionally and
                // was wrong in three of four combinations — see OutputWarning.
                if OutputWarning.replacesOriginals(
                    keepOriginal: settings.keepOriginal,
                    saveInSameFolder: settings.saveInSameFolder,
                    savePath: settings.savePath,
                    useSubfolder: settings.useSubfolder
                ) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Your originals will be overwritten and cannot be recovered. Converted files keep a separate extension, so those originals are left alone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("Output")
            }
```

- [ ] **Step 2: Add the GENERAL section**

Immediately before the closing `}` of the `Form` (after the Metadata `Section`'s footer closure), add:

```swift
            Section {
                Toggle("Enable notifications", isOn: $settings.notification)
                if notificationPermission.showsDeniedNotice(toggleIsOn: settings.notification) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Notifications are turned off for Shrinker Pro in System Settings, so none will appear.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Open Notification Settings…") {
                                NSWorkspace.shared.open(NotificationPermission.systemSettingsURL)
                            }
                            .controlSize(.small)
                        }
                    }
                }
                Toggle("Clear result list when shrinking new images", isOn: $settings.clearList)
                Toggle("Check for updates", isOn: $settings.updateCheck)
            } header: {
                Text("General")
            }
```

- [ ] **Step 3: Build, launch, and verify by eye**

```bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/"Shrinker Pro.app"
```

Then press ⌘, and confirm all five of these:
1. Sections read **Output, Conversion, Quality, Metadata, General** in that order, every one with a visible header.
2. "Files" is a radio pair; picking "Replace originals" reveals the orange warning.
3. Ticking "Put them in a minified subfolder" while "Replace originals" is selected **hides** the warning.
4. Choosing "Choose folder…" and picking a real folder also hides it; leaving it on "Choose folder…" with nothing picked leaves it **shown**.
5. "Warn before replacing a file" is on.

- [ ] **Step 4: Confirm the whole suite still builds and passes**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData
```

Expected: PASS. Nothing here changes behaviour the suite covers, so a failure means a typo.

- [ ] **Step 5: Commit**

```bash
git add Sources/ShrinkerPro/Views/SettingsView.swift
git commit -m "Regroup Settings into five headed sections"
```

---

### Task 4: Split path-building from directory creation

**Files:**
- Modify: `Sources/ShrinkerPro/Core/OutputPathResolver.swift:56-98`
- Test: `Tests/ShrinkerProTests/OutputPathResolverTests.swift` (append)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `OutputPathResolver.destination(input: URL, settings: OutputSettings, targetExtension: String?) -> URL` — pure, non-throwing, creates nothing.
  - `OutputPathResolver.prepareDirectory(for: URL, fileManager: FileManager) throws`
  - `OutputPathResolver.resolve(input:settings:targetExtension:fileManager:) throws -> URL` — retained, now `prepareDirectory` + `destination`, so `ShrinkEngine` is untouched this task.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/ShrinkerProTests/OutputPathResolverTests.swift`, inside the existing class:

```swift
    // MARK: - Building a path without touching the disk

    /// The regression most likely to come back: creating the directory is
    /// what this code does today, and a pre-flight collision scan that
    /// creates `minified/` folders before the user has agreed to anything
    /// would be exactly the bug the warning exists to prevent.
    func testDestinationCreatesNoDirectory() {
        let dest = root.appendingPathComponent("elsewhere")

        let out = OutputPathResolver.destination(
            input: input(),
            settings: settings(sameFolder: false, savePath: dest, subfolder: true),
            targetExtension: nil
        )

        XCTAssertEqual(out.lastPathComponent, "photo.min.png")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dest.path),
            "building a path must not create the save folder"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: out.deletingLastPathComponent().path),
            "building a path must not create the minified/ subfolder"
        )
    }

    /// The split must be behaviour-preserving: for every combination the
    /// suite already covers, the pure builder has to agree with what
    /// `resolve` returns.
    func testDestinationAgreesWithResolveForEveryCombination() throws {
        let dest = root.appendingPathComponent("agree")
        for sameFolder in [true, false] {
            for subfolder in [true, false] {
                for suffix in [true, false] {
                    let cfg = settings(
                        sameFolder: sameFolder,
                        savePath: sameFolder ? nil : dest,
                        subfolder: subfolder, suffix: suffix
                    )
                    let resolved = try OutputPathResolver.resolve(
                        input: input(), settings: cfg, fileManager: .default
                    )
                    let built = OutputPathResolver.destination(
                        input: input(), settings: cfg, targetExtension: nil
                    )
                    XCTAssertEqual(
                        built.path, resolved.path,
                        "pure builder disagreed for sameFolder=\(sameFolder) subfolder=\(subfolder) suffix=\(suffix)"
                    )
                }
            }
        }
    }

    func testPrepareDirectoryCreatesTheDestinationsParent() throws {
        let dest = root.appendingPathComponent("made")
        let out = OutputPathResolver.destination(
            input: input(), settings: settings(sameFolder: false, savePath: dest, subfolder: true),
            targetExtension: nil
        )

        try OutputPathResolver.prepareDirectory(for: out, fileManager: .default)

        var isDir: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: out.deletingLastPathComponent().path, isDirectory: &isDir)
                && isDir.boolValue
        )
    }
```

- [ ] **Step 2: Run the tests and verify they fail**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  -only-testing:ShrinkerProTests/OutputPathResolverTests
```

Expected: compile failure — `type 'OutputPathResolver' has no member 'destination'`.

- [ ] **Step 3: Rewrite the resolver body**

Replace everything from `static func resolve(` to the end of that method in `OutputPathResolver.swift` with:

```swift
    /// Where a file will be written, computed without touching the disk.
    ///
    /// Split out of `resolve` so a caller can ask "where would this land?"
    /// before anything is created. Order matches upstream `generateNewPath`:
    /// redirect the directory, then append the subfolder, then build the
    /// filename.
    static func destination(
        input: URL,
        settings: OutputSettings,
        targetExtension: String? = nil
    ) -> URL {

        var directory = input.deletingLastPathComponent()

        // Upstream only redirects when a savepath actually exists; otherwise it
        // leaves the original directory in place.
        if !settings.saveInSameFolder, let savePath = settings.savePath {
            directory = savePath
        }

        if settings.useSubfolder {
            directory = directory.appendingPathComponent("minified", isDirectory: true)
        }

        // `targetExtension` is nil for same-format compression (keep whatever
        // extension the input had) and set to the conversion's target
        // extension whenever `ShrinkEngine` actually converts the file. That
        // is also why a converting output never collides with its input even
        // with suffix and subfolder both off: the extension itself differs.
        let ext = targetExtension ?? input.pathExtension
        let stem = input.deletingPathExtension().lastPathComponent
        let name = settings.keepOriginal ? stem + ".min" : stem

        return ext.isEmpty
            ? directory.appendingPathComponent(name)
            : directory.appendingPathComponent(name).appendingPathExtension(ext)
    }

    /// Creates the directory a destination will be written into.
    ///
    /// Deliberately separate from `destination`: this is the half with a side
    /// effect, and it must not run until the user has consented to the write.
    static func prepareDirectory(
        for destination: URL,
        fileManager: FileManager = .default
    ) throws {
        let directory = destination.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ShrinkError.outputNotWritten(directory)
        }
    }

    /// Both halves, in the order they have always run. Retained so existing
    /// callers and their tests are unaffected by the split.
    static func resolve(
        input: URL,
        settings: OutputSettings,
        targetExtension: String? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let output = destination(input: input, settings: settings, targetExtension: targetExtension)
        try prepareDirectory(for: output, fileManager: fileManager)
        return output
    }
```

- [ ] **Step 4: Run the tests and verify they pass**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  -only-testing:ShrinkerProTests/OutputPathResolverTests
```

Expected: all tests PASS, including the 13 that already existed — the split is behaviour-preserving or it is wrong.

- [ ] **Step 5: Commit**

```bash
git add Sources/ShrinkerPro/Core/OutputPathResolver.swift Tests/ShrinkerProTests/OutputPathResolverTests.swift
git commit -m "Separate building an output path from creating its directory"
```

---

### Task 5: Finder-style unique naming

**Files:**
- Modify: `Sources/ShrinkerPro/Core/OutputPathResolver.swift`
- Test: `Tests/ShrinkerProTests/OutputPathResolverTests.swift` (append)

**Interfaces:**
- Consumes: nothing.
- Produces: `OutputPathResolver.uniqueDestination(for: URL, fileManager: FileManager) -> URL`

- [ ] **Step 1: Write the failing tests**

Append inside the existing `OutputPathResolverTests` class:

```swift
    // MARK: - Keep Both

    private func touch(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    func testAFreePathIsReturnedUnchanged() throws {
        let free = root.appendingPathComponent("photo.min.png")
        XCTAssertEqual(OutputPathResolver.uniqueDestination(for: free).path, free.path)
    }

    /// Finder's convention, and the `.min` stem must survive it:
    /// `photo.min.png` becomes `photo.min 2.png`, never `photo 2.min.png`.
    func testAnOccupiedPathGetsTheFirstFreeNumber() throws {
        _ = try touch("photo.min.png")

        let unique = OutputPathResolver.uniqueDestination(
            for: root.appendingPathComponent("photo.min.png")
        )

        XCTAssertEqual(unique.lastPathComponent, "photo.min 2.png")
    }

    func testNumberingSkipsGaps() throws {
        _ = try touch("photo.min.png")
        _ = try touch("photo.min 2.png")
        _ = try touch("photo.min 3.png")

        let unique = OutputPathResolver.uniqueDestination(
            for: root.appendingPathComponent("photo.min.png")
        )

        XCTAssertEqual(unique.lastPathComponent, "photo.min 4.png")
    }

    /// Under "Replace originals" there is no `.min` in the stem at all, and
    /// the numbered sibling is what lets the original survive.
    func testAStemWithoutMinIsNumberedToo() throws {
        _ = try touch("photo.png")

        let unique = OutputPathResolver.uniqueDestination(
            for: root.appendingPathComponent("photo.png")
        )

        XCTAssertEqual(unique.lastPathComponent, "photo 2.png")
    }

    func testAnExtensionlessNameIsNumberedWithoutGainingADot() throws {
        _ = try touch("photo")

        let unique = OutputPathResolver.uniqueDestination(
            for: root.appendingPathComponent("photo")
        )

        XCTAssertEqual(unique.lastPathComponent, "photo 2")
    }
```

- [ ] **Step 2: Run the tests and verify they fail**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  -only-testing:ShrinkerProTests/OutputPathResolverTests
```

Expected: compile failure — `type 'OutputPathResolver' has no member 'uniqueDestination'`.

- [ ] **Step 3: Write the implementation**

Add to `OutputPathResolver`, after `prepareDirectory`:

```swift
    /// The first free Finder-style name at or after `destination`.
    ///
    /// `photo.min.png` → `photo.min 2.png`, numbering from 2 and skipping any
    /// that are taken. The whole filename minus its final extension is the
    /// stem, so `.min` is carried along rather than split apart.
    ///
    /// The check-then-write gap is a benign race: the caller writes with a
    /// plain move to a path observed free, and losing it would require another
    /// process to create that exact name in the intervening moment.
    static func uniqueDestination(
        for destination: URL,
        fileManager: FileManager = .default
    ) -> URL {
        guard fileManager.fileExists(atPath: destination.path) else { return destination }

        let ext = destination.pathExtension
        let stem = destination.deletingPathExtension()

        var counter = 2
        while true {
            let numbered = URL(fileURLWithPath: stem.path + " \(counter)")
            let candidate = ext.isEmpty ? numbered : numbered.appendingPathExtension(ext)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }
```

- [ ] **Step 4: Run the tests and verify they pass**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  -only-testing:ShrinkerProTests/OutputPathResolverTests
```

Expected: 5 new tests PASS, existing ones unaffected.

- [ ] **Step 5: Commit**

```bash
git add Sources/ShrinkerPro/Core/OutputPathResolver.swift Tests/ShrinkerProTests/OutputPathResolverTests.swift
git commit -m "Add Finder-style unique naming for Keep Both"
```

---

### Task 6: Promote `Plan` to a `ShrinkPlan` the caller holds

**Files:**
- Modify: `Sources/ShrinkerPro/Core/ShrinkEngine.swift:84-98` (the head of `shrink`), `:274-298` (the `Plan` struct)
- Test: `Tests/ShrinkerProTests/OverwriteGuardTests.swift` (append)

**Interfaces:**
- Consumes: `OutputPathResolver.destination`, `.prepareDirectory` (Task 4).
- Produces:
  - `struct ShrinkPlan` with `let input: URL`, `let destination: URL`, and `func writing(to: URL) -> ShrinkPlan`.
  - `ShrinkEngine.plan(_ input: URL, settings: OutputSettings) throws -> ShrinkPlan`
  - `ShrinkEngine.shrink(_ plan: ShrinkPlan) throws -> ShrinkResult`
  - `ShrinkEngine.shrink(_ input: URL, settings: OutputSettings) throws -> ShrinkResult` — retained convenience, unchanged signature.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/ShrinkerProTests/OverwriteGuardTests.swift`:

```swift
// MARK: - Planning a file without writing it

final class ShrinkPlanTests: XCTestCase {

    private struct MissingTestResource: Error {}

    private func repoRoot() -> URL {
        ProcessInfo.processInfo.environment["SRCROOT"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func makeEngine() throws -> ShrinkEngine {
        let vendor = repoRoot().appendingPathComponent("vendor/compressors")
        guard FileManager.default.isExecutableFile(atPath: vendor.appendingPathComponent("cjpeg").path) else {
            XCTFail("compressors not built — run scripts/build-compressors.sh")
            throw MissingTestResource()
        }
        let bundle = Bundle(for: Self.self)
        guard let svgo = bundle.url(forResource: "svgo.jsc", withExtension: "js")
            ?? Bundle.main.url(forResource: "svgo.jsc", withExtension: "js") else {
            XCTFail("svgo.jsc.js not bundled — run scripts/prepare-svgo.sh, then xcodegen generate")
            throw MissingTestResource()
        }
        return try ShrinkEngine(
            helperProvider: { vendor.appendingPathComponent($0) }, svgoScriptURL: svgo
        )
    }

    private func staged(_ name: String, _ ext: String) throws -> URL {
        let source = repoRoot().appendingPathComponent("Tests/ShrinkerProTests/Fixtures/\(name).\(ext)")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let staged = dir.appendingPathComponent("\(name).\(ext)")
        try FileManager.default.copyItem(at: source, to: staged)
        return staged
    }

    private func settings(subfolder: Bool = false, keepOriginal: Bool = true) -> OutputSettings {
        OutputSettings(
            saveInSameFolder: true, savePath: nil,
            useSubfolder: subfolder, keepOriginal: keepOriginal
        )
    }

    func testPlanningNamesTheDestinationWithoutWritingAnything() throws {
        let engine = try makeEngine()
        let input = try staged("sample", "png")

        let plan = try engine.plan(input, settings: settings())

        XCTAssertEqual(plan.input.path, input.path)
        XCTAssertEqual(plan.destination.lastPathComponent, "sample.min.png")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: plan.destination.path),
            "planning must not write the output"
        )
    }

    /// The side effect that used to be buried in path resolution. A scan of
    /// a hundred files must leave no `minified/` folders behind.
    func testPlanningCreatesNoSubfolder() throws {
        let engine = try makeEngine()
        let input = try staged("sample", "png")

        let plan = try engine.plan(input, settings: settings(subfolder: true))

        XCTAssertEqual(plan.destination.deletingLastPathComponent().lastPathComponent, "minified")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: plan.destination.deletingLastPathComponent().path),
            "planning must not create minified/"
        )
    }

    /// HEIC always converts, so its destination is a `.jpg` — which is the
    /// reason a collision scan cannot be done on filenames alone.
    func testPlanningAccountsForConversion() throws {
        let engine = try makeEngine()
        let input = try staged("sample", "heic")

        let plan = try engine.plan(input, settings: settings())

        XCTAssertEqual(plan.destination.pathExtension, "jpg")
    }

    func testExecutingAPlanWritesToItsDestination() throws {
        let engine = try makeEngine()
        let input = try staged("sample", "png")
        let plan = try engine.plan(input, settings: settings())

        let result = try engine.shrink(plan)

        XCTAssertEqual(result.output.path, plan.destination.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.destination.path))
    }

    /// How Keep Both is applied: the plan is redirected, and everything else
    /// about it — route, conversion, metadata pass — is carried over intact.
    func testARedirectedPlanWritesToTheNewPath() throws {
        let engine = try makeEngine()
        let input = try staged("sample", "png")
        let plan = try engine.plan(input, settings: settings())
        let elsewhere = plan.destination.deletingLastPathComponent()
            .appendingPathComponent("sample.min 2.png")

        let result = try engine.shrink(plan.writing(to: elsewhere))

        XCTAssertEqual(result.output.lastPathComponent, "sample.min 2.png")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: plan.destination.path),
            "redirecting must not also write the original destination"
        )
    }

    /// The convenience overload is what keeps 22 existing engine tests and
    /// the entire CLI compiling. It must agree with planning then executing.
    func testTheConvenienceOverloadMatchesPlanThenShrink() throws {
        let engine = try makeEngine()
        let a = try staged("sample", "png")
        let b = try staged("sample", "png")

        let direct = try engine.shrink(a, settings: settings())
        let staged = try engine.shrink(engine.plan(b, settings: settings()))

        XCTAssertEqual(direct.output.lastPathComponent, staged.output.lastPathComponent)
        XCTAssertEqual(direct.shrunkBytes, staged.shrunkBytes)
    }
}
```

- [ ] **Step 2: Run the tests and verify they fail**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  -only-testing:ShrinkerProTests/ShrinkPlanTests
```

Expected: compile failure — `value of type 'ShrinkEngine' has no member 'plan'`.

- [ ] **Step 3: Promote the struct and split the method**

In `ShrinkEngine.swift`, replace the `private struct Plan { … }` declaration (lines 274-298) with a file-scope type, keeping every existing doc comment on its fields:

```swift
/// Everything `ShrinkEngine.shrink` needs to know about how one file will be
/// handled, decided before a single byte is written — and now handed to the
/// caller, so "where would this land?" can be answered without landing it.
///
/// The routing fields stay `fileprivate`: they are the engine's business, and
/// a caller that could construct one by hand could hand the engine a route
/// that contradicts its own destination.
struct ShrinkPlan {
    let input: URL
    /// Where this will be written. Computed by `OutputPathResolver.destination`,
    /// which creates nothing — the directory is made in `shrink(_:)`.
    let destination: URL

    fileprivate let compressor: Compressor
    /// `nil` means "keep the input's own extension" — same-format
    /// compression — and a non-nil value is the conversion's target
    /// extension that `OutputPathResolver` was given instead.
    fileprivate let targetExtension: String?
    /// Whether the finished output still needs its metadata written by
    /// ImageIO because the encoder could not.
    fileprivate let needsMetadataPostPass: Bool
    /// Whether the source declared an orientation now baked into the pixels.
    fileprivate let wasRotated: Bool
    /// Whether the file comes out in the format it went in as. Deliberately
    /// NOT derived from `targetExtension`: a rotated JPEG is rewritten into a
    /// relayed route that reports a non-nil extension while converting
    /// nothing, and reading "same format" off that is what let the never-grow
    /// guard overwrite rotated originals with larger files.
    fileprivate let isSameFormat: Bool

    /// The same plan, writing somewhere else. This is how Keep Both is
    /// applied: only the destination moves, so the route, the conversion and
    /// the metadata pass are all carried over exactly as planned.
    func writing(to newDestination: URL) -> ShrinkPlan {
        ShrinkPlan(
            input: input, destination: newDestination, compressor: compressor,
            targetExtension: targetExtension, needsMetadataPostPass: needsMetadataPostPass,
            wasRotated: wasRotated, isSameFormat: isSameFormat
        )
    }
}
```

Then replace the head of `shrink` (lines 84-94) with three methods. The body of the old `shrink` from `let scratchExtension = …` onward is unchanged — it moves into `shrink(_ plan:)` and refers to `plan.destination` where it used to refer to `output`:

```swift
    /// Decide how one file will be handled, and where it will land, without
    /// writing anything or creating any directory.
    func plan(_ input: URL, settings: OutputSettings) throws -> ShrinkPlan {
        let ext = input.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else {
            throw ShrinkError.unsupportedFormat(ext)
        }
        let routing = try routing(for: ext, input: input, settings: settings)
        return ShrinkPlan(
            input: input,
            destination: OutputPathResolver.destination(
                input: input, settings: settings, targetExtension: routing.targetExtension
            ),
            compressor: routing.compressor,
            targetExtension: routing.targetExtension,
            needsMetadataPostPass: routing.needsMetadataPostPass,
            wasRotated: routing.wasRotated,
            isSameFormat: routing.isSameFormat
        )
    }

    /// Plan and execute in one call. The shape the CLI and most existing
    /// tests use, and the reason neither had to change.
    func shrink(_ input: URL, settings: OutputSettings) throws -> ShrinkResult {
        try shrink(plan(input, settings: settings))
    }

    func shrink(_ plan: ShrinkPlan) throws -> ShrinkResult {
        let input = plan.input
        let output = plan.destination
        let ext = input.pathExtension.lowercased()
        let originalBytes = try byteCount(of: input)

        // Now, and not before: the user has consented to this write.
        try OutputPathResolver.prepareDirectory(for: output)

        // … the existing body from `let scratchExtension = plan.targetExtension ?? ext`
        // to the end of the method is unchanged.
    }
```

Rename the existing `private func plan(for ext: String, input: URL, settings: OutputSettings) throws -> Plan` to `private func routing(for ext: String, input: URL, settings: OutputSettings) throws -> ShrinkPlanRouting`, and introduce a small `private struct ShrinkPlanRouting` holding exactly the five routing fields (`compressor`, `targetExtension`, `needsMetadataPostPass`, `wasRotated`, `isSameFormat`). Its body is the existing method's, unchanged except for the return type's name — it already returns those five fields and nothing else.

- [ ] **Step 4: Run the tests and verify they pass**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData
```

Expected: the 6 new `ShrinkPlanTests` PASS **and** all 837 lines of `ShrinkEngineTests` still PASS. The second half is the point: the refactor is behaviour-preserving or it is wrong.

- [ ] **Step 5: Commit**

```bash
git add Sources/ShrinkerPro/Core/ShrinkEngine.swift Tests/ShrinkerProTests/OverwriteGuardTests.swift
git commit -m "Let a caller plan a file without writing it"
```

---

### Task 7: Classifying collisions

**Files:**
- Create: `Sources/ShrinkerPro/Core/OverwritePrompt.swift`
- Test: `Tests/ShrinkerProTests/OverwriteGuardTests.swift` (append)

**Interfaces:**
- Consumes: `ShrinkPlan` (Task 6).
- Produces:
  - `enum OverwriteCategory { case original, existingFile }`
  - `enum OverwriteAnswer { case skip, keepBoth, replace }`
  - `struct OverwriteRequest: Identifiable` with `category`, `paths: [URL]`, `unaffectedCount: Int`, `title: String`, `message: String`, `skipButtonTitle: String`
  - `OverwriteScan.classify(_ plans: [ShrinkPlan], fileManager: FileManager) -> (originals: [ShrinkPlan], existing: [ShrinkPlan])`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/ShrinkerProTests/OverwriteGuardTests.swift`:

```swift
// MARK: - Which collisions are which

final class OverwriteScanTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func touch(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    func testAPlanWhoseDestinationIsItsOwnInputIsAnOriginalAtRisk() throws {
        let file = try touch("photo.png")
        let plans = [ShrinkPlan.stub(input: file, destination: file)]

        let (originals, existing) = OverwriteScan.classify(plans)

        XCTAssertEqual(originals.map(\.input.path), [file.path])
        XCTAssertTrue(existing.isEmpty)
    }

    /// Not an original — something else is simply already sitting there.
    /// The sheet must not claim to know what it is.
    func testAnOccupiedDestinationThatIsNotTheInputIsTheOtherCategory() throws {
        let file = try touch("photo.png")
        let occupied = try touch("photo.min.png")
        let plans = [ShrinkPlan.stub(input: file, destination: occupied)]

        let (originals, existing) = OverwriteScan.classify(plans)

        XCTAssertTrue(originals.isEmpty)
        XCTAssertEqual(existing.map(\.destination.path), [occupied.path])
    }

    func testAFreeDestinationIsNoCollisionAtAll() throws {
        let file = try touch("photo.png")
        let free = root.appendingPathComponent("photo.min.png")
        let plans = [ShrinkPlan.stub(input: file, destination: free)]

        let (originals, existing) = OverwriteScan.classify(plans)

        XCTAssertTrue(originals.isEmpty)
        XCTAssertTrue(existing.isEmpty)
    }

    /// "Replace originals" plus a chosen save folder: the original is not at
    /// risk, so this belongs in the second category however destructive it is.
    func testReplacingIntoAChosenFolderIsNotAnOriginalAtRisk() throws {
        let file = try touch("photo.png")
        let dest = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let occupied = dest.appendingPathComponent("photo.png")
        try Data("y".utf8).write(to: occupied)

        let (originals, existing) = OverwriteScan.classify(
            [ShrinkPlan.stub(input: file, destination: occupied)]
        )

        XCTAssertTrue(originals.isEmpty, "the input file itself is not the destination")
        XCTAssertEqual(existing.count, 1)
    }

    /// Path equality has to survive the forms the same file can be spelled
    /// in, or an in-place plan would be misfiled as "some other file".
    func testClassificationIsNotFooledByAnUnstandardisedPath() throws {
        let file = try touch("photo.png")
        let awkward = root.appendingPathComponent("./photo.png")

        let (originals, _) = OverwriteScan.classify(
            [ShrinkPlan.stub(input: file, destination: awkward)]
        )

        XCTAssertEqual(originals.count, 1, "same file, different spelling")
    }

    func testAMixedBatchSplitsIntoBothCategories() throws {
        let inPlace = try touch("a.png")
        let other = try touch("b.png")
        let occupied = try touch("b.min.png")
        let clean = try touch("c.png")

        let (originals, existing) = OverwriteScan.classify([
            ShrinkPlan.stub(input: inPlace, destination: inPlace),
            ShrinkPlan.stub(input: other, destination: occupied),
            ShrinkPlan.stub(input: clean, destination: root.appendingPathComponent("c.min.png")),
        ])

        XCTAssertEqual(originals.count, 1)
        XCTAssertEqual(existing.count, 1)
    }
}

// MARK: - The sheet's own words

final class OverwriteRequestCopyTests: XCTestCase {

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

    func testOneOriginalIsNamedAndTheWarningIsUnambiguous() {
        let request = OverwriteRequest(
            category: .original, paths: [url("photo.jpg")], unaffectedCount: 48
        )

        XCTAssertEqual(request.title, "Replace 1 original?")
        XCTAssertTrue(request.message.contains("photo.jpg"))
        XCTAssertTrue(request.message.contains("cannot be recovered"))
        XCTAssertTrue(request.message.contains("48"))
        XCTAssertEqual(request.skipButtonTitle, "Skip This")
    }

    func testSeveralOriginalsPluraliseTitleAndButton() {
        let request = OverwriteRequest(
            category: .original,
            paths: [url("a.jpg"), url("b.jpg"), url("c.jpg")],
            unaffectedCount: 0
        )

        XCTAssertEqual(request.title, "Replace 3 originals?")
        XCTAssertEqual(request.skipButtonTitle, "Skip These")
    }

    /// The correction that matters: this sheet must not describe the file as
    /// an earlier .min copy, because with a chosen save folder it may be an
    /// unrelated file that merely shares a name.
    func testTheSecondCategoryDoesNotClaimToKnowWhatTheFileIs() {
        let request = OverwriteRequest(
            category: .existingFile, paths: [url("logo.png")], unaffectedCount: 2
        )

        XCTAssertTrue(request.message.contains("logo.png"))
        XCTAssertFalse(
            request.message.lowercased().contains("earlier run"),
            "the app cannot know that, and guessing wrong about what it destroys is worse than naming the path"
        )
        XCTAssertFalse(request.message.lowercased().contains(".min copy"))
    }

    func testAnUnaffectedCountOfZeroIsNotMentioned() {
        let request = OverwriteRequest(
            category: .original, paths: [url("only.jpg")], unaffectedCount: 0
        )

        XCTAssertFalse(
            request.message.contains("unaffected"),
            "there are no other files to reassure anyone about"
        )
    }
}
```

- [ ] **Step 2: Run the tests and verify they fail**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  -only-testing:ShrinkerProTests/OverwriteScanTests
```

Expected: compile failure — `cannot find 'OverwriteScan' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/ShrinkerPro/Core/OverwritePrompt.swift`:

```swift
import Foundation

/// Which kind of file a collision would destroy.
enum OverwriteCategory {
    /// The destination *is* the input. The user's own file, unrecoverable.
    case original
    /// Something else is already at that path. It may be a `.min` copy from
    /// an earlier run, or an unrelated file that happens to share a name —
    /// and the difference is not knowable from here, which is why nothing in
    /// the copy below pretends otherwise.
    case existingFile
}

/// What the user decided about one category of collision.
enum OverwriteAnswer {
    /// Leave those files alone; everything else in the batch still runs.
    case skip
    case keepBoth
    case replace
}

/// One sheet's worth of question.
struct OverwriteRequest: Identifiable {
    let id = UUID()
    let category: OverwriteCategory
    let paths: [URL]
    /// How many files in this batch are not affected either way, so the sheet
    /// can say the drop is not being abandoned.
    let unaffectedCount: Int

    private var names: String {
        paths.map(\.lastPathComponent).joined(separator: ", ")
    }

    var title: String {
        switch category {
        case .original:
            return paths.count == 1 ? "Replace 1 original?" : "Replace \(paths.count) originals?"
        case .existingFile:
            return paths.count == 1 ? "Replace 1 file?" : "Replace \(paths.count) files?"
        }
    }

    var message: String {
        var lines: [String] = []
        switch category {
        case .original:
            lines.append(
                paths.count == 1
                    ? "\(names) will be overwritten and cannot be recovered."
                    : "These will be overwritten and cannot be recovered: \(names)"
            )
        case .existingFile:
            lines.append(
                paths.count == 1
                    ? "\(names) is already there and will be replaced."
                    : "These are already there and will be replaced: \(names)"
            )
        }
        if unaffectedCount > 0 {
            lines.append(
                unaffectedCount == 1
                    ? "The other file is unaffected."
                    : "The other \(unaffectedCount) files are unaffected."
            )
        }
        return lines.joined(separator: "\n\n")
    }

    /// Not "Cancel": it does not cancel the drop, it declines these files.
    var skipButtonTitle: String {
        paths.count == 1 ? "Skip This" : "Skip These"
    }
}

/// Sorts a batch's plans into the two kinds of collision.
enum OverwriteScan {

    static func classify(
        _ plans: [ShrinkPlan],
        fileManager: FileManager = .default
    ) -> (originals: [ShrinkPlan], existing: [ShrinkPlan]) {
        var originals: [ShrinkPlan] = []
        var existing: [ShrinkPlan] = []

        for plan in plans {
            // Standardised so the same file spelled two ways is still one
            // file — otherwise an in-place plan reads as "some other file",
            // and gets the reassuring sheet instead of the alarming one.
            let destination = plan.destination.standardizedFileURL
            guard fileManager.fileExists(atPath: destination.path) else { continue }

            if destination == plan.input.standardizedFileURL {
                originals.append(plan)
            } else {
                existing.append(plan)
            }
        }
        return (originals, existing)
    }
}
```

Add a test-only stub factory so the classification tests need no compressors. Append to `OverwritePrompt.swift`:

```swift
#if DEBUG
extension ShrinkPlan {
    /// A plan with no real route behind it, for tests that only care about
    /// input and destination. `DEBUG`-only so it cannot reach a release build.
    static func stub(input: URL, destination: URL) -> ShrinkPlan {
        ShrinkPlan(
            input: input, destination: destination, compressor: NoopCompressor(),
            targetExtension: nil, needsMetadataPostPass: false,
            wasRotated: false, isSameFormat: true
        )
    }
}

private struct NoopCompressor: Compressor {
    func compress(_ input: URL, to output: URL, settings: OutputSettings) throws {
        throw ShrinkError.unsupportedFormat("stub")
    }
}
#endif
```

> **Note for the implementer:** `ShrinkPlan`'s routing fields are `fileprivate` to `ShrinkEngine.swift`, so this extension will not compile from another file. Change those five fields to `internal` (drop the `fileprivate`) and keep the doc comment explaining that callers outside the engine have no business constructing one by hand. Confirm `Compressor`'s actual requirement signature in `Sources/ShrinkerPro/Core/Compressor.swift` and match it in `NoopCompressor` — the shape above is indicative, and the protocol is the authority.

- [ ] **Step 4: Run the tests and verify they pass**

```bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  -only-testing:ShrinkerProTests/OverwriteScanTests \
  -only-testing:ShrinkerProTests/OverwriteRequestCopyTests
```

Expected: 10 tests, all PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ShrinkerPro/Core/OverwritePrompt.swift Sources/ShrinkerPro/Core/ShrinkEngine.swift Tests/ShrinkerProTests/OverwriteGuardTests.swift ShrinkerPro.xcodeproj
git commit -m "Sort collisions into originals and files already there"
```

---

### Task 8: The pre-flight scan and the two sheets

**Files:**
- Modify: `Sources/ShrinkerPro/AppModel.swift:115-187` (`process(urls:)`)
- Modify: `Sources/ShrinkerPro/Views/ContentView.swift:61-69`
- Test: `Tests/ShrinkerProTests/AppModelTests.swift` (append)

**Interfaces:**
- Consumes: everything from Tasks 1, 5, 6, 7.
- Produces: `AppModel.pendingOverwrite: OverwriteRequest?` (`@Published`), `AppModel.answerOverwrite(_: OverwriteAnswer)`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/ShrinkerProTests/AppModelTests.swift`, as a new class at the end of the file (it reuses the `makeModel`/`stagedPNG` shapes from `AppModelTests`, repeated rather than shared because the existing two classes already each carry their own copy):

```swift
// MARK: - The overwrite guard

@MainActor
final class OverwriteFlowTests: XCTestCase {

    private struct MissingTestResource: Error {}

    private func makeModel() throws -> (AppModel, Settings) {
        let repoRoot = ProcessInfo.processInfo.environment["SRCROOT"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let vendor = repoRoot.appendingPathComponent("vendor/compressors")
        guard FileManager.default.isExecutableFile(atPath: vendor.appendingPathComponent("cjpeg").path) else {
            XCTFail("compressors not built — run scripts/build-compressors.sh")
            throw MissingTestResource()
        }
        let bundle = Bundle(for: Self.self)
        guard let svgo = bundle.url(forResource: "svgo.jsc", withExtension: "js")
            ?? Bundle.main.url(forResource: "svgo.jsc", withExtension: "js") else {
            XCTFail("svgo.jsc.js not bundled — run scripts/prepare-svgo.sh, then xcodegen generate")
            throw MissingTestResource()
        }
        let engine = try ShrinkEngine(
            helperProvider: { vendor.appendingPathComponent($0) }, svgoScriptURL: svgo
        )
        let settings = Settings(defaults: makeTestDefaults("overwrite-flow"))
        return (AppModel(engine: engine, settings: settings, notifier: nil), settings)
    }

    private func staged(_ name: String = "sample") throws -> URL {
        let repoRoot = ProcessInfo.processInfo.environment["SRCROOT"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = repoRoot.appendingPathComponent("Tests/ShrinkerProTests/Fixtures/sample.png")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let staged = dir.appendingPathComponent("\(name).png")
        try FileManager.default.copyItem(at: source, to: staged)
        return staged
    }

    /// Answers the sheet as soon as one appears, so `process` can complete.
    private func answering(_ answer: OverwriteAnswer, on model: AppModel) -> Task<Void, Never> {
        Task { @MainActor in
            while model.pendingOverwrite == nil {
                await Task.yield()
            }
            model.answerOverwrite(answer)
        }
    }

    func testAFirstRunAsksNothing() async throws {
        let (model, _) = try makeModel()

        await model.process(urls: [try staged()])

        XCTAssertNil(model.pendingOverwrite, "nothing was there to replace")
        XCTAssertEqual(model.rows.count, 1)
    }

    /// The requester's own scenario: shrink, then shrink again.
    func testASecondRunOverTheSameFileAsks() async throws {
        let (model, _) = try makeModel()
        let file = try staged()
        await model.process(urls: [file])

        let responder = answering(.replace, on: model)
        await model.process(urls: [file])
        await responder.value

        XCTAssertEqual(model.rows.count, 2, "replacing still produces a result")
    }

    /// With the setting off the code path must be exactly 1.2.0's.
    func testNothingIsAskedWhenTheWarningIsTurnedOff() async throws {
        let (model, settings) = try makeModel()
        settings.warnBeforeOverwrite = false
        let file = try staged()
        await model.process(urls: [file])

        await model.process(urls: [file])

        XCTAssertNil(model.pendingOverwrite)
        XCTAssertEqual(model.rows.count, 2)
    }

    func testSkippingLeavesTheExistingFileByteForByte() async throws {
        let (model, _) = try makeModel()
        let file = try staged()
        await model.process(urls: [file])
        let output = file.deletingLastPathComponent().appendingPathComponent("sample.min.png")
        let before = try Data(contentsOf: output)

        let responder = answering(.skip, on: model)
        await model.process(urls: [file])
        await responder.value

        XCTAssertEqual(try Data(contentsOf: output), before, "skip must not write")
        XCTAssertEqual(model.rows.count, 1, "a skipped file produces no row")
        XCTAssertNil(model.errorMessage, "skipping is a choice, not a failure")
    }

    func testKeepBothWritesANumberedSibling() async throws {
        let (model, _) = try makeModel()
        let file = try staged()
        await model.process(urls: [file])

        let responder = answering(.keepBoth, on: model)
        await model.process(urls: [file])
        await responder.value

        let folder = file.deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("sample.min.png").path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("sample.min 2.png").path),
            "Keep Both must leave both files on disk"
        )
    }

    /// Skipping one file must not abandon the rest of the drop.
    func testUncollidingFilesInTheSameBatchStillRun() async throws {
        let (model, _) = try makeModel()
        let collides = try staged("collides")
        await model.process(urls: [collides])
        let fresh = try staged("fresh")

        let responder = answering(.skip, on: model)
        await model.process(urls: [collides, fresh])
        await responder.value

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fresh.deletingLastPathComponent().appendingPathComponent("fresh.min.png").path
            ),
            "the file nobody was asked about must still have been shrunk"
        )
    }

    /// The sheet must describe the second category, not the first: with
    /// "Keep originals" on, a re-run threatens the .min copy, not the source.
    func testARerunAsksAboutTheExistingFileNotTheOriginal() async throws {
        let (model, _) = try makeModel()
        let file = try staged()
        await model.process(urls: [file])

        let observer = Task { @MainActor () -> OverwriteCategory? in
            while model.pendingOverwrite == nil { await Task.yield() }
            let category = model.pendingOverwrite?.category
            model.answerOverwrite(.skip)
            return category
        }
        await model.process(urls: [file])

        let category = await observer.value
        XCTAssertEqual(category, .existingFile)
    }
}
```

- [ ] **Step 2: Run the tests and verify they fail**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  -only-testing:ShrinkerProTests/OverwriteFlowTests
```

Expected: compile failure — `value of type 'AppModel' has no member 'pendingOverwrite'`.

- [ ] **Step 3: Rewrite `process(urls:)`**

In `AppModel.swift`, add these members alongside `sessionFormat`:

```swift
    /// The sheet the window should be showing, if any. One category at a
    /// time: the originals-at-risk question is asked and answered before the
    /// second is raised, so each carries its own independent answer.
    @Published private(set) var pendingOverwrite: OverwriteRequest?

    /// Resumed exactly once per request — including when the window goes
    /// away, since a continuation that is never resumed leaks the task that
    /// is awaiting it and the batch would hang forever.
    private var overwriteContinuation: CheckedContinuation<OverwriteAnswer, Never>?

    /// Called by the sheet's buttons. Dismissing counts as `.skip`.
    func answerOverwrite(_ answer: OverwriteAnswer) {
        pendingOverwrite = nil
        overwriteContinuation?.resume(returning: answer)
        overwriteContinuation = nil
    }

    private func ask(_ request: OverwriteRequest) async -> OverwriteAnswer {
        await withCheckedContinuation { continuation in
            overwriteContinuation = continuation
            pendingOverwrite = request
        }
    }
```

Replace the body of `process(urls:)` between `let files = InputExpander.expand(urls)` and the `for file in files {` loop, and change the loop to iterate plans:

```swift
        let files = InputExpander.expand(urls)
        // One snapshot per batch, taken before anything is planned, so
        // changing a setting mid-batch cannot split a drop across two
        // behaviours. A `let`, not a mutated `var`: this is captured by the
        // detached task below, and capturing a `var` is what Swift 6 strict
        // concurrency rejects.
        let outputSettings: OutputSettings = {
            var snapshot = settings.outputSettings
            snapshot.sessionFormat = sessionFormat
            return snapshot
        }()

        // Plan the whole batch first. Planning creates nothing, so a drop the
        // user then declines leaves no trace — not even an empty minified/.
        var plans: [ShrinkPlan] = []
        for file in files {
            do {
                plans.append(try engine.plan(file, settings: outputSettings))
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }

        if settings.warnBeforeOverwrite {
            let (originals, existing) = OverwriteScan.classify(plans)
            // Stakes first: the irreversible question is asked before the
            // recoverable one.
            for group in [(OverwriteCategory.original, originals), (.existingFile, existing)]
            where !group.1.isEmpty {
                let colliding = Set(group.1.map(\.destination.path))
                let answer = await ask(OverwriteRequest(
                    category: group.0,
                    paths: group.1.map(\.destination),
                    unaffectedCount: plans.count - colliding.count
                ))
                switch answer {
                case .replace:
                    break
                case .skip:
                    plans.removeAll { colliding.contains($0.destination.path) }
                case .keepBoth:
                    plans = plans.map { plan in
                        colliding.contains(plan.destination.path)
                            ? plan.writing(to: OutputPathResolver.uniqueDestination(for: plan.destination))
                            : plan
                    }
                }
            }
        }

        var succeeded: [ShrinkResult] = []

        for plan in plans {
            do {
                let engine = engine
                let result = try await Task.detached(priority: .userInitiated) {
                    try engine.shrink(plan)
                }.value

                rows.insert(
                    ResultRow(
                        output: result.output,
                        originalBytes: result.originalBytes,
                        shrunkBytes: result.shrunkBytes,
                        savedPercent: result.savedPercent
                    ),
                    at: 0
                )
                session.record(originalBytes: result.originalBytes, shrunkBytes: result.shrunkBytes)
                NSDocumentController.shared.noteNewRecentDocumentURL(plan.input)
                succeeded.append(result)
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
```

`ShrinkPlan` must be `Sendable` for the detached task. Add `: Sendable` to its declaration in `ShrinkEngine.swift`; if `Compressor` is not `Sendable`, mark the protocol `Sendable` rather than making `ShrinkPlan` `@unchecked` — the compressors are stateless value-like types and the engine already shares itself across detached tasks on that basis.

- [ ] **Step 4: Present the sheet**

In `ContentView.swift`, after the existing `.alert(...)` modifier, add:

```swift
        .alert(
            model.pendingOverwrite?.title ?? "",
            isPresented: Binding(
                get: { model.pendingOverwrite != nil },
                // Dismissing without choosing is Skip: it declines these
                // files, it does not cancel the drop.
                set: { if !$0 { model.answerOverwrite(.skip) } }
            ),
            presenting: model.pendingOverwrite,
            actions: { request in
                Button(request.skipButtonTitle, role: .cancel) { model.answerOverwrite(.skip) }
                Button("Keep Both") { model.answerOverwrite(.keepBoth) }
                Button("Replace", role: .destructive) { model.answerOverwrite(.replace) }
            },
            message: { request in Text(request.message) }
        )
```

- [ ] **Step 5: Run the tests and verify they pass**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData
```

Expected: 7 new `OverwriteFlowTests` PASS, and every existing `AppModelTests` / `SessionOverrideTests` still PASS — they all drop fresh files into fresh directories, so none of them should ever see a sheet.

- [ ] **Step 6: Commit**

```bash
git add Sources/ShrinkerPro/AppModel.swift Sources/ShrinkerPro/Views/ContentView.swift Sources/ShrinkerPro/Core/ShrinkEngine.swift Tests/ShrinkerProTests/AppModelTests.swift
git commit -m "Ask before replacing a file, once per kind of collision"
```

---

### Task 9: `--if-exists` parsing, help, and README

**Files:**
- Modify: `Sources/ShrinkerPro/Core/CommandLineOptions.swift` (the `Options` fields, `parse`, `helpText`, the validation block at `:539`)
- Modify: `README.md:72-79`
- Test: `Tests/ShrinkerProTests/CommandLineOptionsTests.swift` (append)

**Interfaces:**
- Consumes: nothing.
- Produces: `enum IfExists: String { case replace, skip, keepBoth, fail }` with `static func parse(_: String) -> IfExists?`, and `CommandLineOptions.ifExists: IfExists` defaulting to `.replace`.

- [ ] **Step 1: Write the failing tests**

Append to `CommandLineOptionsTests`:

```swift
    // MARK: - --if-exists

    /// The default has to be today's behaviour exactly. Anything else breaks
    /// every script and cron job that already calls this tool.
    func testIfExistsDefaultsToReplace() throws {
        XCTAssertEqual(try CommandLineOptions.parse(["a.png"]).ifExists, .replace)
    }

    func testIfExistsAcceptsEachMode() throws {
        XCTAssertEqual(try CommandLineOptions.parse(["--if-exists", "replace", "a.png"]).ifExists, .replace)
        XCTAssertEqual(try CommandLineOptions.parse(["--if-exists", "skip", "a.png"]).ifExists, .skip)
        XCTAssertEqual(try CommandLineOptions.parse(["--if-exists", "keep-both", "a.png"]).ifExists, .keepBoth)
        XCTAssertEqual(try CommandLineOptions.parse(["--if-exists", "fail", "a.png"]).ifExists, .fail)
    }

    /// Same forgiveness as --quality and --metadata: nobody types camelCase
    /// at a shell prompt, and an agent reading --help should not have to guess.
    func testIfExistsModeNamesAreForgiving() throws {
        XCTAssertEqual(try CommandLineOptions.parse(["--if-exists", "KEEP-BOTH", "a.png"]).ifExists, .keepBoth)
        XCTAssertEqual(try CommandLineOptions.parse(["--if-exists", "keepboth", "a.png"]).ifExists, .keepBoth)
        XCTAssertEqual(try CommandLineOptions.parse(["--if-exists", "Skip", "a.png"]).ifExists, .skip)
    }

    func testAnUnknownIfExistsModeIsRejected() throws {
        XCTAssertThrowsError(try CommandLineOptions.parse(["--if-exists", "clobber", "a.png"])) { error in
            XCTAssertEqual(error as? CommandLineParseError, .invalidValue(flag: "--if-exists", value: "clobber"))
        }
    }

    func testIfExistsNeedsAValue() throws {
        XCTAssertThrowsError(try CommandLineOptions.parse(["a.png", "--if-exists"])) { error in
            XCTAssertEqual(error as? CommandLineParseError, .missingValue("--if-exists"))
        }
    }

    /// With --in-place the destination IS the input, so there is nothing for
    /// this flag to govern. Silently ignoring a flag someone typed is how
    /// precedence rules nobody can guess get born — see --in-place + --out.
    func testIfExistsIsRefusedAlongsideInPlace() throws {
        XCTAssertThrowsError(
            try CommandLineOptions.parse(["--in-place", "--if-exists", "skip", "a.png"])
        ) { error in
            XCTAssertEqual(
                error as? CommandLineParseError,
                .contradictoryFlags("--in-place", "--if-exists")
            )
        }
    }

    /// Stating the default explicitly is not a contradiction.
    func testInPlaceWithAnExplicitReplaceIsAccepted() throws {
        let options = try CommandLineOptions.parse(["--in-place", "--if-exists", "replace", "a.png"])
        XCTAssertTrue(options.inPlace)
        XCTAssertEqual(options.ifExists, .replace)
    }
```

Then extend the existing help-text guard — this is the mechanical drift check, and it will fail until `helpText` is updated:

```swift
        for flag in ["--quality", "--to", "--metadata", "--out", "--in-place", "--json", "--if-exists", "--help", "--version"] {
```

And add:

```swift
    /// Every mode name has to appear, for the same reason every quality level
    /// does: "keep-both" is spelled with a hyphen and an agent would
    /// reasonably guess otherwise.
    func testHelpNamesEveryIfExistsMode() {
        let help = CommandLineOptions.helpText
        for name in ["replace", "skip", "keep-both", "fail"] {
            XCTAssertTrue(help.contains(name), "--help never mentions the \(name) mode")
        }
    }
```

- [ ] **Step 2: Run the tests and verify they fail**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  -only-testing:ShrinkerProTests/CommandLineOptionsTests
```

Expected: compile failure — `value of type 'CommandLineOptions' has no member 'ifExists'`.

- [ ] **Step 3: Add the flag**

In `CommandLineOptions.swift`, add the type near `QualityChoice`:

```swift
/// What to do when a result's destination already exists.
///
/// The vocabulary is deliberately the app's sheet buttons plus this tool's
/// own long-standing refusal stance, so the two surfaces answer the same
/// question with the same words.
enum IfExists: String, Equatable, CaseIterable {
    case replace
    case skip
    case keepBoth
    case fail

    /// What a person types, which is not what Swift spells.
    var flagName: String { self == .keepBoth ? "keep-both" : rawValue }

    static func parse(_ raw: String) -> IfExists? {
        let normalised = raw.lowercased().replacingOccurrences(of: "-", with: "")
        return allCases.first { $0.rawValue.lowercased() == normalised }
    }
}
```

Add the stored option beside `inPlace`:

```swift
    /// `--if-exists`: what to do when the destination already exists.
    /// Defaults to `.replace`, which is exactly what every earlier version of
    /// this tool did — the guard is opt-in precisely so no existing script
    /// changes behaviour on upgrade.
    var ifExists: IfExists = .replace
```

In the `parse` switch, after the `--metadata` case:

```swift
            case "--if-exists":
                let raw = try nextValue(for: argument)
                guard let mode = IfExists.parse(raw) else {
                    throw CommandLineParseError.invalidValue(flag: argument, value: raw)
                }
                options.ifExists = mode
```

After the existing `--in-place`/`--out` validation:

```swift
        // --in-place makes the destination the input, so there is nothing for
        // --if-exists to decide. Refused rather than ignored, for the same
        // reason as above: a flag that is accepted and does nothing is worse
        // than one that is rejected and says why. An explicit `replace` is
        // the default and contradicts nothing.
        if options.inPlace, options.ifExists != .replace, !options.showsHelp {
            throw CommandLineParseError.contradictoryFlags("--in-place", "--if-exists")
        }
```

In `helpText`, after the `--in-place` entry:

```
      --if-exists <what>       when the destination already exists:
                               replace (default), skip, keep-both, fail
```

And add to EXAMPLES:

```
      shrinker --if-exists keep-both --quality 60 photo.jpg
```

- [ ] **Step 4: Update the README table**

In `README.md`, add a row after the `--in-place` row at line 78:

```markdown
| `--if-exists <what>` | when the destination exists: `replace` (default), `skip`, `keep-both`, `fail` |
```

And after the paragraph ending "…'the work failed'." at line 85, add:

```markdown
By default a result replaces whatever is already at its destination, which is
what every earlier version did. `--if-exists` changes that per run: `skip`
leaves existing files alone, `keep-both` writes `photo.min 2.jpg` beside them,
and `fail` refuses the run before any work starts.
```

- [ ] **Step 5: Run the tests and verify they pass**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  -only-testing:ShrinkerProTests/CommandLineOptionsTests
```

Expected: all PASS, including the two help-text drift guards.

- [ ] **Step 6: Commit**

```bash
git add Sources/ShrinkerPro/Core/CommandLineOptions.swift Tests/ShrinkerProTests/CommandLineOptionsTests.swift README.md
git commit -m "Add --if-exists to the CLI, defaulting to today's behaviour"
```

---

### Task 10: Applying the mode in the tool

**Files:**
- Modify: `Sources/shrinker/main.swift:166-204`
- Test: `Tests/ShrinkerProTests/ShrinkerCLITests.swift` (append)

**Interfaces:**
- Consumes: `IfExists` (Task 9), `ShrinkEngine.plan`/`shrink(_ plan:)` (Task 6), `OutputPathResolver.uniqueDestination` (Task 5).
- Produces: no new API. Exit code 65 for `--if-exists fail` on a collision.

- [ ] **Step 1: Write the failing tests**

Append to `ShrinkerCLITests`:

```swift
    // MARK: - --if-exists

    /// The compatibility guarantee: with no flag, a re-run replaces, exactly
    /// as every earlier version did.
    func testTheDefaultStillReplacesSilently() throws {
        let helpers = try stagedHelpers()
        let work = try workspace()
        let input = try fixture("sample", "png", into: work)

        _ = try run([input.path], helpers: helpers)
        let result = try run([input.path], helpers: helpers)

        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: work.appendingPathComponent("sample.min 2.png").path),
            "the default must not start inventing names"
        )
    }

    func testSkipLeavesTheExistingFileAloneAndSaysSo() throws {
        let helpers = try stagedHelpers()
        let work = try workspace()
        let input = try fixture("sample", "png", into: work)

        _ = try run([input.path], helpers: helpers)
        let output = work.appendingPathComponent("sample.min.png")
        let before = try Data(contentsOf: output)

        let result = try run(["--if-exists", "skip", input.path], helpers: helpers)

        XCTAssertEqual(result.code, 0, "skipping is what was asked for, not a failure")
        XCTAssertEqual(try Data(contentsOf: output), before)
        XCTAssertTrue(
            result.stderr.contains("sample.min.png"),
            "a skipped file must be named, got: \(result.stderr)"
        )
    }

    func testKeepBothWritesANumberedSibling() throws {
        let helpers = try stagedHelpers()
        let work = try workspace()
        let input = try fixture("sample", "png", into: work)

        _ = try run([input.path], helpers: helpers)
        let result = try run(["--if-exists", "keep-both", input.path], helpers: helpers)

        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.appendingPathComponent("sample.min.png").path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: work.appendingPathComponent("sample.min 2.png").path),
            "keep-both must leave both on disk"
        )
    }

    func testFailRefusesTheRunBeforeDoingAnyWork() throws {
        let helpers = try stagedHelpers()
        let work = try workspace()
        let collides = try fixture("sample", "png", into: work)
        _ = try run([collides.path], helpers: helpers)

        let fresh = work.appendingPathComponent("fresh.png")
        try FileManager.default.copyItem(at: collides, to: fresh)

        let result = try run(["--if-exists", "fail", collides.path, fresh.path], helpers: helpers)

        XCTAssertEqual(result.code, 65, "a set of inputs that cannot be honoured is EX_DATAERR")
        XCTAssertTrue(result.stderr.contains("sample.min.png"), result.stderr)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: work.appendingPathComponent("fresh.min.png").path),
            "fail must refuse before any work starts, not halfway through"
        )
    }

    func testInPlaceWithANonDefaultIfExistsIsRejected() throws {
        let helpers = try stagedHelpers()
        let work = try workspace()
        let input = try fixture("sample", "png", into: work)

        let result = try run(["--in-place", "--if-exists", "skip", input.path], helpers: helpers)

        XCTAssertEqual(result.code, 64, "contradictory flags are a usage error")
        XCTAssertTrue(
            result.stderr.contains("--in-place") && result.stderr.contains("--if-exists"),
            "the message must name both flags, got: \(result.stderr)"
        )
    }
```

- [ ] **Step 2: Run the tests and verify they fail**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  -only-testing:ShrinkerProTests/ShrinkerCLITests
```

Expected: `testSkipLeavesTheExistingFileAloneAndSaysSo`, `testKeepBothWritesANumberedSibling` and `testFailRefusesTheRunBeforeDoingAnyWork` FAIL (the flag parses but does nothing yet).

- [ ] **Step 3: Apply the mode**

In `main.swift`, replace the `for file in inputs { … }` loop's opening — plan first, resolve collisions, then execute:

```swift
let settings = options.outputSettings

// Plan every input before writing anything, so --if-exists fail can refuse
// the whole run rather than stopping halfway with some results written.
var planned: [ShrinkPlan] = []
for file in inputs {
    do {
        planned.append(try engine.plan(file, settings: settings))
    } catch let error as ShrinkError {
        writeLine("shrinker: \(file.path): \(error.errorDescription ?? "failed")", to: .standardError)
        if firstFailure == 0 { firstFailure = error.exitCode }
    } catch {
        writeLine("shrinker: \(file.path): \(error.localizedDescription)", to: .standardError)
        if firstFailure == 0 { firstFailure = 1 }
    }
}

// --in-place makes the destination the input, and the parser refuses any
// non-default --if-exists alongside it, so nothing here can be an original.
let occupied = planned.filter { FileManager.default.fileExists(atPath: $0.destination.path) }

switch options.ifExists {
case .replace:
    break
case .fail:
    if !occupied.isEmpty {
        for plan in occupied {
            writeLine("shrinker: \(plan.destination.path): already exists", to: .standardError)
        }
        writeLine(
            "shrinker: nothing was written. Use --if-exists skip, keep-both, or replace.",
            to: .standardError
        )
        // EX_DATAERR, matching the input-vs-input refusal above: the flags are
        // well formed, it is the state of the destination that cannot be honoured.
        exit(65)
    }
case .skip:
    let skipped = Set(occupied.map(\.destination.path))
    for path in skipped.sorted() {
        writeLine("shrinker: \(path): already exists, skipped", to: .standardError)
    }
    planned.removeAll { skipped.contains($0.destination.path) }
case .keepBoth:
    planned = planned.map { plan in
        FileManager.default.fileExists(atPath: plan.destination.path)
            ? plan.writing(to: OutputPathResolver.uniqueDestination(for: plan.destination))
            : plan
    }
}

for plan in planned {
    do {
        let result = try engine.shrink(plan)
```

The rest of the loop body is unchanged, except the two `catch` blocks now report `plan.input.path` rather than `file.path`.

- [ ] **Step 4: Run the tests and verify they pass**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  -only-testing:ShrinkerProTests/ShrinkerCLITests
```

Expected: all PASS, including the 9 that already existed.

- [ ] **Step 5: Commit**

```bash
git add Sources/shrinker/main.swift Tests/ShrinkerProTests/ShrinkerCLITests.swift
git commit -m "Honour --if-exists when a destination is already taken"
```

---

### Task 11: `status` in the JSON report

**Files:**
- Modify: `Sources/ShrinkerPro/Core/CommandLineOptions.swift:230-258` (`ShrinkReport`), `Sources/shrinker/main.swift`
- Test: `Tests/ShrinkerProTests/CommandLineOptionsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `ShrinkReport.status: String` — `"shrunk"`, `"declined"`, or `"skipped"`; `ShrinkReport.jsonLine(for: ShrinkResult, status:)`.

- [ ] **Step 1: Write the failing tests**

In `CommandLineOptionsTests`, update the key-order guard to include the new key (sorted, `status` comes last):

```swift
        let keys = ["input", "originalBytes", "output", "savedPercent", "shrunkBytes", "status"]
```

And append:

```swift
    // MARK: - status

    /// A skip and a decline both mean "nothing happened", for entirely
    /// different reasons, and a caller may act differently on each. Before
    /// this field the two were indistinguishable — both reported
    /// `output == input` at 0%.
    func testAShrunkFileSaysSo() throws {
        let json = try encodedReport()
        XCTAssertEqual(json["status"] as? String, "shrunk")
    }

    func testADeclinedReEncodeIsLabelledDeclined() throws {
        let result = ShrinkResult(
            input: URL(fileURLWithPath: "/photos/a.webp"),
            output: URL(fileURLWithPath: "/photos/a.webp"),
            originalBytes: 18828, shrunkBytes: 18828
        )
        let data = try JSONEncoder().encode(ShrinkReport(result))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["status"] as? String, "declined")
    }

    func testASkippedFileIsLabelledSkipped() throws {
        let line = try ShrinkReport.jsonLine(
            for: ShrinkResult(
                input: URL(fileURLWithPath: "/photos/a.png"),
                output: URL(fileURLWithPath: "/photos/a.min.png"),
                originalBytes: 1000, shrunkBytes: 1000
            ),
            status: .skipped
        )

        XCTAssertTrue(line.contains("\"status\":\"skipped\""), line)
    }

    /// The three spellings are what a script branches on, so they are pinned.
    func testTheStatusSpellingsAreStable() {
        XCTAssertEqual(ShrinkReport.Status.shrunk.rawValue, "shrunk")
        XCTAssertEqual(ShrinkReport.Status.declined.rawValue, "declined")
        XCTAssertEqual(ShrinkReport.Status.skipped.rawValue, "skipped")
    }
```

- [ ] **Step 2: Run the tests and verify they fail**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  -only-testing:ShrinkerProTests/CommandLineOptionsTests
```

Expected: compile failure — `type 'ShrinkReport' has no member 'Status'`.

- [ ] **Step 3: Add the field**

In `ShrinkReport`:

```swift
    /// What actually happened to this file.
    ///
    /// Additive to a contract that is already a compatibility surface:
    /// `.sortedKeys` places it deterministically and a consumer reading the
    /// five older keys is unaffected. It exists because "nothing happened"
    /// had two causes and only one spelling — a skipped file and a declined
    /// re-encode both reported `output == input` at 0% saved.
    enum Status: String, Encodable {
        case shrunk
        case declined
        case skipped
    }

    let status: Status
```

Add `status` to the stored properties in declaration order (it is emitted sorted regardless), and update the initialiser:

```swift
    init(_ result: ShrinkResult, status: Status? = nil) {
        self.input = result.input.path
        self.output = result.output.path
        self.originalBytes = result.originalBytes
        self.shrunkBytes = result.shrunkBytes
        self.savedPercent = result.savedPercent
        // The engine reports a declined re-encode by pointing the result at
        // the untouched original — the same signal main.swift branches on to
        // print "left alone".
        self.status = status ?? (result.output == result.input ? .declined : .shrunk)
    }
```

And the line emitter:

```swift
    static func jsonLine(for result: ShrinkResult, status: Status? = nil) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return String(decoding: try encoder.encode(ShrinkReport(result, status: status)), as: UTF8.self)
    }
```

In `main.swift`'s `--if-exists skip` branch, emit a JSON line per skipped file when `options.json` is set, so a scripted caller sees one object per input:

```swift
        if options.json {
            for plan in occupied {
                let untouched = ShrinkResult(
                    input: plan.input, output: plan.destination,
                    originalBytes: 0, shrunkBytes: 0
                )
                print(try ShrinkReport.jsonLine(for: untouched, status: .skipped))
            }
        }
```

- [ ] **Step 4: Run the tests and verify they pass**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  -only-testing:ShrinkerProTests/CommandLineOptionsTests
```

Expected: all PASS, including the updated key-order guard.

- [ ] **Step 5: Commit**

```bash
git add Sources/ShrinkerPro/Core/CommandLineOptions.swift Sources/shrinker/main.swift Tests/ShrinkerProTests/CommandLineOptionsTests.swift
git commit -m "Say in JSON what happened to each file"
```

---

### Task 12: `keep-both` resolves the input-vs-input refusal

**Files:**
- Modify: `Sources/shrinker/main.swift:144-164`
- Test: `Tests/ShrinkerProTests/ShrinkerCLITests.swift` (append)

**Interfaces:**
- Consumes: `IfExists` (Task 9), `OutputPathResolver.uniqueDestination` (Task 5).
- Produces: no new API.

- [ ] **Step 1: Write the failing tests**

Append to `ShrinkerCLITests`:

```swift
    /// Two inputs landing on one name is still refused by default — picking a
    /// winner remains the bug it always was. But with keep-both the user has
    /// explicitly asked for numbering, so inventing a name is no longer
    /// inventing: it is doing as told.
    func testKeepBothDisambiguatesTwoInputsThatWouldCollide() throws {
        let helpers = try stagedHelpers()
        let work = try workspace()
        let a = work.appendingPathComponent("a")
        let b = work.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)

        let source = repoRoot().appendingPathComponent("Tests/ShrinkerProTests/Fixtures/sample.png")
        try FileManager.default.copyItem(at: source, to: a.appendingPathComponent("logo.png"))
        try FileManager.default.copyItem(at: source, to: b.appendingPathComponent("logo.png"))

        let out = work.appendingPathComponent("out")
        let result = try run(
            ["--if-exists", "keep-both", "--out", out.path,
             a.appendingPathComponent("logo.png").path,
             b.appendingPathComponent("logo.png").path],
            helpers: helpers
        )

        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("logo.min.png").path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: out.appendingPathComponent("logo.min 2.png").path),
            "both results must survive"
        )
    }

    /// The other three modes keep refusing, unchanged.
    func testSkipAndFailStillRefuseTwoInputsThatWouldCollide() throws {
        let helpers = try stagedHelpers()
        for mode in ["skip", "fail"] {
            let work = try workspace()
            let a = work.appendingPathComponent("a")
            let b = work.appendingPathComponent("b")
            try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
            let source = repoRoot().appendingPathComponent("Tests/ShrinkerProTests/Fixtures/sample.png")
            try FileManager.default.copyItem(at: source, to: a.appendingPathComponent("logo.png"))
            try FileManager.default.copyItem(at: source, to: b.appendingPathComponent("logo.png"))

            let result = try run(
                ["--if-exists", mode, "--out", work.appendingPathComponent("out").path,
                 a.appendingPathComponent("logo.png").path,
                 b.appendingPathComponent("logo.png").path],
                helpers: helpers
            )

            XCTAssertNotEqual(result.code, 0, "--if-exists \(mode) must still refuse a two-input collision")
        }
    }
```

- [ ] **Step 2: Run the tests and verify they fail**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  -only-testing:ShrinkerProTests/ShrinkerCLITests/testKeepBothDisambiguatesTwoInputsThatWouldCollide
```

Expected: FAIL with exit 65 — the refusal fires before `--if-exists` is consulted.

- [ ] **Step 3: Gate the refusal**

In `main.swift`, change the collision guard at line 144 so `keep-both` opts out of it:

```swift
// Two inputs that would land on the same filename inside --out: the second
// overwrites the first, and the run reports success for both. Refused rather
// than disambiguated — inventing `logo-1.min.png` would invent a name nobody
// asked for, and picking a winner is exactly what the bug already did.
//
// `--if-exists keep-both` is the one exception, and it is not an exception to
// the principle: numbering is wrong when nobody asked for it and right when
// somebody did. Those runs fall through to the per-destination numbering
// below, which makes the second input land on `logo.min 2.png`.
if options.outputDirectory != nil, options.ifExists != .keepBoth {
```

Then, in the `.keepBoth` branch added in Task 10, number against destinations already claimed *within this run* as well as files on disk — otherwise two inputs both resolve to the same free name:

```swift
case .keepBoth:
    var claimed: Set<String> = []
    planned = planned.map { plan in
        var destination = plan.destination
        while FileManager.default.fileExists(atPath: destination.path) || claimed.contains(destination.path) {
            destination = OutputPathResolver.uniqueDestination(
                for: destination,
                fileManager: ClaimAwareFileManager(claimed: claimed)
            )
        }
        claimed.insert(destination.path)
        return plan.writing(to: destination)
    }
```

> **Note for the implementer:** rather than introduce a `FileManager` subclass, the simpler correct form is a local loop that appends " 2", " 3"… checking both `FileManager.default.fileExists` and `claimed`. Implement whichever reads more plainly; the requirement under test is only that two identically-named inputs produce `logo.min.png` and `logo.min 2.png`, and that neither silently replaces the other.

- [ ] **Step 4: Run the tests and verify they pass**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  -only-testing:ShrinkerProTests/ShrinkerCLITests
```

Expected: all PASS, including `testTwoInputsThatWouldOverwriteEachOtherAreRefused` and `testAHEICAndAJPEGWithTheSameStemCollide`, which must keep refusing under the default mode.

- [ ] **Step 5: Commit**

```bash
git add Sources/shrinker/main.swift Tests/ShrinkerProTests/ShrinkerCLITests.swift
git commit -m "Let keep-both resolve a two-input collision it used to refuse"
```

---

### Task 13: Version, changelog, and screenshots

**Files:**
- Modify: `project.yml:25` (`MARKETING_VERSION`), `:26` (`CURRENT_PROJECT_VERSION`)
- Modify: `CHANGELOG.md`
- Modify: `docs/screenshots/` (the Settings panel shot)

**Interfaces:**
- Consumes: everything.
- Produces: nothing.

- [ ] **Step 1: Bump the version**

In `project.yml`:

```yaml
    MARKETING_VERSION: "1.2.1"
    CURRENT_PROJECT_VERSION: "6"
```

- [ ] **Step 2: Verify the CLI version guard now fails, then passes**

```bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  -only-testing:ShrinkerProTests/CommandLineOptionsTests/testTheCLIVersionMatchesTheProjectsMarketingVersion
```

Expected: FAIL — `shrinker --version reports 1.2.0 but the project says 1.2.1`. This test exists precisely to catch a forgotten bump. Fix it by updating `ShrinkerVersion.current` in `Sources/ShrinkerPro/Core/ShrinkerVersion.swift` to `"1.2.1"`, then re-run and expect PASS.

- [ ] **Step 3: Write the changelog entry**

At the top of `CHANGELOG.md`, directly under the intro paragraph:

```markdown
## 1.2.1 — 2026-09-14

### Added

**Shrinker Pro now asks before replacing a file.** Drop something whose result
would land on a file that already exists and you are asked once, before any
work starts, with the choice to skip those files, keep both, or replace. Files
in the same drop that collide with nothing are shrunk either way.

Two questions rather than one, because the stakes differ: replacing your own
original cannot be undone, while replacing a copy from an earlier run usually
can be shrugged off. Each is asked separately and answered separately.

You can turn it off in Settings under Output, which restores exactly what
1.2.0 did.

**`--if-exists` for the command line.** The same choices, as a flag:

```
shrinker --if-exists skip ./screenshots
shrinker --if-exists keep-both photo.jpg
shrinker --if-exists fail ./build-assets
```

It defaults to `replace`, which is what every earlier version did, so no
existing script changes behaviour. `--json` output gains a `status` field —
`shrunk`, `declined` or `skipped` — so a caller can tell a file that was left
alone from one that had nothing worth saving.

### Changed

**Settings is easier to read.** The panel is now five labelled sections —
Output, Conversion, Quality, Metadata, General — where two of them previously
had no heading at all. Where files go and whether originals are kept are
radio choices that each state their own consequence, instead of a checkbox
whose off-state you had to work out.

### Fixed

**The "your originals will be overwritten" warning told the truth three times
out of four.** It appeared whenever the `.min` suffix was off, including when
a subfolder or a chosen save folder meant nothing was being overwritten at
all. It now appears only when originals are genuinely at risk.
```

- [ ] **Step 4: Retake the Settings screenshot**

The Settings panel changed shape, so any README or site shot of it is stale.

```bash
open build/DerivedData/Build/Products/Debug/"Shrinker Pro.app"
```

Press ⌘, and capture the panel. **Before capturing anything in Finder, hide the sidebar and the path bar** — they show client folder names. Replace the corresponding file in `docs/screenshots/` keeping its existing filename so no Markdown link changes.

- [ ] **Step 5: Run the entire suite**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData
```

Expected: every test PASSES. Do not proceed past a failure.

- [ ] **Step 6: Commit**

```bash
git add project.yml Sources/ShrinkerPro/Core/ShrinkerVersion.swift CHANGELOG.md docs/screenshots ShrinkerPro.xcodeproj
git commit -m "Prepare 1.2.1"
```

---

## Not in this plan

Deliberately left for when the user says 1.2.1 ships, per the spec and the project's release habits:

- No signed or notarized build, no `scripts/release.sh` run, no appcast entry.
- No website copy or version/size facts.
- No Homebrew formula bump.

## Self-Review

**Spec coverage.** §1 → Task 3. §2 panel → Task 3; the warning-line correction → Tasks 2 and 3; the new key → Task 1. §3 → Tasks 4 and 6. §4 classification → Task 7; two sheets, buttons, mechanism → Task 8; unique naming → Task 5. §5 `--if-exists` → Tasks 9 and 10; the `keep-both` reconciliation → Task 12; `--json` status → Task 11; help and README → Task 9. §6 testing → distributed across every task's Step 1. §7 out of scope → nothing implements it, by design.

**Placeholders.** Two steps carry an explicit "Note for the implementer" rather than final code — Task 7's `NoopCompressor` (the `Compressor` protocol is the authority on its own signature) and Task 12's within-run numbering (two correct shapes, requirement stated as a test). Both name the exact requirement and the file to check; neither defers a decision.

**Type consistency.** `ShrinkPlan` is introduced in Task 6 and consumed by name in 7, 8, 10 and 12. `OverwriteAnswer` cases `.skip`/`.keepBoth`/`.replace` are used identically in Tasks 7, 8 and 10. `IfExists` cases match their flag spellings through `flagName`. `OutputPathResolver.uniqueDestination` has one signature, used in Tasks 5, 8, 10 and 12. `OverwriteCategory` is `.original`/`.existingFile` throughout.
