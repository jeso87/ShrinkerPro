# Shrinker Pro

Minify images and graphics with one drop. A native, Apple Silicon macOS app.

Drag PNG, JPEG, GIF, SVG, WebP, AVIF, or HEIC files onto the window and
Shrinker Pro writes a smaller copy beside the original — or wherever you tell
it to. Originals are never replaced unless you ask for that (turn off both the
`.min` suffix and the `minified/` subfolder in Settings).

## Why this exists

Shrinker Pro is a native rewrite of [Image Shrinker](https://github.com/stefansl/image-shrinker)
by Stefan Schulz-Lauterbach. The original is an Electron app whose compression
binaries ship as x64-only builds, so on Apple Silicon they run through Rosetta 2
and fail outright without it. Apple ended Intel Mac support with macOS 26 Tahoe,
and Rosetta 2 is on a published sunset path — full availability through macOS 26
and 27, then narrowing to a limited subset for older game frameworks. Anything
leaning on translation has a deadline attached to it.

Shrinker Pro replaces the Electron shell with SwiftUI and rebuilds the same
compressors as static arm64 binaries. Every Mach-O in the bundle is arm64-only,
verified by a release gate (`scripts/verify-arch.sh`) that blocks notarization
if anything else appears.

## Compression

Each format is optimised in place by its own encoder:

| Format | Tool |
|---|---|
| JPEG | [mozjpeg](https://github.com/mozilla/mozjpeg) 4.1.5 (`cjpeg`) |
| PNG | [pngquant](https://pngquant.org/) 3.0.3 |
| GIF | [gifsicle](https://github.com/kohler/gifsicle) 1.96 |
| SVG | [svgo](https://github.com/svg/svgo) 4.1.0, run in JavaScriptCore |
| WebP | [libwebp](https://developers.google.com/speed/webp) 1.6.0 (`cwebp`) |
| AVIF | ImageIO (macOS system framework) |

cjpeg, pngquant, gifsicle, and cwebp are built from source as static arm64
binaries and shipped in `Contents/Helpers/`. svgo runs entirely inside a
`JSContext` — no Node.js, no bundled interpreter binary. AVIF and HEIC are
handled by ImageIO, which encodes and decodes both natively on macOS; nothing
is vendored for them.

HEIC has no in-place optimiser here — it is always converted (see below).

## Conversion

Settings carries one conversion rule per input format, so you can convert a
single format without touching the rest — screenshots to WebP, say, while
JPEGs stay JPEGs.

| Input | Options | Default |
|---|---|---|
| PNG | Keep PNG · JPEG · WebP · AVIF | Keep PNG |
| JPEG | Keep JPEG · JPEG · WebP · AVIF | Keep JPEG |
| HEIC / HEIF | JPEG · WebP · AVIF | JPEG |
| WebP | Keep WebP · JPEG · WebP · AVIF | Keep WebP |
| AVIF | Keep AVIF · JPEG · WebP · AVIF | Keep AVIF |

HEIC/HEIF has no "keep" option. It is a camera capture format that most tools
outside Apple's ecosystem still can't open, so leaving it as-is is rarely what
anyone wants — JPEG is the default, and WebP or AVIF are there if you'd rather
have a modern format.

**SVG and GIF have no rule and never convert.** SVG is vector, and GIF is
usually animated; converting either would destroy what makes it useful. This
is stated in the Settings panel too, so their absence doesn't read as an
oversight.

Conversions encode at quality 80 (`cwebp -q 80`, or `0.80` for ImageIO's
lossy targets). Where an encoder can't read the source format directly — cjpeg
reads neither PNG, WebP, AVIF nor HEIC — the pixels are relayed through a
lossless intermediate rather than a second lossy hop. `ConversionRouter`
decides the route for every input × rule combination, and is a pure function
with no file or process access, so all of it is enumerable in tests.

Converting to a format's own type (JPEG→JPEG, WebP→WebP, AVIF→AVIF) takes the
same fast path as "keep" — it compresses, it does not round-trip.

## What it does — and doesn't do

- Drop files or a folder anywhere on the window, or use "Open Files…". The
  entire window is a drop target, not just the dashed zone.
- Output goes beside the original by default, or to a folder you choose, with
  an optional `.min` suffix and/or `minified/` subfolder — configurable in
  Settings.
- Results accumulate for the session, showing each file's before/after size
  and percentage saved. "Clear" empties the list; a Settings toggle can clear
  it automatically on each new drop instead.
- Click a result row to reveal the file in Finder. Hover for the full path.
- Optional notification when a batch finishes. If notifications are turned off
  for the app in System Settings, the panel says so rather than failing quietly.
- Settings persist across launches (backed by `UserDefaults`).
- Updates via [Sparkle](https://sparkle-project.org/) 2.9.6: "Check for
  Updates…" in the app menu, plus an automatic background check gated by
  the same "Check for updates" toggle in Settings. Sparkle polls
  `appcast.xml` (published by `scripts/release.sh`, served from this repo's
  GitHub Pages) and verifies every update's EdDSA signature before offering
  to install it.

## Requirements

macOS 14 Sonoma or later, Apple Silicon.

## Build

```shell
./scripts/bootstrap.sh          # Xcode path, xcodegen, cmake, autoconf/automake, Node, Rust
./scripts/build-compressors.sh  # static arm64 cjpeg, pngquant, gifsicle, cwebp
./scripts/prepare-svgo.sh       # svgo bundle, ESM export stripped for JSContext
./scripts/prepare-sparkle.sh    # Sparkle.framework, fetched and thinned to arm64
./scripts/make-icon.sh          # app icon
xcodegen generate
xcodebuild -scheme ShrinkerPro build
```

`build-compressors.sh` also builds libpng 1.6.58 and libwebp 1.6.0 from source,
because cwebp needs PNG and JPEG *input* decoding and Homebrew's libraries are
dynamic. It reuses mozjpeg's static libjpeg for the JPEG side. Every library is
linked into the helper binaries; no dylibs are shipped.

`bootstrap.sh` exports `DEVELOPER_DIR` for the invocation rather than running
`xcode-select -s` — it doesn't require `sudo` and doesn't touch the
system-wide Xcode path. It also installs Node if `npm` isn't already on
`PATH`: `prepare-svgo.sh` fetches the svgo bundle with `npm pack`. That is
the only thing Node is used for — no Node runtime is bundled, and svgo runs
inside JavaScriptCore in the shipped app.

Building from source needs Xcode 15+ and Homebrew.

`./scripts/verify-arch.sh <path-to-.app>` audits a built bundle: every Mach-O
must be arm64-only, target macOS 14.0 or lower, and link nothing outside
`/usr/lib` and `/System/Library`. It fails closed — a missing target or zero
files examined is an error, not a pass.

Release a signed, notarized DMG with `./scripts/release.sh`.

## Credits

- [Image Shrinker](https://github.com/stefansl/image-shrinker) by Stefan
  Schulz-Lauterbach, released under CC0-1.0 — the original this is based on.
  CC0 requires no attribution; it's given anyway.
- [mozjpeg](https://github.com/mozilla/mozjpeg), [pngquant](https://pngquant.org/),
  [gifsicle](https://github.com/kohler/gifsicle), [libwebp](https://developers.google.com/speed/webp),
  and [svgo](https://github.com/svg/svgo), which do the actual compression.
