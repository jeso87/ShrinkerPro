# Changelog

Notable changes per release. Downloads and signed artifacts are on the
[releases page](https://github.com/jeso87/ShrinkerPro/releases); existing
installs are offered updates automatically by Sparkle.

## 1.2.0 — 2026-09-13

### Added

**Quality.** Settings now offers Super Low, Low, Standard or High for the lossy
encoders, and the same control sits in the window footer so it can be changed
between one drop and the next without opening a panel. Standard is the default
and produces what earlier versions did — upgrading changes nothing about your
output unless you choose to.

It applies to JPEG, WebP, AVIF and HEIC. PNG and GIF are deliberately left out:
the tools that optimise them have no comparable setting, so those files come out
the same whichever level you pick.

**A command-line tool.** `shrinker` runs the same compression engine without a
window — for scripts, for build steps, and for AI assistants that can run a
command but cannot drag a file onto a drop zone.

```
brew install jeso87/tap/shrinker

shrinker photo.jpg
shrinker --quality super-low --to webp ./screenshots
shrinker --json --quality 85 diagram.jpg
```

It writes a `.min` copy beside each original and only overwrites with
`--in-place`; folders are searched the same way dropping one on the window
searches them; and `--json` prints one machine-readable line per file.

Two differences from the app worth knowing. It never reads your saved
preferences, so nothing converts unless `--to` asks — except HEIC, which has no
"keep" option anywhere and always becomes a JPEG. And `--quality` takes a plain
number as well as a level name, for hitting a size target the four named stops
don't reach.

### Fixed

**Compressing a file can no longer make it bigger.** Re-encoding an image that
is already compressed can produce a larger file than the one you started with,
and the app used to write that result and report it as a saving. Now, when a
same-format result comes out larger than the source, it is discarded and your
original is left untouched, reported as 0% saved.

This was already happening before this release in one case: re-optimising a WebP
produced a file about 36 bytes larger every time. Converting between formats is
deliberately exempt — a photo converted to lossless PNG is expected to grow, and
that is the thing you asked for.

### Changed

**The main window has a footer.** "Convert all to" has moved from above the
results list to a bar pinned along the bottom, now as a dropdown, with Quality
beside it. The history scrolls above them, so both controls stay put however
long the list gets. On a narrow window they stack rather than crowd.

"Off" is now "App default", which says what actually happens — your stored
per-format rules apply — rather than only what doesn't.

The warning that PNG makes photographs larger is now a marker beside the control
rather than a line of text that appeared and disappeared, so the footer never
changes height while you use it.

## 1.1.0 — 2026-09-11

Photos keep their rotation, metadata is now yours to control, and there's a
one-off "convert everything to X" in the main window.

### Fixed

**Photos no longer come out rotated the wrong way.** EXIF orientation is now
applied to the image itself rather than passed along as a tag, so a portrait
iPhone photo stays upright in Preview, Finder and browsers alike, whatever
format it is converted to.

This affected HEIC → JPEG — the default rule, so it hit iPhone photos dropped
on the app with no settings changed — along with every AVIF target, every WebP
output, and HEIC/AVIF re-encodes. JPEG → JPEG was never affected, which is why
only some images were coming back wrong.

### Added

**Metadata control.** Settings now offers three choices: keep all metadata,
keep copyright and credit only, or keep none. The default is all, so nothing
you currently get is lost on upgrade.

"Copyright and credit only" is the one to reach for before posting a photo
publicly — it keeps the fields that say who made the image and drops GPS
coordinates, capture time and camera details.

Rotation is not covered by any of the three. It is always applied to the image,
whichever option you choose.

**Convert all to.** A bar above the results list overrides every per-format
conversion rule at once — JPEG, WebP, AVIF or PNG — for as long as the app is
open. It leaves your stored settings untouched and is gone the next time you
launch. It lives in the window rather than in Settings so it is visible the
whole time it is on.

PNG is available here and nowhere else. It is lossless, so photographs
converted to it usually get larger; the app says so when you pick it.

SVG and GIF ignore the override, exactly as they ignore the stored rules.

### Changed

**"Add .min suffix to shrunken files" is now "Keep original files."** Same
setting, same behaviour, same default — the old label described the filename
rather than what turning it off costs you, which is your originals. Your
existing preference carries over untouched.

## 1.0.2 — 2026-09-10

Fixed notifications: they now appear at all, and a batch posts one notification
with the total saved rather than one per file.

## 1.0.1 — 2026-09-10

New app icon, with the app's palette matched to it. Icon assets recompressed.

## 1.0.0 — 2026-09-10

Initial release. A native SwiftUI rewrite of
[Image Shrinker](https://github.com/stefansl/image-shrinker) for Apple Silicon.

- PNG, JPEG, GIF, SVG, WebP, AVIF and HEIC input, each compressed by a
  dedicated encoder — mozjpeg, pngquant, gifsicle and cwebp built from source
  as static arm64 binaries, svgo in JavaScriptCore, AVIF and HEIC via ImageIO.
- Per-format conversion rules to JPEG, WebP or AVIF. SVG and GIF never convert.
- Every Mach-O in the bundle is arm64-only, enforced by a release gate that
  blocks notarization if anything else appears.
- Auto-updates via Sparkle, with every update's EdDSA signature verified.
- MIT licensed, with GPL corresponding source published alongside each release.
