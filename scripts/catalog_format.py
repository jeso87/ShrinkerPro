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
    """Validates spliced catalog text before it is written, then writes it.

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
    only if both checks pass.
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

    CATALOG_PATH.write_text(text, encoding="utf-8")
