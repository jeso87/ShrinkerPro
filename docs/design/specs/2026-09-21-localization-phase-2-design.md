# Localization Phase 2 — Design

**Date:** 2026-09-21
**Status:** Approved for planning
**Follows:** `docs/design/specs/2026-09-20-localization-design.md` (Phase 1, merged)
**Scope:** The 36 translations, the glossary, and the per-language verification.

## Summary

Phase 1 left the app English-only by design: 123 catalog entries, every plural
rule moved out of Swift, a CLI that stays English, and tooling that fails when
a key goes missing. Phase 2 fills the catalog in — 35 more languages, 4,305
string units, of which 420 are plural category sets.

Nothing in the app's behaviour changes. Every line of this phase is data and
the machinery to check it.

## Goals

- 35 languages beside English, matching Sparkle's set exactly.
- **No hand-written table of plural categories anywhere.** Each language's
  required categories are derived from the platform at test time.
- Each language independently authored, reviewable, revertible and
  re-runnable, without touching any other language or the English source.
- Every placeholder preserved exactly. A dropped `%@` is a crash or a
  corrupted sentence, and it is invisible to anyone who cannot read the
  language.

## Non-goals

- Changing any English string. Phase 1's pinned tests still govern.
- Translating the `shrinker` CLI, the README, the website or release notes.
- Fixing the two controls that truncate. That is Phase 3, though this phase
  will make them concrete (below).

## What the platform actually says about plurals

Phase 1's spec demoted its own hand-written CLDR table to "illustrative" after
a reviewer disputed one row and neither party could settle it offline. This
phase settles it by asking the system.

A probe writes a `.stringsdict` carrying `one`/`two`/`few`/`many`/`other`,
loads it as a bundle per language, formats every integer from 0 to 220, and
records which distinct categories are actually reached:

| Categories | Languages |
|---|---|
| 5 | `ar` (few, many, one, other, two) |
| 4 | `sl` (few, one, other, two) |
| 3 | `cs` `hr` `ro` `sk` (few, one, other) · `he` (one, other, two) · `pl` `ru` `uk` (few, many, one) |
| 2 | `ca` `da` `de` `el` `en` `es` `fa` `fi` `fr` `hu` `is` `it` `nb` `nl` `nn` `pt-BR` `pt-PT` `sv` `tr` |
| 1 | `ja` `ko` `th` `vi` `zh-Hans` `zh-Hant` `zh-HK` (other) |

Two results are worth stating because they contradict what a reasonable person
would assume:

**Hebrew is three, not four.** This was the disputed row. The system says
`one`/`two`/`other` for integers.

**Polish, Russian and Ukrainian never reach `other`.** Their `other` category
applies to fractional values, and a file count is never fractional. Their
integer categories are `one`/`few`/`many`.

**On `zero`.** The probe omits it deliberately. Apple's stringsdict supports a
`zero` key that overrides for a literal 0 in *every* language, including
English and Japanese — an Apple extension, not a CLDR category. Including it
in the probe makes all 36 languages appear to have it and tells us nothing. It
is therefore treated as always-optional: permitted anywhere, required nowhere.
Arabic is the one language where it is also CLDR-correct.

**Authoring rule.** Every plural entry carries the probe's observed set for its
language, **plus `other` in all cases**, because `other` is the format's
universal fallback and costs one string. So Polish carries `one`/`few`/`many`/
`other` even though integers never reach the last.

## Artifacts and data flow

`Localizable.xcstrings` is one JSON file holding all 123 entries. Thirty-five
agents editing it in sequence would be slow, conflict-prone, and would put at
risk the byte-preservation that protects Phase 1's hand-authored English.

So no translator ever edits the catalog. Each language is authored as its own
file:

    translations/de.json
    {
      "%lld images shrunk": { "one": "Bild verkleinert", "other": "%lld Bilder verkleinert" },
      "Reveal": "Zeigen",
      ...
    }

A flat string maps to a string; a plural entry maps to an object keyed by
category. `scripts/merge-translations.py` folds these into the catalog — a
sibling to `sync-catalog.py`, reusing its splice-rather-than-reparse approach
so existing entries survive byte-for-byte.

The benefits are the point of the design: a bad language is one file to delete
rather than catalog surgery; a language can be re-run without disturbing the
other 34; and the diff for "what did German change" is one file, not a
scattered 123-entry patch.

## The glossary

`docs/localization-glossary.md`, written before any translation and treated as
an input to every one of them.

It holds two things. First, the English terms that must render consistently
within a language: *shrink*, *minified*, *session*, *original*, *crop*, *Keep
Both*, *Skip These*, *Replace*, *Reveal*. Without this, "shrink" arrives three
different ways inside one language's catalog, because each string was
translated in isolation and nothing connected them.

Second, the platform's own term where one exists. A German Mac user expects
"Sichern", not "Speichern", because that is what the system menu says. An app
that invents its own vocabulary for a standard action reads as foreign even
when every word is correct.

## Verification

Two gates per language, both required.

**Structural** — guard tests, extending `LocalizationGuardTests`:

- Every one of the 123 keys present in every language.
- Every plural entry carries exactly the categories the probe derives for that
  language, plus `other`. The probe runs in-process at test time; there is no
  table to fall out of date.
- Placeholders preserved: the same `%@` / `%lld` specifiers, in the same
  count, and where English uses positional specifiers (`%1$@`) the translation
  does too.
- No entry left identical to its English source in a language where that would
  be implausible — a heuristic, reported rather than failed, since some strings
  legitimately do not change.

**Editorial** — a review agent per language, reading that language's file
against the glossary and the English source, checking term consistency,
platform conventions, register, and flagging any string long enough to worsen
the two controls already known to clip.

## Order

German first, alone, all the way through: author, merge, build, confirm
`de.lproj` appears, run the guard tests, and read it.

German is the right pilot for two reasons. Its compounds are the longest of
the 36, so it stresses the layout hardest — and Phase 1's pseudolocalization
already identified two controls that clip, the session bar's max-size
placeholder and the Settings metadata popup. German will make those concrete
rather than hypothetical, which is the most useful thing a pilot can do here.
Second, it is a language the author can actually read, so the editorial gate
has a human check exactly once before it is trusted 34 more times.

Only when German is proven do the remaining 34 run, one language per agent so
each sees the whole catalog and stays internally consistent, batched for
throughput.

## Unchanged

"Shrinker Pro", the format names (JPEG, WebP, AVIF, PNG, HEIC, GIF, SVG), the
entire `shrinker` CLI, `UserDefaults` keys, SF Symbol names.

## Costs worth stating plainly

**This is the expensive phase.** 4,305 string units plus an editorial pass per
language. Phase 1 built the machinery; this is where it is paid for.

**Quality is unverifiable for most of the 36.** The structural gate catches
everything that would crash, corrupt or silently drop text. It cannot catch a
translation that is merely wrong, or right but foreign-sounding. The editorial
gate narrows that; it does not close it. The honest description is: idiomatic,
conventional, and reviewed by a machine — with German alone reviewed by a
person.

**The truncation findings will get worse before Phase 3 fixes them.** German
is the language most likely to clip, and this phase will ship it. That is a
deliberate ordering choice: better to see the real damage in one language now
than to discover it in 36 later.
