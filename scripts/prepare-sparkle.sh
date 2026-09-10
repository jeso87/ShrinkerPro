#!/usr/bin/env bash
# Fetches Sparkle's official prebuilt framework release and thins its five
# Mach-Os to arm64, matching this app's arm64-only guarantee.
#
# Unlike build-compressors.sh, this does not build anything from source:
# Sparkle.framework is a signed, prebuilt binary distribution, and rebuilding
# the whole Sparkle.xcodeproj (with its own helper-tool targets, entitlements,
# and code-signing requirements) from source is out of scope here. Thinning
# and re-signing what Sparkle ships is the supported way to make a vendored
# binary framework arm64-only — see release.sh for the second half (the real
# Developer ID re-sign, done inside-out immediately before export, exactly
# like it already does for vendor/compressors/*).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPARKLE_VERSION=2.9.6
SRC="$ROOT/vendor/src/sparkle"
OUT="$ROOT/vendor/Sparkle"
# Same identity as release.sh's $IDENTITY (kept as a separate literal here,
# matching this project's existing style of not sharing constants between
# scripts/*.sh — see e.g. MIN_MACOS in build-compressors.sh).
IDENTITY="Developer ID Application: Eight-Seven Inc. (LY424U3HLD)"

echo "==> fetching Sparkle $SPARKLE_VERSION"
rm -rf "$SRC"
mkdir -p "$SRC"
curl -fsSL \
  "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
  -o "$SRC/sparkle.tar.xz"
tar xJf "$SRC/sparkle.tar.xz" -C "$SRC"

[ -d "$SRC/Sparkle.framework" ] || {
  echo "FATAL: Sparkle.framework not found in the $SPARKLE_VERSION release tarball — layout may have changed" >&2
  exit 1
}
[ -x "$SRC/bin/sign_update" ] && [ -x "$SRC/bin/generate_appcast" ] || {
  echo "FATAL: bin/sign_update or bin/generate_appcast missing from the release tarball" >&2
  exit 1
}

echo "==> installing framework + publishing tools into vendor/Sparkle"
rm -rf "$OUT"
mkdir -p "$OUT/bin"
# -P (cp's alias for -R with no symlink-following): a framework bundle IS its
# symlinks (Versions/Current -> B, and the top-level Headers/Modules/
# Resources/Sparkle aliases into Versions/Current/*) — copying with them
# resolved/dereferenced would silently turn this into a broken, doubled-up
# layout that happens to still work by accident today (only one real
# version, "B", exists) and breaks the moment that stops being true.
cp -PR "$SRC/Sparkle.framework" "$OUT/Sparkle.framework"
# release.sh's publish step needs these; they're build/publish-time tools,
# never copied into the app bundle, so — unlike everything below — they are
# never thinned or re-signed. They only ever run on this (arm64) machine.
cp "$SRC/bin/sign_update" "$SRC/bin/generate_appcast" "$OUT/bin/"

FRAMEWORK="$OUT/Sparkle.framework"
BINARIES=(
  "$FRAMEWORK/Versions/B/Sparkle"
  "$FRAMEWORK/Versions/B/Autoupdate"
  "$FRAMEWORK/Versions/B/Updater.app/Contents/MacOS/Updater"
  "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"
  "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
)

echo "==> thinning to arm64 (Sparkle ships x86_64+arm64 universal; this project is arm64-only)"
for bin in "${BINARIES[@]}"; do
  [ -f "$bin" ] || { echo "FATAL: expected Sparkle Mach-O not found: $bin" >&2; exit 1; }
  tmp="$bin.thin.$$"
  lipo -thin arm64 "$bin" -output "$tmp"
  mv "$tmp" "$bin"
done

# lipo rewrites the file's bytes, which invalidates every code signature
# under this framework: the top-level framework's own seal, and each nested
# bundle's (Updater.app, both XPC services) independent one. An ad hoc
# re-sign here would NOT be enough to make a plain local `xcodebuild build`
# (or Xcode's own Debug run) launchable: ShrinkerPro itself is built with
# the hardened runtime, which enforces Library Validation — every framework
# it dynamically loads must be signed by the SAME Team ID, or loading it
# fails outright at launch with "different Team IDs" (confirmed empirically:
# an ad hoc-signed Sparkle.framework here made every Debug test run crash on
# launch before a single test could execute). So this re-signs with this
# project's real Developer ID identity immediately, non-interactively, using
# the same certificate xcodebuild itself already signs everything else with
# — release.sh re-signs these same five paths again right before export
# (nested XPC services and Updater.app before the umbrella framework, same
# order as here) as the authoritative, byte-final signature for the
# shipped, notarized build; doing it here too is what makes every build in
# between — Debug, plain `xcodebuild build`, `xcodebuild test` — launchable
# in the first place.
echo "==> re-signing with the project's Developer ID identity"
for item in \
  "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" \
  "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc" \
  "$FRAMEWORK/Versions/B/Updater.app" \
  "$FRAMEWORK/Versions/B/Autoupdate" \
  "$FRAMEWORK"; do
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$item"
done

echo
echo "==> verifying architecture"
"$ROOT/scripts/verify-arch.sh" "$FRAMEWORK"
echo
for bin in "${BINARIES[@]}"; do
  printf '%-10s %s\n' "$(basename "$bin")" "$(lipo -archs "$bin")"
done
