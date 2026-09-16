# Shrinker Pro — The Session Settings Bar

**Date:** 2026-09-16

The window's footer becomes one line that states what will happen to the next files
dropped, with an Adjust button that opens the three controls in place. Implements design
"1c" from `design_handoff_session_settings_bar`, and supersedes the inline footer row
described in `2026-09-16-max-size-resize-design.md` §7.

## 1. Why it changed

Three labelled controls in a row need about 620pt. The window's floor is 340pt, so the
row wrapped and the bar grew a second line with Max size orphaned under Convert. Adding a
fourth control later would have made that worse.

Collapsing to a summary fixes the width problem, and it also says something the row never
did: **these settings are this session's, not the app's defaults.** That sentence is now
printed in the panel, which is what forced the decision in §3.

## 2. The two states

**Collapsed** — `[dot] This session   {format} · {quality} · {max size}   Reset   Adjust ⌃`

38pt tall, one line, never wraps. The dot and Reset appear only when something differs
from the app's defaults; the summary is secondary-coloured until then. Below 380pt the
bar drops "This session" and the inline Reset — the dot and the summary carry the meaning
and Reset is still inside the panel. The summary is the only element allowed to truncate.

A width threshold rather than a `ViewThatFits`, deliberately: the summary truncates, and
a child that truncates always "fits", which would defeat the fallback entirely. The
previous footer's layout comments record the same trap.

**Expanded** — a header, three labelled rows on a 104pt label column, and a footer row
carrying "Applies to this session only. Defaults live in Settings." beside Done. Done,
Escape, a click anywhere above the bar, and dropping files all close it. Closing never
discards anything, because every control applies the moment it is used.

## 3. Quality stops persisting

The old footer's Quality picker was bound straight to `Settings.quality` and wrote to
UserDefaults on every change. The panel's own footer line cannot be true of two of its
three controls, so quality became session state like the other two:

- `AppModel.sessionQuality: QualityLevel?` — `nil` means "use the stored default".
- The stored preference in Settings is untouched and still owns what each session starts
  from. Nothing is migrated and nothing is lost.
- `nil` rather than a copy taken at launch, so changing the default in Settings
  mid-session is still felt by a session that never overrode it.
- "Modified" therefore means *differs from the stored default*, not *differs from
  Standard*. Someone whose stored quality is High and who has not touched the bar is not
  overriding anything and is shown no dot and no Reset.

The Settings footer text now says so from its own side: "Every session starts here; the
window's session bar can change it for one session without changing this."

## 4. Where the handoff and the app disagreed

Recorded rather than silently resolved, since each is a place the design will look
different from its mock:

| Handoff | Shipped | Why |
|---|---|---|
| Quality: Standard / High / Maximum compression | Super Low / Low / Standard / High | `QualityLevel.allCases` *is* every picker's option list, and its raw values are the persistence format. The handoff's three-item list omits two shipped levels; renaming cases would be a defaults migration. |
| Format: App default / JPEG / WebP / AVIF | …plus PNG | PNG is reachable only through the session override, on purpose (`2026-09-10-format-conversion.md`), and it keeps the growth warning beside the picker. |
| Popups filled to the row width | Native `.menu` width | A macOS `.menu` picker does not stretch its chrome: given a wider frame it centres the same button, leaving the popups' left edges ragged against the label column. Drawing the popup by hand would cost menu behaviour, keyboard handling and accessibility. |
| Max size field filled to the row width | 112pt | Five digits is the most it can hold; a field several times wider than its longest value reads as though something longer belongs in it. |
| Dark-mode tokens only | Dark as specified, light derived | The app tracks the system appearance (`Theme`), so a dark-only palette would have made light mode unreadable. Light values keep the *relationships* — bar a step from the content, controls a step above the bar, field recessed — and text is left to `.primary`/`.secondary` so contrast keeps tracking accessibility settings. **Send these back to the designer; they are derived, not sampled.** |
| ~320pt narrow state | 340pt | `ContentView`'s existing minimum width. |

Everything else — 38pt bar, 13pt gutters, 8pt spacing, 104pt label column, 7pt radii,
0.5pt hairline and insets, the 0.22s ease-out expand and chevron rotation, the dot, the
summary format and the copy — is as specified.

## 5. Max size validation

The handoff's range applies: 1–20000, clamped rather than refused. The text is snapped
into range only when editing ends, because rewriting it mid-keystroke would fight anyone
typing "20000" one digit at a time — "2" is in range, "20" is, and so on. `MaxSizeField`
owns all of it, and `SessionBarStateTests` covers it.

## 6. Tests

`SessionBarStateTests` covers the summary line for every quality level, what counts as
modified (including the stored-quality comparison in §3), the narrow-width threshold and
the growth warning. `AppModelTests` covers the session quality reaching the engine, *not*
reaching UserDefaults, Reset leaving stored settings alone, and a drop closing the panel.
