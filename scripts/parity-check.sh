#!/usr/bin/env bash
# Compares Shrinker Pro's output against upstream Image Shrinker's for the
# same inputs. Upstream's x64 binaries run under Rosetta; ours run native.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UP="$ROOT/upstream-image-shrinker"
WORK="$ROOT/vendor/src/parity"

# upstream-image-shrinker/ was deleted in commit ca42a82 — the reference clone
# is no longer part of this repository, so this script cannot just be run: the
# upstream tree has to be re-cloned first. Saying "run npm install in $UP"
# would send a future maintainer looking for a directory that isn't there.
if [ ! -d "$UP/node_modules" ]; then
  cat >&2 <<EOF
parity-check needs upstream Image Shrinker's own x64 binaries, which are not
vendored here. Re-create the reference clone first:

    git clone https://github.com/stefansl/image-shrinker "$UP"
    (cd "$UP" && npm install)

then re-run this script. (The clone was removed from this repo in ca42a82;
it is a comparison aid, not a build dependency.)
EOF
  exit 1
fi
rm -rf "$WORK" && mkdir -p "$WORK/ours" "$WORK/theirs"

for f in "$ROOT"/Tests/ShrinkerProTests/Fixtures/sample.*; do
  base=$(basename "$f")
  cp "$f" "$WORK/ours/$base"
  cp "$f" "$WORK/theirs/$base"
done

echo "==> ours (native arm64)"
"$ROOT/vendor/compressors/cjpeg"    -outfile "$WORK/ours/out.jpg" "$WORK/ours/sample.jpg"
"$ROOT/vendor/compressors/pngquant" -fo      "$WORK/ours/out.png" "$WORK/ours/sample.png"
"$ROOT/vendor/compressors/gifsicle" -o       "$WORK/ours/out.gif" "$WORK/ours/sample.gif" -O=2 -i

echo "==> theirs (upstream x64 via Rosetta)"
"$UP/node_modules/mozjpeg/vendor/cjpeg"        -outfile "$WORK/theirs/out.jpg" "$WORK/theirs/sample.jpg"
"$UP/node_modules/pngquant-bin/vendor/pngquant" -fo     "$WORK/theirs/out.png" "$WORK/theirs/sample.png"
"$UP/node_modules/gifsicle/vendor/gifsicle"    -o       "$WORK/theirs/out.gif" "$WORK/theirs/sample.gif" -O=2 -i

echo
printf '%-6s %12s %12s   %s\n' FORMAT OURS THEIRS VERDICT
for ext in jpg png gif; do
  ours=$(stat -f%z "$WORK/ours/out.$ext")
  theirs=$(stat -f%z "$WORK/theirs/out.$ext")
  if cmp -s "$WORK/ours/out.$ext" "$WORK/theirs/out.$ext"; then
    verdict="identical"
  elif [ "$theirs" -eq 0 ]; then
    # A zero-byte upstream output means their run failed, not that ours is
    # infinitely worse — and dividing by it would kill the script mid-table
    # under `set -e`, hiding the formats that did compare cleanly.
    verdict="upstream produced 0 bytes — their run failed; no comparison possible"
  else
    delta=$(( (ours - theirs) * 100 / theirs ))
    verdict="differs (${delta}% size delta — expected, newer upstream tool versions)"
  fi
  printf '%-6s %12s %12s   %s\n' "$ext" "$ours" "$theirs" "$verdict"
done
