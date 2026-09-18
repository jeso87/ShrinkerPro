# Shrinker Pro — A Session Center Crop

**Date:** 2026-09-17

A shape, set in the session settings bar for the length of a session: what every
image is cut down to, from the center. Blank means no cropping, which is today's
behaviour exactly. Builds on `2026-09-16-max-size-resize-design.md`, whose §10 listed
"separate width and height caps, or a crop" as out of scope — this is that item — and
on `2026-09-16-session-settings-bar-design.md`, whose §1 recorded that the bar was
collapsed *so a fourth control could be added later*. This is that control.

## 1. What it does

> **The largest centered rectangle of the target shape is cut out of the
> orientation-corrected image. In pixel mode that rectangle is then scaled down to the
> target size. Nothing is ever scaled up.**

Two modes, one control:

- **`1200 × 1200 px`** — crop to that shape, then scale to exactly that size.
- **`1 : 1`** — crop to that shape and leave the resolution alone. The session's max
  size, if set, still applies to what is left.

Three consequences are stated here rather than discovered:

**The target is applied literally.** A portrait photo with a 16:9 target comes out as a
16:9 landscape strip, not a 9:16 portrait one. Matching the target's orientation to each
source was considered and rejected: it makes a batch come out in two different shapes,
which defeats the reason someone sets a fixed crop, and it is a branch on orientation of
exactly the kind §1 of the max size spec argued its way out of.

**Nothing is enlarged.** An 800×600 source asked for 1200×1200 comes out **600×600** —
the right shape, smaller than asked. This keeps the never-grow rule the app has always
had. It also means a mixed batch does not come out uniform, which is the opposite of
what a fixed crop is usually for, so the tooltip says so.

**A crop applies to nearly every file**, unlike a max size, which only touches files
over the cap. Only a source whose aspect already matches escapes it.

Scope is every raster format the app accepts, plus GIF (§6). SVG is excluded for the
reason already recorded: it is vector and has no pixels to cut.

## 2. Where the value lives

`OutputSettings.cropTarget: CropTarget?`, beside `sessionFormat` and `maxDimension` and
sharing their lifetime: set in the main window, never written to UserDefaults, gone at
quit. Layered onto the settings snapshot in `AppModel` at the same point and for the same
reason — one snapshot per batch, so changing the field mid-drop cannot split one drop
across two behaviours.

There is deliberately **no persisted default in Settings**, for the reason
`2026-09-10-format-conversion.md` gave first and the max size spec repeated: a stored
crop is a setting that changes every file "silently, and forever". A crop is the most
destructive of the three — it throws pixels away — so the argument applies to it hardest.

`nil` is the off state, and off must cost nothing. With no crop and no max size, no
dimension is read, no predicate is computed, and every file takes byte-for-byte the route
it takes today. Stated as a requirement rather than an expectation because §9 tests it.

## 3. Composition with the max size

**Crop, then the crop's own pixel target, then the cap — and the cap only in ratio
mode.** Each step can only shrink what the last produced, which is why "never upscale"
needs no clause of its own: it is the shape of the function.

| set | result |
|---|---|
| ratio only | crop to shape, keep the cropped size |
| ratio + cap | crop to shape, then the cap over what is left |
| pixels only | crop to shape, scale down to W×H — or to the cropped size, if that is smaller |
| pixels + cap | **refused**: the crop has already set the size |

**A pixel crop and a max size are two answers to one question**, and the crop is the more
specific of them. There is no size a cap could impose that smaller numbers in the crop
would not state better, so a cap can only contradict it.

Composing them was implemented first, and it worked: `Crop 1200×1200` with `Max 500px`
produced a 500×500 file — correct arithmetic, and a file the size of neither thing the
user had typed. It needed a warning beside the max size field to be survivable, and a
warning about two controls fighting is a sign that one of them should not be there.

So neither front end lets the pair through. The window disables and dims the max size
field while a pixel crop is set, naming the size that will be written and both ways back
(switch the crop to a ratio, or clear it). The CLI refuses `--crop WxH` alongside
`--max-size` as contradictory flags, rather than accepting a flag and silently dropping
it. A ratio crop is the opposite case throughout: it says nothing about size, the cap is
the only thing sizing the result, and the two compose exactly as they did before cropping
existed.

**Ratio is therefore the default mode.** It is the milder of the two — it leaves every
other control in the bar alone — and it is the one that composes.

## 4. Reading the size

The crop is measured against the file's **oriented** size, from the same
`ImageMetadata.header(of:)` read the router already pays for. The reason is §3 of the max
size spec, made sharper: a cap is one number and survives an axis swap, but a rectangle
does not. Cropping the stored buffer of a portrait phone photo would take the rectangle
out of the wrong axis and produce a file that is the requested shape on disk and the
wrong shape on screen.

For the same reason the crop itself is applied **after** the orientation is baked into
the pixels, not before — see §5. The two are different statements and both are needed:
the *decision* uses the oriented size, and the *cut* happens on oriented pixels.

## 5. Doing the crop

`ImageIOCompressor` grows two steps after the orientation bake it already performs:
`CGImage.cropping(to:)` with the centered rectangle, and — only when the result is not
already the target size — one `CGContext` draw at high interpolation quality.

The rectangle is recomputed from the dimensions of the image actually in hand rather than
from anything predicted earlier, because `kCGImageSourceThumbnailMaxPixelSize` is a bound
and not an exact request. The existing max size tests assert with `accuracy: 1` for the
same reason.

**The decode stays cheap, and the arithmetic for that is one line.** A crop is a
*sub-rectangle*, so shrinking the whole image by the factor the crop needs leaves the crop
at exactly its finished size:

```
s        = outputSize.width / cropRect.width      (never above 1, so it cannot upscale)
thumbMax = ceil(max(sourceWidth, sourceHeight) × s)
```

`max(width, height)` is the same number before and after rotation, so there is no axis
swap to get wrong here — rotating swaps the axes without changing the ratio between any
two lengths. A 48 megapixel photo cropped to 1200×1200 therefore decodes at 1600×1200
rather than 8000×6000, and `ImageMetadata.applyingOrientation` then allocates the small
buffer rather than the large one, which doubles the saving on any rotated photo.

In ratio-only mode `s` is 1, no thumbnail is taken, and the file gets the full decode it
always got. That is correct rather than a gap: the output genuinely is those pixels.

The single-lossy-hop guarantee is untouched. Cropping happens inside the existing decode
path and adds no encode, so `IntermediateConversionCompressor` still hands cjpeg, cwebp
and pngquant a carrier that is already the final shape and the final size, and still
passes `quality: nil` to it.

## 6. GIF

GIF keeps its short-circuit and is cropped by `gifsicle`, the only tool here that can cut
an animation without flattening it. Three findings from the spike, all measured against
the vendored binary:

**`--crop X,Y+WxH` must appear before the input path.** It is an *image* option, applied
to "the following input frames". Appended after the input it is accepted and silently
does nothing.

**`--unoptimize` must come before it, and this is the finding that decides the feature.**
`gifsicle`'s `analyze_crop` measures the crop against the bounding box of the input
frames, not the logical screen. On an optimised GIF whose frames do not reach the edges
of the screen, a rectangle computed from the screen size is either silently clipped or
rejected outright. Both were reproduced on a 300×300 GIF whose frames are 120×120 at
(10,10):

| argv | asked for | got |
|---|---|---|
| `--crop 0,65+300x169` | 300×169 | **130×65**, no error |
| `--crop 0,0+300x300` | 300×300 | **130×130**, no error |
| `--crop 250,250+300x300` | 300×300 | `cropping dimensions don't fit image`, **exit 1** |
| `--unoptimize --crop 0,65+300x169 --resize-fit 300x169` | 300×169 | **300×169** ✓ |
| `--unoptimize --crop 0,0+300x300` | 300×300 | **300×300** ✓ |

`--unoptimize` expands every frame to the full logical screen, which makes the bounding
box and the screen the same rectangle and the crop exact. `-O2`, already in the argv,
re-optimises afterwards: on the 120×120 fixture, cropping with and without `--unoptimize`
produced **byte-identical 590 byte output** with all 12 frames, so correctness here is
free. It is passed only when cropping; a resize alone has never had this problem, because
it scales the logical screen rather than indexing into it.

**ImageIO reports a GIF's logical screen size**, not frame zero's — verified as 300×300
for the file above. That is the coordinate space `--crop` uses once `--unoptimize` has
run, so the rectangle the engine computes from `ImageMetadata.header(of:)` needs no
translation.

**`--resize-fit`, not `--resize`.** `--resize-fit` only ever shrinks, which is §1's
never-upscale rule expressed by the tool rather than reimplemented beside it. The crop has
already made the aspect exact, so "fit" lands on exactly the requested size, and because
the resolved output size already has the cap folded into it, one `--resize-fit` pair
carries the crop target and the max size together.

No silent retry-without-crop fallback. That would make an explicit instruction disappear
with nothing on screen to say why, which is the failure the never-grow exemption in §8
exists to avoid.

## 7. The controls

A fourth row in the expanded session bar, on the existing 104pt label column:

```
Crop to      [ 1200 ] × [ 1200 ]   [ px | ratio ]
```

Two `DigitsOnlyField`s in the max size field's chrome, and a two-segment picker for the
mode. **The separator does double duty** — `×` in pixel mode, `:` in ratio mode — which is
the cheapest possible signal that the mode changed, placed exactly where the numbers are,
and it makes both modes read as what people already write.

A segmented control rather than a third `.menu` picker: the mode is binary, and the two
numbers mean something entirely different depending on it, so it has to be readable
without opening anything. This is a third control idiom in a four-row panel and is
recorded here as a deviation rather than left for the designer to find.

**Both sides are required, or there is no crop.** A half-typed `1200 × ` must mean
nothing, or someone types one number, drags a folder in, and every file is cropped to a
height nobody chose. This is the same failure the live parse was introduced to prevent,
one field along.

The collapsed summary gains a fourth part — `Crop 1200×1200`, `Crop 1:1`, or `No crop` —
keeping the format of the existing three.

**The cap-beats-crop warning.** When pixel mode is set and the max size is smaller than
the crop, the warning glyph beside the max size row says which number will actually win.
It uses the space the PNG growth warning already reserves.

## 8. The never-grow guard, and routing

`RoutingContext.needsResize` becomes `needsPixelRework` and `ShrinkPlan.wasResized`
becomes `dimensionsChanged`: a crop is a **third reason for the identical rewrite**, not a
new kind of rewrite. None of the three vendored CLI encoders that can be handed the user's
file directly can crop it, any more than they can scale or rotate it, so the rewrite table
in §4 of the max size spec applies unchanged and no route case and no compressor type is
added.

The guard becomes `if plan.isSameFormat, !plan.dimensionsChanged, shrunkBytes >=
originalBytes`, which is the exemption resizing and converting already have, for the
reason recorded beside it: growth the user explicitly asked for is not the guard's
business. The consequence is worth stating, because it is larger here than for a max size:
since a crop touches nearly every file, setting one turns the guard off for nearly the
whole batch, and a ratio-only crop of already well-compressed JPEGs will sometimes write a
slightly larger file.

## 9. Tests

- **`CropGeometryTests`** — the centered rectangle for landscape, portrait and square
  sources against landscape, portrait and square targets; the odd-pixel rule; never a
  zero-area rect; idempotence; and a sweep asserting the rectangle is always inside the
  frame.
- **`ShrinkEngineTests`** — per route, the requested size exactly; ratio mode at source
  resolution; a source too small coming out at the cropped size rather than upscaled; a
  portrait source with a landscape target coming out landscape, named so nobody "fixes"
  it; crop with max size, including the §3 surprise; and the regression net from §2 — with
  neither setting the whole plan reproduces today's exactly.
- **The orientation test**, which is the one that matters most: a rotated fixture cropped
  to 1:1 is centered on what a viewer sees, not on the stored buffer. A wrongly centered
  square still looks like a square, so nothing else would catch it.
- **GIF** — every frame survives a crop, and a cropped-and-resized GIF is exactly the
  requested size. Both on a normal fixture and on an optimised one with offset frames,
  which is the case §6 exists for.
- **`CropField` and `SessionBarState`** — validation, the both-sides rule, the summary in
  both modes, and the cap-beats-crop predicate.
- **`AppModelTests`** — the crop reaches the engine, never reaches UserDefaults, and is
  cleared by Reset.
- **`CommandLineOptionsTests`** — `--crop WxH` and `--crop W:H`, every error case, and the
  flag's presence in `--help`.

## 10. Out of scope

Stated so they are decisions rather than gaps:

- a nine-point anchor; the crop is always centered
- matching the target's orientation to each source (§1)
- upscaling to fill an exact size (§1)
- a persisted crop default in Settings (§2)
- showing output dimensions in the result rows
- SVG (§1)
- a crop preview
