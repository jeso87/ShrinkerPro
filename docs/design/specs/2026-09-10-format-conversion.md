# Shrinker Pro — Format Conversion (WebP, AVIF, HEIC)

**Date:** 2026-09-10

## What changes

The app has been strictly same-format: drop a PNG, get a smaller PNG. This adds
**per-input-type conversion rules**, so each format can be routed independently.

Settings holds one rule per convertible input format. For PNG, JPEG, WebP and AVIF each
rule's value is **Keep original** / **JPEG** / **WebP** / **AVIF**. HEIC/HEIF has no
"Keep original" option at all — its rule is **JPEG** / **WebP** / **AVIF** only.

| input | rule options | default |
|---|---|---|
| PNG | Keep PNG / JPEG / WebP / AVIF | Keep PNG |
| JPEG | Keep JPEG / WebP / AVIF | Keep JPEG |
| HEIC / HEIF | JPEG / WebP / AVIF (no Keep) | **JPEG** |
| WebP | Keep WebP / JPEG / AVIF | Keep WebP |
| AVIF | Keep AVIF / JPEG / WebP | Keep AVIF |

Everything defaults to Keep except HEIC, and HEIC has no Keep to default away from in the
first place: keeping a HEIC is never what someone wants when they drop one into a
compressor. It's a capture format — iPhone photos — re-encoding it to HEIC saves little,
and it stays a file many apps and sites still cannot open. JPEG is what someone dragging
a HEIC into a compressor actually wants, so it's not just the default, it's the only
non-converting-away-from-HEIC outcome available: the picker offers three options, not
four, and there is no code path — persisted setting, UI selection, or router input — that
can put HEIC back into "keep". Every other format's behaviour is unchanged from today.

A single global "convert everything to X" was considered and rejected: it is too blunt.
Setting it to AVIF would silently convert JPEGs too, and there is no way to express the
common case of "convert my HEICs, leave everything else alone". Per-type rules also make
the exclusions **visible** — SVG and GIF simply have no row.

## Measured baseline

macOS encodes AVIF and HEIC natively via ImageIO. Verified against the project's own
244,413-byte PNG fixture:

| target | bytes | vs source |
|---|---|---|
| AVIF (ImageIO) | 20,981 | −91% |
| HEIC (ImageIO) | 24,772 | −90% |
| JPEG (ImageIO) | 45,726 | −81% |
| PNG via pngquant (today) | 67,609 | −72% |

AVIF beats the app's best same-format result substantially and needs **no vendored
binary** — building libavif plus an AV1 encoder is avoided entirely.

**WebP is the exception:** macOS reads it but will not write it (`sips --formats` lists
`webp` without `Writable`, and encoding fails). WebP requires vendoring `cwebp`.

## Input formats

Accepted inputs become: `svg png gif jpg jpeg webp avif heic heif`.

`heic`/`heif`/`avif`/`webp` are new. They decode through ImageIO, which already handles
all four.

## Conversion rules

**SVG never converts.** It is vector; rasterising it is a different operation with
different options (dimensions, DPI) and is almost never what someone dropping an SVG
wants. An SVG always produces an optimised SVG, whatever the output setting says.

**GIF never converts.** GIFs here are usually animated, and a still-image encoder would
silently drop every frame but one. Losing an animation without saying so is worse than
not converting.

Both exemptions are *silent* in the sense that no error is raised — the file is simply
optimised in its own format, which is the useful outcome.

**This must be stated in Settings, not left to be discovered.** SVG and GIF have no rule
row, and their absence needs explaining rather than leaving a user to wonder whether it
was an oversight. Required copy beneath the rule list:

> SVG and GIF files are always optimised in their own format. SVG is vector, and GIF is
> usually animated — converting either would lose what makes it useful.

Wording may be tightened, but it must name **both** formats and give the **reason** for
each. "Some formats are excluded" is not sufficient; the user cannot act on that.

Each rule's "no change" option should read **"Keep PNG"**, **"Keep JPEG"** and so on
rather than a bare "None" or "Off", so the row states its own behaviour. HEIC/HEIF has no
"no change" option to word this way — see above.

**Everything else converts** when a target format is set: PNG, JPEG, HEIC/HEIF, WebP and
AVIF all decode via ImageIO and re-encode to the target.

**Same-format conversion is still compression.** If the target is JPEG and the input is a
JPEG, route it through the existing `cjpeg` path rather than a decode/re-encode cycle —
generational loss for no benefit. Same for WebP→WebP and AVIF→AVIF.

**JPEG target routes through mozjpeg.** ImageIO's JPEG encoder is adequate; `cjpeg` is
better. For a non-JPEG source targeting JPEG, decode via ImageIO to an intermediate, then
run the existing `JPEGCompressor`. This reuses the tuned path instead of adding a second,
worse one.

## Output paths

`OutputPathResolver` currently preserves the input extension. When converting it must use
the **target** extension: `photo.heic` → `photo.min.jpg`.

The in-place case needs care. With suffix and subfolder both off, a same-format output
collides with the input — that is the documented behaviour the engine's temp-staging
protects. When **converting**, the extension differs, so there is no collision; the
original is left untouched beside the new file. That is correct and should not be
"fixed" into deleting the source.

## cwebp

Vendored as a fourth helper alongside `cjpeg`, `pngquant` and `gifsicle`, built from
libwebp source as a static arm64 binary through the existing
`scripts/build-compressors.sh` pipeline, and subject to the same architecture gate:
arm64-only, `minos <= 14.0`, links nothing outside `/usr/lib` and `/System/Library`.

`release.sh` asserts the expected helper set before signing — it must be updated to
expect four, or a missing `cwebp` would ship silently.

`cwebp` accepts PNG, JPEG, TIFF and WebP input, but **not** HEIC or AVIF. Those decode
through ImageIO to an intermediate first.

## Quality

Lossy encoders need a quality setting. Use a sensible fixed default rather than adding a
slider in this pass — the spec's original "no quality slider" non-goal still holds. State
the chosen value in code with a comment; it can become a setting later if it proves wrong.

## Out of scope

- A quality slider
- Resizing or dimension changes
- Rasterising SVG
- Converting animated GIF
