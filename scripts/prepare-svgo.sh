#!/usr/bin/env bash
# Fetches svgo and rewrites its ESM export into a globalThis assignment so
# JSContext (which has no ES module loader) can evaluate it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SVGO_VERSION=4.1.0
WORK="$ROOT/vendor/src/svgo"
DEST="$ROOT/Sources/ShrinkerPro/Resources/svgo.jsc.js"

rm -rf "$WORK" && mkdir -p "$WORK"
pushd "$WORK" >/dev/null
npm pack "svgo@$SVGO_VERSION" --silent >/dev/null
tar xzf "svgo-$SVGO_VERSION.tgz"
popd >/dev/null

python3 - "$WORK/package/dist/svgo.browser.js" "$DEST" <<'PY'
import re, sys, pathlib
src = pathlib.Path(sys.argv[1]).read_text()
new, n = re.subn(
    r'export\{([^}]*)\}\s*$',
    lambda m: "globalThis.svgo={" + ",".join(x.strip() for x in m.group(1).split(",")) + "};",
    src,
)
if n != 1:
    raise SystemExit(f"expected exactly 1 trailing ESM export, found {n} — svgo bundle format changed")
# Not anchored to line start: a different minifier could emit a static
# import mid-line (e.g. `;import{x}from"y"`) or a dynamic import(...)/
# import.meta. The negative lookbehind excludes identifiers that merely
# contain "import" (e.g. "importantStyles", "reimport") by requiring the
# preceding character not be an identifier character.
if re.search(r'(?<![A-Za-z0-9_$])import(?=[\s{(.])', new):
    raise SystemExit("bundle contains import statements; JSContext cannot resolve them")
pathlib.Path(sys.argv[2]).write_text(new)
print(f"wrote {sys.argv[2]} ({len(new)} bytes)")
PY
