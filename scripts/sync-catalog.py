#!/usr/bin/env python3
"""Merge keys extracted from Swift build .stringsdata files into
Sources/ShrinkerPro/Resources/Localizable.xcstrings.

`SWIFT_EMIT_LOC_STRINGS: YES` plus `xcodebuild build` writes one
.stringsdata file per compiled Swift file, and each one really does list
every localizable string literal in that file. What it does NOT do is
merge those keys into the checked-in .xcstrings catalog -- that merge-back
is an Xcode.app IDE feature. Verified: `xcodebuild build` alone leaves the
catalog untouched, and `xcrun xcstringstool sync <catalog> --stringsdata
<files>` exits 0 and adds nothing. This script does the merge itself, from
the .stringsdata files a build already produced.

Usage:
    python3 scripts/sync-catalog.py [stringsdata-dir-or-file-or-glob]

With no argument, the script looks under
~/Library/Developer/Xcode/DerivedData for the most recently built
ShrinkerPro target's .stringsdata directory:

    <DerivedData>/Build/Intermediates.noindex/ShrinkerPro.build/Debug/
    ShrinkerPro.build/Objects-normal/arm64/*.stringsdata

The argument lets tests (and anyone re-running this without a fresh build)
point the script at a specific directory, glob, or single file instead.

Rules:
- Only keys missing from the catalog are added. An existing entry is never
  modified, reordered, or removed -- authored plural variations and hand
  written comments must survive byte-for-byte.
- Keys that are empty, whitespace-only, or made up entirely of punctuation
  or symbols (e.g. "", ":", "×") are glyphs, not prose, and are skipped.
"""
from __future__ import annotations

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


def default_stringsdata_dir() -> Path:
    """Find the most recently built ShrinkerPro target's .stringsdata directory."""
    dd_root = Path.home() / "Library" / "Developer" / "Xcode" / "DerivedData"
    if not dd_root.is_dir():
        sys.exit(f"No DerivedData directory at {dd_root}")

    candidates = []
    for name in os.listdir(dd_root):
        if "ShrinkerPro" not in name:
            continue
        stringsdata_dir = dd_root / name / STRINGSDATA_RELATIVE
        if stringsdata_dir.is_dir() and any(stringsdata_dir.glob("*.stringsdata")):
            candidates.append(stringsdata_dir)

    if not candidates:
        sys.exit(
            "No ShrinkerPro DerivedData with .stringsdata files found under "
            f"{dd_root}. Build the app first, or pass a path explicitly."
        )

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
        sys.exit(f"No .stringsdata files found at/under {override!r}")
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
    catalog entry) or "  —  %@" has no alnum characters either, but it is
    a real piece of interpolated prose that still needs to reach a
    translator -- the format specifier is what tells them apart from a
    stray glyph.
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


def merge(text: str, existing_keys: set[str], found: dict[str, str]) -> tuple[str, list[str]]:
    """Splices newly-found, missing keys into the catalog's raw text,
    leaving every byte of the existing "strings" object untouched."""
    to_add = sorted((k for k in found if k not in existing_keys), key=str.lower)
    if not to_add:
        return text, to_add

    anchor = '\n  },\n  "version"'
    idx = text.rfind(anchor)
    if idx == -1:
        sys.exit('Could not find the end of the "strings" object -- has the catalog format changed?')

    before = text[:idx]
    if not before.endswith("    }"):
        sys.exit("Unexpected formatting immediately before the closing brace -- refusing to guess.")

    new_blocks = ",\n".join(format_entry(key, found[key]) for key in to_add)
    new_text = before + ",\n" + new_blocks + text[idx:]
    return new_text, to_add


def main() -> None:
    override = sys.argv[1] if len(sys.argv) > 1 else None
    files = find_stringsdata_files(override)

    found, junk = collect_keys(files)

    text = CATALOG_PATH.read_text(encoding="utf-8")
    catalog = json.loads(text)
    existing_keys = set(catalog["strings"].keys())
    already_present = sorted(k for k in found if k in existing_keys)

    new_text, added = merge(text, existing_keys, found)
    if added:
        CATALOG_PATH.write_text(new_text, encoding="utf-8")

    print(f"Keys found in .stringsdata: {len(found)}")
    print(f"Added: {len(added)}")
    for key in added:
        print(f"  + {key!r}")
    print(f"Skipped as junk: {len(junk)}")
    for key in sorted(junk):
        print(f"  x {key!r}")
    print(f"Already present: {len(already_present)}")


if __name__ == "__main__":
    main()
