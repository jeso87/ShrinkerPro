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
DMG="dist/Shrinker Pro-$VERSION.dmg"
STAGE="build/dmg-stage"

echo "==> building DMG $DMG"
mkdir -p dist
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp build/ShrinkerPro.icns "$STAGE/.VolumeIcon.icns"

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
xcrun stapler validate "$DMG"

echo
echo "Release ready: $DMG"
