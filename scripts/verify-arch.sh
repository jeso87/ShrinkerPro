#!/usr/bin/env bash
# Fails if any Mach-O under the given path is not arm64-only, targets a
# minimum macOS above the deployment target, or links anything outside
# /usr/lib and /System/Library.
set -uo pipefail

TARGET="${1:?usage: verify-arch.sh <path-to-app-or-directory>}"

# Must match MACOSX_DEPLOYMENT_TARGET in project.yml and the compressors'
# -mmacosx-version-min in build-compressors.sh. A shipped Mach-O whose
# LC_BUILD_VERSION minos is *above* this would crash on launch ("not
# supported on this version of macOS") for users the app claims to support.
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-14.0}"

# Fail closed (Ruling 9): this script is the release gate — a target that
# doesn't exist must never be reported as PASS. Silently passing on a wrong
# target (e.g. from a stale --configuration flag or a build that produced
# nothing) would be the same vacuous-pass failure this whole task exists to
# prevent, just moved up to the target-resolution layer.
[ -e "$TARGET" ] || { echo "FAIL  target does not exist: $TARGET" >&2; exit 1; }

# Defense in depth against the same class of bug that broke `xcodebuild
# archive`: the walk below uses `find -type f`, which does not traverse a
# symlink, so a TARGET that is itself a symlink to a real bundle would
# enumerate nothing. That currently fail-closes at the EXAMINED == 0 check —
# correct, but it reports the bundle as empty when it is merely indirect.
# Resolve a symlinked directory target to its physical path so the gate
# inspects the thing it was pointed at instead. (Xcode plants exactly such a
# symlink at BUILT_PRODUCTS_DIR/<wrapper> during an archive.) Only the
# top-level target is resolved; nothing about the strictness of the per-file
# checks below changes.
if [ -L "$TARGET" ] && [ -d "$TARGET" ]; then
  RESOLVED="$(cd "$TARGET" && pwd -P)" || {
    echo "FAIL  target is a symlink that could not be resolved: $TARGET" >&2
    exit 1
  }
  echo "note: target is a symlink; verifying its physical path $RESOLVED"
  TARGET="$RESOLVED"
fi

FAILED=0
EXAMINED=0

is_macho() {
  local magic
  magic=$(xxd -p -l 4 "$1" 2>/dev/null) || return 1
  case "$magic" in
    # 64-bit Mach-O (LE/BE), 32-bit fat/universal (LE/BE), and 64-bit
    # fat/universal (LE/BE, used when a fat archive has many slices or
    # large offsets — e.g. vendored multi-arch compressor binaries).
    cffaedfe|feedfacf|cafebabe|bebafeca|cafebabf|bfbafeca) return 0 ;;
    *) return 1 ;;
  esac
}

while IFS= read -r -d '' file; do
  is_macho "$file" || continue
  EXAMINED=$((EXAMINED + 1))

  archs=$(lipo -archs "$file" 2>/dev/null | tr -s ' ' | sed 's/^ *//;s/ *$//')
  # Intentionally strict equality against the literal string "arm64": this
  # also rejects "arm64e" (Apple's pointer-authentication ABI variant, as
  # shipped in many system binaries such as /bin/ls). arm64e is a distinct
  # architecture from arm64, not a superset of it — rejecting it here is
  # correct and deliberate, not a bug to "fix" by loosening this comparison.
  if [ "$archs" != "arm64" ]; then
    echo "FAIL [arch]  $file"
    echo "             expected 'arm64', got '$archs'"
    FAILED=1
  fi

  # Spec: reject an LC_BUILD_VERSION minos above the deployment target.
  # Older toolchains emit LC_VERSION_MIN_MACOSX with a "version" field
  # instead, so accept either. Fat files report one load command per slice;
  # every one of them is checked.
  minos_list=$(otool -l "$file" 2>/dev/null | awk '
    /LC_BUILD_VERSION|LC_VERSION_MIN_MACOSX/ { want = 1; next }
    want && ($1 == "minos" || $1 == "version") { print $2; want = 0 }
    /^Load command/ { want = 0 }
  ')
  if [ -z "$minos_list" ]; then
    # Fail closed: a shipped Mach-O with no minimum-OS load command at all
    # is unverifiable, not "fine".
    echo "FAIL [minos] $file"
    echo "             no LC_BUILD_VERSION/LC_VERSION_MIN_MACOSX found; cannot verify minimum OS"
    FAILED=1
  else
    while IFS= read -r minos; do
      [ -n "$minos" ] || continue
      # Compare as dotted version numbers: sort -V puts the larger last, so
      # if the larger of {minos, target} is minos and they differ, minos is
      # above the deployment target.
      larger=$(printf '%s\n%s\n' "$minos" "$DEPLOYMENT_TARGET" | sort -V | tail -n 1)
      if [ "$minos" != "$DEPLOYMENT_TARGET" ] && [ "$larger" = "$minos" ]; then
        echo "FAIL [minos] $file"
        echo "             minos $minos is above the deployment target $DEPLOYMENT_TARGET"
        FAILED=1
      fi
    done <<< "$minos_list"
  fi

  otool_output=$(otool -L "$file" 2>/dev/null)
  if [ -z "$otool_output" ]; then
    # Fail closed (Ruling 9, minor 2): if otool -L produces no output at all
    # for a file already identified as Mach-O — e.g. it fails on a file
    # lipo can still read — that is unverifiable linkage, not "nothing to
    # check". Treat it as a FAIL instead of silently skipping the loop below.
    echo "FAIL [link]  $file"
    echo "             otool -L produced no output; cannot verify linkage"
    FAILED=1
  else
    while IFS= read -r lib; do
      case "$lib" in
        /usr/lib/*|/System/Library/*|@rpath/*|@executable_path/*|@loader_path/*) ;;
        *)
          echo "FAIL [link]  $file"
          echo "             links non-system library: $lib"
          FAILED=1
          ;;
      esac
    done < <(printf '%s\n' "$otool_output" | tail -n +2 | awk '{print $1}')
  fi
done < <(find "$TARGET" -type f -print0)

# Fail closed (Ruling 9): a target that exists but contains no Mach-O files
# at all (e.g. an empty directory, or a directory of unrelated files) must
# not report PASS either — nothing was actually verified.
if [ "$EXAMINED" -eq 0 ]; then
  echo "FAIL  no Mach-O files found under $TARGET — nothing was verified" >&2
  exit 1
fi

if [ "$FAILED" -eq 0 ]; then
  echo "PASS  $EXAMINED Mach-O file(s) under $TARGET are arm64-only, minos <= $DEPLOYMENT_TARGET, with system-only linkage"
fi
exit "$FAILED"
