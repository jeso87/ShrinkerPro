#!/usr/bin/env bash
set -euo pipefail

# Use the full Xcode toolchain for this invocation without requiring sudo or
# changing the system-wide xcode-select path. Every xcodebuild/xcrun call in
# this script (and in any script that sources this one) must run with this
# exported.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# autoconf and automake are needed by gifsicle's build: its GitHub release
# tarball ships configure.ac but no generated `configure`, so its
# bootstrap.sh runs `autoreconf -i`, which shells out to autoconf/autoheader/
# autom4te (from the autoconf formula) and aclocal (from the automake
# formula). libtool is deliberately NOT installed here: gifsicle's
# configure.ac contains no LT_INIT/AC_PROG_LIBTOOL macro, so autoreconf never
# invokes libtoolize for it — confirmed by gifsicle's bootstrap succeeding
# with no `libtoolize` (or Homebrew's renamed `glibtoolize`) on PATH at all.
for tool in xcodegen cmake autoconf automake; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Installing $tool..."
    brew install "$tool"
  fi
done

# Node is a build-time-only prerequisite: scripts/prepare-svgo.sh fetches the
# svgo bundle with `npm pack`. Nothing Node-based ships in the app — svgo runs
# inside JavaScriptCore — but a clean machine following the README verbatim
# used to fail at step 3 with "npm: command not found", because this check
# didn't exist and the README didn't mention it. Checked by command name
# (`npm`) rather than formula name (`node`) so an existing Node from nvm,
# Volta, or the official installer is accepted instead of being shadowed by a
# second Homebrew copy.
if ! command -v npm >/dev/null 2>&1; then
  echo "Installing Node (npm is used by scripts/prepare-svgo.sh)..."
  brew install node
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "Installing Rust toolchain (needed by pngquant 3.x)..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
fi
# shellcheck disable=SC1090
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

echo "xcodebuild: $(xcodebuild -version | head -1)"
echo "xcodegen:   $(xcodegen --version)"
echo "cmake:      $(cmake --version | head -1)"
echo "npm:        $(npm --version)"
echo "cargo:      $(cargo --version)"
echo "Bootstrap complete."
