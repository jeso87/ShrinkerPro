#!/usr/bin/env bash
# Regenerates THIRD-PARTY-LICENSES.md from the license files inside the
# sources that scripts/build-compressors.sh actually downloaded and built.
#
# Generated rather than hand-written on purpose. Shrinker Pro ships two GPL
# programs (gifsicle, pngquant), so the notice is a distribution obligation,
# not documentation — and a hand-maintained copy silently goes stale the
# moment a version is bumped in build-compressors.sh. Reading the texts out
# of vendor/src means the notice can only ever describe the code that was
# built.
#
# Run this after build-compressors.sh (which populates vendor/src) and
# commit the result. release.sh verifies it is present and current.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/vendor/src"
OUT="$ROOT/THIRD-PARTY-LICENSES.md"

[ -d "$SRC" ] || {
  echo "FAIL  $SRC missing — run ./scripts/build-compressors.sh first" >&2
  exit 1
}

# name | version | license | license file, relative to vendor/src | upstream source URL
COMPONENTS=(
  "mozjpeg (cjpeg)|4.1.5|BSD-3-Clause and IJG|mozjpeg/LICENSE.md|https://github.com/mozilla/mozjpeg/archive/refs/tags/v4.1.5.tar.gz"
  "pngquant|3.0.3|GPL-3.0-or-later|pngquant/COPYRIGHT|https://github.com/kornelski/pngquant/archive/refs/tags/3.0.3.tar.gz"
  # Compiled into the pngquant executable rather than invoked beside it, and
  # absent from this notice for three releases. pngquant's tag tarball carries
  # lib/ as an empty gitlink, so build-compressors.sh fetches the pinned
  # submodule separately — see the comment there. The version is the crate's
  # own (imagequant 4.2.2 in Cargo.toml), not the imagequant-sys wrapper's.
  "libimagequant|4.2.2|GPL-3.0-or-later|pngquant/lib/COPYRIGHT|https://github.com/ImageOptim/libimagequant"
  "gifsicle|1.96|GPL-2.0|gifsicle/COPYING|https://github.com/kohler/gifsicle/archive/refs/tags/v1.96.tar.gz"
  "libwebp (cwebp)|1.6.0|BSD-3-Clause|libwebp/COPYING|https://github.com/webmproject/libwebp/archive/refs/tags/v1.6.0.tar.gz"
  "libpng|1.6.58|libpng-2.0|libpng/LICENSE|https://github.com/pnggroup/libpng/archive/refs/tags/v1.6.58.tar.gz"
  "libjxl (cjxl)|0.12.0|BSD-3-Clause|libjxl/LICENSE|https://github.com/libjxl/libjxl/archive/refs/tags/v0.12.0.tar.gz"
  # Not a licence condition — BSD-3-Clause asks for nothing of the sort — but
  # libjxl ships a royalty-free patent grant beside its licence, and the grant
  # is what a reader of a JPEG XL encoder's notice is most likely to look for.
  "libjxl patent grant|0.12.0|Royalty-free patent licence|libjxl/PATENTS|https://github.com/libjxl/libjxl/blob/v0.12.0/PATENTS"
  # The three libraries compiled into cjxl. libjxl's tag tarball carries each
  # as an empty submodule directory, so build-compressors.sh fetches them at
  # the commits libjxl pins — see the comment there. Highway is dual-licensed
  # Apache-2.0 or BSD-3-Clause; the BSD text is the one reproduced here.
  "brotli|1.2.0|MIT|libjxl/third_party/brotli/LICENSE|https://github.com/google/brotli/archive/028fb5a23661f123017c060daa546b55cf4bde29.tar.gz"
  "highway|1.2.0|Apache-2.0 or BSD-3-Clause|libjxl/third_party/highway/LICENSE-BSD3|https://github.com/google/highway/archive/457c891775a7397bdb0376bb1031e6e027af1c48.tar.gz"
  "skcms|96d9171 (2025-09-16)|BSD-3-Clause|libjxl/third_party/skcms/LICENSE|https://github.com/google/skcms/archive/96d9171c94b937a1b5f0293de7309ac16311b722.tar.gz"
  "svgo|4.1.0|MIT|svgo/package/LICENSE|https://registry.npmjs.org/svgo/-/svgo-4.1.0.tgz"
)

{
  cat <<'HEADER'
# Third-party licenses

Shrinker Pro's own source code is MIT licensed (see `LICENSE`). The
distributed application also contains the programs below, each under its own
license.

**Three of them are under the GPL.** gifsicle and pngquant are shipped as
standalone command-line executables — in `Contents/Helpers/` inside the app,
and in `libexec/shrinker/` inside the `shrinker` command-line tool's archive.
They are invoked as separate processes over a command-line interface, so
Shrinker Pro does not link against them and no GPL code is compiled into the
application binary. Their licenses apply to those executables.

libimagequant is different and is listed separately below: it is compiled
*into* the pngquant executable rather than invoked alongside it.

Corresponding source for every component is listed below, and the exact
source archives used to build the shipped binaries — together with the
committed `Cargo.lock` that pins pngquant's dependency graph — are attached
to each GitHub release, alongside both the DMG and the CLI archive.

| Component | Version | License |
|---|---|---|
HEADER

  for entry in "${COMPONENTS[@]}"; do
    IFS='|' read -r name version license _ _ <<<"$entry"
    printf '| %s | %s | %s |\n' "$name" "$version" "$license"
  done

  cat <<'MIDDLE'
| ssimulacra2 (from libjxl), Shrinker Studio only | 0.12.0 | BSD-3-Clause |
| Rust crates compiled into pngquant, Little CMS among them | see below | MIT, Apache-2.0 and others |
| Sparkle | 2.9.6 | MIT |

`ssimulacra2`, the image-quality scorer Shrinker Studio runs for "Looks the
same", is built from libjxl's `tools/` at the version above, with the libpng
and mozjpeg listed here linked in statically, and ships in
`Contents/Helpers/` beside cjxl. libjxl's notice below covers it.

pngquant is written in Rust, and the crates it is built from are compiled
into its executable. Each one's license is reproduced after the components
below, every distinct text once with the crates it covers.

Sparkle is embedded as a framework and its license is reproduced at the end
of this file.

MIDDLE

  for entry in "${COMPONENTS[@]}"; do
    IFS='|' read -r name version license file url <<<"$entry"
    [ -f "$SRC/$file" ] || { echo "FAIL  missing license file: $SRC/$file" >&2; exit 1; }
    printf -- '---\n\n## %s %s\n\nLicense: %s\nSource: %s\n\n```\n' "$name" "$version" "$license" "$url"
    cat "$SRC/$file"
    printf '```\n\n'
  done

  # The crates pngquant was built from: every registry package in its pinned
  # Cargo.lock that cargo actually downloaded (the lock also lists packages
  # for other platforms and switched-off features, which are never fetched
  # and so never built). Read from cargo's local registry, which
  # build-compressors.sh populated, so this needs no network.
  python3 - "$ROOT/vendor/pngquant-3.0.3-Cargo.lock" "${CARGO_HOME:-$HOME/.cargo}/registry/src" <<'CRATES' || exit 1
import glob, os, re, sys
lock, registry = sys.argv[1], sys.argv[2]
roots = sorted(glob.glob(os.path.join(registry, "*")))
if not roots:
    sys.exit(f"FAIL  no cargo registry at {registry} -- run ./scripts/build-compressors.sh first")
packages = re.findall(r'\[\[package\]\]\nname = "([^"]+)"\nversion = "([^"]+)"\nsource = "registry', open(lock).read())
# A crate whose license is a component's already reproduced above, carried in
# its vendored sources' headers rather than a file of its own.
covered = {"libpng-sys": "libpng's vendored copy: the libpng License, reproduced above under libpng"}
texts, referenced = {}, []
for name, version in packages:
    folder = next((os.path.join(r, f"{name}-{version}") for r in roots if os.path.isdir(os.path.join(r, f"{name}-{version}"))), None)
    if folder is None:
        continue
    toml = open(os.path.join(folder, "Cargo.toml"), encoding="utf-8", errors="replace").read()
    declared = (re.search(r'^license\s*=\s*"([^"]+)"', toml, re.M) or [None, "see text"])[1]
    files = sorted(glob.glob(os.path.join(folder, "LICEN[CS]E*")) + glob.glob(os.path.join(folder, "COPYING*"))
                   + glob.glob(os.path.join(folder, "COPYRIGHT*")))
    # lcms2-sys keeps Little CMS's own license with the sources it vendors.
    files += sorted(glob.glob(os.path.join(folder, "vendor", "LICENSE*")) + glob.glob(os.path.join(folder, "vendor", "COPYING*")))
    if not files and name in covered:
        referenced.append(f"{name} {version} ({declared}): {covered[name]}.")
        continue
    if not files:
        sys.exit(f"FAIL  {name} {version} ({declared}) has no license file in {folder}")
    for path in files:
        text = open(path, encoding="utf-8", errors="replace").read().strip()
        label = f"{name} {version}" + (" (Little CMS)" if "vendor" in os.path.relpath(path, folder) else "")
        texts.setdefault(text, []).append((label, declared, os.path.basename(path)))
print("---\n\n## Rust crates compiled into pngquant\n")
print("Each distinct license text once, after the crates it covers.\n")
for line in referenced:
    print("- " + line)
if referenced:
    print()
for text, users in texts.items():
    print("### " + ", ".join(sorted({u[0] for u in users})) + "\n")
    print("License: " + ", ".join(sorted({u[1] for u in users})) + "\n")
    print("```\n" + text + "\n```\n")
CRATES

  printf -- '---\n\n## Sparkle 2.9.6\n\nLicense: MIT\nSource: https://github.com/sparkle-project/Sparkle/releases/tag/2.9.6\n\n```\n'
  cat <<'SPARKLE'
Copyright (c) 2006-2013 Andy Matuschak.
Copyright (c) 2009-2013 Elgato Systems GmbH.
Copyright (c) 2011-2014 Kornel Lesinski.
Copyright (c) 2015-2017 Mayur Pawashe.
Copyright (c) 2014 C.W. Betts.
Copyright (c) 2014 Petroules Corporation.
Copyright (c) 2014 Big Nerd Ranch.
All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
SPARKLE
  printf '```\n'
} > "$OUT"

echo "wrote $OUT ($(wc -l <"$OUT" | tr -d ' ') lines)"
