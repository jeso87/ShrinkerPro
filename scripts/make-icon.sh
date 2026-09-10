#!/usr/bin/env bash
# Builds the app icon from Logo.icon — the Icon Composer document that is the
# single source of truth for Shrinker Pro's icon.
#
# Pipeline: Icon Composer document -> ictool render -> macOS icon geometry ->
# asset catalog + standalone .icns for the DMG volume icon.
#
# Earlier versions of this script drew the icon programmatically in
# make-icon.swift. That art has been replaced by Logo.icon, so the drawing
# script is gone; edit Logo.icon in Icon Composer and re-run this.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$ROOT/vendor/src/icon"
SET="$ROOT/Sources/ShrinkerPro/Resources/Assets.xcassets/AppIcon.appiconset"
LOGO="$ROOT/Logo.icon"

# Ships inside Xcode rather than being on PATH. Pinned rather than discovered
# so a machine with several Xcodes cannot silently render with a different
# version than the one this project builds against.
ICTOOL="${ICTOOL:-/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool}"

[ -d "$LOGO" ] || { echo "FAIL  $LOGO not found" >&2; exit 1; }
[ -x "$ICTOOL" ] || {
  echo "FAIL  ictool not found at: $ICTOOL" >&2
  echo "      It ships with Xcode 26+ (Icon Composer.app). Set ICTOOL to override." >&2
  exit 1
}

rm -rf "$TMP" && mkdir -p "$TMP" "$SET"

# Render once at 2048 (1024 @2x) and downsample from there: every size the
# catalog needs divides into it cleanly, and one render keeps all ten sizes
# pixel-consistent with each other.
echo "==> rendering Logo.icon"
"$ICTOOL" "$LOGO" \
  --export-image \
  --output-file "$TMP/full-bleed.png" \
  --platform macOS \
  --rendition Default \
  --width 1024 --height 1024 --scale 2 > /dev/null

[ -s "$TMP/full-bleed.png" ] || { echo "FAIL  ictool produced no image" >&2; exit 1; }

echo "==> applying macOS icon geometry"
swift "$ROOT/scripts/render-icon.swift" "$TMP/full-bleed.png" "$TMP" \
  16,32,64,128,256,512,1024

copy() { cp "$TMP/icon_$1.png" "$SET/$2"; }
copy 16   icon_16x16.png
copy 32   icon_16x16@2x.png
copy 32   icon_32x32.png
copy 64   icon_32x32@2x.png
copy 128  icon_128x128.png
copy 256  icon_128x128@2x.png
copy 256  icon_256x256.png
copy 512  icon_256x256@2x.png
copy 512  icon_512x512.png
copy 1024 icon_512x512@2x.png

cat > "$SET/Contents.json" <<'JSON'
{
  "images": [
    {"idiom":"mac","scale":"1x","size":"16x16","filename":"icon_16x16.png"},
    {"idiom":"mac","scale":"2x","size":"16x16","filename":"icon_16x16@2x.png"},
    {"idiom":"mac","scale":"1x","size":"32x32","filename":"icon_32x32.png"},
    {"idiom":"mac","scale":"2x","size":"32x32","filename":"icon_32x32@2x.png"},
    {"idiom":"mac","scale":"1x","size":"128x128","filename":"icon_128x128.png"},
    {"idiom":"mac","scale":"2x","size":"128x128","filename":"icon_128x128@2x.png"},
    {"idiom":"mac","scale":"1x","size":"256x256","filename":"icon_256x256.png"},
    {"idiom":"mac","scale":"2x","size":"256x256","filename":"icon_256x256@2x.png"},
    {"idiom":"mac","scale":"1x","size":"512x512","filename":"icon_512x512.png"},
    {"idiom":"mac","scale":"2x","size":"512x512","filename":"icon_512x512@2x.png"}
  ],
  "info": {"author":"xcode","version":1}
}
JSON

# Standalone .icns for the DMG volume icon.
ICONSET="$TMP/ShrinkerPro.iconset"
mkdir -p "$ICONSET"
for f in "$SET"/icon_*.png; do cp "$f" "$ICONSET/$(basename "$f")"; done
mkdir -p "$ROOT/build"
iconutil -c icns "$ICONSET" -o "$ROOT/build/ShrinkerPro.icns"
echo "wrote asset catalog and build/ShrinkerPro.icns"
