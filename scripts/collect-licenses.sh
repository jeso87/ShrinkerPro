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
  "gifsicle|1.96|GPL-2.0|gifsicle/COPYING|https://github.com/kohler/gifsicle/archive/refs/tags/v1.96.tar.gz"
  "libwebp (cwebp)|1.6.0|BSD-3-Clause|libwebp/COPYING|https://github.com/webmproject/libwebp/archive/refs/tags/v1.6.0.tar.gz"
  "libpng|1.6.58|libpng-2.0|libpng/LICENSE|https://github.com/pnggroup/libpng/archive/refs/tags/v1.6.58.tar.gz"
  "svgo|4.1.0|MIT|svgo/package/LICENSE|https://registry.npmjs.org/svgo/-/svgo-4.1.0.tgz"
)

{
  cat <<'HEADER'
# Third-party licenses

Shrinker Pro's own source code is MIT licensed (see `LICENSE`). The
distributed application also contains the programs below, each under its own
license.

**Two of them are under the GPL.** They are shipped as standalone
command-line executables in `Contents/Helpers/`, invoked as separate
processes over a command-line interface — Shrinker Pro does not link against
them, and no GPL code is compiled into the application binary. Their licenses
apply to those executables.

Corresponding source for every component is listed below, and the exact
source archives used to build the shipped binaries are attached to each
GitHub release alongside the DMG.

| Component | Version | License |
|---|---|---|
HEADER

  for entry in "${COMPONENTS[@]}"; do
    IFS='|' read -r name version license _ _ <<<"$entry"
    printf '| %s | %s | %s |\n' "$name" "$version" "$license"
  done

  cat <<'MIDDLE'
| Sparkle | 2.9.6 | MIT |

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
