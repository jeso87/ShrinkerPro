#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$ROOT/vendor/src/icon"
SET="$ROOT/Sources/ShrinkerPro/Resources/Assets.xcassets/AppIcon.appiconset"

rm -rf "$TMP" && mkdir -p "$TMP" "$SET"
swift "$ROOT/scripts/make-icon.swift" "$TMP"

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
iconutil -c icns "$ICONSET" -o "$ROOT/build/ShrinkerPro.icns"
echo "wrote asset catalog and build/ShrinkerPro.icns"
