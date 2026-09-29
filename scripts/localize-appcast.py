#!/usr/bin/env python3
"""Add the translated release notes to an appcast item as `xml:lang` siblings.

Sparkle shows the update's notes in whatever language the Mac is set to, if
the feed offers them: an item may carry several `<description>` elements
distinguished by `xml:lang`, and the updater picks the best match for the
user's preferred languages, falling back to the one with no `xml:lang` when
it has nothing closer.

`generate_appcast` does not know about this. It embeds exactly one set of
notes — the `.md` staged beside the archive — so this script runs after it
and splices the rest in.

Verified against the vendored framework rather than assumed. Parsing a feed
carrying `en`/`de`/`ja` descriptions through Sparkle's own `SUAppcast`,
inside a real localized app bundle, selects the German notes under
`-AppleLanguages (de)`, the Japanese under `(ja)`, and falls back to the
unlabelled English under `(fr)` when French is absent. That fallback is why
a missing translation here is a soft failure: the dialog shows English, not
nothing.

The feed is spliced as text rather than re-serialised through an XML
library, for the same reason `merge-translations.py` splices the string
catalog: a round trip rewrites attribute order, entity escaping and
whitespace across the whole file, turning a two-line change into an
unreviewable one.

Usage:
    python3 scripts/localize-appcast.py <version> [--check]

    --check   Report what would change and write nothing. Exits 1 if the
              feed is missing any language that has a notes file on disk,
              which is what CI wants: a release whose feed quietly lost its
              translations still updates users, in English, and nobody
              notices until someone asks why.
"""

from __future__ import annotations

import html
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
APPCAST = REPO_ROOT / "appcast.xml"
NOTES_DIR = REPO_ROOT / "docs" / "release-notes"

NOTHING_TO_DO = 0
MISSING_LANGUAGES = 1
BAD_INPUT = 2


def notes_for(version: str) -> dict[str, Path]:
    """Every translated notes file for this version, keyed by language.

    `1.5.0.md` is the English source and is deliberately excluded: it is
    already in the feed as the unlabelled `<description>`, and adding it
    again with `xml:lang="en"` would change behaviour for users whose
    preferred language is none of the 36 — they would still match nothing
    and fall back, but the fallback would now be competing with an explicit
    entry, which is a difference nobody needs to reason about.
    """
    found = {}
    for path in sorted(NOTES_DIR.glob(f"{version}.*.md")):
        # "1.5.0.pt-BR.md" -> "pt-BR". Split off the version prefix and the
        # .md suffix rather than using .stem, which would give "1.5.0.pt-BR".
        lang = path.name[len(version) + 1 : -len(".md")]
        if lang:
            found[lang] = path
    return found


def find_item(text: str, version: str) -> tuple[int, int]:
    """The [start, end) of the <item> whose shortVersionString is `version`."""
    for match in re.finditer(r"<item>.*?</item>", text, re.DOTALL):
        body = match.group(0)
        if re.search(
            rf"<sparkle:shortVersionString>{re.escape(version)}</sparkle:shortVersionString>",
            body,
        ):
            return match.start(), match.end()
    raise SystemExit(f"FAIL  no <item> in appcast.xml for version {version}")


def strip_localized(item: str) -> str:
    """Remove any `<description xml:lang=...>` already present.

    So re-running after a translation is corrected replaces it rather than
    appending a second copy of that language — at which point Sparkle picks
    whichever it saw first and the fix appears not to have worked.
    """
    return re.sub(
        r"\n\s*<description[^>]*\bxml:lang=\"[^\"]+\"[^>]*>.*?</description>",
        "",
        item,
        flags=re.DOTALL,
    )


def build(lang: str, body: str, indent: str) -> str:
    """One `<description>` element carrying `body` as CDATA.

    `]]>` inside the notes would close the section early and leave the rest
    of the file as markup; it cannot appear in prose by accident, so this is
    a hard failure rather than an escape.
    """
    if "]]>" in body:
        raise SystemExit(f"FAIL  {lang} notes contain ']]>' and cannot be embedded as CDATA")
    return (
        f'\n{indent}<description xml:lang="{html.escape(lang, quote=True)}" '
        f'sparkle:format="markdown"><![CDATA[{body}]]></description>'
    )


def main(argv: list[str]) -> int:
    args = [a for a in argv[1:] if not a.startswith("--")]
    check = "--check" in argv[1:]
    if len(args) != 1:
        print(__doc__.strip().splitlines()[-4].strip(), file=sys.stderr)
        return BAD_INPUT
    version = args[0]

    english = NOTES_DIR / f"{version}.md"
    if not english.is_file():
        print(f"FAIL  no English notes at {english.relative_to(REPO_ROOT)}", file=sys.stderr)
        return BAD_INPUT

    translations = notes_for(version)
    if not translations:
        print(f"no translated notes for {version} — nothing to splice")
        return NOTHING_TO_DO

    text = APPCAST.read_text(encoding="utf-8")
    start, end = find_item(text, version)
    item = strip_localized(text[start:end])

    # Anchor on the unlabelled description generate_appcast wrote, and put
    # the translations directly after it so the English stays first and
    # readable when someone opens the feed by hand.
    anchor = re.search(r"\n(\s*)<description(?![^>]*xml:lang)[^>]*>.*?</description>", item, re.DOTALL)
    if anchor is None:
        print(f"FAIL  item {version} has no unlabelled <description> to anchor to", file=sys.stderr)
        return BAD_INPUT
    indent = anchor.group(1)

    added = "".join(
        build(lang, path.read_text(encoding="utf-8").rstrip("\n"), indent)
        for lang, path in sorted(translations.items())
    )
    item = item[: anchor.end()] + added + item[anchor.end() :]

    if check:
        present = set(re.findall(r'<description xml:lang="([^"]+)"', text[start:end]))
        missing = sorted(set(translations) - present)
        for lang in sorted(translations):
            print(f"  {lang}: {'in feed' if lang in present else 'MISSING from feed'}")
        if missing:
            print(f"FAIL  {len(missing)} language(s) missing from the feed: {' '.join(missing)}", file=sys.stderr)
            return MISSING_LANGUAGES
        print(f"all {len(translations)} translated notes are in the feed for {version}")
        return NOTHING_TO_DO

    APPCAST.write_text(text[:start] + item + text[end:], encoding="utf-8")
    print(f"spliced {len(translations)} translated release notes into {version}")
    print(f"  {' '.join(sorted(translations))}")
    return NOTHING_TO_DO


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
