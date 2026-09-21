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
              as a side effect of merely checking.

With no positional argument, the script looks under
~/Library/Developer/Xcode/DerivedData for the most recently built
ShrinkerPro target's .stringsdata directory:

    <DerivedData>/Build/Intermediates.noindex/ShrinkerPro.build/Debug/
    ShrinkerPro.build/Objects-normal/arm64/*.stringsdata

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
    0   Ran to completion; the catalog has no un-pruned orphans.
    1   Ran to completion; orphaned catalog entries remain (i.e. --prune
        was not given, or removing them somehow left some behind).
    2   Could not run at all -- no DerivedData / .stringsdata found. This
        is an environment problem, not a catalog problem: it means no
        build has happened yet, so the comparison has nothing to compare
        against.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CATALOG_PATH = REPO_ROOT / "Sources" / "ShrinkerPro" / "Resources" / "Localizable.xcstrings"

STRINGSDATA_RELATIVE = Path(
    "Build/Intermediates.noindex/ShrinkerPro.build/Debug/ShrinkerPro.build/Objects-normal/arm64"
)

NO_BUILD_FOUND = 2


def default_stringsdata_dir() -> Path:
    """Find the most recently built ShrinkerPro target's .stringsdata directory."""
    dd_root = Path.home() / "Library" / "Developer" / "Xcode" / "DerivedData"
    if not dd_root.is_dir():
        print(f"No DerivedData directory at {dd_root}", file=sys.stderr)
        sys.exit(NO_BUILD_FOUND)

    candidates = []
    for name in os.listdir(dd_root):
        if "ShrinkerPro" not in name:
            continue
        stringsdata_dir = dd_root / name / STRINGSDATA_RELATIVE
        if stringsdata_dir.is_dir() and any(stringsdata_dir.glob("*.stringsdata")):
            candidates.append(stringsdata_dir)

    if not candidates:
        print(
            "No ShrinkerPro DerivedData with .stringsdata files found under "
            f"{dd_root}. Build the app first (xcodebuild build -scheme ShrinkerPro), "
            "or pass a path explicitly.",
            file=sys.stderr,
        )
        sys.exit(NO_BUILD_FOUND)

    candidates.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return candidates[0]


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
        sys.exit(f"plutil failed to convert {path}:\n{result.stderr.strip()}")
    return json.loads(result.stdout)


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
        sys.exit('Could not find the end of the "strings" object -- has the catalog format changed?')

    before = text[:idx]
    if not before.endswith("    }"):
        sys.exit("Unexpected formatting immediately before the closing brace -- refusing to guess.")

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
    close_brace = find_matching_brace(text, open_brace)
    end = close_brace + 1

    if text[end:end + 2] == ",\n":
        # Not the last entry: also drop the comma that introduced the next one.
        end += 2
    elif text[:start].endswith(",\n"):
        # Was the last entry: drop the comma that used to precede it instead,
        # so the entry now left last still has none.
        start -= 2

    return text[:start] + text[end:]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("stringsdata", nargs="?", default=None, help="Directory, glob, or single .stringsdata file. Defaults to the most recently built ShrinkerPro DerivedData.")
    parser.add_argument("--prune", action="store_true", help="Remove orphaned catalog entries instead of only reporting them.")
    parser.add_argument("--check", action="store_true", help="Dry run: report and set the exit status, but never write the catalog.")
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
    if changed and not args.check:
        CATALOG_PATH.write_text(new_text, encoding="utf-8")

    remaining_orphans = [] if (args.prune and not args.check) else orphans

    print(f"Keys found in .stringsdata: {len(found)}")
    print(f"Added: {len(to_add)}")
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

    sys.exit(0 if not remaining_orphans else 1)


if __name__ == "__main__":
    main()
