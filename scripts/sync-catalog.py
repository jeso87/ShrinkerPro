#!/usr/bin/env python3
"""Merge keys extracted from Swift build .stringsdata files into
Sources/ShrinkerPro/Resources/Localizable.xcstrings, and report catalog
entries the build no longer produces.

`SWIFT_EMIT_LOC_STRINGS: YES` plus `xcodebuild build` writes one
.stringsdata file per compiled Swift file, and each one really does list
every localizable string literal in that file. What it does NOT do is
merge those keys into the checked-in .xcstrings catalog -- that merge-back
is an Xcode.app IDE feature. Verified: `xcodebuild build` alone leaves the
catalog untouched, and `xcrun xcstringstool sync <catalog> --stringsdata
<files>` exits 0 and adds nothing. This script does the merge itself, from
the .stringsdata files a build already produced -- and, since the same
comparison also tells us the reverse, reports any catalog entry whose
source string is gone (e.g. the `Text` that used to produce it was
rewritten or removed). Phase 2 translates this catalog into 36 languages,
so a key nothing emits any more is dead weight someone pays to translate
36 times, on every release, forever -- catching it here is cheap; catching
it after translation is not.

Usage:
    python3 scripts/sync-catalog.py [options] [stringsdata-dir-or-file-or-glob]

Options:
    --prune   Remove orphaned catalog entries (keys the build no longer
              produces) instead of only reporting them. Off by default:
              silently deleting a translator's work on a mis-invocation
              is worse than printing a warning, so pruning is opt-in.
    --check   Dry run: never writes the catalog, even if there are keys to
              add or --prune is also given. For callers (tests, CI) that
              want the report and the exit code without risking a mutation
              as a side effect of merely checking. Under --check a key the
              build emits but the catalog lacks is a FAILURE (exit 3), not
              a silent to-do: without --check the script would have written
              it, so with --check the only honest report is that the
              checked-in catalog does not match the source.

With no positional argument, the script looks under
~/Library/Developer/Xcode/DerivedData for the most recently built
ShrinkerPro target's .stringsdata directory:

    <DerivedData>/Build/Intermediates.noindex/ShrinkerPro.build/
    <configuration>/ShrinkerPro.build/Objects-normal/<arch>/*.stringsdata

Configuration and architecture are globbed rather than pinned to
Debug/arm64: a Release build, or an Intel machine, writes the same files
under a different pair of directory names, and a script that resolved
nothing there would exit 2 and take the guard test silently down with it.
"Most recently built" is measured by the newest .stringsdata file, not by
the directory's own mtime -- an incremental rebuild rewrites the files
without touching the directory, so a directory mtime can be arbitrarily
older than its contents.

The argument lets tests (and anyone re-running this without a fresh build)
point the script at a specific directory, glob, or single file instead.

Rules:
- Only keys missing from the catalog are added. An existing entry is never
  modified or reordered -- authored plural variations and hand written
  comments must survive byte-for-byte. Removal (--prune) is the one
  exception, and only for entries the build no longer produces at all.
- Keys that are empty, whitespace-only, or made up entirely of punctuation
  or symbols (e.g. "", ":", "×") are glyphs, not prose, and are skipped --
  on both sides of the comparison, so a still-emitted format-only fragment
  like "%@ → %@" is never mistaken for an orphan just because it has no
  letters.

Exit status:
    0   Ran to completion; the catalog matches the build.
    1   Ran to completion; orphaned catalog entries remain (i.e. --prune
        was not given, or removing them somehow left some behind).
    2   Could not run at all -- no DerivedData / .stringsdata found. This
        is an environment problem, not a catalog problem: it means no
        build has happened yet, so the comparison has nothing to compare
        against.
    3   --check only: the build emits keys the catalog does not have. This
        is the expensive direction and the one worth failing loudest on --
        an orphan costs 36 wasted translations, but a MISSING key ships a
        visible string untranslated in all 36 languages. Takes precedence
        over 1 when both are true; the report lists both either way.
    4   The script itself failed -- unreadable .stringsdata, a catalog
        whose format it does not recognise, a splice that did not come
        back as the JSON it should be. Distinct from 1 and 3 so a caller
        can tell "the tool broke" from "the tool found something".
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import NoReturn

REPO_ROOT = Path(__file__).resolve().parent.parent
CATALOG_PATH = REPO_ROOT / "Sources" / "ShrinkerPro" / "Resources" / "Localizable.xcstrings"

# Configuration and architecture are globbed, not pinned -- see the module
# docstring. The trailing component is the file glob, so one pass finds both
# the directory and the mtimes that rank it.
STRINGSDATA_GLOB = (
    "Build/Intermediates.noindex/ShrinkerPro.build/*/ShrinkerPro.build/"
    "Objects-normal/*/*.stringsdata"
)

NO_BUILD_FOUND = 2
ORPHANS_FOUND = 1
KEYS_MISSING = 3
INTERNAL_ERROR = 4


def die_internal(message: str) -> NoReturn:
    """The script itself could not do its job. Deliberately NOT exit 1:
    that code means "found orphans", and a caller that cannot tell a
    finding from a crash reports the crash as a finding."""
    print(f"sync-catalog.py: internal error: {message}", file=sys.stderr)
    sys.exit(INTERNAL_ERROR)


def default_stringsdata_dir() -> Path:
    """Find the most recently built ShrinkerPro target's .stringsdata directory."""
    dd_root = Path.home() / "Library" / "Developer" / "Xcode" / "DerivedData"
    if not dd_root.is_dir():
        print(f"No DerivedData directory at {dd_root}", file=sys.stderr)
        sys.exit(NO_BUILD_FOUND)

    # Ranked by the newest .stringsdata file each directory holds, not by
    # the directory's own mtime: an incremental rebuild rewrites files in
    # place without touching the directory, so directory mtime can point
    # at a stale build.
    newest: dict[Path, float] = {}
    for name in os.listdir(dd_root):
        if "ShrinkerPro" not in name:
            continue
        for match in (dd_root / name).glob(STRINGSDATA_GLOB):
            directory = match.parent
            mtime = match.stat().st_mtime
            if mtime > newest.get(directory, 0.0):
                newest[directory] = mtime

    if not newest:
        print(
            "No ShrinkerPro DerivedData with .stringsdata files found under "
            f"{dd_root}. Build the app first (xcodebuild build -scheme ShrinkerPro), "
            "or pass a path explicitly.",
            file=sys.stderr,
        )
        sys.exit(NO_BUILD_FOUND)

    return max(newest, key=lambda directory: newest[directory])


def find_stringsdata_files(override: str | None) -> list[str]:
    if override is None:
        directory = default_stringsdata_dir()
        print(f"Using DerivedData: {directory}")
        files = sorted(str(p) for p in directory.glob("*.stringsdata"))
    else:
        path = Path(override)
        if path.is_dir():
            files = sorted(str(p) for p in path.glob("*.stringsdata"))
        elif path.is_file():
            files = [str(path)]
        else:
            files = sorted(glob.glob(override))

    if not files:
        print(f"No .stringsdata files found at/under {override!r}", file=sys.stderr)
        sys.exit(NO_BUILD_FOUND)
    return files


def convert_to_json(path: str) -> dict:
    """.stringsdata files are binary plists that plistlib doesn't reliably
    read; plutil is available everywhere Xcode is and handles them fine."""
    result = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", path],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        die_internal(f"plutil failed to convert {path}:\n{result.stderr.strip()}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        die_internal(f"plutil produced unreadable JSON for {path}: {exc}")


def is_junk(key: str) -> bool:
    """Empty, whitespace-only, or solely punctuation/symbols -- e.g. "",
    ":", "×" from `Text(model.sessionCropMode == .pixels ? "×" : ":")`.
    Those are bare glyphs, not prose, and must never become catalog entries.

    A key with no letters or digits is not automatically junk, though: a
    templated fragment like "%@ → %@" (already a real, hand-authored
    catalog entry) has no alnum characters either, but it is a real piece
    of interpolated prose that still needs to reach a translator -- the
    format specifier is what tells them apart from a stray glyph. This
    matters on both sides of the merge/orphan comparison: it is also what
    keeps a still-emitted fragment like that from being mistaken for an
    orphan merely because it has no letters.
    """
    if key.strip() == "":
        return True
    if any(ch.isalnum() for ch in key):
        return False
    return "%" not in key


def collect_keys(files: list[str]) -> tuple[dict[str, str], set[str]]:
    """Returns (found keys -> comment, junk keys skipped)."""
    found: dict[str, str] = {}
    junk: set[str] = set()

    for path in files:
        data = convert_to_json(path)
        for entry in data.get("tables", {}).get("Localizable", []):
            key = entry.get("key", "")
            comment = (entry.get("comment") or "").strip()

            if is_junk(key):
                junk.add(key)
                continue

            if key not in found or (not found[key] and comment):
                found[key] = comment

    return found, junk


def format_entry(key: str, comment: str) -> str:
    """Renders one new catalog entry the way Xcode's own writer does for a
    plain extracted string: 2-space-per-level indent, `"key" : value`
    spacing, and a compact single-line stringUnit. `extractionState` is
    "extracted_with_value" (not "manual") because nothing has reviewed or
    hand-written these -- they are exactly what the build found, verbatim.
    The comment field is included only when the source actually gave one,
    matching how the hand-authored entries elsewhere in this file do it."""
    key_json = json.dumps(key, ensure_ascii=False)
    lines = [f'    {key_json} : {{']
    if comment:
        lines.append(f'      "comment" : {json.dumps(comment, ensure_ascii=False)},')
    lines.append('      "extractionState" : "extracted_with_value",')
    lines.append('      "localizations" : {')
    lines.append('        "en" : {')
    lines.append(f'          "stringUnit" : {{ "state" : "translated", "value" : {key_json} }}')
    lines.append('        }')
    lines.append('      }')
    lines.append('    }')
    return "\n".join(lines)


def insert_entries(text: str, to_add: list[str], found: dict[str, str]) -> str:
    """Splices newly-found, missing keys into the catalog's raw text,
    leaving every byte of the existing "strings" object untouched."""
    if not to_add:
        return text

    anchor = '\n  },\n  "version"'
    idx = text.rfind(anchor)
    if idx == -1:
        die_internal('could not find the end of the "strings" object -- has the catalog format changed?')

    before = text[:idx]
    if not before.endswith("    }"):
        die_internal("unexpected formatting immediately before the closing brace -- refusing to guess.")

    new_blocks = ",\n".join(format_entry(key, found[key]) for key in to_add)
    return before + ",\n" + new_blocks + text[idx:]


def find_matching_brace(text: str, open_idx: int) -> int:
    """Given the index of an opening '{' in `text`, returns the index of
    its matching '}', respecting JSON string literals -- so a stray '{' or
    '}' inside a quoted value never miscounts the depth."""
    depth = 0
    in_string = False
    escape = False
    i = open_idx
    while i < len(text):
        ch = text[i]
        if in_string:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
        else:
            if ch == '"':
                in_string = True
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    return i
        i += 1
    raise ValueError(f"Unbalanced braces starting at {open_idx}")


def remove_entry(text: str, key: str) -> str:
    """Deletes one top-level entry (key, and its whole `{ ... }` value)
    from the catalog's raw text, leaving every other entry's bytes
    untouched -- including which of them ends up last, and so trailing-
    comma-free."""
    key_json = json.dumps(key, ensure_ascii=False)
    marker = f'    {key_json} : {{'
    start = text.find(marker)
    if start == -1:
        return text  # already gone

    open_brace = start + len(marker) - 1
    try:
        close_brace = find_matching_brace(text, open_brace)
    except ValueError as exc:
        die_internal(f"could not delimit the entry for {key!r}: {exc}")
    end = close_brace + 1

    if text[end:end + 2] == ",\n":
        # Not the last entry: also drop the comma that introduced the next one.
        end += 2
    elif text[:start].endswith(",\n"):
        # Was the last entry: drop the comma that used to precede it instead,
        # so the entry now left last still has none.
        start -= 2

    return text[:start] + text[end:]


def verify_spliced(text: str, expected_keys: set[str]) -> dict:
    """Re-parses the spliced text before anything is written with it.

    Everything above works on the catalog as RAW TEXT, deliberately -- that
    is what keeps existing entries byte-identical, which is the whole point
    of the tool. The cost of that choice is that a splice bug produces a
    corrupt file rather than an exception, and the corruption lands in the
    one file Phase 2 translates 36 times. One parse and one key-set
    comparison is the cheapest possible proof that the text about to be
    written is still the catalog it claims to be."""
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError as exc:
        die_internal(f"the spliced catalog is not valid JSON, so nothing was written: {exc}")

    actual_keys = set(parsed.get("strings", {}))
    if actual_keys != expected_keys:
        unexpected = sorted(actual_keys - expected_keys)
        lost = sorted(expected_keys - actual_keys)
        die_internal(
            "the spliced catalog does not hold the keys it should, so nothing was "
            f"written. Unexpectedly present: {unexpected}. Unexpectedly gone: {lost}."
        )
    return parsed


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("stringsdata", nargs="?", default=None, help="Directory, glob, or single .stringsdata file. Defaults to the most recently built ShrinkerPro DerivedData.")
    parser.add_argument("--prune", action="store_true", help="Remove orphaned catalog entries instead of only reporting them.")
    parser.add_argument("--check", action="store_true", help="Dry run: report and set the exit status, but never write the catalog. Missing keys fail with exit 3, orphans with exit 1.")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    files = find_stringsdata_files(args.stringsdata)

    found, junk = collect_keys(files)

    text = CATALOG_PATH.read_text(encoding="utf-8")
    catalog = json.loads(text)
    existing_keys = set(catalog["strings"].keys())

    already_present = sorted(k for k in found if k in existing_keys)
    to_add = sorted((k for k in found if k not in existing_keys), key=str.lower)

    # Orphans: catalog keys the build no longer produces at all. `found`
    # already excludes junk on the build side (see is_junk's docstring), so
    # nothing further is needed to apply that same exemption here -- a
    # catalog key still being emitted, junk-shaped or not, is in `found`
    # and is therefore never flagged as an orphan.
    orphans = sorted(k for k in existing_keys if k not in found)

    new_text = insert_entries(text, to_add, found)
    if args.prune:
        for key in orphans:
            new_text = remove_entry(new_text, key)

    changed = new_text != text
    if changed:
        expected_keys = existing_keys | set(to_add)
        if args.prune:
            expected_keys -= set(orphans)
        spliced = verify_spliced(new_text, expected_keys)
    else:
        spliced = catalog

    if changed and not args.check:
        CATALOG_PATH.write_text(new_text, encoding="utf-8")

    if args.prune and not args.check:
        # Recomputed from the catalog that was actually written, rather
        # than assumed empty. The documented exit-1 case "removing them
        # somehow left some behind" could never fire while this was a
        # hardcoded [].
        remaining_orphans = sorted(k for k in spliced["strings"] if k not in found)
    else:
        remaining_orphans = orphans

    # Under --check nothing was written, so a key the build emits and the
    # catalog lacks is a finding rather than a to-do. Without --check it
    # was just written, so it is neither.
    missing = to_add if args.check else []

    print(f"Keys found in .stringsdata: {len(found)}")
    print(f"{'Missing from catalog' if args.check else 'Added'}: {len(to_add)}")
    for key in to_add:
        print(f"  + {key!r}")
    print(f"Skipped as junk: {len(junk)}")
    for key in sorted(junk):
        print(f"  x {key!r}")
    print(f"Already present: {len(already_present)}")
    print(f"Orphaned in catalog but not in build: {len(orphans)}")
    for key in orphans:
        status = "pruned" if (args.prune and not args.check) else "not removed (pass --prune)"
        print(f"  ! {key!r} ({status})")
    if args.check and changed:
        print("(--check: catalog left unmodified)")

    if missing:
        print(
            f"FAIL: {len(missing)} key(s) the build emits are not in the catalog. "
            "Run `python3 scripts/sync-catalog.py` to merge them in.",
            file=sys.stderr,
        )
        sys.exit(KEYS_MISSING)
    if remaining_orphans:
        print(
            f"FAIL: {len(remaining_orphans)} catalog entry/entries the build no longer produces. "
            "Run `python3 scripts/sync-catalog.py --prune` to remove them.",
            file=sys.stderr,
        )
        sys.exit(ORPHANS_FOUND)
    sys.exit(0)


if __name__ == "__main__":
    main()
