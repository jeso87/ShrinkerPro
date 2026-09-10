# Shrinker Pro — Design

**Date:** 2026-09-08
**Status:** Approved for planning
**Upstream:** [stefansl/image-shrinker](https://github.com/stefansl/image-shrinker) v1.6.5 (CC0-1.0)

## Summary

Shrinker Pro is a native SwiftUI macOS application for Apple Silicon that
reimplements Image Shrinker 1.6.5. Drag an image onto the window and it is
compressed in place or into a configured folder; the original is never
replaced.

Upstream is an Electron 11 app whose three compressors ship as x64-only
prebuilt binaries. On Apple Silicon they run only under Rosetta 2, and they
fail outright on a Mac without it. Shrinker Pro replaces the Electron shell
with a native app and the x64 binaries with statically-linked arm64 builds, so
the entire application is native.

Distribution is free and direct — not the Mac App Store — as a Developer ID
signed, notarized DMG.

## Goals

- Feature parity with Image Shrinker 1.6.5, minus two deliberate cuts (below).
- **Every Mach-O in the shipped bundle is arm64-only.** Not "arm64 native",
  not universal — no `x86_64` slice anywhere, including the app executable
  itself. See "Architecture enforcement" below, which makes this a release
  gate rather than an intention.
- Compression output stays byte-comparable with upstream for JPEG, PNG and GIF.
- Reproducible signed and notarized DMG from a single script.

## Non-goals

- Intel or universal builds. Apple Silicon only, enforced at release (see "Architecture enforcement").
- Mac App Store distribution and the sandbox entitlements it requires.
- New capabilities beyond parity: no WebP/AVIF output, no resize, no quality
  slider, no batch queue. These are plausible follow-ons, not this project.
- Windows and Linux. Upstream nominally targeted them and never tested them.

## Architecture

Three layers. The split exists so compression is testable without launching
a UI.

### App shell (SwiftUI)

- Main window: drop zone plus a results list showing each file's original
  size, new size, and percentage saved.
- Settings scene mirroring upstream's toggles.
- Menu commands, recent documents, and file-type associations declared via
  `CFBundleDocumentTypes` for svg, png, gif, jpg, jpeg.
- Files can arrive three ways: drag-and-drop onto the window, a "Choose
  Files…" picker, and Finder open events (`application(_:open:)`).

### ShrinkEngine (core)

Pure logic, no UI imports. Takes a file URL and a settings snapshot,
dispatches on lowercased path extension, returns a `ShrinkResult` of output
URL, original byte count, and new byte count. Unsupported extensions produce
a typed error rather than a dialog — presentation is the shell's job.

### Compressors

A `Compressor` protocol with four implementations. Three spawn a bundled
binary; SVG runs in-process.

| Format | Implementation | Invocation |
|---|---|---|
| JPEG | mozjpeg 4.1.5 `cjpeg` | `cjpeg -outfile OUT IN` |
| PNG | pngquant 3.0.3 | `pngquant -fo OUT IN` |
| GIF | gifsicle 1.96 | `gifsicle -o OUT IN -O=2 -i` |
| SVG | svgo 4.1.0 via JavaScriptCore | in-process, default preset |

Arguments are preserved verbatim from upstream `main.js` so output can be
diffed against Image Shrinker during verification.

### OutputPathResolver

Reimplements upstream's `generateNewPath`. This is the fiddliest logic in the
original and the easiest to get subtly wrong, so it is a separate type with
exhaustive tests. Rules, in order:

1. If `folderswitch` is false and a `savepath` is set, replace the directory
   with `savepath`.
2. If `subfolder` is true, append `minified/` to the directory.
3. Create the directory if absent.
4. Filename is `name + (suffix ? ".min" : "") + ext`.

### Settings

Six toggles in `UserDefaults`, matching upstream's defaults:

| Key | Default | Effect |
|---|---|---|
| `notification` | true | Post a notification when a file finishes (see below) |
| `folderswitch` | true | Save beside the original vs. to `savepath` |
| `savepath` | unset | Fixed destination when `folderswitch` is false |
| `clearlist` | false | Clear the results list between drops |
| `suffix` | true | Append `.min` to output filenames |
| `updatecheck` | true | Check for a newer release at launch |
| `subfolder` | false | Save into a `minified/` subdirectory |

Notifications use `UserNotifications`, which requires runtime authorization.
Authorization is requested lazily the first time a notification would be
posted, not at launch. If the user denies it, the toggle reflects the denial
and links to System Settings rather than silently doing nothing.

## Architecture enforcement

Apple has ended Intel Mac support with macOS 26 Tahoe, and Rosetta 2 is on a
published sunset path — full availability through macOS 26 and 27, then
narrowing to a limited subset for older unmaintained game frameworks. An app
that leans on translation anywhere has a deadline attached to it.

Shrinker Pro therefore treats "arm64 everywhere" as a verified property of the
build output, not a property of how it was written. Two mechanisms:

### Build settings

The Xcode target pins architecture explicitly. This is not the default:
`ARCHS_STANDARD` for macOS resolves to `arm64 x86_64`, so an unconfigured
Xcode project produces a **universal** binary with an Intel slice — silently
contradicting the non-goal above.

| Setting | Value |
|---|---|
| `ARCHS` | `arm64` |
| `EXCLUDED_ARCHS` | `x86_64` |
| `ONLY_ACTIVE_ARCH` (Release) | `NO` |
| `MACOSX_DEPLOYMENT_TARGET` | `14.0` |

Compressors are built with `-arch arm64 -mmacosx-version-min=14.0`, with no
universal `lipo` step at any point.

### Release gate

`scripts/verify-arch.sh` walks **every Mach-O in the built `.app`** — not just
the helpers — and fails on any of:

- a slice other than `arm64` (`lipo -archs` must output exactly `arm64`)
- a load command referencing anything outside `/usr/lib` or
  `/System/Library` (`otool -L`)
- an `LC_BUILD_VERSION` minos above the deployment target (`otool -l`)

It enumerates binaries by Mach-O magic rather than by directory, so a helper,
framework, or dylib added later is covered automatically instead of slipping
past a hardcoded path list.

The gate runs in three places: at the end of `build-compressors.sh`, as an
Xcode Run Script phase on Release builds, and in `release.sh` before
notarization is submitted. A failure stops the release.

Scope note: this governs *shipped* artifacts. Build-time tools (cmake, cargo,
autotools) are native arm64 on this machine but are not part of the bundle and
are not gated.

## The arm64 compressors

The core of the port. Binaries are **built from source as statically-linked
arm64 executables**, not vendored from Homebrew.

Homebrew bottles are unsuitable for distribution on two counts: they link
against `/opt/homebrew/lib/*.dylib`, which does not exist on an end user's
machine, and they are built per-macOS-version (currently `arm64_tahoe` only).

`scripts/build-compressors.sh` fetches, builds, and stages all three:

| Tool | Version | Build |
|---|---|---|
| mozjpeg `cjpeg` | 4.1.5 | cmake, `-DENABLE_SHARED=OFF -DENABLE_STATIC=ON` |
| pngquant | 3.0.3 | cargo release build, static libimagequant |
| gifsicle | 1.96 | autotools, `--disable-gifview --disable-gifdiff` |

All three are built with `-mmacosx-version-min=14.0` to match the app's
deployment target.

**Acceptance gate:** for each produced binary, `lipo -archs` reports `arm64`
only, and `otool -L` lists nothing outside `/usr/lib`. The build script fails
if either check fails, and the same checks run as unit tests so a bad binary
cannot reach a release.

### Build prerequisites

Not currently installed on the development machine; `scripts/bootstrap.sh`
installs them:

- `cmake` — mozjpeg
- Rust toolchain via `rustup` — pngquant 3.x, whose libimagequant is Rust

Already present: `autoconf` 2.73, `pkg-config` 2.5.1, Xcode 26.6.

Note: `xcode-select -p` currently points at `/Library/Developer/CommandLineTools`,
so `xcodebuild` is not on `PATH`. Bootstrap sets it to
`/Applications/Xcode.app/Contents/Developer`.

### JPEG temp-file workaround

Upstream issue #54: when `suffix` is false and `subfolder` is false, the
output path equals the input path, and `cjpeg` reading and writing the same
file corrupts it. Upstream copies the original to `OUT.tmp`, compresses from
the copy, then deletes it. Shrinker Pro keeps this behavior, and it is covered
by a regression test.

### SVG via JavaScriptCore

svgo has no native equivalent, and bundling Node to run it would add ~50 MB
for one format. Instead, svgo 4.1.0's `dist/svgo.browser.js` — which has no
Node API dependencies — is bundled as a resource and evaluated in a
`JSContext`. JavaScriptCore is a system framework, so this costs roughly 1 MB
of JavaScript and no native binary.

Consequence for signing: JavaScriptCore's JIT requires
`com.apple.security.cs.allow-jit` under the hardened runtime.

## Build and distribution

An Xcode project (`ShrinkerPro.xcodeproj`) with a single app target.

- A **Copy Files** build phase embeds the three compressors into
  `Contents/Helpers/`.
- An **asset catalog** holds the app icon; `actool` produces the icon set.
- `xcodebuild archive` then `exportArchive` produces a signed `.app`.
- `notarytool submit --wait` then `stapler staple` notarizes it.
- `hdiutil` builds the DMG, reusing upstream's background artwork.

Scripts under `scripts/`: `bootstrap.sh`, `build-compressors.sh`,
`verify-arch.sh`, `release.sh` (archive → export → **verify-arch** → notarize →
staple → DMG).

### Signing

- Identity: `Developer ID Application: Eight-Seven Inc. (LY424U3HLD)`
- Bundle identifier: `com.eightseven.shrinkerpro`
- Hardened runtime enabled.
- Helper binaries are signed individually, inside-out, before the app.
- Not sandboxed — direct distribution, so no App Sandbox entitlement.

Entitlements:

| Entitlement | Reason |
|---|---|
| `com.apple.security.cs.allow-jit` | JavaScriptCore JIT for svgo |

Upstream's `com.apple.security.cs.allow-unsigned-executable-memory` was an
Electron requirement and is deliberately not carried over.

Notarization credentials come from the environment, never from the repo.

## Deliberate cuts from parity

**TouchBar.** Upstream exposes a file picker through a `TouchBarButton`. No
Mac has shipped a Touch Bar since 2023. The capability is preserved as a
"Choose Files…" button and a File menu item; the Touch Bar API is not.

**Auto-update.** Upstream uses `electron-updater`, which has no Swift
equivalent within this scope. The `updatecheck` setting is preserved and
performs a lightweight check: a `GET` against the GitHub releases API for the
distribution repository, comparing the latest tag to `CFBundleShortVersionString`
and offering to open the releases page when a newer version exists. The
repository URL is a build setting, so it can be filled in once the project has
a public home; until then the check is disabled by default and the setting is
shown as unavailable. Sparkle is the natural follow-on if silent updates are
wanted later; it is out of scope here.

## Testing

- **`OutputPathResolver`** — all eight combinations of `folderswitch`,
  `suffix`, and `subfolder`, plus the `savepath`-set and `savepath`-unset
  cases.
- **Each compressor** — against a checked-in fixture, asserting the output is
  smaller than the input and begins with valid magic bytes for its format.
- **JPEG in-place regression** — suffix off and subfolder off produces a valid,
  smaller JPEG rather than a corrupt file.
- **Architecture guard** — `verify-arch.sh` over every Mach-O in the built
  bundle, the app executable included. Fails the build, not just the suite.
- **Universal-slice regression** — a test that deliberately `lipo`-fattens a
  fixture binary and asserts the guard rejects it, so the gate is known to
  actually catch an Intel slice rather than passing vacuously.
- **SVG** — svgo loads in `JSContext` and shrinks a fixture, confirming the
  browser bundle needs no Node shims.

## Repository layout

```
ShrinkerPro.xcodeproj
Sources/ShrinkerPro/
  ShrinkerProApp.swift
  Views/          DropZoneView, ResultsListView, SettingsView
  Core/           ShrinkEngine, Compressor, OutputPathResolver, Settings
  Resources/      svgo.browser.js, Assets.xcassets
Tests/ShrinkerProTests/
  Fixtures/       sample.jpg, sample.png, sample.gif, sample.svg
scripts/          bootstrap.sh, build-compressors.sh, verify-arch.sh, release.sh
build/            entitlements.plist, dmg background
vendor/compressors/   built arm64 binaries (gitignored)
docs/design/specs/
```

`upstream-image-shrinker/` remains on disk as a gitignored reference for
parity checking during the port, and is deleted once parity is verified.

Upstream is CC0-1.0, so attribution is not required, but the README credits
Stefan Schulz-Lauterbach and the four compression projects regardless.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Host | Native SwiftUI | ~5 MB vs. ~250 MB, instant launch, genuinely arm64 |
| Compressors | Same CLIs, built arm64 | Output stays comparable to upstream |
| Delivery | Vendored into bundle | Self-contained; no Homebrew dependency |
| pngquant | 3.0.3 (Rust) | Current release, better quantization |
| Deployment target | macOS 14 Sonoma | Mature SwiftUI; covers supported Apple Silicon |
| Build system | Xcode project | Handles bundle assembly, signing, asset catalog |
| Repo | Clean new repo | No merge path back to an Electron codebase |
| Icon | New artwork | Distinct identity from Image Shrinker |

## Risks

| Risk | Mitigation |
|---|---|
| pngquant's Rust build fails to link statically | Fall back to pngquant 2.17.0, pure C; already validated as a viable option |
| Notarization rejects an embedded helper | Sign inside-out and verify with `codesign -vvv --deep --strict` before submitting |
| svgo browser bundle needs a Node shim in JSC | Detect early — the SVG test is written first, before the UI |
| mozjpeg needs `nasm` | arm64 uses NEON intrinsics, not x86 SIMD; confirm during the first build |
| Xcode silently reintroduces an x86_64 slice via `ARCHS_STANDARD` | `EXCLUDED_ARCHS=x86_64` plus the release gate, which is itself tested against a deliberately fattened binary |
