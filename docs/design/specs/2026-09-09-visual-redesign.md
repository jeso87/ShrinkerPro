# Shrinker Pro — Visual Redesign

**Source:** Claude Design handoff, `Shrinker Pro Redesign.dc.html` (artboards 1a dark, 1b light, 1c batch).
**Date:** 2026-09-09

## Intent

> The drop zone shrinks to a band once it isn't the only thing on screen, so the window
> never looks empty. History fills the rest, newest first.
>
> "You saved 51%. Your shrunken image is here:" plus a wrapping blue path becomes one
> scannable row: filename, before → after, percent. Reveal in Finder on hover.
>
> The coral→ice gradient survives in the icon, the drop-zone glow and the savings bars —
> the places where it signals value. Everything else is standard macOS surface grey.

## Decisions already made

- **Type:** SF Pro for UI, SF Mono for sizes/labels. The mock's Inter Tight / JetBrains Mono
  are not on macOS; system faces are the native equivalents and cost nothing.
- **Batch (1c) is OUT of scope** — descoped by the user after the design was read:
  "scrap the progress then, just list out the files nicely in that design format".
  No progress card, no ETA, no Cancel. The existing simple spinner stays.
- **Settings gear is a native `NSToolbar` item**, not a custom title bar.
- **Window stays 440pt wide** for now; widen only if rows genuinely cramp.

## Colour tokens

OKLCh from the design, converted to sRGB. Define these once; do not re-derive inline.

| Token | Dark | Light |
|---|---|---|
| `gradientStart` (bars) | `#ED7665` | `#D55948` |
| `gradientEnd` (bars) | `#7FAFE2` | `#6197CD` |
| `iconGradientStart` | `#E6705F` | `#E36654` |
| `iconGradientEnd` | `#79A9DB` | `#679DD4` |
| `savingsAccent` (percent, aggregate) | `#FFB09D` | `#BD4334` |
| `dropGlow` tint | `#E17363` @ 0.13 alpha | `#E17363` @ 0.12 alpha |

Everything else uses standard SwiftUI semantic colours (`.primary`, `.secondary`,
`Color(nsColor: .windowBackgroundColor)`, etc.) so light/dark and accessibility
settings work without a parallel palette.

Gradients are `LinearGradient(colors:, startPoint: .leading, endPoint: .trailing)` for
bars, `145°` diagonal for the icon circle.

## Layout — idle (1a / 1b)

**Drop band** — replaces the tall centred box.
- Horizontal: 38pt gradient circle (↓ glyph, white, 22pt) on the leading edge, 16pt gap,
  then a two-line stack.
- Title "Drag files here" — 16pt semibold, tracking −0.01em.
- Subtitle "SVG, JPG, GIF and PNG — or press ⌘O" — 12.5pt secondary.
- Container: 10pt radius, 1.5pt dashed border, radial-gradient glow from the top centre
  (`120% 160% at 50% 0%`), 20pt padding, 16pt horizontal window margin.

**Recent header** — between band and rows.
- Leading: "RECENT" — SF Mono 10.5pt, uppercase, tracking 0.12em, secondary.
- Trailing: "`N` files · `X` saved" with the size portion in `savingsAccent`, semibold, 11.5pt.
- Hidden entirely when there is no history.

**Result row** — 11pt vertical / 18pt horizontal padding, 0.5pt hairline separator,
subtle hover fill.
- Filename, 13pt medium, single line, truncating at the tail.
- Below it: a 150×3pt savings bar (2pt radius, hairline track, gradient fill to `pct`),
  9pt gap, then `3.1 MB → 1.2 MB` in SF Mono 11pt secondary.
- Trailing: `−62%` in `savingsAccent`, 13.5pt bold, **tabular figures**.
- Trailing-most: a "Reveal" pill — 11.5pt, 4×9pt padding, 6pt radius, hairline inset ring,
  brightening on hover.

Row click and the Reveal pill both call `NSWorkspace.activateFileViewerSelecting`.

## Behaviour this requires

1. **Rows must carry byte counts.** `ShrinkResult` already computes `originalBytes` and
   `shrunkBytes`; `ResultRow` currently discards both. Carry them so the row can render
   `before → after`. (The final whole-branch review flagged this as dropped data.)
2. **Session aggregate** — count of files and total bytes saved since launch, for the
   Recent header. Resets when the list is cleared.

Byte formatting uses `ByteCountFormatter` with `.file` count style, so it matches Finder.

Progress, ETA and cancellation were considered and cut. The engine's temp-staging
invariant — which fixed a real data-loss bug — is untouched by this redesign.

## Out of scope

WebP and AVIF. Deliberately deferred; they need new vendored binaries.
