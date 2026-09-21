#!/usr/bin/env python3
"""Shared text-splicing machinery for the two scripts that touch
Sources/ShrinkerPro/Resources/Localizable.xcstrings:
scripts/sync-catalog.py (merges keys the build extracted) and
scripts/merge-translations.py (splices in translations). Both must agree
on the catalog's format, so that format lives here once rather than as
two copies that drift.

The catalog is written in Xcode's own JSON style -- `"key" : value` with a
space before the colon, short `stringUnit` objects inline on one line --
and Xcode reformats the whole file back to that style the next time
anyone opens it in the IDE. A `json.dump` round-trip would not reproduce
it, so every write here works on the catalog as raw text and splices into
it, never re-serialising the document. `find_matching_brace` is what
makes that safe: it walks the text respecting JSON string literals, so a
stray '{' or '}' inside a quoted value never miscounts depth.

Import-safe: nothing here runs at import time beyond the two path
constants, and there is no `main()` or argument parsing -- both belong to
the scripts that use this module, not to the module itself.
"""
from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CATALOG_PATH = REPO_ROOT / "Sources" / "ShrinkerPro" / "Resources" / "Localizable.xcstrings"


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


def load_catalog_text() -> str:
    """Reads the catalog's raw text, for splicing -- never for
    re-serialising (see the module docstring)."""
    return CATALOG_PATH.read_text(encoding="utf-8")


def write_catalog_text(text: str, expected_keys: set[str]) -> None:
    """Validates spliced catalog text before it is written, then writes it
    atomically.

    Everything upstream of this call works on the catalog as raw text,
    deliberately -- that is what keeps existing entries byte-identical,
    which is the whole point of splicing instead of re-serialising. The
    cost of that choice is that a splice bug produces a corrupt file
    rather than an exception, and the corruption would land in the one
    file every language draws from. One parse and one key-set comparison
    is the cheapest possible proof that the text about to be written is
    still the catalog it claims to be.

    Raises ValueError if the text does not parse as JSON, or if its
    top-level "strings" keys do not exactly match `expected_keys`. Writes
    only if both checks pass -- and the write itself goes to a sibling
    temp file first, then `os.replace()`s it into position, so a process
    killed mid-write or a full disk leaves the checked-in catalog either
    fully old or fully new, never truncated. `CATALOG_PATH.write_text()`
    would truncate in place, which is fine for a bug caught by the
    key-set check above but not for a crash or a full disk that happens
    after that check has already passed.
    """
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError as exc:
        raise ValueError(f"the spliced catalog is not valid JSON: {exc}") from exc

    actual_keys = set(parsed.get("strings", {}))
    if actual_keys != expected_keys:
        unexpected = sorted(actual_keys - expected_keys)
        lost = sorted(expected_keys - actual_keys)
        raise ValueError(
            "the spliced catalog does not hold the keys it should. "
            f"Unexpectedly present: {unexpected}. Unexpectedly gone: {lost}."
        )

    fd, tmp_name = tempfile.mkstemp(
        dir=CATALOG_PATH.parent, prefix=CATALOG_PATH.name + ".", suffix=".tmp"
    )
    tmp_path = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as tmp_file:
            tmp_file.write(text)
        if CATALOG_PATH.exists():
            # Match the catalog's existing permissions rather than
            # mkstemp's default 0600 -- os.replace() would otherwise
            # silently tighten them on every write.
            os.chmod(tmp_path, CATALOG_PATH.stat().st_mode)
        os.replace(tmp_path, CATALOG_PATH)
    except BaseException:
        tmp_path.unlink(missing_ok=True)
        raise
