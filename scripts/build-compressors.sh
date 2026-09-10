#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/vendor/src"
OUT="$ROOT/vendor/compressors"
MIN_MACOS=14.0

# pngquant 3.0.3 ships no Cargo.lock in its release tag (confirmed: GitHub
# serves a 404 for Cargo.lock at that tag), so a plain `cargo build` resolves
# libpng-sys/lcms2-sys/libz-sys/imagequant-sys and friends against semver
# ranges at build time — the exact versions could drift over time and no
# longer match what verify-arch.sh and the smoke tests were run against.
# vendor/pngquant-$PNGQUANT_VERSION-Cargo.lock pins the dependency graph this
# build was actually verified against (imagequant-sys 4.0.3, lcms2-sys 4.0.7,
# libpng-sys 1.1.11, libz-sys 1.1.29) and is the one file under vendor/ that
# IS committed (see .gitignore's negation for it) — it's a source input, not
# build output.
#
# Bumping PNGQUANT_VERSION requires regenerating this lockfile: run this
# script once with PNGQUANT_LOCKFILE pointed at a scratch path (or just
# comment out the `cp`+`--locked` below) to let cargo resolve fresh, then
# copy the resulting vendor/src/pngquant/Cargo.lock to
# vendor/pngquant-<new-version>-Cargo.lock and update PNGQUANT_VERSION here.
PNGQUANT_VERSION=3.0.3
PNGQUANT_LOCKFILE="$ROOT/vendor/pngquant-$PNGQUANT_VERSION-Cargo.lock"

# cwebp needs PNG and JPEG *input* decoding (libwebp's imagedec), which pulls
# in libpng and libjpeg. Building each of those against Homebrew would link
# /opt/homebrew/lib into the final cwebp binary -- not present on a user's
# Mac -- so both are built from source here instead, exactly as pngquant's
# "static" feature avoids the same trap for libpng/lcms2. libpng 1.6.58 and
# libwebp 1.6.0 are each other's most recent non-beta GitHub release tags at
# the time this was written.
LIBPNG_VERSION=1.6.58
LIBWEBP_VERSION=1.6.0

# This script is normally invoked as its own process after a separate
# `./scripts/bootstrap.sh` run, so bootstrap.sh's own `export DEVELOPER_DIR`
# does not carry over (exports don't cross process boundaries). cmake, cc,
# make, and cargo's build scripts (the `cc` crate) can all shell out to
# `xcrun` internally to resolve the active SDK, which otherwise depends on
# `xcode-select`'s system-wide default — deliberately left pointing at the
# bare Command Line Tools rather than Xcode.app. Set it here too so this
# script's SDK/toolchain resolution is pinned the same way regardless of
# which shell or session runs it.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
export CFLAGS="-arch arm64 -mmacosx-version-min=$MIN_MACOS -O2"
export LDFLAGS="-arch arm64 -mmacosx-version-min=$MIN_MACOS"

mkdir -p "$SRC" "$OUT"
# shellcheck disable=SC1090
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

# gifsicle's GitHub tag tarball ships configure.ac but no generated
# `configure`; its bootstrap.sh runs `autoreconf -i`, which shells out to
# autoconf/autoheader/autom4te and aclocal. scripts/bootstrap.sh installs
# both autoconf and automake for exactly this reason; this check is only a
# defensive fallback for someone running this script without having run
# bootstrap.sh first. (libtool is intentionally not checked for here: it is
# not needed — gifsicle's configure.ac has no LT_INIT/AC_PROG_LIBTOOL macro,
# so autoreconf never invokes libtoolize for it.)
command -v aclocal >/dev/null 2>&1 || { echo "Installing automake (needed by gifsicle's bootstrap.sh)..."; brew install automake; }

fetch() { # url, dirname
  local url="$1" dir="$2"
  if [ ! -d "$SRC/$dir" ]; then
    echo "==> fetching $dir"
    # Extract into a temporary sibling directory and only `mv` it into its
    # final name after `tar` has returned success. If this script is
    # interrupted (Ctrl-C, disk full, killed) mid-extraction, the *final*
    # "$SRC/$dir" path never exists in a partial state — the next run's
    # `[ ! -d "$SRC/$dir" ]` check still sees it as missing and re-fetches,
    # instead of silently building against a truncated source tree. A stray
    # "$dir.tmp.<pid>" directory can be left behind by an interrupted run
    # (it's named per-PID, so it isn't cleaned up by a later, different-PID
    # invocation) — this is harmless disk cruft under the already-gitignored
    # vendor/src/, not a correctness issue; `rm -rf vendor/src` clears it.
    local tmp="$SRC/$dir.tmp.$$"
    rm -rf "$tmp"
    curl -fsSL "$url" -o "$SRC/$dir.tar.gz"
    mkdir -p "$tmp"
    tar xzf "$SRC/$dir.tar.gz" -C "$tmp" --strip-components=1
    mv "$tmp" "$SRC/$dir"
  else
    echo "==> $dir already fetched, skipping"
  fi
}

# ---------- mozjpeg 4.1.5 -> cjpeg ----------
build_mozjpeg() {
  echo "==> building mozjpeg (cjpeg)"
  fetch https://github.com/mozilla/mozjpeg/archive/refs/tags/v4.1.5.tar.gz mozjpeg
  rm -rf "$SRC/mozjpeg/build" && mkdir -p "$SRC/mozjpeg/build"
  # Ruling 7: CMake 4.4.3 dropped compatibility with cmake_minimum_required
  # below 3.5. mozjpeg 4.1.5 declares 2.8.12, so configuration fails without
  # explicitly setting a policy floor.
  cmake -S "$SRC/mozjpeg" -B "$SRC/mozjpeg/build" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
    -DENABLE_SHARED=FALSE \
    -DENABLE_STATIC=TRUE \
    -DPNG_SUPPORTED=FALSE \
    -DWITH_TURBOJPEG=FALSE
  # With ENABLE_SHARED=FALSE, mozjpeg's CMake only defines the static
  # executable target "cjpeg-static" (the plain "cjpeg" target requires the
  # shared libjpeg build). Build and ship that one.
  cmake --build "$SRC/mozjpeg/build" --target cjpeg-static -j"$(sysctl -n hw.ncpu)"
  cp "$SRC/mozjpeg/build/cjpeg-static" "$OUT/cjpeg"

  # Building "cjpeg-static" also builds its dependency, the static
  # "jpeg-static" library target -> vendor/src/mozjpeg/build/libjpeg.a. It
  # implements the plain libjpeg API mozjpeg was forked from (not a mozjpeg-
  # specific ABI), which is exactly what libwebp's imagedec (jpegdec.c) links
  # against, so build_libwebp reuses this static archive instead of building
  # a second, separate libjpeg from source. Its headers are split across the
  # source tree (jpeglib.h, jerror.h, jmorecfg.h) and the build tree
  # (jconfig.h, generated by cmake's configure_file) -- CMake's FindJPEG
  # wants a single include dir, so gather all four into one place here,
  # right after the archive that needs them is built.
  mkdir -p "$SRC/mozjpeg/build/jpeg-include"
  cp "$SRC/mozjpeg/jpeglib.h" "$SRC/mozjpeg/jerror.h" "$SRC/mozjpeg/jmorecfg.h" \
     "$SRC/mozjpeg/build/jconfig.h" \
     "$SRC/mozjpeg/build/jpeg-include/"
}

# ---------- gifsicle 1.96 ----------
build_gifsicle() {
  echo "==> building gifsicle"
  fetch https://github.com/kohler/gifsicle/archive/refs/tags/v1.96.tar.gz gifsicle
  pushd "$SRC/gifsicle" >/dev/null
  [ -f configure ] || ./bootstrap.sh
  ./configure --disable-gifview --disable-gifdiff --disable-dependency-tracking
  make -j"$(sysctl -n hw.ncpu)"
  popd >/dev/null
  cp "$SRC/gifsicle/src/gifsicle" "$OUT/gifsicle"
}

# ---------- pngquant 3.0.3 (Rust libimagequant) ----------
build_pngquant() {
  echo "==> building pngquant"
  fetch "https://github.com/kornelski/pngquant/archive/refs/tags/$PNGQUANT_VERSION.tar.gz" pngquant

  # pngquant's Cargo.toml depends on lib/imagequant-sys via a git submodule
  # (.gitmodules: "lib" -> ../../ImageOptim/libimagequant.git). A plain
  # `git archive`-style tag tarball (what GitHub serves for a tag URL, and
  # what `fetch()` above downloads) never includes submodule contents —
  # that's a git-clone-time step, not part of any single repo's tree — so
  # `lib/` is just an empty gitlink here and `cargo build` fails with
  # "unable to update .../lib". There is no tarball fix for this; the
  # submodule's own content has to be fetched separately.
  #
  # This is a genuine network dependency on the GitHub REST API's current
  # response shape (Contents API, "type": "submodule" entries expose the
  # pinned commit as "sha"), not just on github.com serving tarballs. At the
  # time this was written, this resolved to commit
  # 6e9805761851f1a8320380b9f563961f892ec6ba — tags are immutable, so this
  # SHA cannot change for pngquant's 3.0.3 tag specifically, but a future
  # change to GitHub's Contents API response format could break the `sed`
  # parse below.
  if [ ! -f "$SRC/pngquant/lib/Cargo.toml" ]; then
    echo "==> fetching pinned libimagequant submodule for pngquant"
    local sha
    sha=$(curl -fsSL "https://api.github.com/repos/kornelski/pngquant/contents/lib?ref=$PNGQUANT_VERSION" \
      | sed -n 's/.*"sha": *"\([0-9a-f]*\)".*/\1/p' | head -1)
    curl -fsSL "https://github.com/ImageOptim/libimagequant/archive/$sha.tar.gz" -o "$SRC/pngquant/lib.tar.gz"
    # Same atomicity concern as fetch() above, and the same fix: extract to a
    # temp dir first and only replace "$SRC/pngquant/lib" once tar succeeds.
    # Note the outer pngquant tarball already contains an empty "lib/"
    # directory (the submodule's git mount point), so unlike fetch()'s case
    # the destination isn't simply absent — it exists but is (correctly)
    # empty until this step fills it in, or (if a prior run was interrupted
    # here) partially filled. Either way, `rm -rf` it right before the `mv`
    # so the replacement is a single atomic rename, never a merge into an
    # existing directory.
    local libtmp="$SRC/pngquant/lib.tmp.$$"
    rm -rf "$libtmp"
    mkdir -p "$libtmp"
    tar xzf "$SRC/pngquant/lib.tar.gz" -C "$libtmp" --strip-components=1
    rm -rf "$SRC/pngquant/lib"
    mv "$libtmp" "$SRC/pngquant/lib"
  fi

  # Pin the dependency graph: copy the committed lockfile into place before
  # building. Copied fresh on every run (not just when Cargo.lock is
  # missing) so a stale/hand-edited Cargo.lock left over in vendor/src from
  # a previous run can never silently diverge from what's committed.
  if [ ! -f "$PNGQUANT_LOCKFILE" ]; then
    echo "FATAL: missing committed lockfile $PNGQUANT_LOCKFILE" >&2
    echo "       (see the PNGQUANT_VERSION comment above for how to generate it)" >&2
    exit 1
  fi
  cp "$PNGQUANT_LOCKFILE" "$SRC/pngquant/Cargo.lock"

  pushd "$SRC/pngquant" >/dev/null
  # Default features pull in libpng-sys/lcms2-sys in their dynamic modes,
  # which (with Homebrew's libpng/lcms2 pkg-config files on this machine)
  # would link against /opt/homebrew/lib — not present on a user's Mac.
  # The "static" feature (-> lcms2-static + png-static) makes both crates
  # vendor and statically link their C dependencies instead, so the only
  # remaining dynamic links are system libz/libiconv/libSystem.
  #
  # Note on pkg-config: it is NOT required for this invocation. Verified by
  # reading libpng-sys's and lcms2-sys's build.rs — with the "static"
  # feature set, both go straight to their vendored-C compile path and never
  # call pkg-config at all (lcms2-sys's own `||` short-circuits past it;
  # libpng-sys's `if wants_static { build_static(...); return; }` returns
  # before ever trying it). The only crate here that does still attempt
  # pkg-config is libz-sys, for locating system zlib (matching the
  # /usr/lib/libz.1.dylib we ship), and even there it degrades to a plain
  # `cc -lz` link-check on failure — so this build succeeds whether or not
  # the pkg-config binary is present on the machine at all.
  #
  # --locked makes the pin in vendor/pngquant-$PNGQUANT_VERSION-Cargo.lock
  # real: without it, cargo treats a lockfile as a cache and will silently
  # re-resolve (and rewrite it) if the manifest doesn't match exactly.
  # With --locked, cargo instead FAILS the build the moment the committed
  # lock and Cargo.toml disagree, rather than quietly building against a
  # different dependency graph than the one this task's binaries were
  # verified against.
  cargo build --release --target aarch64-apple-darwin --no-default-features --features static --locked
  popd >/dev/null
  cp "$SRC/pngquant/target/aarch64-apple-darwin/release/pngquant" "$OUT/pngquant"
}

# ---------- libpng 1.6.58 (static, PNG input support for cwebp) ----------
build_libpng() {
  echo "==> building libpng"
  fetch "https://github.com/pnggroup/libpng/archive/refs/tags/v$LIBPNG_VERSION.tar.gz" libpng
  rm -rf "$SRC/libpng/build" && mkdir -p "$SRC/libpng/build"

  # libpng only needs zlib, which macOS ships in the SDK itself (both
  # usr/include/zlib.h and usr/lib/libz.tbd) -- no Homebrew or vendored zlib
  # needed. Pointing ZLIB_INCLUDE_DIR/ZLIB_LIBRARY at the SDK explicitly,
  # rather than leaving them for CMake's default search to resolve, matters
  # here: this machine's Homebrew-installed cmake ships with /opt/homebrew
  # baked into its default CMAKE_SYSTEM_PREFIX_PATH (verified with `cmake
  # --system-information`), and this machine also happens to have libpng and
  # zlib formulas present -- exactly the scenario the arch gate exists to
  # catch. CMake's find_path/find_library skip searching entirely once the
  # corresponding cache variable already has a value, so pre-setting these
  # (and PNG_PNG_INCLUDE_DIR/PNG_LIBRARY/JPEG_INCLUDE_DIR/JPEG_LIBRARY below,
  # in build_libwebp) is not a preference hint -- it is a hard bypass of that
  # search, immune to whatever happens to be installed on the build machine.
  local sdk
  sdk="$(xcrun --sdk macosx --show-sdk-path)"
  cmake -S "$SRC/libpng" -B "$SRC/libpng/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
    -DPNG_SHARED=OFF \
    -DPNG_STATIC=ON \
    -DPNG_FRAMEWORK=OFF \
    -DPNG_TESTS=OFF \
    -DPNG_TOOLS=OFF \
    -DPNG_EXECUTABLES=OFF \
    -DZLIB_INCLUDE_DIR="$sdk/usr/include" \
    -DZLIB_LIBRARY="$sdk/usr/lib/libz.tbd" \
    -DCMAKE_INSTALL_PREFIX="$SRC/libpng-install"
  cmake --build "$SRC/libpng/build" -j"$(sysctl -n hw.ncpu)"
  # Installing (rather than pointing libwebp straight at the build tree)
  # collects png.h/pngconf.h (source tree) and the generated pnglibconf.h
  # (build tree) into one include dir, matching what CMake's FindPNG module
  # expects (a single PNG_PNG_INCLUDE_DIR).
  rm -rf "$SRC/libpng-install"
  cmake --install "$SRC/libpng/build"
}

# ---------- libwebp 1.6.0 -> cwebp ----------
build_libwebp() {
  echo "==> building libwebp (cwebp)"
  fetch "https://github.com/webmproject/libwebp/archive/refs/tags/v$LIBWEBP_VERSION.tar.gz" libwebp
  rm -rf "$SRC/libwebp/build" && mkdir -p "$SRC/libwebp/build"

  local mozjpeg_include="$SRC/mozjpeg/build/jpeg-include"
  local mozjpeg_lib="$SRC/mozjpeg/build/libjpeg.a"
  local png_include="$SRC/libpng-install/include"
  local png_lib="$SRC/libpng-install/lib/libpng16.a"
  for f in "$mozjpeg_lib" "$mozjpeg_include/jpeglib.h" "$png_lib" "$png_include/png.h"; do
    [ -e "$f" ] || {
      echo "FATAL: $f missing -- build_mozjpeg and build_libpng must run before build_libwebp" >&2
      exit 1
    }
  done

  local sdk
  sdk="$(xcrun --sdk macosx --show-sdk-path)"
  # Only cwebp is needed, not the whole libwebp tool suite -- gif2webp,
  # img2webp, webpmux and the libwebpmux library it needs all exist to
  # *write* animated/multi-image containers, vwebp is a GUI viewer, and
  # webpinfo/dwebp/the "extras" targets are unrelated inspection and decode
  # tools. Turning them off keeps the dependency surface to exactly PNG,
  # JPEG and zlib -- no incidental pull of giflib. WEBP_LINK_STATIC=ON (the
  # project's own default whenever BUILD_SHARED_LIBS is off) also makes its
  # FindPNG/FindJPEG search prefer .a over .dylib, matching the static
  # libraries pointed at below.
  cmake -S "$SRC/libwebp" -B "$SRC/libwebp/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
    -DBUILD_SHARED_LIBS=OFF \
    -DWEBP_LINK_STATIC=ON \
    -DWEBP_BUILD_CWEBP=ON \
    -DWEBP_BUILD_DWEBP=OFF \
    -DWEBP_BUILD_GIF2WEBP=OFF \
    -DWEBP_BUILD_IMG2WEBP=OFF \
    -DWEBP_BUILD_VWEBP=OFF \
    -DWEBP_BUILD_WEBPINFO=OFF \
    -DWEBP_BUILD_LIBWEBPMUX=OFF \
    -DWEBP_BUILD_WEBPMUX=OFF \
    -DWEBP_BUILD_EXTRAS=OFF \
    -DWEBP_BUILD_ANIM_UTILS=OFF \
    -DZLIB_INCLUDE_DIR="$sdk/usr/include" \
    -DZLIB_LIBRARY="$sdk/usr/lib/libz.tbd" \
    -DPNG_PNG_INCLUDE_DIR="$png_include" \
    -DPNG_LIBRARY="$png_lib" \
    -DJPEG_INCLUDE_DIR="$mozjpeg_include" \
    -DJPEG_LIBRARY="$mozjpeg_lib"
  cmake --build "$SRC/libwebp/build" --target cwebp -j"$(sysctl -n hw.ncpu)"
  cp "$SRC/libwebp/build/cwebp" "$OUT/cwebp"
}

build_mozjpeg
build_gifsicle
build_pngquant
build_libpng
build_libwebp

echo
echo "==> verifying architecture"
"$ROOT/scripts/verify-arch.sh" "$OUT"
echo
for b in cjpeg gifsicle pngquant cwebp; do
  printf '%-10s %s\n' "$b" "$(lipo -archs "$OUT/$b")"
done
