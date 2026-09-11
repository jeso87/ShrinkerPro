# Changelog

Notable changes per release. Downloads and signed artifacts are on the
[releases page](https://github.com/jeso87/ShrinkerPro/releases); existing
installs are offered updates automatically by Sparkle.

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
