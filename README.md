# Shrinker Pro

Minify images and graphics with one drop. A native, Apple Silicon macOS app.

Drag PNG, JPG, GIF, or SVG files onto the window and Shrinker Pro writes a
smaller copy beside the original — or wherever you tell it to. Originals are
never replaced unless you ask for that (turn off both the `.min` suffix and
the `minified/` subfolder in Settings).

## Why this exists

Shrinker Pro is a native rewrite of [Image Shrinker](https://github.com/stefansl/image-shrinker)
by Stefan Schulz-Lauterbach. The original is an Electron app whose compression
binaries ship as x64-only builds, so on Apple Silicon they run through Rosetta 2
and fail outright without it. With Intel support ending in macOS 26 and Rosetta
on a sunset path, that foundation has a deadline.

Shrinker Pro replaces the Electron shell with SwiftUI and rebuilds the same
compressors as static arm64 binaries. Every Mach-O in the bundle is arm64-only,
verified by a release gate (`scripts/verify-arch.sh`) that blocks notarization
if anything else appears.

## Compression

| Format | Tool |
|---|---|
| JPEG | [mozjpeg](https://github.com/mozilla/mozjpeg) 4.1.5 |
| PNG | [pngquant](https://pngquant.org/) 3.0.3 |
| GIF | [gifsicle](https://github.com/kohler/gifsicle) 1.96 |
| SVG | [svgo](https://github.com/svg/svgo) 4.1.0, run in JavaScriptCore |

mozjpeg, pngquant, and gifsicle are built from source as static arm64
binaries and shipped in `Contents/Helpers/`. svgo runs entirely inside a
`JSContext` — no Node.js, no bundled interpreter binary.

## What it does — and doesn't do

- Drop files, a folder, or use "Open Files…" to shrink PNG, JPG, GIF, and SVG.
- Output goes beside the original by default, or to a folder you choose, with
  an optional `.min` suffix and/or `minified/` subfolder — configurable in
  Settings.
- Click a result row to reveal the file in Finder.
- Settings persist across launches (backed by `UserDefaults`).
- It does **not** auto-update. A version check runs against a GitHub
  releases API if `SPRepository` in `Info.plist` is set, but that key ships
  empty, so the check always reports "not configured" and no update banner
  ever appears. There is no installer or background updater.

## Requirements

macOS 14 Sonoma or later, Apple Silicon.

## Build

```shell
./scripts/bootstrap.sh          # Xcode path, xcodegen, cmake, autoconf/automake, Node, Rust
./scripts/build-compressors.sh  # static arm64 mozjpeg, pngquant, gifsicle
./scripts/prepare-svgo.sh       # svgo bundle, ESM export stripped for JSContext
./scripts/make-icon.sh          # app icon
xcodegen generate
xcodebuild -scheme ShrinkerPro build
```

`bootstrap.sh` exports `DEVELOPER_DIR` for the invocation rather than running
`xcode-select -s` — it doesn't require `sudo` and doesn't touch the
system-wide Xcode path. It also installs Node if `npm` isn't already on
`PATH`: `prepare-svgo.sh` fetches the svgo bundle with `npm pack`. That is
the only thing Node is used for — no Node runtime is bundled, and svgo runs
inside JavaScriptCore in the shipped app.

Building from source needs Xcode 15+ and Homebrew.

Release a signed, notarized DMG with `./scripts/release.sh`.

## Credits

- [Image Shrinker](https://github.com/stefansl/image-shrinker) by Stefan
  Schulz-Lauterbach, released under CC0-1.0 — the original this is based on.
  CC0 requires no attribution; it's given anyway.
- [mozjpeg](https://github.com/mozilla/mozjpeg), [pngquant](https://pngquant.org/),
  [gifsicle](https://github.com/kohler/gifsicle), and [svgo](https://github.com/svg/svgo),
  which do the actual compression.
