# Localization Phase 2 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fill the 123-entry String Catalog with 35 more languages, verified structurally and editorially, without changing a line of English.

**Architecture:** No translator touches the catalog. Each language is authored
as `translations/<lang>.json` and spliced in by `scripts/merge-translations.py`,
a sibling to the existing `sync-catalog.py`. Guard tests derive each language's
required plural categories from the platform at test time rather than from any
written table.

**Tech Stack:** Swift 6.4, XCTest, Python 3 (stdlib only), String Catalogs.

**Spec:** `docs/design/specs/2026-09-21-localization-phase-2-design.md`

## Global Constraints

- **English must not change.** Not one `"en"` value, not one key, not one
  comment. All 506 existing tests pass unmodified.
- **The catalog is formatted in Xcode's style** — `"key" : value`, with short
  `stringUnit` objects inline on one line. 742 lines use it. A `json.dump`
  round-trip reformats the whole file and Xcode flips it back on next open, so
  **all catalog writes splice text; none re-serialise the document.**
- **Never edit `Localizable.xcstrings` by hand** in this phase. Author
  `translations/<lang>.json` and run the merge script.
- **The 35 languages:** ar ca cs da de el es fa fi fr he hr hu is it ja ko nb
  nl nn pl pt-BR pt-PT ro ru sk sl sv th tr uk vi zh-Hans zh-Hant zh-HK.
- **Stays English everywhere:** "Shrinker Pro", format names (JPEG, WebP, AVIF,
  PNG, HEIC, GIF, SVG), the entire `shrinker` CLI, `UserDefaults` keys, SF
  Symbol names.
- **Placeholders are load-bearing.** Every `%@`, `%lld`, `%1$@`, `%2$lld` must
  survive translation in the same count, and positional specifiers must stay
  positional. A dropped placeholder is a crash or a corrupted sentence, and it
  is invisible to anyone who cannot read the language.
- **Repo spelling:** British ("optimised", "pluralisation") EXCEPT
  "center"/"centered", American. This governs English source text and comments
  only.
- **Build/test:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project ShrinkerPro.xcodeproj -scheme ShrinkerPro -destination 'platform=macOS'`
- After editing `project.yml`, run `xcodegen generate` first. (No task here
  should need to.)

---

### Task 1: The glossary

Written before any translation, because a glossary produced afterwards
documents whatever was already done rather than governing it.

**Files:**
- Create: `docs/localization-glossary.md`
- Test: `Tests/ShrinkerProTests/LocalizationGuardTests.swift` (append)

**Interfaces:**
- Consumes: nothing.
- Produces: `docs/localization-glossary.md` with a `## Terms` section whose
  entries are Markdown list items of the form `- **<term>** — <guidance>`.
  Task 6 and Task 7 read it.

- [ ] **Step 1: Write the glossary**

Create `docs/localization-glossary.md` with two sections.

`## Terms` — the English words that must render consistently inside a single
language. One list item each, in this exact form, and these exact terms:

```markdown
- **shrink** — the app's core verb. The same word must be used in the drop zone, the notification and the Settings prose. Do not alternate with a synonym for variety.
- **minified** — the subfolder name and the `.min` suffix. A borrowed technical term; keep it recognisable rather than translating it to a general word for "smaller".
- **session** — one run of the app, as opposed to a saved default. The session bar and Settings both lean on the distinction, so the two must not collapse into the same word.
- **original** — the user's own input file, the thing that can be destroyed. Must be distinct from "file", which the same sheet uses for something less alarming.
- **crop** — the noun and the verb. Distinct from "resize" and from "scale".
- **Keep Both** — the overwrite sheet's non-destructive choice. Match the platform's own wording for this action where one exists.
- **Skip These** — declines these files without cancelling the drop. Not "Cancel"; the distinction is the whole point of the button.
- **Replace** — overwrites. Destructive. Must read as more final than "Keep Both".
- **Reveal** — shows the file in Finder. Use the platform's own term for this action, which is rarely a literal translation of "reveal".
```

`## Platform conventions` — a short prose section instructing the translator to
prefer the term macOS itself uses for standard actions (Save, Open, Settings,
Quit, Reveal in Finder) over a literal translation, and to check the system's
own menus rather than guessing. Name the risk plainly: an app that invents its
own vocabulary for a standard action reads as foreign even when every word is
correct.

- [ ] **Step 2: Write the failing test**

Append to the existing `LocalizationGuardTests` class:

```swift
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
```

- [ ] **Step 3: Run it**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project ShrinkerPro.xcodeproj -scheme ShrinkerPro -destination 'platform=macOS' -only-testing:ShrinkerProTests/LocalizationGuardTests`
Expected: PASS. If a term fails, the term is wrong — fix the glossary, not the test. (Note every term above was chosen because it appears in a catalog key; a failure means the catalog changed.)

- [ ] **Step 4: Commit**

```bash
git add docs/localization-glossary.md Tests/ShrinkerProTests/LocalizationGuardTests.swift
git commit -m "Pin the terms every language has to keep straight"
```

---

### Task 2: Share the catalog's text-splicing helpers

`merge-translations.py` needs the same brace-matching and Xcode-style emitting
that `sync-catalog.py` already has. Duplicating them would give the two scripts
two different ideas of the catalog's format, which is exactly the drift the
guard test in Phase 1 was written to prevent.

**Files:**
- Create: `scripts/catalog_format.py`
- Modify: `scripts/sync-catalog.py`
- Test: `Tests/ShrinkerProTests/LocalizationGuardTests.swift` (existing tests must pass)

**Interfaces:**
- Consumes: nothing.
- Produces, in `scripts/catalog_format.py`:
  - `REPO_ROOT: Path`
  - `CATALOG_PATH: Path`
  - `find_matching_brace(text: str, open_idx: int) -> int`
  - `load_catalog_text() -> str`
  - `write_catalog_text(text: str, expected_keys: set[str]) -> None` — validates by `json.loads` before writing, raising on mismatch
  Task 3 imports all of these.

- [ ] **Step 1: Create the shared module**

Move `find_matching_brace` verbatim from `scripts/sync-catalog.py` into
`scripts/catalog_format.py`, together with `REPO_ROOT` and `CATALOG_PATH`. Add
`load_catalog_text()` and `write_catalog_text(text, expected_keys)`; the latter
performs the `json.loads` + key-set check that `sync-catalog.py`'s
`verify_spliced` already does, then writes.

Keep the module import-safe: no side effects at import time, no `main()`.

- [ ] **Step 2: Point `sync-catalog.py` at it**

Replace its local `find_matching_brace`, `REPO_ROOT` and `CATALOG_PATH` with
`from catalog_format import ...`. Because the script lives in `scripts/`, add
at the top, before the import:

```python
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
```

Leave its exit-code vocabulary (`ORPHANS_FOUND = 1`, `NO_BUILD_FOUND = 2`,
`KEYS_MISSING = 3`, `INTERNAL_ERROR = 4`) exactly where it is — Task 3 reuses
the same numbers but they belong to each script's own CLI contract.

- [ ] **Step 3: Prove the refactor changed nothing**

Run:
```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "/Users/iomili/Developer/Apps/Shrinker Pro"
xcodebuild build -project ShrinkerPro.xcodeproj -scheme ShrinkerPro -destination 'platform=macOS' >/dev/null 2>&1
python3 scripts/sync-catalog.py --check; echo "exit=$?"
git diff --stat Sources/ShrinkerPro/Resources/Localizable.xcstrings
```
Expected: exit 0, and an **empty** catalog diff. A non-empty diff means the
refactor changed behaviour.

- [ ] **Step 4: Run the suite**

Run the full test command. Expected: 506 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add scripts/catalog_format.py scripts/sync-catalog.py
git commit -m "Give both catalog scripts one idea of the file's format"
```

---

### Task 3: `scripts/merge-translations.py`

**Files:**
- Create: `scripts/merge-translations.py`
- Create: `translations/.gitkeep`
- Test: `Tests/ShrinkerProTests/LocalizationGuardTests.swift` (append)

**Interfaces:**
- Consumes: `catalog_format.find_matching_brace`, `load_catalog_text`,
  `write_catalog_text`, `CATALOG_PATH`, `REPO_ROOT`.
- Produces: `scripts/merge-translations.py` with
  `--check` (report only, never writes) and exit codes
  `0` clean, `1` a language has keys the catalog does not, `3` a language is
  missing catalog keys, `4` internal error.

- [ ] **Step 1: Define the input format**

A language file is `translations/<lang>.json`, a flat object. A non-plural key
maps to a string; a plural key maps to an object of CLDR categories:

```json
{
  "Reveal": "Im Finder zeigen",
  "%lld images shrunk": { "one": "Bild verkleinert", "other": "%lld Bilder verkleinert" }
}
```

- [ ] **Step 2: Write the script**

It must:

- Read every `translations/*.json`, taking the language from the filename.
- **Refuse `en`.** If `translations/en.json` exists, exit 4 — English is the
  source and is never merged.
- For each key, locate that entry's `"localizations" : {` in the catalog text,
  find its matching brace with `find_matching_brace`, and splice a new
  `"<lang>" : { ... }` block in **before** the closing brace, adding the comma
  the existing last member now needs.
- Emit Xcode's style: `"key" : value`, with a short `stringUnit` inline as
  `"stringUnit" : { "state" : "translated", "value" : "…" }`. Match the
  indentation of the `"en"` block it sits beside.
- Be idempotent: a language already present is replaced, not duplicated.
- Never touch the `"en"` block, any `comment`, or any `extractionState`.
- Validate through `write_catalog_text` before writing.
- Print a summary per language: keys merged, keys missing from the file, keys
  present in the file but not in the catalog.

- [ ] **Step 3: Write the failing test**

Append to `LocalizationGuardTests`:

```swift
    /// The merge script is the only thing that writes translations into the
    /// catalog, so it is worth knowing it round-trips without disturbing
    /// English. Driven through a throwaway language so the test needs no real
    /// translations and leaves nothing behind.
    func testMergingALanguageLeavesEnglishUntouched() throws {
        let root = Self.repoRoot()
        let catalog = Self.catalogURL(named: "Localizable")
        let before = try String(contentsOf: catalog, encoding: .utf8)
        let probe = root.appendingPathComponent("translations/zz.json")

        defer {
            try? FileManager.default.removeItem(at: probe)
            try? before.write(to: catalog, atomically: true, encoding: .utf8)
        }

        try #"{ "Reveal" : "ZZ-REVEAL" }"#.write(to: probe, atomically: true, encoding: .utf8)

        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        run.arguments = ["python3", root.appendingPathComponent("scripts/merge-translations.py").path]
        let pipe = Pipe()
        run.standardOutput = pipe
        run.standardError = pipe
        try run.run()
        run.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(run.terminationStatus, 0, output)

        let after = try String(contentsOf: catalog, encoding: .utf8)
        XCTAssertTrue(after.contains("ZZ-REVEAL"), "the translation was not merged")

        // English is untouched: every "en" block in the before-text still
        // appears verbatim in the after-text.
        let data = try Data(contentsOf: catalog)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(json["strings"] as? [String: Any])
        let reveal = try XCTUnwrap(strings["Reveal"] as? [String: Any])
        let locs = try XCTUnwrap(reveal["localizations"] as? [String: Any])
        let en = try XCTUnwrap(locs["en"] as? [String: Any])
        let unit = try XCTUnwrap(en["stringUnit"] as? [String: Any])
        XCTAssertEqual(unit["value"] as? String, "Reveal", "English must survive the merge byte-for-byte")
    }
```

Add a second test in the same class, for completeness per language. It drives
the real script rather than reimplementing the comparison in Swift, for the
same reason `testCatalogMatchesTheBuildsExtractedKeys` does — two definitions
of "complete" would drift apart:

```swift
    /// Every language that exists must carry every key. A language merged
    /// while half-written would otherwise sit in the catalog looking finished
    /// and fall back to English at runtime for whatever it is missing —
    /// invisible to anyone who cannot read it.
    func testEveryLanguagePresentIsComplete() throws {
        let root = Self.repoRoot()
        let dir = root.appendingPathComponent("translations")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        try XCTSkipIf(
            files.filter { $0.hasSuffix(".json") }.isEmpty,
            "no languages have landed yet — Task 6 is the first"
        )

        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        run.arguments = [
            "python3",
            root.appendingPathComponent("scripts/merge-translations.py").path,
            "--check",
        ]
        let pipe = Pipe()
        run.standardOutput = pipe
        run.standardError = pipe
        try run.run()
        run.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        XCTAssertEqual(
            run.terminationStatus, 0,
            "merge-translations.py --check reported an incomplete language:\n\(output)"
        )
    }
```

Note the `XCTSkipIf` is deliberate and temporary: it is true only until Task 6
lands German, after which this test has something to check on every run. It
skips rather than passes, so it never reports success it has not earned.

- [ ] **Step 4: Run it and watch it fail**

Run the `-only-testing:ShrinkerProTests/LocalizationGuardTests` command.
Expected: FAIL, because `scripts/merge-translations.py` does not exist yet
(non-zero termination status, message in `output`).

- [ ] **Step 5: Make it pass, then prove idempotence by hand**

```bash
cd "/Users/iomili/Developer/Apps/Shrinker Pro"
printf '{ "Reveal" : "ZZ" }' > translations/zz.json
python3 scripts/merge-translations.py && python3 scripts/merge-translations.py
git diff --stat Sources/ShrinkerPro/Resources/Localizable.xcstrings   # one entry changed, not two
git checkout -- Sources/ShrinkerPro/Resources/Localizable.xcstrings
rm translations/zz.json
```
Expected: running twice produces the same file as running once, and the
catalog still parses.

- [ ] **Step 6: Run the suite and commit**

Full test command, expect 507 tests, 0 failures.

```bash
git add scripts/merge-translations.py translations/.gitkeep Tests/ShrinkerProTests/LocalizationGuardTests.swift
git commit -m "Let each language arrive as its own file"
```

---

### Task 4: Plural categories, derived at test time

**Files:**
- Test: `Tests/ShrinkerProTests/LocalizationGuardTests.swift` (append)

**Interfaces:**
- Consumes: nothing.
- Produces: `LocalizationGuardTests.pluralCategories(for language: String) -> Set<String>`,
  used by Task 6 and Task 7's verification.

- [ ] **Step 1: Write the probe helper and its test**

The probe writes a `.stringsdict` carrying `one`/`two`/`few`/`many`/`other`
into a temp bundle, loads it, formats every integer 0...220 and records which
categories are reached. `zero` is deliberately absent: Apple honours a `zero`
override in **every** language including English and Japanese, so including it
makes all 36 look alike and tells us nothing.

Append to `LocalizationGuardTests`:

```swift
    /// Which plural categories a language actually reaches for whole numbers,
    /// asked of the platform rather than read from a table.
    ///
    /// Phase 1's spec demoted its own hand-written CLDR table to
    /// "illustrative" after a reviewer disputed a row nobody could settle.
    /// This is the replacement: it cannot go stale, because it is measured.
    static func pluralCategories(for language: String) throws -> Set<String> {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plural-\(language)-\(UUID().uuidString)")
            .appendingPathComponent("\(language).lproj")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

        let dict: [String: Any] = [
            "probe": [
                "NSStringLocalizedFormatKey": "%#@n@",
                "n": [
                    "NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
                    "NSStringFormatValueTypeKey": "lld",
                    "one": "one", "two": "two", "few": "few", "many": "many", "other": "other",
                ],
            ],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: dir.appendingPathComponent("Localizable.stringsdict"))

        let bundle = try XCTUnwrap(Bundle(path: dir.path), "could not load the probe bundle for \(language)")
        let format = bundle.localizedString(forKey: "probe", value: nil, table: "Localizable")
        var seen: Set<String> = []
        for n in 0...220 {
            seen.insert(String(format: format, locale: Locale(identifier: language), n))
        }
        return seen
    }

    /// Guards the probe itself. English must come back as exactly one/other;
    /// Japanese inflects no nouns for number and must come back as other
    /// alone. If the probe ever returns the raw category names for these, it
    /// has stopped selecting and is reporting its own input.
    func testThePluralProbeAgreesWithTwoLanguagesWeCanCheck() throws {
        XCTAssertEqual(try Self.pluralCategories(for: "en"), ["one", "other"])
        XCTAssertEqual(try Self.pluralCategories(for: "ja"), ["other"])
    }

    /// Arabic is the one language here that reaches five categories for whole
    /// numbers. If this ever returns two, the probe is resolving against the
    /// wrong bundle and every per-language assertion built on it is worthless.
    func testThePluralProbeFindsArabicsFiveCategories() throws {
        XCTAssertEqual(try Self.pluralCategories(for: "ar"), ["one", "two", "few", "many", "other"])
    }
```

- [ ] **Step 2: Run it**

Run the `-only-testing:ShrinkerProTests/LocalizationGuardTests` command.
Expected: PASS. A failure here means the probe is not selecting — stop and
report rather than adjusting the expectations, because everything downstream
trusts it.

- [ ] **Step 3: Write the per-language completeness guard**

```swift
    /// Every plural entry must carry the categories its language actually
    /// reaches, plus `other` as the format's universal fallback. Languages
    /// with no translations yet are skipped, so this tightens on its own as
    /// Phase 2 lands each one.
    func testPluralEntriesCarryTheCategoriesTheirLanguageNeeds() throws {
        let data = try Data(contentsOf: Self.catalogURL(named: "Localizable"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(json["strings"] as? [String: Any])

        var checked = 0
        for (key, entry) in strings {
            guard let entry = entry as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any] else { continue }

            for (language, body) in localizations {
                guard let body = body as? [String: Any],
                      let variations = body["variations"] as? [String: Any],
                      let plural = variations["plural"] as? [String: Any] else { continue }

                let required = try Self.pluralCategories(for: language).union(["other"])
                let supplied = Set(plural.keys).subtracting(["zero"])   // zero is always optional
                XCTAssertTrue(
                    required.isSubset(of: supplied),
                    "\(key) in \(language) is missing \(required.subtracting(supplied).sorted())"
                )
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0, "no plural entries examined — this would have passed vacuously")
    }
```

- [ ] **Step 4: Run the suite and commit**

Full test command. Expected: 510 tests, 0 failures.

```bash
git add Tests/ShrinkerProTests/LocalizationGuardTests.swift
git commit -m "Ask the system which plural forms each language needs"
```

---

### Task 5: Placeholders must survive translation

**Files:**
- Test: `Tests/ShrinkerProTests/LocalizationGuardTests.swift` (append)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing later tasks call.

- [ ] **Step 1: Write the guard**

```swift
    /// A dropped or reordered placeholder is a crash or a corrupted sentence,
    /// and it is invisible to anyone who cannot read the language. So the
    /// specifiers are compared rather than trusted: same kinds, same count.
    ///
    /// Compared as a multiset, not a sequence — a language is free to reorder
    /// its arguments, which is exactly why the positional forms exist.
    func testEveryTranslationKeepsItsPlaceholders() throws {
        let data = try Data(contentsOf: Self.catalogURL(named: "Localizable"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(json["strings"] as? [String: Any])

        var compared = 0
        for (key, entry) in strings {
            guard let entry = entry as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any],
                  let english = localizations["en"] as? [String: Any] else { continue }

            let expected = Self.specifiers(in: Self.values(of: english).joined(separator: " "))
            guard !expected.isEmpty else { continue }

            for (language, body) in localizations where language != "en" {
                guard let body = body as? [String: Any] else { continue }
                for value in Self.values(of: body) {
                    let found = Self.specifiers(in: value)
                    // A plural variant may legitimately drop the count (English's
                    // own "Image shrunk" does), so this asserts no specifier is
                    // INVENTED and none is of a kind English did not use.
                    XCTAssertTrue(
                        found.isSubset(of: expected),
                        "\(key) in \(language) uses \(found.subtracting(expected).sorted()), which English does not: \(value)"
                    )
                    compared += 1
                }
            }
        }
        XCTAssertGreaterThan(compared, 0, "no translated values compared — did any language land?")
    }

    /// Every `stringUnit` value in a localization, flat or plural.
    static func values(of localization: [String: Any]) -> [String] {
        if let unit = localization["stringUnit"] as? [String: Any],
           let value = unit["value"] as? String {
            return [value]
        }
        guard let variations = localization["variations"] as? [String: Any],
              let plural = variations["plural"] as? [String: Any] else { return [] }
        return plural.values.compactMap {
            (($0 as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
        }
    }

    /// The format specifiers in a string, normalised so `%1$@` and `%@` count
    /// as the same kind — a translation may reorder arguments freely.
    static func specifiers(in text: String) -> Set<String> {
        let pattern = #"%(?:\d+\$)?(?:lld|ld|d|@|f)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var found: Set<String> = []
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, let r = Range(match.range, in: text) else { return }
            found.insert(String(text[r]).replacingOccurrences(
                of: #"^%\d+\$"#, with: "%", options: .regularExpression))
        }
        return found
    }
```

- [ ] **Step 2: Run it and watch it fail**

Run the `-only-testing:ShrinkerProTests/LocalizationGuardTests` command.
Expected: FAIL on `"no translated values compared"` — no language has landed
yet. **That failure is the point**: it proves the test is not vacuous. Leave it
red and note it in the commit; Task 6 turns it green.

- [ ] **Step 3: Commit the red test**

```bash
git add Tests/ShrinkerProTests/LocalizationGuardTests.swift
git commit -m "Pin the placeholders before any translation can drop one"
```

---

### Task 6: German — the pilot

The first language, alone, all the way through. If anything about the format,
the merge or the guards is wrong, it is wrong here, once, rather than 35 times.

**Files:**
- Create: `translations/de.json`
- Modify: `Sources/ShrinkerPro/Resources/Localizable.xcstrings` (via the script only)

**Interfaces:**
- Consumes: the glossary, `scripts/merge-translations.py`,
  `LocalizationGuardTests.pluralCategories(for:)`.
- Produces: `translations/de.json`, the pattern Task 7 repeats.

- [ ] **Step 1: Read the source**

```bash
cd "/Users/iomili/Developer/Apps/Shrinker Pro"
python3 -c "
import json
d = json.load(open('Sources/ShrinkerPro/Resources/Localizable.xcstrings'))['strings']
for k, v in sorted(d.items()):
    en = v['localizations']['en']
    print(repr(k))
    print('   comment:', v.get('comment', '—'))
    if 'variations' in en:
        for cat, u in en['variations']['plural'].items():
            print(f'   {cat}: {u[\"stringUnit\"][\"value\"]!r}')
    else:
        print('   value:', repr(en['stringUnit']['value']))
"
```

Read `docs/localization-glossary.md` first and translate against it, not
string-by-string. The comments carry the context that decides register and
word choice — a translation produced without reading them will be grammatical
and wrong.

- [ ] **Step 2: Confirm German's plural categories**

German needs `one` and `other`. Do not take that from this sentence — the
probe in `LocalizationGuardTests.pluralCategories(for: "de")` is the authority,
and Task 4's tests prove it works.

- [ ] **Step 3: Author `translations/de.json`**

All 123 keys. Flat keys map to strings, the 12 plural keys to objects of
categories. Rules that matter more than fluency:

- Keep every placeholder. `%@` stays `%@`; `%lld` stays `%lld`. Where English
  uses positional specifiers (`%1$@`, `%2$lld`) because a variant reorders or
  drops an argument, German keeps them positional.
- Leave format names English: JPEG, WebP, AVIF, PNG, HEIC, GIF, SVG.
- Leave "Shrinker Pro" alone.
- `"px"` is an SI-style abbreviation and stays `"px"`.
- Use the platform's own term for standard actions. "Reveal" is *Im Finder
  zeigen*, not a literal rendering.
- German compounds are long. Where a shorter synonym is equally correct,
  prefer it for the session bar and Settings row labels — the layout adapts,
  but it adapts by growing the window.

- [ ] **Step 4: Merge and build**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "/Users/iomili/Developer/Apps/Shrinker Pro"
python3 scripts/merge-translations.py
xcodebuild build -project ShrinkerPro.xcodeproj -scheme ShrinkerPro -destination 'platform=macOS' 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED"
ls "$HOME/Library/Developer/Xcode/DerivedData/ShrinkerPro-chzepkdvmsqoxvalpxbtiduiohwr/Build/Products/Debug/Shrinker Pro.app/Contents/Resources/" | grep lproj
```
Expected: BUILD SUCCEEDED, and **both** `de.lproj` and `en.lproj` present. If
`de.lproj` is absent the catalog did not compile German and nothing downstream
is real.

- [ ] **Step 5: Run the guards**

Full test command. Expected: all pass — including Task 5's placeholder test,
which was red and now has German to compare. Confirm explicitly that it turned
green, and that `sync-catalog.py --check` still exits 0.

- [ ] **Step 6: Report for a human read**

German is the one language the author can check. Produce a side-by-side of
every key: English value, German value. Write it to
`docs/design/notes/2026-09-21-german-review.md` so it can be read without
running anything, and say in the commit that it is awaiting review.

- [ ] **Step 7: Commit**

```bash
git add translations/de.json Sources/ShrinkerPro/Resources/Localizable.xcstrings docs/design/notes/2026-09-21-german-review.md
git commit -m "Translate the catalog into German"
```

---

### Task 7: The remaining 34 languages

Run **once per language**, after German is reviewed and accepted. One language
per agent, so each sees the whole catalog and stays internally consistent.

The 34, in full: ar ca cs da el es fa fi fr he hr hu is it ja ko nb nl nn pl
pt-BR pt-PT ro ru sk sl sv th tr uk vi zh-Hans zh-Hant zh-HK. (German is Task
6; there is no `en` file.)

**Files:**
- Create: `translations/<lang>.json`
- Modify: `Sources/ShrinkerPro/Resources/Localizable.xcstrings` (via the script only)

**Interfaces:**
- Consumes: everything Tasks 1–6 produced; `translations/de.json` as the
  worked example of the format.
- Produces: `translations/<lang>.json`.

- [ ] **Step 1: Read the source, the glossary, and German**

```bash
cd "/Users/iomili/Developer/Apps/Shrinker Pro"
python3 -c "
import json
d = json.load(open('Sources/ShrinkerPro/Resources/Localizable.xcstrings'))['strings']
for k, v in sorted(d.items()):
    en = v['localizations']['en']
    print(repr(k))
    print('   comment:', v.get('comment', '—'))
    if 'variations' in en:
        for cat, u in en['variations']['plural'].items():
            print(f'   {cat}: {u[\"stringUnit\"][\"value\"]!r}')
    else:
        print('   value:', repr(en['stringUnit']['value']))
"
```

Read `docs/localization-glossary.md` and translate against it rather than
string-by-string. Then read `translations/de.json` as the reference for the
file's shape — it is the only example that has been through a human.

- [ ] **Step 2: Get this language's plural categories**

From the probe, never from memory. Arabic reaches five categories for whole
numbers; Polish, Russian and Ukrainian reach `one`/`few`/`many` and never
`other` for integers; Japanese, Korean, Thai, Vietnamese and the three Chinese
variants reach `other` alone. Author the probe's set **plus `other`** in every
case.

- [ ] **Step 3: Author `translations/<lang>.json`**

All 123 keys, under the same rules as Task 6 Step 3. For right-to-left
languages (`ar`, `he`, `fa`) note one extra: the entry `"%@ → %@"` carries a
direction. Its arrow should point the other way (`←`) so the before-and-after
reads correctly in a right-to-left line.

- [ ] **Step 4: Merge, build, and guard**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "/Users/iomili/Developer/Apps/Shrinker Pro"
python3 scripts/merge-translations.py
xcodebuild test -project ShrinkerPro.xcodeproj -scheme ShrinkerPro -destination 'platform=macOS' 2>&1 | grep -E "Executed|TEST SUCCEEDED|TEST FAILED"
python3 scripts/sync-catalog.py --check; echo "exit=$?"
```
Expected: tests pass, `--check` exits 0, and `<lang>.lproj` appears in the
built bundle.

- [ ] **Step 5: Editorial review**

A separate reviewer reads this language's file against the English source and
the glossary, checking: the glossary terms render consistently; standard
actions use the platform's own vocabulary; register is consistent; no string is
so much longer than English that it threatens a control. Findings go back as a
revised `translations/<lang>.json`, re-merged.

- [ ] **Step 6: Commit**

```bash
git add translations/<lang>.json Sources/ShrinkerPro/Resources/Localizable.xcstrings
git commit -m "Translate the catalog into <language>"
```

---

## Done when

- `translations/` holds 35 files; no `en.json`.
- The catalog has 36 localizations on every one of its 123 entries.
- Every plural entry carries its language's probe-derived categories plus
  `other`.
- No translated value invents a placeholder English does not use.
- The full suite passes, and `sync-catalog.py --check` exits 0.
- The built bundle contains 36 `.lproj` directories.
- `shrinker --help` and its stderr remain byte-identical under any `LANG`.
- English is unchanged: `git diff` over the catalog shows no `"en"` value
  altered across the whole phase.

## Not in this phase

Layout work (done — `b5a942b`), RTL screenshots, the README, the website, and
the ~14 English diagnostic payloads recorded in the Phase 1 spec as needing
their own seam decision.
