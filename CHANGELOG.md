# Changelog

Notable changes per release. Downloads and signed artifacts are on the
[releases page](https://github.com/jeso87/ShrinkerPro/releases); existing
installs are offered updates automatically by Sparkle.

## 1.4.0 — 2026-09-17

### Added

**Crop from the center.** A fourth control in the session bar takes two numbers
and a choice of what they mean. **`16 : 9`** crops the largest centered
rectangle of that shape out of every image and leaves the resolution alone.
**`1200 × 1200 px`** crops to that shape and then scales it down to exactly that
size — which is what you want for a folder of product photos that all have to
come out one size.

Nothing is ever enlarged: an 800×600 image asked for 1200×1200 comes out
600×600, the right shape and smaller than asked. The shape is used exactly as
typed, so a portrait photo cropped to 16:9 comes out as a landscape strip rather
than being quietly turned on its side to suit. Both consequences are stated in
the control's own tooltip rather than left to be discovered.

Every still format is cropped by the same code that already handles rotation and
resizing, so a PNG and a WebP given the same numbers match. Animated GIFs keep
every frame — gifsicle does the work, because an ImageIO round trip would write
a still. SVG is unaffected; it is vector, so it has no pixels to cut. And like
the format override and the max size beside it, the crop lasts for the session
and is never written to disk.

Both numbers are required. With one filled in there is no shape to crop to, so
the panel will not close and nothing is shrunk until the pair is finished or
cleared — running a whole batch as though the number had never been typed is not
undoable once the originals have been replaced.

A pixel crop sets the output size outright, so it takes the max size out of
play: the window dims that field, and the command line refuses `--crop 1200x1200`
alongside `--max-size`. A ratio crop says nothing about size, so the two still
compose exactly as they did.

The headless `shrinker` command gains the same thing as `--crop 16:9` or
`--crop 1200x1200`.

### Fixed

**The Settings window can be read on a small screen.** It is a little over
1000 points tall, and a 13" laptop has roughly 745 points of usable height, so
the Metadata and General sections — and half of Quality — sat below the bottom
of the screen with no way to reach them. The window would not scroll, and it
could not be resized to make it.

The cause was a single layout instruction pinning the settings list to its full
height. A list that is pinned can only overflow; unpinned, it scrolls. The
window is now as tall as its content where the display allows that, as tall as
the display where it does not, and it scrolls the difference.

Because macOS hides scroll bars until you are already scrolling, a window that
has more below now says so: the last row fades out and a small chevron sits at
the bottom edge. Both appear only on displays where something is actually
hidden, so nothing changes on a large monitor.

## 1.3.1 — 2026-09-17

### Changed

**Settings no longer offers a choice that does nothing.** The Output section's
second choice decides whether `.min` is added to the filename — but it was
labelled "Keep originals, save a .min copy" and "Replace originals", which is
only what it means when the shrunken file lands in the original's own folder.
Send output to a chosen folder or a "minified" subfolder and the original is
untouchable either way, so the panel was offering to replace files it could
not reach.

It now says what it does. With output going elsewhere the row is headed
**Filenames** and reads *Add .min — photo.min.png* / *Leave as is —
photo.png*. In the one arrangement where the suffix really is all that stands
between you and an overwritten file, the wording is unchanged, and so is the
warning underneath it.

Nothing about where your files go, or what they are called, has changed — this
is what the panel says, not what it does.

**Shrinker Pro now always checks for updates, once a day.** The "Check for
updates" toggle is gone from Settings, including for anyone who had switched
it off.

This app is open source and free, and most releases exist because somebody
asked for the thing in them. An install that never hears about those is the
failure case, not the private one.

Checking is not installing. A new version is still something you are told
about and agree to; nothing downloads or replaces itself behind you, and
**Check for Updates…** in the app menu still works the way it always has.

## 1.3.0 — 2026-09-16

### Added

**Max size.** Give Shrinker Pro a number and nothing comes out bigger than it
on its longest side: a landscape image is scaled by its width, a portrait one
by its height, always keeping the aspect ratio. Anything already inside the cap
is left at the size it arrived — the number is a ceiling, not a target, and
nothing is ever scaled up.

Every still image is resized by the same resampler, whichever encoder finishes
the file, so a PNG and a WebP capped at the same number match. GIF is the one
exception, and it is resized by gifsicle precisely so an animation stays an
animation. SVG is unaffected: it is vector, so it has no pixel size to cap.

A resized file is written even if it comes out larger — the same exemption
converting already had. You asked for those dimensions.

**`--max-size` for the command line.**

```
shrinker --max-size 2000 ./camera-roll
```

### Changed

**The window footer is now a session settings bar.** One line states what will
happen to the next files you drop — `WebP · High · Max 2000px` — and **Adjust**
opens Convert all to, Quality and Max size in place. Done, Escape, or a click
anywhere above closes it again; nothing is discarded by closing, because every
control applies the moment you use it. A dot marks any setting that differs
from your defaults, and **Reset** puts all three back.

The three controls in a row needed about 620pt of window. A summary fits any
width, and it says something the row never did: these settings are the
session's, not the app's.

**Quality set in the window no longer changes your saved default.** It applies
to that session and is gone at the next launch, which is now true of everything
in the bar — the defaults each session starts from still live in Settings, and
that is where to change them for good. If you never open the panel, nothing
about your quality changes.

## 1.2.1 — 2026-09-14

### Added

**Shrinker Pro now asks before replacing a file.** Drop something whose result
would land on a file that already exists and you are asked before any work
starts, with the choice to skip those files, keep both, or replace. Files in
the same drop that collide with nothing still get shrunk.

Two questions rather than one, asked separately and answered separately,
because the stakes differ. Your own originals are asked about first —
overwriting one cannot be undone — then anything already sitting at the
destination: a copy from an earlier run, or something unrelated that happens
to share the name. Shrinker Pro cannot tell which from where it stands, so it
asks rather than assuming. Skipping declines only the files in that one
answer; the rest of the drop still runs.

You can turn it off in Settings, under Output, which restores exactly what
1.2.0 did.

**`--if-exists` for the command line.** The same three choices, plus a fourth
that has no sheet equivalent, as a flag:

```
shrinker --if-exists skip ./screenshots
shrinker --if-exists keep-both photo.jpg
shrinker --if-exists fail ./build-assets
```

It defaults to `replace`, which is what every earlier version did, so no
existing script changes behaviour. `--json` output gains a `status` field —
`shrunk`, `declined` or `skipped` — so a caller can tell a file that was
skipped from one that had nothing worth saving.

### Changed

**Settings is easier to read.** The panel is now five labelled sections —
Output, Conversion, Quality, Metadata, General — where two of them previously
had no heading at all. Where files go and whether originals are kept are
radio choices that each state their own consequence, instead of a checkbox
whose off-state you had to work out.

### Fixed

**The "your originals will be overwritten" warning told the truth only some
of the time.** It appeared whenever the `.min` suffix was off, including when
a subfolder or a chosen save folder meant nothing was actually being
overwritten. It now appears only when originals are genuinely at risk.

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
