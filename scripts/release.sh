#!/usr/bin/env bash
set -euo pipefail

# xcode-select on this machine points at CommandLineTools, not Xcode, and we
# deliberately do not change that with sudo. Every xcodebuild/xcrun call in
# this script needs the full Xcode toolchain (archiving, exporting, and
# notarytool/stapler all require it), so pin it here rather than relying on
# it leaking in from the calling shell or another script.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

IDENTITY="Developer ID Application: Eight-Seven Inc. (LY424U3HLD)"
KEYCHAIN_PROFILE="${NOTARY_PROFILE:-shrinkerpro-notary}"
ARCHIVE="build/ShrinkerPro.xcarchive"
EXPORT="build/export"
APP="$EXPORT/Shrinker Pro.app"

echo "==> regenerating project"
xcodegen generate

echo "==> archiving"
rm -rf "$ARCHIVE" "$EXPORT"
xcodebuild archive \
  -scheme ShrinkerPro \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  -destination 'generic/platform=macOS' \
  ARCHS=arm64 EXCLUDED_ARCHS=x86_64 \
  | tail -5

HELPERS_DIR="$ARCHIVE/Products/Applications/Shrinker Pro.app/Contents/Helpers"
REQUIRED_HELPERS=(cjpeg pngquant gifsicle cwebp)

echo "==> verifying required helpers are present"
# verify-arch.sh deliberately only checks "at least one Mach-O was
# examined" — it's app-agnostic and is also run against vendor/compressors/
# directly, where the expected count differs, so it can't know this app
# needs exactly these three. A build that silently dropped a helper (e.g.
# gifsicle missing from the archive) would still pass the arch gate: 1 or 2
# Mach-O files, all arm64/system-linked, is still a PASS. That knowledge
# belongs here instead: assert the specific set this app ships, and abort
# naming whatever is missing, before anything gets signed or notarized.
MISSING_HELPERS=()
for helper in "${REQUIRED_HELPERS[@]}"; do
  path="$HELPERS_DIR/$helper"
  if [ ! -f "$path" ] || [ ! -x "$path" ]; then
    MISSING_HELPERS+=("$helper")
  fi
done
if [ "${#MISSING_HELPERS[@]}" -ne 0 ]; then
  echo "FAIL  missing required helper(s) in $HELPERS_DIR: ${MISSING_HELPERS[*]}" >&2
  exit 1
fi
echo "    present: ${REQUIRED_HELPERS[*]}"

echo "==> signing helpers inside-out"
# Helpers must be signed before the app that contains them, or the outer
# signature is invalidated the moment they change.
for helper in "$HELPERS_DIR/"*; do
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$helper"
  echo "    signed $(basename "$helper")"
done

FRAMEWORKS_DIR="$ARCHIVE/Products/Applications/Shrinker Pro.app/Contents/Frameworks"
SPARKLE="$FRAMEWORKS_DIR/Sparkle.framework"

echo "==> verifying Sparkle.framework is present"
# Same reasoning as the helpers check above: a build that silently dropped
# or failed to embed Sparkle would still pass the (app-agnostic) arch gate.
[ -d "$SPARKLE" ] || {
  echo "FAIL  Sparkle.framework not found at $SPARKLE" >&2
  echo "      (scripts/prepare-sparkle.sh must be run before xcodegen generate)" >&2
  exit 1
}

echo "==> signing Sparkle.framework inside-out"
# Sparkle ships universal (x86_64+arm64); its five Mach-Os are thinned to
# arm64 by scripts/prepare-sparkle.sh before this project is even built,
# which invalidates every signature under the framework (thinning rewrites
# the binaries; codesign hashes exact bytes). prepare-sparkle.sh leaves it
# ad hoc signed, just enough to be locally launchable — this is the real
# re-sign, with this project's actual Developer ID identity, extending the
# exact same inside-out-before-container pattern as the helpers above:
# both XPC services and the nested Updater.app are signed first, the
# loose Autoupdate tool next, and only then the umbrella framework itself
# (which is what the app's own signature, applied during export below,
# will in turn expect to find already valid).
for nested in \
  "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
  "$SPARKLE/Versions/B/XPCServices/Installer.xpc" \
  "$SPARKLE/Versions/B/Updater.app" \
  "$SPARKLE/Versions/B/Autoupdate"; do
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$nested"
  echo "    signed ${nested#"$FRAMEWORKS_DIR/"}"
done
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE"
echo "    signed Sparkle.framework"

echo "==> exporting"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" \
  -exportOptionsPlist build/ExportOptions.plist | tail -5

echo "==> ARCHITECTURE GATE"
# This is the project's central guarantee: every Mach-O in the shipped,
# signed bundle must be arm64-only and link only system libraries. It must
# run against the exported app before notarization is submitted, and it
# must abort the release on failure — never weaken or skip this.
./scripts/verify-arch.sh "$APP"

echo "==> verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose "$APP" || echo "    (spctl will pass only after notarization)"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
# No space in the DMG's *filename*, deliberately — the mounted volume is
# still named "Shrinker Pro" (see -volname below), which is what a user
# actually sees.
#
# GitHub rewrites spaces in a release asset's filename to periods when it
# is uploaded, so "Shrinker Pro-1.0.0.dmg" is served as
# "Shrinker.Pro-1.0.0.dmg". generate_appcast builds the appcast enclosure
# URL from the local filename, giving "Shrinker%20Pro-1.0.0.dmg" — a URL
# that 404s. Sparkle would then find an update and fail to download it,
# which is worse than finding none, and is unfixable by shipping an
# update: every existing install keeps checking the same broken feed.
DMG="dist/ShrinkerPro-$VERSION.dmg"
STAGE="build/dmg-stage"

echo "==> building DMG $DMG"
mkdir -p dist
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp build/ShrinkerPro.icns "$STAGE/.VolumeIcon.icns"

# GPL-2.0 (gifsicle) and GPL-3.0 (pngquant) both require the license text to
# accompany the binaries wherever they are distributed — the repo having a
# copy is not enough, because the DMG is what most people receive. Fail
# rather than ship a DMG without them.
for doc in LICENSE THIRD-PARTY-LICENSES.md; do
  [ -f "$ROOT/$doc" ] || {
    echo "FAIL  $doc missing — run ./scripts/collect-licenses.sh" >&2
    exit 1
  }
  cp "$ROOT/$doc" "$STAGE/"
done

# A custom volume icon requires setting the "has custom icon" attribute on
# a writable HFS+ volume before the DMG is compressed, so this builds an
# intermediate read-write image, attaches it, flips the attributes, detaches
# it, then converts to the final compressed read-only format.
#
# The attach/SetFile/detach window is the one stage in this script that
# isn't defensively idempotent on its own (every other stage — xcarchive,
# export, dmg-stage, the final DMG — cleans up both before its own run and
# via -ov/-rf). If SetFile errors, or `hdiutil detach` hits "Resource busy"
# (observed in practice when Spotlight or Finder touches a freshly-mounted
# volume), set -e would otherwise abort with the volume still mounted and
# no cleanup until it's ejected by hand. The trap below guarantees a
# re-run never inherits a stranded mount regardless of how this window
# fails; it's disarmed immediately after a clean detach so it doesn't mask
# unrelated failures later in the script.
RW_DMG="build/dmg-rw.dmg"
rm -f "$RW_DMG"
hdiutil create -volname "Shrinker Pro" -srcfolder "$STAGE" -ov -fs HFS+ -format UDRW "$RW_DMG"

MOUNT_DIR=""
cleanup_rw_mount() {
  if [ -n "$MOUNT_DIR" ] && hdiutil info | grep -qF "$MOUNT_DIR"; then
    echo "    cleaning up dangling mount: $MOUNT_DIR" >&2
    hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
  fi
}
trap cleanup_rw_mount EXIT

MOUNT_DIR=$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen | awk -F '\t' '/\/Volumes\// {print $3}')
SetFile -a C "$MOUNT_DIR"
SetFile -a V "$MOUNT_DIR/.VolumeIcon.icns"
hdiutil detach "$MOUNT_DIR"
MOUNT_DIR=""
trap - EXIT

hdiutil convert "$RW_DMG" -format ULFO -ov -o "$DMG"
rm -f "$RW_DMG"

echo "==> signing DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

echo "==> notarizing (this takes a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$KEYCHAIN_PROFILE" --wait

echo "==> stapling"
xcrun stapler staple "$DMG"

# A second, identical copy under a name that never changes.
#
# GitHub's permanent "latest release" download URL is
# .../releases/latest/download/<exact asset name>, so a stable download
# button needs an asset whose filename carries no version. Sparkle needs
# the opposite: generate_appcast derives the enclosure URL from the
# versioned filename, and each release's asset must stay distinct. Upload
# both and each consumer gets what it needs.
#
# Copied after stapling so this one carries the notarization ticket too —
# copying before would produce a file that needs a network round trip on
# first launch, and would silently fail to open offline.
STABLE_DMG="dist/ShrinkerPro.dmg"
cp "$DMG" "$STABLE_DMG"
xcrun stapler validate "$STABLE_DMG" >/dev/null || {
  echo "FAIL  $STABLE_DMG is not stapled — the copy must happen after stapling" >&2
  exit 1
}
echo "    wrote $STABLE_DMG (stable download URL, same bytes)"
xcrun stapler validate "$DMG"

echo
echo "Release ready: $DMG"

# --- Sparkle: sign the DMG and publish an appcast entry for it -------------
#
# Deliberately placed after stapling, not right after "signing DMG" above:
# Sparkle's EdDSA signature (and the appcast entry generate_appcast builds
# around it) must cover the exact bytes a user's copy of Sparkle will
# actually download — which is this final, notarized-and-stapled DMG, not
# the pre-notarization one.
SPARKLE_BIN="$ROOT/vendor/Sparkle/bin"
GITHUB_REPO="jeso87/ShrinkerPro"
RELEASE_TAG="v$VERSION"

echo "==> signing update artifact with Sparkle's EdDSA key"
# Reads the private key from this machine's Keychain — never touches disk,
# never passed on the command line. This is the same signature
# generate_appcast computes internally for the appcast entry below; running
# it here too is purely so the signature is visible and logged for this
# release, matching the brief's two explicit steps rather than treating
# generate_appcast as a black box.
UPDATE_SIGNATURE=$("$SPARKLE_BIN/sign_update" "$DMG")
echo "    $UPDATE_SIGNATURE"

echo "==> generating appcast"
APPCAST_STAGE="build/appcast-stage"
rm -rf "$APPCAST_STAGE"
mkdir -p "$APPCAST_STAGE"
cp "$DMG" "$APPCAST_STAGE/"
# generate_appcast only looks for a pre-existing appcast.xml to extend
# inside its own archives-source-dir (not wherever -o points), and dist/ is
# gitignored/ephemeral — so the previously-published feed (committed at the
# repo root) is copied in here first, if one exists, purely so history
# (older versions, delta eligibility) carries forward across a clean
# dist/build/ wipe instead of restarting from a single-entry feed every
# release.
[ -f "$ROOT/appcast.xml" ] && cp "$ROOT/appcast.xml" "$APPCAST_STAGE/appcast.xml"

"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "https://github.com/$GITHUB_REPO/releases/download/$RELEASE_TAG/" \
  "$APPCAST_STAGE"

cp "$APPCAST_STAGE/appcast.xml" "$ROOT/appcast.xml"
rm -rf "$APPCAST_STAGE"
echo "    wrote $ROOT/appcast.xml"

# --- GPL corresponding source ---------------------------------------------
#
# gifsicle (GPL-2.0) and pngquant (GPL-3.0) are distributed as binaries in
# the DMG, which obliges us to make their source available. Pointing at an
# upstream URL alone is fragile: a tag can be retagged or deleted, and the
# obligation attaches to the source for *these* binaries. So the exact
# archives build-compressors.sh downloaded and built are bundled here and
# uploaded to the same release, which discharges it unambiguously.
#
# Permissively-licensed components are included too. They carry no such
# obligation, but a single archive that matches the notice file is easier to
# reason about than one that mysteriously omits three of its six entries.
SOURCES_ZIP="dist/ShrinkerPro-$VERSION-thirdparty-sources.zip"
echo "==> collecting third-party source archives"
rm -f "$SOURCES_ZIP"
TARBALLS=()
while IFS= read -r t; do TARBALLS+=("$t"); done < <(find "$ROOT/vendor/src" -maxdepth 1 -name '*.tar.gz' | sort)
# Fail closed: an empty archive would look like compliance while providing
# nothing. build-compressors.sh leaves these behind, so none means the
# vendor tree was cleaned and the release is being cut from stale binaries.
[ "${#TARBALLS[@]}" -ge 5 ] || {
  echo "FAIL  expected >=5 source tarballs in vendor/src, found ${#TARBALLS[@]}" >&2
  echo "      run ./scripts/build-compressors.sh to repopulate" >&2
  exit 1
}
ditto -c -k --sequesterRsrc "${TARBALLS[@]}" "$ROOT/THIRD-PARTY-LICENSES.md" "$SOURCES_ZIP" 2>/dev/null \
  || zip -j -q "$SOURCES_ZIP" "${TARBALLS[@]}" "$ROOT/THIRD-PARTY-LICENSES.md"
echo "    wrote $SOURCES_ZIP ($(du -h "$SOURCES_ZIP" | cut -f1 | tr -d ' '), ${#TARBALLS[@]} archives)"

# No `gh` on this machine, and this project doesn't push or open releases on
# its own initiative — print exactly what a human needs to do instead of
# guessing at automating it.
echo
echo "=================================================================="
echo "Update feed regenerated locally. Nothing has been published yet."
echo
echo "To publish v$VERSION:"
echo
echo "  1. Create a GitHub Release tagged $RELEASE_TAG at:"
echo "       https://github.com/$GITHUB_REPO/releases/new?tag=$RELEASE_TAG"
echo "  2. Upload these as release assets. The DMG's filename must not"
echo "     change — the appcast enclosure URL below is built from it, and"
echo "     GitHub rewrites spaces to periods, which is why it has none:"
echo "       $DMG"
echo "       $STABLE_DMG                (same bytes; powers the README"
echo "                                         download button, which breaks"
echo "                                         if this asset is missing)"
echo "       $SOURCES_ZIP   (GPL corresponding source — required)"
echo "  3. Commit and push the regenerated feed so GitHub Pages serves it:"
echo "       git add appcast.xml"
echo "       git commit -m \"Publish $RELEASE_TAG to the update feed\""
echo "       git push"
echo
echo "  Feed URL (must match Info.plist's SUFeedURL exactly):"
echo "    https://jeso87.github.io/ShrinkerPro/appcast.xml"
echo "=================================================================="
