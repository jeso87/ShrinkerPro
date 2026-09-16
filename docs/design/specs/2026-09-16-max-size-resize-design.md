# Shrinker Pro — A Session Max Size

**Date:** 2026-09-16

One number, set in the window footer for the length of a session: the longest side an
image is allowed to keep. Blank means no resizing, which is today's behaviour exactly.
Builds on `2026-09-10-orientation-metadata-and-session-override.md`, whose rewrite table
this spec extends rather than replaces.

## 1. What it does

> **When a max size is set, any image whose longest side exceeds it is scaled down so
> that side equals it, preserving aspect ratio. Anything already within it is left
> alone.**

A landscape image is therefore capped by its width and a portrait one by its height,
which is the rule as it was asked for — but it is not implemented as a branch on
orientation, because "constrain the longer side" is the same rule with no case to get
wrong. A square image is capped on both, being the same number.

Nothing is ever scaled **up**. A 900px image under a 2000px cap is not a resize that
happens to be a no-op; it never enters the resize path at all (§3).

Scope is every raster format the app accepts, plus GIF. SVG is excluded and that is not
an omission: it is vector, it has no pixel size to cap, and `svgo` is not a resizer.

## 2. Where the value lives

`OutputSettings.maxDimension: Int?`, sitting beside `sessionFormat` and sharing its
lifetime: set in the main window, never written to UserDefaults, gone at quit. It is
layered onto the settings snapshot in `AppModel.startShrinking` at the same point and for
the same reason — one snapshot per batch, so changing the field mid-drop cannot split one
drop across two behaviours.

There is deliberately **no persisted default in Settings**. A stored dimension cap is the
same object `2026-09-10-format-conversion.md` rejected for conversion: a setting that
changes every file "silently, and forever". The answer there was a control visible for
exactly as long as it is switched on, and that answer applies here unchanged.

`nil` is the off state, and off must cost nothing. When `maxDimension` is `nil` no
dimension is read, no predicate is computed, and every file takes byte-for-byte the route
it takes today. This is stated as a requirement rather than an expectation because §7
tests it.

## 3. Reading the size

The threshold test needs the file's **oriented** size. A portrait phone photo stores
landscape pixels plus a rotation tag, so testing the stored dimensions would cap the
wrong axis and produce an image that is the requested size in the file and the wrong size
on screen.

`ImageMetadata.orientation(of:)` already opens a `CGImageSource` and reads
`CGImageSourceCopyPropertiesAtIndex` for every raster file before a route is chosen. The
pixel dimensions come out of that same properties dictionary
(`kCGImagePropertyPixelWidth` / `kCGImagePropertyPixelHeight`), so the two reads are
merged into one call returning both, and planning still pays exactly one header read per
file. It is a header read, not a decode, which is what makes it affordable before routing.

For the four 90° orientations the width and height are swapped before the comparison.

GIF short-circuits before the router and pays no header read today. When — and only when
— a max size is set, it pays one, so that §6's guard bypass can know whether a resize
actually happened.

## 4. Needing a resize is a routing fact

None of the three vendored CLI encoders that receive the user's file directly can resize
it: `pngquant` has no such flag, `cjpeg` has none, and `cwebp` has `-resize` but using it
would mean two different resamplers for still images, so that a PNG and a WebP capped at
the same number would not match. ImageIO is the app's only decoder, and it is where
rotation is already resolved. Resizing belongs in the same place.

`RoutingContext` therefore gains `needsResize: Bool`, and `honouring()` — which already
rewrites any route that would point a CLI encoder at a file it cannot cope with — gains a
third reason to rewrite, alongside `isUpright` and `.copyright`:

| route without resize | route when resizing |
|---|---|
| `.sameFormat(.jpeg)` (cjpeg) | `.viaIntermediate(target: .jpeg, intermediate: .tga)` |
| `.sameFormat(.png)` (pngquant) | `.viaIntermediate(target: .png, intermediate: .png)` |
| `.sameFormat(.webp)` (cwebp) | `.viaIntermediate(target: .webp, intermediate: .png)` |
| `.direct(target: .webp)` (cwebp) | `.viaIntermediate(target: .webp, intermediate: .png)` |
| `.sameFormat(.avif)`, `.sameFormat(.heic)`, `.direct(target: .avif)` | unchanged — already ImageIO |
| every `.viaIntermediate` | unchanged — already ImageIO |

This is the rotation table, with an identical right-hand column. That is the argument for
the design: no route case is added, no compressor type is added, and every rewrite lands
on a path that already exists and is already tested.

`cwebpNeedsNoHelp` becomes `context.isUpright && context.policy != .copyright &&
!context.needsResize` — a third clause on a predicate that already means "cwebp can be
pointed at the user's original file".

## 5. Doing the resize

`ImageIOCompressor` gains `maxDimension: Int?` and downsamples during the decode it is
already performing, via `CGImageSourceCreateThumbnailAtIndex` with
`kCGImageSourceThumbnailMaxPixelSize`. That option's semantics are exactly the rule in
§1 — it constrains the larger dimension and preserves aspect ratio — so the rule is
expressed by the API rather than re-derived in arithmetic here.

`IntermediateConversionCompressor` threads the value into its ImageIO stage. The
consequence is worth stating: a relayed file is **already at its final size** when the
downstream encoder sees it, so cjpeg, cwebp and pngquant encode fewer pixels rather than
full-size ones that are then thrown away.

The single-lossy-hop guarantee the README states is untouched. Resizing happens inside
the existing ImageIO decode; it does not add an encode. `IntermediateConversionCompressor`
still passes `quality: nil` to its carrier, for the reasons documented on that type.

**GIF keeps its short-circuit** and is resized by `gifsicle`, which is the only tool here
that can resize an animation without flattening it — ImageIO would have to round-trip the
frames. `GIFCompressor`'s argv gains `--resize-fit WxH` (shrink to fit, preserving aspect
ratio, a no-op when the image already fits — so the semantics match §1 without a second
implementation of them) and `--resize-method mix` for resample quality.

## 6. The never-grow guard

`ShrinkEngine.shrink` discards a same-format result that is not smaller than its source
and keeps the user's original. A resized file is still same-format, so as written the
guard would silently return a full-size image to someone who asked for 2000px.

`ShrinkPlan` and `ShrinkPlanRouting` gain `wasResized: Bool`, and the guard becomes:

```swift
if plan.isSameFormat, !plan.wasResized, shrunkBytes >= originalBytes {
```

This is the exemption conversions already have, for the reason already recorded beside
it: growth the user explicitly asked for is not the guard's business. Refusing it would
be silently ignoring the request.

`wasResized` is carried on the plan rather than derived from `targetExtension` or from
`isSameFormat`, in keeping with the note on those fields — the bug they document came
from inferring one property of a route from another.

`--help`'s paragraph on the guard gains the extra clause: resizing is exempt alongside
converting.

## 7. The footer control

A third control in `WindowFooterView`: `Max size [____] px`.

The field's text — not a parsed `Int?` — is what lives on `AppModel`, parsed on every
keystroke. This is the whole reason for choosing a live parse over commit-on-Return:
otherwise someone types `2000`, drags a file in without pressing Return, and the drop is
processed with no resize and no indication why.

Parsing and filtering live in a pure `MaxSizeField` enum beside `WindowFooterState`, for
the reason that type exists at all: this project carries no view-tree testing dependency,
so anything left inline in a `body` is logic no test can reach. It owns:

- digits only; anything else is rejected as typed
- five digits maximum, which keeps the field narrow and the value sane
- leading zeros stripped
- blank, or a value of zero, means `nil` — off

The "Max size" label is semibold and accent-coloured while a value is set, matching how
"Convert all to" signals an active override. A session setting in force must never be
invisible; that is the same argument that put this row in the window rather than in
Settings.

Tooltip: *"Shrinks images so the longest side is at most this many pixels. Smaller images
are left alone. SVG is unaffected. Not saved — it resets when you quit."*

The footer's `ViewThatFits` grows from two variants to three: all three controls in a
row; format and quality on one row with max size beneath; all three stacked at
`ContentView`'s 340pt floor. The field is a fixed width so the footer does not twitch as
digits are typed — the same reason the PNG warning glyph holds its space with `opacity`
rather than being inserted conditionally.

## 8. The CLI

`--max-size N`, threaded into `CommandLineOptions.outputSettings` beside `sessionFormat`.
A non-numeric or non-positive argument is a parse error in the existing style, with its
own reason string. `--help` gains the option, one example, and the guard clause from §6.

## 9. Tests

- **`ConversionRouterTests`** — `needsResize` × source format × target, enumerated: every
  CLI-encoder route rewritten onto its relay, every ImageIO route unchanged. And the
  regression net for §2: with `needsResize: false` the whole table reproduces today's
  routes exactly.
- **`ImageMetadataTests`** — oriented size across all eight orientation fixtures, so a
  portrait photo is capped on the axis a viewer actually sees.
- **`ShrinkEngineTests`** — end to end per route (PNG, JPEG, WebP, AVIF, HEIC, GIF):
  output long edge equals the cap, aspect ratio preserved within a pixel, an under-cap
  file comes out dimensionally untouched, and a resized file that grows is still written.
- **A GIF frame-count test** — the animation survives `--resize-fit`. This is the
  regression that would be easiest to ship unnoticed, because a resized first frame looks
  entirely correct.
- **`MaxSizeField` tests** — every rule in §7, including that `"0"` and `""` are both off.
- **`CommandLineOptionsTests`** — the flag, its error cases, and its presence in `--help`.

## 10. Out of scope

Stated so they are decisions rather than gaps:

- a persisted default in Settings (§2)
- showing output dimensions in the result rows
- upscaling images below the cap
- separate width and height caps, or a crop
- SVG (§1)
- a resize-without-recompress mode
