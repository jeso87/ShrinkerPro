# Localization glossary

This glossary fixes the English vocabulary that every one of the app's 35
translations must map consistently. It is written before any translation
exists, so it governs the work rather than describing it afterwards.

Without a fixed term, a translator working string by string has no way to
notice that "shrink" has arrived three different ways inside one language's
catalog — each string was translated in isolation, and nothing connected
them. The terms below name that connection explicitly.

## Terms

- **shrink** — the app's core verb. The same word must be used in the drop zone, the notification and the Settings prose. Do not alternate with a synonym for variety.
- **minified** — the subfolder name and the `.min` suffix. A borrowed technical term; keep it recognisable rather than translating it to a general word for "smaller".
- **session** — one run of the app, as opposed to a saved default. The session bar and Settings both lean on the distinction, so the two must not collapse into the same word.
- **original** — the user's own input file, the thing that can be destroyed. Must be distinct from "file", which the same sheet uses for something less alarming.
- **crop** — the noun and the verb. Distinct from "resize" and from "scale".
- **Keep Both** — the overwrite sheet's non-destructive choice. Match the platform's own wording for this action where one exists.
- **Skip These** — declines these files without cancelling the drop. Not "Cancel"; the distinction is the whole point of the button.
- **Replace** — overwrites. Destructive. Must read as more final than "Keep Both".
- **Reveal** — shows the file in Finder. Use the platform's own term for this action, which is rarely a literal translation of "reveal".

## Platform conventions

For any string that names a standard macOS action — Save, Open, Settings,
Quit, Reveal in Finder — prefer the term macOS itself uses over a literal
translation. Check the system's own menus in the target language rather than
guessing: System Settings, the Finder menu bar and the standard File and
Edit menus are all localised by Apple already, and that vocabulary is what
the user already expects.

A German Mac user expects "Sichern", not "Speichern", because that is what
the system menu says. An app that invents its own vocabulary for a standard
action reads as foreign even when every individual word is correct — the
error is not in the translation but in ignoring the platform convention
around it. When in doubt, match the OS; do not translate the English source
string as if the platform's own choice did not already exist.
