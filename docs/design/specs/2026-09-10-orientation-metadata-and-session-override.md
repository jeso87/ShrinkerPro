# Shrinker Pro — Orientation, Metadata Policy, and a Session Conversion Override

**Date:** 2026-09-10

Three changes: photos stop coming out rotated, the user decides what metadata survives,
and a one-off "convert everything to X" becomes one click. Builds directly on
`2026-09-10-format-conversion.md`, which this spec assumes.

## 1. Rotation

### The bug

`ImageIOCompressor` decodes with `CGImageSourceCreateImageAtIndex`, which returns the
**raw, unrotated** pixel buffer — ImageIO does not apply EXIF orientation on decode — and
writes with `CGImageDestinationAddImage` and an options dictionary holding only
`kCGImageDestinationLossyCompressionQuality`. No orientation tag, no EXIF, nothing. A
repo-wide grep for `kCGImageProperty*` across `Sources/` returned zero hits.

So an iPhone photo tagged `Orientation = 6` is decoded sideways and written with no tag
saying so. This hits **HEIC → JPEG, the default rule**, plus every AVIF target, every
HEIC/AVIF re-encode, and both the TGA and PNG intermediates.

Two paths were never broken, which is why the reports were about *some* images:

- **JPEG → JPEG preserves EXIF today.** mozjpeg's `cjpeg` sets `copy_markers = TRUE` for
  JPEG input (`vendor/src/mozjpeg/cjpeg.c:124-125`) and `rdjpeg.c:65-68` saves COM and
  every APPn marker. The orientation tag survives, the pixels stay unrotated, and the
  file displays exactly as it did before.
- **PNG, GIF and SVG** have no orientation to lose.

`cwebp` is invoked with no `-metadata`, whose libwebp default is `none`, so every WebP
output loses orientation regardless of source.

### The fix: bake, don't preserve

Rotation is applied **to the pixels**, and the output carries no orientation tag. The
alternative — carrying the tag forward — was rejected: the TGA and PNG intermediates have
no orientation field to carry it in, so it cannot fix the HEIC → JPEG case at all, and
WebP viewers honour the tag inconsistently. Baking is correct in every viewer and every
format, and is the only option that works end to end.

This means the app's one decoder must see the pixels of every rotated file:

> **If the source declares an orientation other than "up", its pixels must pass through
> an ImageIO decode before any encoder sees them.**

ImageIO is the only component in the app that can rotate, so the router rewrites the
CLI-direct routes to their relayed equivalents whenever orientation ≠ 1:

| route when upright | route when rotated |
|---|---|
| `.sameFormat(.jpeg)` (cjpeg) | `.viaIntermediate(target: .jpeg, intermediate: .tga)` |
| `.sameFormat(.png)` (pngquant) | `.viaIntermediate(target: .png, intermediate: .png)` |
| `.sameFormat(.webp)` (cwebp) | `.viaIntermediate(target: .webp, intermediate: .png)` |
| `.direct(target: .webp)` (cwebp) | `.viaIntermediate(target: .webp, intermediate: .png)` |
| `.sameFormat(.avif)`, `.sameFormat(.heic)`, `.direct(target: .avif)` | unchanged — already ImageIO |

The JPEG detour costs no extra generational loss: `cjpeg` already fully decodes and
re-encodes, and the TGA intermediate is lossless. SVG and GIF never reach the router.

Reading the orientation is cheap — `CGImageSourceCopyPropertiesAtIndex` does not decode
pixels — so `ShrinkEngine.shrink` reads it once per file and passes it to `plan`.
`ConversionRouter` stays pure and IO-free; orientation arrives as an argument, so every
combination remains enumerable in tests without touching a real image.

### The transform

The eight EXIF orientations map to eight affine transforms applied during a `CGContext`
redraw, with width and height swapped for the four 90° cases. The implementation was
verified against ImageIO's own `kCGImageSourceCreateThumbnailWithTransform` output for
**all eight** orientations — matching dimensions and a four-quadrant colour signature in
every case. That equivalence is the correctness argument; it is worth re-running rather
than re-deriving if the transform is ever touched.

## 2. Metadata policy

A new setting, because the right answer genuinely differs by person: a photographer wants
capture data kept, someone posting to a forum wants GPS gone.

| Setting | Behaviour |
|---|---|
| **Keep all** (default) | Everything except orientation |
| **Copyright and credit only** | Rights and attribution tags; everything else dropped |
| **No metadata** | Nothing |

**"Keep all" is the default because it is the only value that doesn't silently regress.**
JPEG → JPEG keeps everything today (see above), so any other default would delete data
from files the app currently round-trips intact, on upgrade, without asking.

Orientation is never subject to the policy. It is always applied to the pixels and always
absent from the output — under all three settings — because it is not really metadata
about the image, it is an instruction about how to draw it, and that instruction has
already been carried out.

### How it is applied

The encoders differ in what they can be told, so the mechanism differs by output format:

- **ImageIO-authored outputs** (AVIF, HEIC): the filtered properties go straight into
  `CGImageDestinationAddImage`.
- **CLI-authored JPEG and PNG** (`cjpeg`, `pngquant`): a post-pass over the engine's
  scratch file using `CGImageDestinationCopyImageSource`, which rewrites metadata
  **without re-encoding the pixels** — verified byte-identical on a JPEG. The source
  metadata comes from the original file via `CGImageSourceCopyMetadataAtIndex`, since the
  scratch produced from a TGA intermediate has none. This also makes "No metadata" and
  "Copyright only" work on JPEG → JPEG, which `cjpeg`'s all-or-nothing marker copy cannot
  express.
- **WebP**: ImageIO cannot write WebP at all (re-verified — `org.webmproject.webp` is
  absent from `CGImageDestinationCopyTypeIdentifiers()`), so no post-pass is possible.
  Instead the PNG intermediate is authored carrying exactly the metadata to keep, and
  `cwebp` is passed `-metadata all`. Verified: `cwebp` reads copyright, capture date and
  GPS out of an ImageIO-written PNG's `eXIf` chunk. On the direct path — upright source,
  Keep all — `cwebp -metadata all` reads the source's own EXIF, which is already correct.

**`kCGImageMetadataShouldExcludeXMP: true` is mandatory on every post-pass.** Without it
ImageIO writes a padded XMP packet: on a 1,421-byte test JPEG, "No metadata" came back at
**3,682 bytes** — a compressor inflating a file by 2.3 KB while claiming to strip it.
With the flag, "No metadata" is 1,343 bytes (smaller than the input) and "Keep all" is
1,653, the genuine cost of the EXIF.

The post-pass runs on the scratch **before** promotion, so the invariant documented at
`ShrinkEngine.shrink` — no compressor and no metadata step ever writes to a file the user
cares about — is untouched.

## 3. Session conversion override

`2026-09-10-format-conversion.md` rejected a global "convert everything to X" as too
blunt: it would convert silently, and forever, with no way to express "just this once".

A **session** override is a different proposition and is accepted here on two conditions,
both of which answer that rejection directly:

1. **It is visible while it is active.** It lives in the main window, above the results
   list, accent-coloured when set — not buried in Settings where it could be left on and
   forgotten. Nothing it does is silent.
2. **It does not persist.** It is gone at quit, and it never touches the stored
   per-format rules, which remain exactly as configured.

### Targets

**JPEG, WebP, AVIF and PNG.** PNG is a new conversion target, reachable **only** through
the override — the per-format rules in Settings keep their existing options. A "PNG" entry
in the PNG row would sit beside "Keep PNG" meaning almost the same thing, and HEIC → PNG
as a persistent default is rarely what anyone wants.

PNG's route is an ImageIO decode to a PNG intermediate, then `pngquant` — reusing the
existing relay machinery rather than adding an encoder.

**Converting photographs to PNG usually makes them larger.** PNG is lossless; a JPEG or
HEIC photo re-encoded as PNG routinely grows several times over. The app does this anyway
when asked — quietly keeping the original instead would be ignoring an explicit
instruction and would leave a folder half-converted, which is worse than a big file. The
UI says so when PNG is selected, and the results row already reports a negative saving
honestly.

### Types

The override's format is a **session-only type**, deliberately not `ConversionFormat`.
Both Settings rows iterate `allCases` on purpose, so that they always offer exactly the
cases the type has and nothing can fall out of sync; adding `.png` to `ConversionFormat`
would therefore put PNG in the HEIC row as a side effect, and make `"png"` a value the
persistence layer would accept for a rule the UI cannot express. A separate type keeps the
fourth option out of persistence entirely.

`ConversionTarget` and `ConversionFormat` — the two persisted types — are not modified.

SVG and GIF are exempt from the override for free: `ShrinkEngine` short-circuits both
before rules are consulted at all. The UI states this, in the same spirit as the existing
Settings footer — an exemption the user cannot see is an exemption they will assume is a
bug.

## 4. "Add .min suffix" becomes "Keep original files"

The toggle describes its mechanism, not its stake. Turning it off makes the output path
equal the input path, so the user's original is replaced — which the label never says.
It is renamed to **"Keep original files"**, with subtext naming both the `.min` suffix and
the overwrite.

Polarity is unchanged — on still means "write a separate `.min` file" — so the stored
value keeps its meaning and **the UserDefaults key stays `"suffix"`**. No migration, and
no chance of reading somebody's existing preference backwards. The Swift property is
renamed alongside the label so the code and the UI agree.

One honest wrinkle: when a file is **converted**, the output extension differs from the
input's, so the original survives beside the new file whatever this toggle says. "Keep
original files" is therefore a promise the app over-delivers on rather than breaks, and
the in-place overwrite it warns about applies to same-format compression.

## Out of scope

- A quality slider (still, from the previous spec)
- Resizing or dimension changes
- Rasterising SVG, converting animated GIF
- PNG in the persistent per-format rules
- Inverting the toggle to "Overwrite originals"
