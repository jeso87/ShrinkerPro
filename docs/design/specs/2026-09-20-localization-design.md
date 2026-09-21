# Localization — Design

**Date:** 2026-09-20
**Status:** Approved for planning
**Scope:** The `ShrinkerPro` app target only. The `shrinker` CLI stays English.

## Summary

Shrinker Pro ships in English and nothing else. There is no `.lproj`, no
string catalog, and not one `NSLocalizedString` or `String(localized:)` in
8,187 lines of Swift. This design adds localization into **36 languages** and,
just as importantly, fixes the several places where the current code bakes
English grammar into logic that no amount of translation could rescue.

The app is already most of the way there without knowing it. Almost every
piece of UI text is written as a bare `Text("Drag files here")`, which is a
`LocalizedStringKey` — the moment a catalog exists, roughly 150 strings
resolve through it with no code change at all. The work that remains is
concentrated in a handful of files that build sentences by hand.

## Goals

- 36 languages, matching Sparkle's own set exactly (below), so the app and
  its update dialog are never in different languages.
- **No English grammar encoded in Swift.** Plural forms, list separators and
  sentence fragments move into the catalog, where each language can answer for
  itself.
- The `shrinker` CLI's stdout, stderr and `--json` output stay byte-identical
  English regardless of system locale. This is a release gate, not an
  intention — see "Verification".
- English output of the app is unchanged by Phase 1. Existing tests that pin
  the wording are the proof.

## Non-goals

- An in-app language picker. macOS already provides a per-app language
  override in System Settings › General › Language & Region › Applications,
  which works automatically once `KNOWN_REGIONS` is declared. A second control
  could only disagree with the first.
- Translating the CLI. See "The Core seam".
- Localizing the website, README or release notes. Those are separate surfaces
  with a separate audience, and bundling them here would triple the scope.

## The language set

Sparkle ships its update dialogs in 36 languages. That set is the boundary,
and it is a real constraint rather than an arbitrary round number: localize
past it and a user gets a translated app with an English update dialog;
stop short of it and they get an English app with a translated update dialog.
Either way there is a visible seam, and matching Sparkle removes it.

    ar  ca  cs  da  de  el  en  es  fa  fi  fr  he  hr  hu  is
    it  ja  ko  nb  nl  nn  pl  pt-BR  pt-PT  ro  ru  sk  sl
    sv  th  tr  uk  vi  zh-Hans  zh-Hant  zh-HK

Note the Chinese codes. Sparkle's bundled resources use the older directory
spellings `zh_CN`, `zh_TW` and `zh_HK`; Apple's modern region codes, and what
`KNOWN_REGIONS` must contain, are `zh-Hans`, `zh-Hant` and `zh-HK`. They
denote the same audiences. The mismatch is in the spelling only, and Sparkle
resolves its own resources independently of what this app declares.

Three of the 36 are right-to-left: `ar`, `he`, `fa`. They are included
deliberately, and they carry work the other 33 do not — see "Right-to-left".

## Mechanism: String Catalogs

`Localizable.xcstrings` for the UI, `InfoPlist.xcstrings` for bundle strings.
The toolchain is Swift 6.4, so these are fully supported.

String Catalogs over `.strings` plus `genstrings` for three reasons. Plural
variations are first-class, which matters enormously here (see below). Xcode
extracts keys from `Text(…)` at build time, so the catalog cannot silently
drift from the source. And one JSON file per catalog is reviewable in a diff,
where 36 parallel `.lproj` directories are not.

## Build configuration

In `project.yml`, on the `ShrinkerPro` target only:

    KNOWN_REGIONS: [en, ar, ca, cs, da, de, el, es, fa, fi, fr, he, hr, hu,
                    is, it, ja, ko, nb, nl, nn, pl, pt-BR, pt-PT, ro, ru,
                    sk, sl, sv, th, tr, uk, vi, zh-Hans, zh-Hant, zh-HK]
    DEVELOPMENT_LANGUAGE: en
    SWIFT_EMIT_LOC_STRINGS: YES

The `shrinker` target receives none of these. That omission is what keeps the
CLI English, and it is load-bearing rather than incidental — a future edit
that adds `KNOWN_REGIONS` to the tool target would silently start translating
stderr.

## The Core seam

`Sources/ShrinkerPro/Core` compiles into both targets, which makes it the one
place where "localize the app" and "leave the CLI alone" can collide.

It divides cleanly in two.

**The `displayName` properties** on `ConversionQuality`, `MetadataPolicy`,
`SessionFormat` and `ConversionRules` are consumed only by `Views`. Nothing in
`Sources/shrinker` reads them; the CLI parses and prints raw values instead.
These localize directly, with no seam and no ceremony.

**The error types** are the genuine collision. `AppModel` shows
`errorDescription` in the window's alert, and `main.swift` prints the same
property to stderr at lines 196 and 382. Localizing it in place would
translate the CLI.

The split: `errorDescription` stays exactly as it is — English,
`LocalizedError`, CLI-facing. Each error type gains a separate
`localizedMessage` that only `AppModel` reads. Two properties, two audiences,
neither pretending to serve the other.

This is a deliberate duplication and worth naming as such. The alternative —
having Core call `String(localized:)` and relying on the CLI's `Bundle.main`
having no catalog, so lookups fall back to the key — happens to produce
English today, but only by accident of bundle layout. A property that means
"the English one" should say so.

## Plural forms: the real work

This is where localization stops being mechanical. `OverwritePrompt.swift`
currently reads:

    counted = paths.count == 1 ? "1 original" : "\(paths.count) originals"

That ternary is not a formatting choice. It is English's plural rule —
one form for exactly 1, another for everything else — compiled into Swift.
Under CLDR, the 36 languages divide three ways:

- **Six categories:** Arabic (zero, one, two, few, many, other).
- **Four:** Polish, Russian, Ukrainian, Czech, Slovak, Slovenian.
- **Three:** Croatian, Romanian, Hebrew.
- **Two** (English's shape): the remaining nineteen.
- **One:** Japanese, Korean, Thai, Vietnamese and the three Chinese
  variants inflect no nouns for number at all.

So in ten of the 36 a two-branch ternary cannot produce grammatical text, no
matter what strings are poured into it, and in a further seven it invents a
singular/plural distinction the language does not make.

Each of these becomes a single catalog entry with `%lld` and per-language
variations:

- `OverwriteRequest.title` — "1 original" / "N originals", "1 file" / "N files"
- `OverwriteRequest.message` — both category sentences, singular and plural
- `OverwriteRequest.skipButtonTitle` — "Skip This" / "Skip These"
- The `"…and \(rest) more"` tail
- `"The other file is unaffected"` / `"The other \(n) files are unaffected"`
- `AppModel.notificationTitle` — "Image shrunk" / "N images shrunk"
- `RecentHeaderView`'s file count

The constraint that makes this non-trivial: a plural entry must be **one**
catalog string containing the number. Building `counted` separately and
interpolating it into `"Replace \(counted)?"` defeats the mechanism, because
in many languages the surrounding words inflect with the count too. The title
is therefore one entry per category, not a shared frame plus a variable part.

## Sentence fragments

`SessionBarView.swift` assembles several explanatory sentences by
concatenating fragments across source lines with `+`:

    "Crops the center of each image to this shape, then scales it down to "
    + ... + " fits"

Concatenated sentences cannot be translated. Word order is not universal, and
a translator handed `" from "` in isolation has no sentence to place it in.
Each assembled sentence becomes one catalog entry with its variables as
positional placeholders, so a language that needs to reorder them can.

## List separators

`OverwriteRequest.displayNames` joins filenames with `", "`. CJK languages use
`、` and several others differ.

The obvious fix — `ListFormatter` — is wrong here, and the reason is worth
recording so nobody reaches for it later. `ListFormatter` in English produces
`"a, b, and c"`, inserting a conjunction the current output does not have.
That would change English output, break the assertion at
`OverwriteGuardTests.swift:478`, and read absurdly in the truncated case:
`"…, and 5.png, …and 3 more"`. The list here is deliberately a truncated
enumeration, not a grammatical list.

The separator itself becomes a catalog entry. English keeps `", "` exactly;
CJK gets `、`. English output is untouched.

## Right-to-left

SwiftUI mirrors layout automatically for `ar`, `he` and `fa`, so most of the
window needs nothing. Three specific places do:

- **`ResultRow.summary`** builds `"\(before) → \(after)"`. The arrow encodes
  reading direction and must point the other way in RTL. It becomes a catalog
  entry holding both operands and the arrow, so each language supplies the
  form it needs.
- **`DropZoneView`'s `.tracking(-0.16)`** applies negative letter-spacing to
  the headline. Arabic and Persian are cursive scripts whose glyphs join;
  negative tracking damages that joining. The tracking must apply only to
  Latin-script languages.
- **`"Crop \(w)×\(h)"` and `"Max \($0)px"`** place a unit against a number.
  Unit placement and digit direction are not universal; both become catalog
  entries rather than interpolations with a hardcoded suffix.

`ByteCountFormatter` already localizes on its own and needs no change.

## What stays English

- **"Shrinker Pro"** — a product name, not a phrase. Both `CFBundleName` and
  `CFBundleDisplayName` stay as they are.
- **The entire `shrinker` CLI** — help text, error messages, `--json` keys and
  values. CLI convention (git, curl, ffmpeg all behave this way), and anything
  else breaks scripts that parse the output.
- **`UserDefaults` keys.** `OverwriteGuardTests` already records why: "the
  stored spelling is a compatibility surface — renaming it resets everyone."
- **`Theme.swift`** — 27 string literals, 26 of which are hex colors. Only
  `"Recent"` is text.
- **SF Symbol names, file extensions, format identifiers.**

## Translation workflow

Translations are LLM-produced and spot-checked, which is the honest
description of the quality bar: idiomatic, conventional, and not reviewed by a
native speaker of most of the 36.

A glossary at `docs/localization-glossary.md` pins the recurring terms —
*shrink*, *minified*, *session*, *original*, *Keep Both*, *Skip These*,
*Replace* — with their agreed rendering per language. Without it, "shrink"
arrives three different ways inside one language's catalog, because each
string was translated in isolation. Translation proceeds per language against
the whole catalog and the glossary, never string-by-string.

macOS has strong platform conventions for interface language — a Mac user in
German expects "Sichern", not "Speichern", because that is what the system
uses. The glossary records the platform term where one exists.

## Verification

The existing 28 test files must stay green throughout. Several are directly
load-bearing here, and their strictness is an asset rather than an obstacle:

- `OverwriteRequestCopyTests` (`OverwriteGuardTests.swift:377`) asserts the
  sheet's exact wording — titles, the truncation tail, the unaffected-count
  sentence, the Skip button. This is the proof that Phase 1's plural
  restructuring preserves English exactly.
- `AppModelTests:339` and `:352` pin both notification titles.
- `RecentHeaderFormatterTests:38` pins `" saved"`.

Restructuring under tests that pin the output is the safe direction of travel:
if the catalog's English plural variations are right, these pass unmodified.
If any needs its expectation changed, that is a signal to look hard rather
than a formality.

A new `LocalizationGuardTests`, in the style of the existing
`ArchitectureGuardTests`, adds:

- Every key in `Localizable.xcstrings` has a translation in all 36 languages.
- No entry is left in `needs_review` state.
- Plural entries carry the categories their language actually requires —
  six for Arabic, four for Polish, Russian, Ukrainian, Czech, Slovak and
  Slovenian, three for Croatian, Romanian and Hebrew. A catalog with only
  `one`/`other` for Arabic is the failure this catches.
- **The CLI stays English.** `errorDescription` and `helpText` return
  identical strings under a forced non-English locale.

Beyond the suite: a pseudolocalization pass (accented, ~40% lengthened
strings) to catch truncation before a real translation reveals it, and
screenshots in German (longest compounds), Japanese (densest glyphs) and
Arabic (RTL) to check the session bar and Settings actually hold their layout.

## Phasing

**Phase 1 — Infrastructure and restructuring.** The catalogs, the build
settings, the Core seam, the plural and fragment restructuring, the separator,
the RTL fixes. English only; no translations. Every existing test green, with
the copy tests unmodified. This phase carries all the code risk and is
provably behavior-preserving.

**Phase 2 — Translation.** The glossary, then the 36 languages, then
`LocalizationGuardTests`. Additive; no behavior change to English.

**Phase 3 — Proving it.** Pseudolocalization, RTL and long-language
screenshots, then README, website and appcast per the project's rule that a
release updates the site in the same pass.

Phase 1 is a prerequisite for 2 and 3. Phases 2 and 3 are independent of each
other and could ship separately.

## Costs worth stating plainly

**This is permanent overhead.** Every future release that adds or changes UI
text means 36 re-translations and a glossary check. A one-word label change is
no longer a one-word change. That cost is the actual price of the feature, and
it is paid on every release from here, not once.

**Phase 1 rewrites the text of the data-loss guard rail.** `OverwritePrompt`
is the sheet standing between a user and destroying their own originals. The
copy tests cover it thoroughly, which is exactly why the restructuring is
tractable — but it deserves the most careful review in the whole change.

**36 languages ship without native review.** Somewhere in the catalog there is
a clumsy or wrong phrase neither of us can read. The glossary, the plural
guard test and the screenshot pass narrow it; they do not eliminate it. The
mitigation is that an MIT app on a public repo can take corrections as PRs,
and the catalog format makes such a PR a one-line diff.
