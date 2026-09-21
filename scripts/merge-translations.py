#!/usr/bin/env python3
"""Splice per-language translation files into
Sources/ShrinkerPro/Resources/Localizable.xcstrings.

Phase 2 hands each language its own small, reviewable file rather than one
enormous shared JSON: `translations/<lang>.json`, a flat object where a
non-plural key maps to a string and a plural key maps to an object of CLDR
categories, e.g.

    {
      "Reveal": "Im Finder zeigen",
      "%lld images shrunk": { "one": "Bild verkleinert", "other": "%lld Bilder verkleinert" }
    }

This is the only script that ever writes a translation INTO the catalog, so
a bug here corrupts a file every future release depends on. It works the
same way `sync-catalog.py` does and for the same reason (see
`catalog_format`'s module docstring): the catalog is spliced as raw text,
never re-serialised, so Xcode's own single-line `stringUnit` style survives
untouched and the English source is never at risk of being reformatted.

For each key found in both the language file and the catalog, this script
locates that entry's `"localizations" : {` object, and splices in a
`"<lang>" : { ... }` sibling of `"en"` — replacing any block already there
for that language, so re-running for a language that is already merged is a
no-op rather than a duplicate. Nothing about the `"en"` block, any
`comment`, or any `extractionState` is ever touched.

Usage:
    python3 scripts/merge-translations.py [--check]

Options:
    --check   Report only; never writes the catalog. A language missing
              catalog keys is only a FAILURE under --check (exit 3) — the
              expensive direction, since it means a language sits in the
              catalog looking present and silently falls back to English
              for whatever it lacks. Without --check the same thing is
              simply a translation still in progress, and is not an error:
              the script merges as much of a language as the file
              currently has.

Rules:
- English is never merged. If any discovered `translations/*.json` file's
  stem is "en" under a case-insensitive comparison, the script refuses to
  run (exit 4): English is the catalog's source language, not a
  translation of it. The check is against the files this run actually
  discovered, not a literal `translations/en.json` path lookup -- a
  filesystem-existence check would only catch that exact casing, and on a
  case-insensitive volume happens to catch "EN.json" too by accident of
  the filesystem rather than by anything the script enforces. Checking
  the discovered files' stems (case-folded) catches "EN.json",
  "En.json", etc. on every filesystem, case-sensitive or not.
- A translation's shape must match what the catalog already says that key
  is: a plain string for a flat entry, an object of CLDR categories for a
  plural one. A mismatch (a string where the catalog's English is plural,
  or an object where it is flat) is a caller error, rejected before
  anything is spliced (exit 4).
- A key in a language file that the catalog does not have is a genuine
  problem — a stale key, a typo, a rename the translation missed — and is
  always reported and always fails the run (exit 1), with or without
  --check.
- A key the catalog has that a language's file lacks is reported every
  run, but only fails the run under --check.
- Every actual splice is verified before anything is written: for each
  (key, lang) spliced, the resulting catalog's "en" localization for that
  key must be byte-for-byte identical to what it was before merging, and
  the new language's localization must have exactly the shape (flat
  `stringUnit`, or `variations.plural` with exactly the categories
  supplied) the script intended to write. `write_catalog_text`'s own
  check only proves the top-level key set survived and the result parses
  -- it says nothing about what happened *inside* an entry, and a splice
  bug that corrupted "en" or wrote the wrong shape while leaving the key
  set alone would otherwise pass silently. This verification is what
  catches that class of bug instead of relying on the splice code having
  been built correctly. On failure: internal error, exit 4, nothing
  written.

Exit status:
    0   Ran to completion; every language file merged cleanly and
        completely.
    1   A language file has one or more keys the catalog does not.
    3   --check only: a language file is missing one or more catalog keys.
        Takes precedence over 1 when both are true, for the same reason
        `sync-catalog.py` gives its own analogous precedence: a missing
        translation ships a visible, silently-English string, which is
        worse than a stray translated key nothing merges.
    4   The script itself failed -- a discovered file is "en" under
        case-insensitive comparison, a language file could not be read or
        is not valid JSON or not a flat object, a translation's shape
        does not match what the catalog says that key is, a key's
        catalog entry has no "localizations" object, the post-splice
        verification found English disturbed or a language block with
        the wrong shape, or the splice did not come back as the JSON it
        should be. One code for every way the script itself -- as
        opposed to a language file's content -- failed to do its job.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import NoReturn

sys.path.insert(0, str(Path(__file__).resolve().parent))
from catalog_format import (
    CATALOG_PATH,
    REPO_ROOT,
    find_matching_brace,
    load_catalog_text,
    write_catalog_text,
)

TRANSLATIONS_DIR = REPO_ROOT / "translations"

CLEAN = 0
EXTRA_KEYS = 1
MISSING_KEYS = 3
INTERNAL_ERROR = 4


def die_internal(message: str) -> NoReturn:
    """The script itself could not do its job. Deliberately NOT exit 1 or
    3: those codes describe a finding about a language file, and a caller
    that cannot tell a finding from a crash would report the crash as a
    finding."""
    print(f"merge-translations.py: internal error: {message}", file=sys.stderr)
    sys.exit(INTERNAL_ERROR)


def discover_language_files() -> list[Path]:
    if not TRANSLATIONS_DIR.is_dir():
        return []
    return sorted(TRANSLATIONS_DIR.glob("*.json"))


def load_translation(path: Path) -> dict:
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        # Broader than the JSON-decode catch below on purpose: a dangling
        # symlink, a permissions problem, or anything else that stops the
        # file from being read at all raises some subclass of OSError
        # (FileNotFoundError among them), not a JSONDecodeError -- and it
        # deserves the same controlled exit 4 rather than an unhandled
        # traceback.
        die_internal(f"could not read {path}: {exc}")
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        die_internal(f"{path} is not valid JSON: {exc}")
    if not isinstance(data, dict):
        die_internal(f"{path} must be a flat JSON object, got {type(data).__name__}")
    return data


def catalog_localization_is_plural(catalog: dict, key: str) -> bool:
    """Whether `key`'s English localization in the (already-parsed) catalog
    is a plural entry (`variations.plural`) or a flat one (`stringUnit`) --
    the shape every language's own translation for that key must match."""
    en = catalog.get("strings", {}).get(key, {}).get("localizations", {}).get("en", {})
    if isinstance(en, dict) and "variations" in en:
        return True
    if isinstance(en, dict) and "stringUnit" in en:
        return False
    die_internal(
        f'{key!r}\'s English localization has neither "stringUnit" nor '
        f'"variations" -- unrecognised catalog shape'
    )


def verify_merge(
    original_catalog: dict, merged_text: str, merges: list[tuple[str, str, object]]
) -> None:
    """The last line of defence before anything is written: `merges` is
    every (key, lang, value) this run actually spliced. For each one,
    confirms the resulting catalog's "en" localization for that key is
    untouched, and the new language's localization has exactly the shape
    intended. `write_catalog_text`'s own check proves only that the
    top-level key set survived and the result parses -- nothing about
    what happened inside an entry -- so this is what actually proves the
    splice did what it meant to, rather than trusting that it was built
    correctly."""
    try:
        merged = json.loads(merged_text)
    except json.JSONDecodeError as exc:
        die_internal(f"the merged catalog is not valid JSON: {exc}")

    for key, lang, value in merges:
        original_entry = original_catalog.get("strings", {}).get(key)
        merged_entry = merged.get("strings", {}).get(key)
        if original_entry is None or merged_entry is None:
            die_internal(f"{key!r} is missing from the catalog after merging {lang!r}")

        original_en = original_entry.get("localizations", {}).get("en")
        merged_en = merged_entry.get("localizations", {}).get("en")
        if merged_en != original_en:
            die_internal(
                f'merging {lang!r} into {key!r} disturbed English -- "en" '
                f"changed from {original_en!r} to {merged_en!r}"
            )

        merged_lang = merged_entry.get("localizations", {}).get(lang)
        if not isinstance(merged_lang, dict):
            die_internal(f"{lang!r} did not land in {key!r} after merging")

        if isinstance(value, str):
            expected = {"stringUnit": {"state": "translated", "value": value}}
            if merged_lang != expected:
                die_internal(
                    f"{key!r}/{lang!r} did not splice as the flat entry it "
                    f"should be: got {merged_lang!r}"
                )
        else:
            expected_categories = {
                category: {"stringUnit": {"state": "translated", "value": category_value}}
                for category, category_value in value.items()
            }
            actual_categories = merged_lang.get("variations", {}).get("plural")
            if actual_categories != expected_categories:
                die_internal(
                    f"{key!r}/{lang!r} did not splice as the plural entry it "
                    f"should be: got {merged_lang!r}"
                )


def line_indent(text: str, idx: int) -> str:
    """Returns the leading whitespace of the line containing `idx`."""
    line_start = text.rfind("\n", 0, idx) + 1
    end = line_start
    while end < len(text) and text[end] == " ":
        end += 1
    return text[line_start:end]


def find_entry_span(text: str, key: str) -> tuple[int, int] | None:
    """Returns (open_brace_idx, close_brace_idx) delimiting the top-level
    catalog entry object for `key`, or None if the key is not present.
    Mirrors `sync-catalog.py`'s `remove_entry` marker so both scripts agree
    on how a top-level entry is found."""
    key_json = json.dumps(key, ensure_ascii=False)
    marker = f'    {key_json} : {{'
    start = text.find(marker)
    if start == -1:
        return None
    open_brace = start + len(marker) - 1
    close_brace = find_matching_brace(text, open_brace)
    return open_brace, close_brace


def render_language_block(child_pad: str, lang: str, value) -> list[str]:
    """Renders a `"<lang>" : { ... }` block as a sibling of `"en"`, at the
    same indentation, in Xcode's own style. `value` is either a string (a
    flat entry, rendered as an inline `stringUnit`) or a dict of CLDR
    plural category -> string (rendered as `variations.plural`, matching
    the shape English's own plural entries use)."""
    lang_json = json.dumps(lang, ensure_ascii=False)
    lines = [f'{child_pad}{lang_json} : {{']

    if isinstance(value, str):
        lines.append(
            f'{child_pad}  "stringUnit" : {{ "state" : "translated", '
            f'"value" : {json.dumps(value, ensure_ascii=False)} }}'
        )
    elif isinstance(value, dict):
        if not value:
            die_internal(f"{lang!r}: a plural value has no CLDR categories")
        lines.append(f'{child_pad}  "variations" : {{')
        lines.append(f'{child_pad}    "plural" : {{')
        items = list(value.items())
        for i, (category, category_value) in enumerate(items):
            if not isinstance(category_value, str):
                die_internal(
                    f"{lang!r}: plural category {category!r} must be a string, "
                    f"got {type(category_value).__name__}"
                )
            comma = "," if i < len(items) - 1 else ""
            category_json = json.dumps(category, ensure_ascii=False)
            lines.append(f'{child_pad}      {category_json} : {{')
            lines.append(
                f'{child_pad}        "stringUnit" : {{ "state" : "translated", '
                f'"value" : {json.dumps(category_value, ensure_ascii=False)} }}'
            )
            lines.append(f'{child_pad}      }}{comma}')
        lines.append(f'{child_pad}    }}')
        lines.append(f'{child_pad}  }}')
    else:
        die_internal(
            f"{lang!r}: a translation value must be a string or an object of "
            f"CLDR categories, got {type(value).__name__}"
        )

    lines.append(f'{child_pad}}}')
    return lines


def remove_child_block(
    text: str, child_pad: str, lang: str, loc_open: int, loc_close: int
) -> tuple[str, int]:
    """Removes an existing `"<lang>" : { ... }` block from inside the
    `"localizations"` object spanning [loc_open, loc_close], including the
    comma its removal now leaves dangling -- so a language already present
    is replaced rather than duplicated. Returns the new text and the
    (shifted) index of the localizations object's own closing brace.
    Mirrors `sync-catalog.py`'s `remove_entry`, scoped to one language's
    block instead of a whole top-level entry."""
    lang_json = json.dumps(lang, ensure_ascii=False)
    marker = f'{child_pad}{lang_json} : {{'
    start = text.find(marker, loc_open, loc_close)
    if start == -1:
        return text, loc_close

    open_brace = start + len(marker) - 1
    close_brace = find_matching_brace(text, open_brace)
    end = close_brace + 1

    if text[end:end + 2] == ",\n":
        # Not the last child: also drop the comma that introduced the next one.
        end += 2
    elif text[:start].endswith(",\n"):
        # Was the last child: drop the comma that used to precede it instead,
        # so the child now left last still has none.
        start -= 2

    new_text = text[:start] + text[end:]
    delta = len(text) - len(new_text)
    return new_text, loc_close - delta


def splice_translation(text: str, key: str, lang: str, value) -> str:
    """Splices a `"<lang>" : { ... }` sibling of `"en"` into `key`'s
    `"localizations"` object, replacing any block already there for
    `lang`. Never touches `"en"`, `comment`, or `extractionState`."""
    span = find_entry_span(text, key)
    if span is None:
        die_internal(f"key {key!r} vanished from the catalog mid-merge")
    open_brace, close_brace = span

    loc_marker = '"localizations" : {'
    loc_start = text.find(loc_marker, open_brace, close_brace)
    if loc_start == -1:
        die_internal(f'entry {key!r} has no "localizations" object')
    loc_open = loc_start + len(loc_marker) - 1
    loc_close = find_matching_brace(text, loc_open)

    # The "en" block sits two spaces deeper than "localizations" itself --
    # derived from the live text rather than hardcoded, so a reindent of
    # the surrounding entry can never silently misalign a new block.
    child_pad = line_indent(text, loc_start) + "  "

    text, loc_close = remove_child_block(text, child_pad, lang, loc_open, loc_close)

    block_lines = render_language_block(child_pad, lang, value)

    # Insert right before the newline that leads into the closing brace's
    # own line -- i.e. right after whatever is now the last existing
    # child (always at least "en"), which is exactly where a trailing
    # comma plus the new block belongs.
    nl_idx = text.rfind("\n", 0, loc_close)
    if nl_idx == -1:
        die_internal(f"could not find the localizations object's closing line for {key!r}")

    new_text = text[:nl_idx] + ",\n" + "\n".join(block_lines) + text[nl_idx:]
    return new_text


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help=(
            "Report only; never writes the catalog. A language missing "
            "catalog keys only fails the run under --check (exit 3)."
        ),
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    language_files = discover_language_files()

    # Checked against the files this run actually discovered, not a
    # literal `translations/en.json` existence check -- see the module
    # docstring's "Rules" section for why that distinction matters on a
    # case-sensitive filesystem.
    english_impostors = [p for p in language_files if p.stem.casefold() == "en"]
    if english_impostors:
        names = ", ".join(p.name for p in english_impostors)
        print(
            f"merge-translations.py: {names} looks like English (stem "
            '"en", case-insensitive) -- English is the catalog\'s source '
            "language and is never merged as a translation. Delete it and "
            'let the catalog\'s own "en" blocks stay the source of truth.',
            file=sys.stderr,
        )
        sys.exit(INTERNAL_ERROR)

    text = load_catalog_text()
    try:
        catalog = json.loads(text)
    except json.JSONDecodeError as exc:
        die_internal(f"the checked-in catalog is not valid JSON: {exc}")
    catalog_keys = set(catalog.get("strings", {}))
    expected_keys = set(catalog_keys)  # merging never adds/removes top-level keys

    if not language_files:
        print("No translation files found under translations/.")
        sys.exit(CLEAN)

    any_extra = False
    any_missing = False
    all_merges: list[tuple[str, str, object]] = []

    for path in language_files:
        lang = path.stem
        data = load_translation(path)
        file_keys = set(data)

        extra = sorted(file_keys - catalog_keys)
        missing = sorted(catalog_keys - file_keys)
        to_merge = sorted(file_keys & catalog_keys)

        for key in to_merge:
            value = data[key]
            expects_plural = catalog_localization_is_plural(catalog, key)
            if expects_plural and not isinstance(value, dict):
                die_internal(
                    f"{lang}.json: {key!r} is a plural entry in the catalog "
                    "(CLDR categories like 'one'/'other') but the "
                    "translation is a plain string"
                )
            if not expects_plural and isinstance(value, dict):
                die_internal(
                    f"{lang}.json: {key!r} is a flat entry in the catalog "
                    "but the translation is an object of CLDR categories"
                )

            text = splice_translation(text, key, lang, value)
            all_merges.append((key, lang, value))

        print(
            f"{lang}: merged {len(to_merge)} key(s), "
            f"missing {len(missing)} from the file, "
            f"{len(extra)} extra in the file"
        )
        for key in missing:
            print(f"  - missing from {lang}.json: {key!r}")
        for key in extra:
            print(f"  + {lang}.json has a key the catalog does not: {key!r}")

        if extra:
            any_extra = True
        if missing:
            any_missing = True

    if all_merges:
        verify_merge(catalog, text, all_merges)

    if not args.check and text != load_catalog_text():
        try:
            write_catalog_text(text, expected_keys)
        except ValueError as exc:
            die_internal(str(exc))
    elif args.check:
        print("(--check: catalog left unmodified)")

    if args.check and any_missing:
        sys.exit(MISSING_KEYS)
    if any_extra:
        sys.exit(EXTRA_KEYS)
    sys.exit(CLEAN)


if __name__ == "__main__":
    main()
