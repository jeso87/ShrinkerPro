# Shrinker Pro Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Shrinker Pro — a native SwiftUI, arm64-only macOS image compressor with feature parity to Image Shrinker 1.6.5 — as a Developer ID signed, notarized DMG.

**Architecture:** Three layers. A SwiftUI shell handles drops, results, and settings. A UI-free `ShrinkEngine` dispatches on file extension to one of four `Compressor` implementations. Three of those spawn statically-linked arm64 CLI binaries embedded in `Contents/Helpers/`; the fourth runs svgo 4.1.0 inside JavaScriptCore. An architecture gate verifies every Mach-O in the bundle is arm64-only before release.

**Tech Stack:** Swift 6.3 / SwiftUI, macOS 14+, JavaScriptCore, XcodeGen, mozjpeg 4.1.5, pngquant 3.0.3, gifsicle 1.96, svgo 4.1.0, `notarytool`, `hdiutil`.

**Spec:** `docs/design/specs/2026-09-08-shrinker-pro-arm-port-design.md`

**Upstream reference:** `upstream-image-shrinker/` (gitignored clone of stefansl/image-shrinker v1.6.5). Read `main.js` and `renderer.js` for parity questions. Deleted in the final task.

## Global Constraints

Every task's requirements implicitly include this section.

- **arm64 only.** `ARCHS = arm64`, `EXCLUDED_ARCHS = x86_64`. No universal builds, no `lipo` fattening, no `x86_64` slice in any shipped Mach-O. Xcode's default `ARCHS_STANDARD` is `arm64 x86_64` and **must** be overridden.
- **Deployment target:** `MACOSX_DEPLOYMENT_TARGET = 14.0`. Compressors built with `-mmacosx-version-min=14.0`.
- **Bundle identifier:** `com.eightseven.shrinkerpro`
- **Product name:** `Shrinker Pro` — executable name `ShrinkerPro`
- **Signing identity:** `Developer ID Application: Eight-Seven Inc. (LY424U3HLD)`
- **Hardened runtime enabled.** Entitlement `com.apple.security.cs.allow-jit` (JavaScriptCore). **Not** sandboxed. Do **not** carry over upstream's `allow-unsigned-executable-memory`.
- **Helper binaries live in `Contents/Helpers/`**, signed individually, inside-out, before the app.
- **Compressor arguments are copied verbatim from upstream** so output stays byte-comparable. Do not "improve" them.
- **No secrets in the repo.** Notarization credentials come from the environment only.
- **TDD.** Every task writes a failing test first, watches it fail, then implements. Commit at the end of each task.

## Project decision: XcodeGen

The `.xcodeproj` is **generated** from a checked-in `project.yml` via XcodeGen, not hand-edited. Rationale: build settings that matter (`ARCHS`, `EXCLUDED_ARCHS`, entitlements, the Helpers copy phase) become reviewable lines in git rather than buried pbxproj entries, and the project is reproducible. `ShrinkerPro.xcodeproj` is gitignored; `project.yml` is the source of truth. After editing `project.yml`, always re-run `xcodegen generate`.

## File Structure

```
project.yml                          XcodeGen source of truth
Sources/ShrinkerPro/
  ShrinkerProApp.swift               @main, app lifecycle, AppDelegate for Finder opens
  AppModel.swift                     ObservableObject: results list, drop handling
  Views/
    ContentView.swift                Window root: drop zone + results
    DropZoneView.swift               Drop target, hover state, file picker
    ResultsListView.swift            Result rows, reveal-in-Finder
    SettingsView.swift               Settings scene
  Core/
    ShrinkEngine.swift               Extension dispatch -> Compressor
    Compressor.swift                 Protocol + ShrinkOutcome + ShrinkError
    ProcessRunner.swift              Spawns helpers, captures stderr
    HelperLocator.swift              Resolves Contents/Helpers/<name>
    JPEGCompressor.swift             cjpeg + upstream issue #54 workaround
    PNGCompressor.swift              pngquant
    GIFCompressor.swift              gifsicle
    SVGCompressor.swift              svgo via JavaScriptCore
    OutputPathResolver.swift         Upstream generateNewPath port
    Settings.swift                   UserDefaults-backed settings
    UpdateChecker.swift              GitHub releases version check
    Notifier.swift                   UserNotifications wrapper
  Resources/
    svgo.jsc.js                      Generated: svgo browser bundle, ESM stripped
    Assets.xcassets                  App icon
    Info.plist                       CFBundleDocumentTypes etc.
Tests/ShrinkerProTests/
  OutputPathResolverTests.swift
  SVGCompressorTests.swift
  BinaryCompressorTests.swift
  ShrinkEngineTests.swift
  ArchitectureGuardTests.swift
  Fixtures/                          sample.jpg/.png/.gif/.svg
scripts/
  bootstrap.sh                       Toolchain prerequisites
  build-compressors.sh               Build static arm64 mozjpeg/pngquant/gifsicle
  prepare-svgo.sh                    Fetch svgo, strip ESM export
  verify-arch.sh                     Architecture release gate
  release.sh                         archive -> verify -> notarize -> staple -> DMG
build/
  entitlements.plist
  dmg-background.tiff
vendor/compressors/                  Built binaries (gitignored)
```

---

### Task 1: Project scaffold that builds and tests

Establishes the Xcode project with architecture pinned correctly from the first commit, so no later task can accidentally inherit Xcode's universal default.

**Files:**
- Create: `project.yml`, `Sources/ShrinkerPro/ShrinkerProApp.swift`, `Sources/ShrinkerPro/Resources/Info.plist`, `build/entitlements.plist`, `scripts/bootstrap.sh`
- Create: `Tests/ShrinkerProTests/ArchitectureGuardTests.swift`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: nothing
- Produces: a buildable scheme named `ShrinkerPro`; build products at `build/DerivedData/Build/Products/Release/Shrinker Pro.app`

- [ ] **Step 1: Point xcode-select at full Xcode and install prerequisites**

`xcodebuild` is currently unavailable because `xcode-select -p` returns the Command Line Tools path. Write `scripts/bootstrap.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

if [ "$(xcode-select -p)" != "/Applications/Xcode.app/Contents/Developer" ]; then
  echo "Pointing xcode-select at full Xcode (requires sudo)..."
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
fi

for tool in xcodegen cmake; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Installing $tool..."
    brew install "$tool"
  fi
done

if ! command -v cargo >/dev/null 2>&1; then
  echo "Installing Rust toolchain (needed by pngquant 3.x)..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
fi
# shellcheck disable=SC1090
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

echo "xcodebuild: $(xcodebuild -version | head -1)"
echo "xcodegen:   $(xcodegen --version)"
echo "cmake:      $(cmake --version | head -1)"
echo "cargo:      $(cargo --version)"
echo "Bootstrap complete."
```

Run: `chmod +x scripts/bootstrap.sh && ./scripts/bootstrap.sh`
Expected: all four versions print. The Rust install takes several minutes.

- [ ] **Step 2: Write project.yml with architecture pinned**

```yaml
name: ShrinkerPro
options:
  bundleIdPrefix: com.eightseven
  deploymentTarget:
    macOS: "14.0"
  createIntermediateGroups: true

settings:
  base:
    ARCHS: arm64
    EXCLUDED_ARCHS: x86_64
    ONLY_ACTIVE_ARCH: NO
    MACOSX_DEPLOYMENT_TARGET: "14.0"
    SWIFT_VERSION: "6.0"
    ENABLE_HARDENED_RUNTIME: YES
    CODE_SIGN_ENTITLEMENTS: build/entitlements.plist
    DEVELOPMENT_TEAM: LY424U3HLD
    PRODUCT_NAME: ShrinkerPro
    MARKETING_VERSION: "1.0.0"
    CURRENT_PROJECT_VERSION: "1"

targets:
  ShrinkerPro:
    type: application
    platform: macOS
    sources:
      - path: Sources/ShrinkerPro
        excludes: ["Resources/Info.plist"]
    settings:
      base:
        INFOPLIST_FILE: Sources/ShrinkerPro/Resources/Info.plist
        PRODUCT_BUNDLE_IDENTIFIER: com.eightseven.shrinkerpro
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        CODE_SIGN_STYLE: Manual
        CODE_SIGN_IDENTITY: "Developer ID Application"

  ShrinkerProTests:
    type: bundle.unit-test
    platform: macOS
    sources: [Tests/ShrinkerProTests]
    dependencies:
      - target: ShrinkerPro
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.eightseven.shrinkerpro.tests

schemes:
  ShrinkerPro:
    build:
      targets:
        ShrinkerPro: all
        ShrinkerProTests: [test]
    test:
      targets: [ShrinkerProTests]
```

- [ ] **Step 3: Write Info.plist, entitlements, and a minimal app**

`Sources/ShrinkerPro/Resources/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Shrinker Pro</string>
    <key>CFBundleDisplayName</key><string>Shrinker Pro</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$(MARKETING_VERSION)</string>
    <key>CFBundleVersion</key><string>$(CURRENT_PROJECT_VERSION)</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHumanReadableCopyright</key><string>Free software. Based on Image Shrinker by Stefan Schulz-Lauterbach (CC0-1.0).</string>
</dict>
</plist>
```

`build/entitlements.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-jit</key>
    <true/>
</dict>
</plist>
```

`Sources/ShrinkerPro/ShrinkerProApp.swift`:

```swift
import SwiftUI

@main
struct ShrinkerProApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Shrinker Pro")
                .frame(width: 340, height: 550)
        }
        .windowResizability(.contentSize)
    }
}
```

- [ ] **Step 4: Write the failing architecture test**

`Tests/ShrinkerProTests/ArchitectureGuardTests.swift`:

```swift
import XCTest

final class ArchitectureGuardTests: XCTestCase {

    /// Every Mach-O in the app bundle must be arm64-only.
    /// Guards against Xcode's default ARCHS_STANDARD (arm64 x86_64).
    func testAppBundleIsArm64Only() throws {
        let appURL = try Self.builtAppURL()
        let binaries = try Self.machOFiles(in: appURL)
        XCTAssertFalse(binaries.isEmpty, "found no Mach-O files in \(appURL.path)")

        for binary in binaries {
            let archs = try Self.architectures(of: binary)
            XCTAssertEqual(
                archs, ["arm64"],
                "\(binary.lastPathComponent) has architectures \(archs), expected exactly [arm64]"
            )
        }
    }

    // MARK: - Helpers

    static func builtAppURL() throws -> URL {
        // The test bundle sits next to the app under test in the products dir.
        let testBundle = Bundle(for: ArchitectureGuardTests.self)
        let productsDir = testBundle.bundleURL.deletingLastPathComponent()
        let app = productsDir.appendingPathComponent("Shrinker Pro.app")
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw XCTSkip("app bundle not found at \(app.path)")
        }
        return app
    }

    static func machOFiles(in root: URL) throws -> [URL] {
        var found: [URL] = []
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]
        )
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            if try isMachO(url) { found.append(url) }
        }
        return found
    }

    /// Identify by magic number, not by directory, so binaries added later are covered.
    static func isMachO(_ url: URL) throws -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: 4), data.count == 4 else { return false }
        let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        // 64-bit Mach-O (LE/BE) and universal/fat archives.
        return [0xfeedfacf, 0xcffaedfe, 0xcafebabe, 0xbebafeca].contains(magic)
    }

    static func architectures(of binary: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lipo")
        process.arguments = ["-archs", binary.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").map(String.init)
    }
}
```

- [ ] **Step 5: Generate, build, and run the test**

```bash
xcodegen generate
xcodebuild test -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData | tail -20
```

Expected: PASS. If it fails reporting `["arm64", "x86_64"]`, the `EXCLUDED_ARCHS` setting did not apply — fix `project.yml` before continuing. **Do not proceed with a failing architecture test.**

- [ ] **Step 6: Commit**

```bash
cat >> .gitignore <<'EOF'

# XcodeGen output (project.yml is the source of truth)
*.xcodeproj/
build/DerivedData/
EOF
git add project.yml Sources build/entitlements.plist scripts/bootstrap.sh Tests .gitignore
git commit -m "Scaffold arm64-only Xcode project with architecture guard test"
```

---

### Task 2: verify-arch.sh release gate

The test in Task 1 covers the app bundle during test runs. This is the standalone gate that also runs over `vendor/compressors/` and blocks `release.sh`.

**Files:**
- Create: `scripts/verify-arch.sh`
- Modify: `Tests/ShrinkerProTests/ArchitectureGuardTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `scripts/verify-arch.sh <path>` — exits 0 if every Mach-O under `<path>` is arm64-only with no non-system linkage; exits 1 with a diagnostic otherwise.

- [ ] **Step 1: Write the failing test — the gate must reject a fat binary**

A gate that never rejects anything passes vacuously. This test fattens a real binary and asserts rejection. Append to `ArchitectureGuardTests.swift`:

```swift
extension ArchitectureGuardTests {

    func testVerifyArchRejectsUniversalBinary() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("archgate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // /bin/ls ships as a universal binary on macOS; copy it in as a poisoned artifact.
        let fat = tmp.appendingPathComponent("fatbinary")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: fat)
        let archs = try Self.architectures(of: fat)
        try XCTSkipUnless(archs.count > 1, "/bin/ls is not universal on this system")

        let exit = try Self.runVerifyArch(on: tmp)
        XCTAssertEqual(exit, 1, "verify-arch.sh accepted a universal binary — the gate is not working")
    }

    func testVerifyArchAcceptsArm64OnlyBinary() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("archgate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let thin = tmp.appendingPathComponent("thinbinary")
        let lipo = Process()
        lipo.executableURL = URL(fileURLWithPath: "/usr/bin/lipo")
        lipo.arguments = ["/bin/ls", "-thin", "arm64", "-output", thin.path]
        try lipo.run()
        lipo.waitUntilExit()
        try XCTSkipUnless(lipo.terminationStatus == 0, "could not thin /bin/ls to arm64")

        let exit = try Self.runVerifyArch(on: tmp)
        XCTAssertEqual(exit, 0, "verify-arch.sh rejected a valid arm64-only binary")
    }

    static func runVerifyArch(on path: URL) throws -> Int32 {
        // Tests run from DerivedData; walk up to the repo root via SRCROOT if present.
        let repoRoot = ProcessInfo.processInfo.environment["SRCROOT"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let script = repoRoot.appendingPathComponent("scripts/verify-arch.sh")
        let process = Process()
        process.executableURL = script
        process.arguments = [path.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcodebuild test -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData 2>&1 | grep -E 'testVerifyArch|error:' | head
```

Expected: FAIL — `scripts/verify-arch.sh` does not exist yet, so `process.run()` throws.

- [ ] **Step 3: Write verify-arch.sh**

```bash
#!/usr/bin/env bash
# Fails if any Mach-O under the given path is not arm64-only, or links
# anything outside /usr/lib and /System/Library.
set -uo pipefail

TARGET="${1:?usage: verify-arch.sh <path-to-app-or-directory>}"
FAILED=0

is_macho() {
  local magic
  magic=$(xxd -p -l 4 "$1" 2>/dev/null) || return 1
  case "$magic" in
    cffaedfe|feedfacf|cafebabe|bebafeca) return 0 ;;
    *) return 1 ;;
  esac
}

while IFS= read -r -d '' file; do
  is_macho "$file" || continue

  archs=$(lipo -archs "$file" 2>/dev/null | tr -s ' ' | sed 's/^ *//;s/ *$//')
  if [ "$archs" != "arm64" ]; then
    echo "FAIL [arch]  $file"
    echo "             expected 'arm64', got '$archs'"
    FAILED=1
  fi

  while IFS= read -r lib; do
    case "$lib" in
      /usr/lib/*|/System/Library/*|@rpath/*|@executable_path/*|@loader_path/*) ;;
      *)
        echo "FAIL [link]  $file"
        echo "             links non-system library: $lib"
        FAILED=1
        ;;
    esac
  done < <(otool -L "$file" 2>/dev/null | tail -n +2 | awk '{print $1}')
done < <(find "$TARGET" -type f -print0)

if [ "$FAILED" -eq 0 ]; then
  echo "PASS  all Mach-O files under $TARGET are arm64-only with system-only linkage"
fi
exit "$FAILED"
```

Note the `@rpath`/`@executable_path`/`@loader_path` allowances: Swift apps legitimately reference their own embedded runtime that way. A `/opt/homebrew/...` path is what this catches.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
chmod +x scripts/verify-arch.sh
./scripts/verify-arch.sh "build/DerivedData/Build/Products/Debug/Shrinker Pro.app"
xcodebuild test -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData 2>&1 | grep -E 'testVerifyArch|Test Suite.*passed' | head
```

Expected: the script prints PASS, and both `testVerifyArch*` tests pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/verify-arch.sh Tests/ShrinkerProTests/ArchitectureGuardTests.swift
git commit -m "Add verify-arch release gate with anti-vacuity test"
```

---

### Task 3: Build static arm64 compressors

The riskiest build task. pngquant 3.x links a Rust libimagequant; if static linking proves intractable, fall back to pngquant 2.17.0 (pure C) as the spec's risk table allows.

**Files:**
- Create: `scripts/build-compressors.sh`
- Output (gitignored): `vendor/compressors/{cjpeg,pngquant,gifsicle}`

**Interfaces:**
- Consumes: `scripts/verify-arch.sh` from Task 2
- Produces: three executables in `vendor/compressors/`, each arm64-only, linking only system libraries

- [ ] **Step 1: Write build-compressors.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/vendor/src"
OUT="$ROOT/vendor/compressors"
MIN_MACOS=14.0

export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
export CFLAGS="-arch arm64 -mmacosx-version-min=$MIN_MACOS -O2"
export LDFLAGS="-arch arm64 -mmacosx-version-min=$MIN_MACOS"

mkdir -p "$SRC" "$OUT"
# shellcheck disable=SC1090
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

fetch() { # url, dirname
  local url="$1" dir="$2"
  if [ ! -d "$SRC/$dir" ]; then
    echo "==> fetching $dir"
    curl -fsSL "$url" -o "$SRC/$dir.tar.gz"
    mkdir -p "$SRC/$dir"
    tar xzf "$SRC/$dir.tar.gz" -C "$SRC/$dir" --strip-components=1
  fi
}

# ---------- mozjpeg 4.1.5 -> cjpeg ----------
build_mozjpeg() {
  echo "==> building mozjpeg (cjpeg)"
  fetch https://github.com/mozilla/mozjpeg/archive/refs/tags/v4.1.5.tar.gz mozjpeg
  rm -rf "$SRC/mozjpeg/build" && mkdir -p "$SRC/mozjpeg/build"
  cmake -S "$SRC/mozjpeg" -B "$SRC/mozjpeg/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
    -DENABLE_SHARED=FALSE \
    -DENABLE_STATIC=TRUE \
    -DPNG_SUPPORTED=FALSE \
    -DWITH_TURBOJPEG=FALSE
  cmake --build "$SRC/mozjpeg/build" --target cjpeg -j"$(sysctl -n hw.ncpu)"
  cp "$SRC/mozjpeg/build/cjpeg" "$OUT/cjpeg"
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
  fetch https://github.com/kornelski/pngquant/archive/refs/tags/3.0.3.tar.gz pngquant
  pushd "$SRC/pngquant" >/dev/null
  cargo build --release --target aarch64-apple-darwin
  popd >/dev/null
  cp "$SRC/pngquant/target/aarch64-apple-darwin/release/pngquant" "$OUT/pngquant"
}

build_mozjpeg
build_gifsicle
build_pngquant

echo
echo "==> verifying architecture"
"$ROOT/scripts/verify-arch.sh" "$OUT"
echo
for b in cjpeg gifsicle pngquant; do
  printf '%-10s %s\n' "$b" "$(lipo -archs "$OUT/$b")"
done
```

- [ ] **Step 2: Run it**

```bash
chmod +x scripts/build-compressors.sh
./scripts/build-compressors.sh
```

Expected: `verify-arch.sh` prints PASS and each binary reports `arm64`.

**If pngquant fails to build or links non-system libraries** (the known risk), fall back to pngquant 2.17.0, which is pure C, by replacing `build_pngquant` with:

```bash
build_pngquant() {
  echo "==> building pngquant 2.17.0 (C fallback)"
  fetch https://github.com/kornelski/pngquant/archive/refs/tags/2.17.0.tar.gz pngquant
  pushd "$SRC/pngquant" >/dev/null
  git submodule update --init 2>/dev/null || true
  ./configure --without-cocoa --without-libpng
  make -j"$(sysctl -n hw.ncpu)"
  popd >/dev/null
  cp "$SRC/pngquant/pngquant" "$OUT/pngquant"
}
```

Record which variant was used in the commit message.

- [ ] **Step 3: Smoke-test each binary against a real image**

```bash
mkdir -p /tmp/shrinkercheck
sips -s format jpeg /System/Library/Desktop\ Pictures/*.heic \
  --out /tmp/shrinkercheck/in.jpg 2>/dev/null || \
  sips -s format jpeg "$(find /System/Library -name '*.png' | head -1)" --out /tmp/shrinkercheck/in.jpg
./vendor/compressors/cjpeg -outfile /tmp/shrinkercheck/out.jpg /tmp/shrinkercheck/in.jpg
ls -l /tmp/shrinkercheck/
file /tmp/shrinkercheck/out.jpg
```

Expected: `out.jpg` exists, is smaller than `in.jpg`, and `file` reports JPEG image data.

- [ ] **Step 4: Commit**

`vendor/compressors/` is gitignored — only the script is committed.

```bash
git add scripts/build-compressors.sh
git commit -m "Add static arm64 compressor build script (mozjpeg, gifsicle, pngquant)"
```

---

### Task 4: svgo in JavaScriptCore

The approach is already proven in a spike: svgo 4.1.0's browser bundle is an ES module with no imports, and rewriting its single trailing `export{...}` into a `globalThis` assignment makes it loadable by `JSContext`. Verified output on a 155-byte fixture: 109 bytes, comment stripped, `rect` converted to `path`.

**Files:**
- Create: `scripts/prepare-svgo.sh`, `Sources/ShrinkerPro/Core/SVGCompressor.swift`, `Sources/ShrinkerPro/Core/Compressor.swift`
- Create: `Tests/ShrinkerProTests/SVGCompressorTests.swift`, `Tests/ShrinkerProTests/Fixtures/sample.svg`
- Output (gitignored until Step 2): `Sources/ShrinkerPro/Resources/svgo.jsc.js`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `protocol Compressor { func compress(input: URL, output: URL) throws }`
  - `enum ShrinkError: Error, LocalizedError` with cases `unsupportedFormat(String)`, `helperMissing(String)`, `compressorFailed(tool: String, code: Int32, message: String)`, `javascriptFailed(String)`, `outputNotWritten(URL)`
  - `final class SVGCompressor: Compressor` with `init(scriptURL: URL) throws`

- [ ] **Step 1: Write prepare-svgo.sh**

```bash
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
if re.search(r'^\s*import[\s{]', new, re.M):
    raise SystemExit("bundle contains import statements; JSContext cannot resolve them")
pathlib.Path(sys.argv[2]).write_text(new)
print(f"wrote {sys.argv[2]} ({len(new)} bytes)")
PY
```

The two guard clauses matter: if a future svgo changes its bundle format, this fails loudly at build time rather than producing a script that silently defines nothing.

Run: `chmod +x scripts/prepare-svgo.sh && ./scripts/prepare-svgo.sh`
Expected: `wrote .../svgo.jsc.js (~804866 bytes)`

- [ ] **Step 2: Add the resource to project.yml and create the fixture**

Add to the `ShrinkerPro` target in `project.yml`, under `sources`:

```yaml
      - path: Sources/ShrinkerPro/Resources/svgo.jsc.js
        type: file
        buildPhase: resources
```

Add to the `ShrinkerProTests` target:

```yaml
    sources:
      - Tests/ShrinkerProTests
      - path: Tests/ShrinkerProTests/Fixtures
        type: folder
        buildPhase: resources
```

`Tests/ShrinkerProTests/Fixtures/sample.svg`:

```xml
<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><!-- removable comment --><g><rect x="0" y="0" width="100" height="100" fill="#ff0000"/></g></svg>
```

Then: `xcodegen generate`

- [ ] **Step 3: Write the failing test**

`Tests/ShrinkerProTests/SVGCompressorTests.swift`:

```swift
import XCTest
@testable import ShrinkerPro

final class SVGCompressorTests: XCTestCase {

    private func makeCompressor() throws -> SVGCompressor {
        let bundle = Bundle(for: SVGCompressorTests.self)
        guard let script = Bundle.main.url(forResource: "svgo.jsc", withExtension: "js")
            ?? bundle.url(forResource: "svgo.jsc", withExtension: "js") else {
            throw XCTSkip("svgo.jsc.js not bundled — run scripts/prepare-svgo.sh")
        }
        return try SVGCompressor(scriptURL: script)
    }

    func testShrinksSVGAndStripsComment() throws {
        let compressor = try makeCompressor()
        let input = try fixture("sample", "svg")
        let output = tempURL("out.svg")
        defer { try? FileManager.default.removeItem(at: output) }

        try compressor.compress(input: input, output: output)

        let before = try Data(contentsOf: input)
        let after = try Data(contentsOf: output)
        let text = String(decoding: after, as: UTF8.self)

        XCTAssertLessThan(after.count, before.count, "svgo did not reduce the file")
        XCTAssertFalse(text.contains("removable comment"), "comment survived optimization")
        XCTAssertTrue(text.hasPrefix("<svg"), "output is not an SVG document: \(text.prefix(40))")
    }

    func testReportsInvalidSVGAsError() throws {
        let compressor = try makeCompressor()
        let input = tempURL("bad.svg")
        try "<svg><unclosed>".write(to: input, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: input) }

        XCTAssertThrowsError(try compressor.compress(input: input, output: tempURL("bad.out.svg"))) { error in
            guard case ShrinkError.javascriptFailed = error else {
                return XCTFail("expected .javascriptFailed, got \(error)")
            }
        }
    }

    // MARK: - Helpers

    func fixture(_ name: String, _ ext: String) throws -> URL {
        let bundle = Bundle(for: SVGCompressorTests.self)
        guard let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: ext) else {
            throw XCTSkip("fixture \(name).\(ext) not found in test bundle")
        }
        return url
    }

    func tempURL(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString)-\(name)")
    }
}
```

- [ ] **Step 4: Run the test to verify it fails**

```bash
xcodebuild test -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData 2>&1 | grep -E 'SVGCompressor|error:' | head
```

Expected: FAIL — `cannot find 'SVGCompressor' in scope`.

- [ ] **Step 5: Write Compressor.swift**

```swift
import Foundation

/// Compresses a single image file. Implementations are stateless with respect
/// to individual calls and safe to reuse across files.
protocol Compressor {
    func compress(input: URL, output: URL) throws
}

enum ShrinkError: Error, LocalizedError {
    case unsupportedFormat(String)
    case helperMissing(String)
    case compressorFailed(tool: String, code: Int32, message: String)
    case javascriptFailed(String)
    case outputNotWritten(URL)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return "Only SVG, JPG, GIF and PNG are supported (got \"\(ext)\")."
        case .helperMissing(let name):
            return "The bundled \(name) tool is missing. The app may be damaged — try reinstalling."
        case .compressorFailed(let tool, let code, let message):
            let detail = message.isEmpty ? "" : ": \(message)"
            return "\(tool) failed with exit code \(code)\(detail)"
        case .javascriptFailed(let message):
            return "SVG optimization failed: \(message)"
        case .outputNotWritten(let url):
            return "No output was written to \(url.lastPathComponent)."
        }
    }
}
```

- [ ] **Step 6: Write SVGCompressor.swift**

```swift
import Foundation
import JavaScriptCore

/// Runs svgo 4.1.0 inside JavaScriptCore.
///
/// svgo ships `dist/svgo.browser.js` as an ES module, which `JSContext` cannot
/// load. `scripts/prepare-svgo.sh` rewrites its single trailing `export{...}`
/// into a `globalThis.svgo = {...}` assignment; this class consumes that
/// rewritten script. JavaScriptCore's JIT requires the
/// `com.apple.security.cs.allow-jit` entitlement under the hardened runtime.
final class SVGCompressor: Compressor {

    private let context: JSContext
    private let lock = NSLock()

    init(scriptURL: URL) throws {
        guard let context = JSContext() else {
            throw ShrinkError.javascriptFailed("could not create a JavaScript context")
        }
        self.context = context

        var thrown: String?
        context.exceptionHandler = { _, exception in
            thrown = exception?.toString() ?? "unknown JavaScript exception"
        }

        let source = try String(contentsOf: scriptURL, encoding: .utf8)
        context.evaluateScript(source, withSourceURL: scriptURL)
        if let thrown { throw ShrinkError.javascriptFailed("loading svgo: \(thrown)") }

        guard context.objectForKeyedSubscript("svgo")?.isObject == true else {
            throw ShrinkError.javascriptFailed(
                "svgo did not register itself — re-run scripts/prepare-svgo.sh"
            )
        }
    }

    func compress(input: URL, output: URL) throws {
        let svg = try String(contentsOf: input, encoding: .utf8)

        // JSContext is not thread-safe; serialize access.
        lock.lock()
        defer { lock.unlock() }

        var thrown: String?
        context.exceptionHandler = { _, exception in
            thrown = exception?.toString() ?? "unknown JavaScript exception"
        }

        context.setObject(svg, forKeyedSubscript: "__shrinkerInput" as NSString)
        let result = context.evaluateScript("globalThis.svgo.optimize(__shrinkerInput).data")
        context.setObject(nil, forKeyedSubscript: "__shrinkerInput" as NSString)

        if let thrown { throw ShrinkError.javascriptFailed(thrown) }
        guard let optimized = result?.toString(), !optimized.isEmpty, optimized != "undefined" else {
            throw ShrinkError.outputNotWritten(output)
        }

        try optimized.write(to: output, atomically: true, encoding: .utf8)
    }
}
```

- [ ] **Step 7: Run the tests to verify they pass**

```bash
xcodebuild test -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData 2>&1 | grep -E 'SVGCompressor|Test Suite' | head
```

Expected: both `SVGCompressorTests` tests PASS.

- [ ] **Step 8: Commit**

```bash
git add scripts/prepare-svgo.sh project.yml \
  Sources/ShrinkerPro/Core/Compressor.swift \
  Sources/ShrinkerPro/Core/SVGCompressor.swift \
  Tests/ShrinkerProTests/SVGCompressorTests.swift \
  Tests/ShrinkerProTests/Fixtures/sample.svg
git commit -m "Run svgo 4.1.0 in JavaScriptCore for SVG compression"
```

---

### Task 5: OutputPathResolver

A direct port of upstream's `generateNewPath` (`upstream-image-shrinker/main.js`). This is the fiddliest logic in the original — three independent settings interact to produce the destination path — so it gets exhaustive tests.

**Files:**
- Create: `Sources/ShrinkerPro/Core/OutputPathResolver.swift`
- Create: `Tests/ShrinkerProTests/OutputPathResolverTests.swift`

**Interfaces:**
- Consumes: `ShrinkError` from Task 4
- Produces:
  - `struct OutputSettings { var saveInSameFolder: Bool; var savePath: URL?; var useSubfolder: Bool; var addSuffix: Bool }`
  - `enum OutputPathResolver { static func resolve(input: URL, settings: OutputSettings, fileManager: FileManager) throws -> URL }`

Naming note: upstream's setting is `folderswitch`, which reads as its inverse. It is surfaced in Swift as `saveInSameFolder` with identical semantics — `true` means save beside the original.

- [ ] **Step 1: Write the failing tests**

`Tests/ShrinkerProTests/OutputPathResolverTests.swift`:

```swift
import XCTest
@testable import ShrinkerPro

final class OutputPathResolverTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func input(_ name: String = "photo.png") -> URL {
        root.appendingPathComponent("source").appendingPathComponent(name)
    }

    private func settings(
        sameFolder: Bool = true, savePath: URL? = nil,
        subfolder: Bool = false, suffix: Bool = true
    ) -> OutputSettings {
        OutputSettings(
            saveInSameFolder: sameFolder, savePath: savePath,
            useSubfolder: subfolder, addSuffix: suffix
        )
    }

    // suffix on, subfolder off, same folder -> photo.min.png beside the original
    func testSuffixOnly() throws {
        let out = try OutputPathResolver.resolve(
            input: input(), settings: settings(), fileManager: .default
        )
        XCTAssertEqual(out.lastPathComponent, "photo.min.png")
        XCTAssertEqual(out.deletingLastPathComponent(), input().deletingLastPathComponent())
    }

    // suffix off, subfolder off, same folder -> output path equals input path
    func testNoSuffixOverwritesInPlace() throws {
        let out = try OutputPathResolver.resolve(
            input: input(), settings: settings(suffix: false), fileManager: .default
        )
        XCTAssertEqual(out.path, input().path,
                       "with no suffix and no subfolder, output must collide with input (upstream issue #54)")
    }

    // subfolder on -> minified/ subdirectory, created on disk
    func testSubfolderIsCreated() throws {
        let out = try OutputPathResolver.resolve(
            input: input(), settings: settings(subfolder: true), fileManager: .default
        )
        XCTAssertEqual(out.deletingLastPathComponent().lastPathComponent, "minified")
        XCTAssertEqual(out.lastPathComponent, "photo.min.png")
        var isDir: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: out.deletingLastPathComponent().path, isDirectory: &isDir)
            && isDir.boolValue,
            "resolver must create the destination directory"
        )
    }

    // saveInSameFolder false + savePath set -> redirected
    func testSavePathRedirects() throws {
        let dest = root.appendingPathComponent("elsewhere")
        let out = try OutputPathResolver.resolve(
            input: input(), settings: settings(sameFolder: false, savePath: dest), fileManager: .default
        )
        XCTAssertEqual(out.deletingLastPathComponent().path, dest.path)
        XCTAssertEqual(out.lastPathComponent, "photo.min.png")
    }

    // saveInSameFolder false but no savePath chosen -> fall back beside the original
    func testMissingSavePathFallsBackToSourceFolder() throws {
        let out = try OutputPathResolver.resolve(
            input: input(), settings: settings(sameFolder: false, savePath: nil), fileManager: .default
        )
        XCTAssertEqual(out.deletingLastPathComponent(), input().deletingLastPathComponent())
    }

    // savePath and subfolder compose: savePath/minified/
    func testSavePathAndSubfolderCompose() throws {
        let dest = root.appendingPathComponent("elsewhere")
        let out = try OutputPathResolver.resolve(
            input: input(),
            settings: settings(sameFolder: false, savePath: dest, subfolder: true),
            fileManager: .default
        )
        XCTAssertEqual(out.deletingLastPathComponent().path,
                       dest.appendingPathComponent("minified").path)
    }

    // Exhaustive: all 8 combinations resolve without throwing and keep the extension
    func testAllSettingCombinationsResolve() throws {
        let dest = root.appendingPathComponent("dest")
        for sameFolder in [true, false] {
            for subfolder in [true, false] {
                for suffix in [true, false] {
                    let cfg = settings(
                        sameFolder: sameFolder,
                        savePath: sameFolder ? nil : dest,
                        subfolder: subfolder, suffix: suffix
                    )
                    let out = try OutputPathResolver.resolve(
                        input: input(), settings: cfg, fileManager: .default
                    )
                    XCTAssertEqual(out.pathExtension, "png",
                                   "extension lost for sameFolder=\(sameFolder) subfolder=\(subfolder) suffix=\(suffix)")
                    let expectedName = suffix ? "photo.min.png" : "photo.png"
                    XCTAssertEqual(out.lastPathComponent, expectedName)
                }
            }
        }
    }

    // Multi-dot filenames keep only the final extension
    func testMultiDotFilename() throws {
        let out = try OutputPathResolver.resolve(
            input: input("my.photo.v2.png"), settings: settings(), fileManager: .default
        )
        XCTAssertEqual(out.lastPathComponent, "my.photo.v2.min.png")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData 2>&1 | grep -E 'OutputPathResolver|error:' | head
```

Expected: FAIL — `cannot find 'OutputPathResolver' in scope`.

- [ ] **Step 3: Write OutputPathResolver.swift**

```swift
import Foundation

/// The subset of settings that determine where a shrunken file is written.
struct OutputSettings: Equatable {
    /// Upstream calls this `folderswitch`. True means "save beside the original".
    var saveInSameFolder: Bool
    /// Destination used when `saveInSameFolder` is false.
    var savePath: URL?
    /// Write into a `minified/` subdirectory of the destination.
    var useSubfolder: Bool
    /// Append `.min` before the extension.
    var addSuffix: Bool
}

/// Port of upstream `generateNewPath` in image-shrinker's main.js.
///
/// Order matters and matches upstream: redirect the directory, then append the
/// subfolder, then create it, then build the filename.
enum OutputPathResolver {

    static func resolve(
        input: URL,
        settings: OutputSettings,
        fileManager: FileManager = .default
    ) throws -> URL {

        var directory = input.deletingLastPathComponent()

        // Upstream only redirects when a savepath actually exists; otherwise it
        // leaves the original directory in place.
        if !settings.saveInSameFolder, let savePath = settings.savePath {
            directory = savePath
        }

        if settings.useSubfolder {
            directory = directory.appendingPathComponent("minified", isDirectory: true)
        }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ShrinkError.outputNotWritten(directory)
        }

        let ext = input.pathExtension
        let stem = input.deletingPathExtension().lastPathComponent
        let name = settings.addSuffix ? stem + ".min" : stem

        return ext.isEmpty
            ? directory.appendingPathComponent(name)
            : directory.appendingPathComponent(name).appendingPathExtension(ext)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData 2>&1 | grep -E 'OutputPathResolver|Test Suite' | head
```

Expected: all eight `OutputPathResolverTests` tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ShrinkerPro/Core/OutputPathResolver.swift Tests/ShrinkerProTests/OutputPathResolverTests.swift
git commit -m "Port generateNewPath as OutputPathResolver with exhaustive tests"
```

---

### Task 6: Binary compressors (JPEG, PNG, GIF)

Wires the three vendored binaries in. Arguments are copied verbatim from upstream `main.js`; do not change them.

**Files:**
- Create: `Sources/ShrinkerPro/Core/ProcessRunner.swift`, `HelperLocator.swift`, `JPEGCompressor.swift`, `PNGCompressor.swift`, `GIFCompressor.swift`
- Create: `Tests/ShrinkerProTests/BinaryCompressorTests.swift`
- Create fixtures: `Tests/ShrinkerProTests/Fixtures/sample.jpg`, `sample.png`, `sample.gif`
- Modify: `project.yml` (Copy Files phase for helpers)

**Interfaces:**
- Consumes: `Compressor`, `ShrinkError` (Task 4)
- Produces:
  - `enum ProcessRunner { static func run(_ executable: URL, _ arguments: [String]) throws -> (code: Int32, stderr: String) }`
  - `enum HelperLocator { static func url(named: String, in bundle: Bundle) throws -> URL }`
  - `struct JPEGCompressor: Compressor { init(executable: URL, willOverwriteInput: Bool) }`
  - `struct PNGCompressor: Compressor { init(executable: URL) }`
  - `struct GIFCompressor: Compressor { init(executable: URL) }`

- [ ] **Step 1: Create fixtures and embed helpers in the bundle**

```bash
mkdir -p Tests/ShrinkerProTests/Fixtures
SRC=$(find /System/Library/CoreServices -name '*.png' -size +20k | head -1)
sips -s format jpeg "$SRC" --out Tests/ShrinkerProTests/Fixtures/sample.jpg >/dev/null
sips -s format png  "$SRC" --out Tests/ShrinkerProTests/Fixtures/sample.png >/dev/null
sips -s format gif  "$SRC" --out Tests/ShrinkerProTests/Fixtures/sample.gif >/dev/null
ls -l Tests/ShrinkerProTests/Fixtures/
```

Expected: three non-empty files. Verify each is at least 20 KB so compression has headroom to demonstrate a reduction.

Add the Copy Files phase to the `ShrinkerPro` target in `project.yml`:

```yaml
    dependencies:
      - bundle: vendor/compressors/cjpeg
        copy:
          destination: executables
      - bundle: vendor/compressors/pngquant
        copy:
          destination: executables
      - bundle: vendor/compressors/gifsicle
        copy:
          destination: executables
```

`destination: executables` maps to `Contents/Helpers/`. Run `xcodegen generate`, then confirm after a build:

```bash
xcodebuild -scheme ShrinkerPro -configuration Debug -derivedDataPath build/DerivedData build | tail -3
ls -l "build/DerivedData/Build/Products/Debug/Shrinker Pro.app/Contents/Helpers/"
```

Expected: `cjpeg`, `gifsicle`, `pngquant` all present.

- [ ] **Step 2: Write the failing tests**

`Tests/ShrinkerProTests/BinaryCompressorTests.swift`:

```swift
import XCTest
@testable import ShrinkerPro

final class BinaryCompressorTests: XCTestCase {

    /// Tests run from a test bundle, not the app bundle, so point directly at
    /// the build output of scripts/build-compressors.sh.
    private func helper(_ name: String) throws -> URL {
        let repoRoot = ProcessInfo.processInfo.environment["SRCROOT"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent("vendor/compressors/\(name)")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw XCTSkip("\(name) not built — run scripts/build-compressors.sh")
        }
        return url
    }

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        let bundle = Bundle(for: BinaryCompressorTests.self)
        guard let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: ext) else {
            throw XCTSkip("fixture \(name).\(ext) missing")
        }
        return url
    }

    private func tempURL(_ ext: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).\(ext)")
    }

    private func assertShrunk(_ input: URL, _ output: URL, magic: [UInt8], file: StaticString = #filePath, line: UInt = #line) throws {
        let before = try Data(contentsOf: input)
        let after = try Data(contentsOf: output)
        XCTAssertLessThan(after.count, before.count, "output not smaller", file: file, line: line)
        XCTAssertGreaterThan(after.count, 0, "output is empty", file: file, line: line)
        XCTAssertEqual(Array(after.prefix(magic.count)), magic, "wrong magic bytes", file: file, line: line)
    }

    func testJPEGCompression() throws {
        let input = try fixture("sample", "jpg")
        let output = tempURL("jpg")
        defer { try? FileManager.default.removeItem(at: output) }

        let compressor = JPEGCompressor(executable: try helper("cjpeg"), willOverwriteInput: false)
        try compressor.compress(input: input, output: output)
        try assertShrunk(input, output, magic: [0xFF, 0xD8, 0xFF])
    }

    /// Upstream issue #54: with suffix and subfolder both off, output path ==
    /// input path, and cjpeg reading and writing the same file corrupts it.
    func testJPEGInPlaceDoesNotCorrupt() throws {
        let source = try fixture("sample", "jpg")
        let inPlace = tempURL("jpg")
        try FileManager.default.copyItem(at: source, to: inPlace)
        defer { try? FileManager.default.removeItem(at: inPlace) }
        let originalSize = try Data(contentsOf: inPlace).count

        let compressor = JPEGCompressor(executable: try helper("cjpeg"), willOverwriteInput: true)
        try compressor.compress(input: inPlace, output: inPlace)

        let result = try Data(contentsOf: inPlace)
        XCTAssertGreaterThan(result.count, 0, "in-place compression produced an empty file")
        XCTAssertLessThan(result.count, originalSize, "in-place compression did not shrink")
        XCTAssertEqual(Array(result.prefix(3)), [0xFF, 0xD8, 0xFF], "in-place output is not valid JPEG")

        // No temp file left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: inPlace.deletingLastPathComponent().path
        ).filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty, "temp files left behind: \(leftovers)")
    }

    func testPNGCompression() throws {
        let input = try fixture("sample", "png")
        let output = tempURL("png")
        defer { try? FileManager.default.removeItem(at: output) }

        try PNGCompressor(executable: try helper("pngquant")).compress(input: input, output: output)
        try assertShrunk(input, output, magic: [0x89, 0x50, 0x4E, 0x47])
    }

    func testGIFCompression() throws {
        let input = try fixture("sample", "gif")
        let output = tempURL("gif")
        defer { try? FileManager.default.removeItem(at: output) }

        try GIFCompressor(executable: try helper("gifsicle")).compress(input: input, output: output)
        try assertShrunk(input, output, magic: Array("GIF8".utf8))
    }

    func testFailureSurfacesCompressorError() throws {
        let bogus = tempURL("png")
        try Data("not a png".utf8).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }

        XCTAssertThrowsError(
            try PNGCompressor(executable: try helper("pngquant"))
                .compress(input: bogus, output: tempURL("png"))
        ) { error in
            guard case ShrinkError.compressorFailed(let tool, _, _) = error else {
                return XCTFail("expected .compressorFailed, got \(error)")
            }
            XCTAssertEqual(tool, "pngquant")
        }
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
xcodebuild test -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData 2>&1 | grep -E 'BinaryCompressor|error:' | head
```

Expected: FAIL — the compressor types do not exist.

- [ ] **Step 4: Write ProcessRunner.swift and HelperLocator.swift**

```swift
import Foundation

enum ProcessRunner {

    /// Runs an executable to completion and returns its exit code and stderr.
    ///
    /// stderr is drained before `waitUntilExit()` — waiting first would deadlock
    /// if the child fills the pipe buffer. stdout goes to /dev/null because none
    /// of the compressors write image data there.
    static func run(_ executable: URL, _ arguments: [String]) throws -> (code: Int32, stderr: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let message = String(decoding: errorData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, message)
    }
}
```

```swift
import Foundation

/// Resolves the bundled compressor binaries in `Contents/Helpers/`.
enum HelperLocator {

    static func url(named name: String, in bundle: Bundle = .main) throws -> URL {
        let url = bundle.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(name)

        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw ShrinkError.helperMissing(name)
        }
        return url
    }
}
```

- [ ] **Step 5: Write the three compressors**

`JPEGCompressor.swift`:

```swift
import Foundation

/// mozjpeg's `cjpeg`. Upstream invocation: `cjpeg -outfile OUT IN`.
struct JPEGCompressor: Compressor {

    let executable: URL
    /// True when the resolved output path equals the input path, which happens
    /// when both the `.min` suffix and the `minified/` subfolder are disabled.
    let willOverwriteInput: Bool

    func compress(input: URL, output: URL) throws {
        // Upstream issue #54: cjpeg cannot read and write the same file, so
        // compress from a temporary copy of the original when they collide.
        var source = input
        var temporaryCopy: URL?

        if willOverwriteInput {
            let copy = output.appendingPathExtension("tmp")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: input, to: copy)
            source = copy
            temporaryCopy = copy
        }
        defer { if let temporaryCopy { try? FileManager.default.removeItem(at: temporaryCopy) } }

        let result = try ProcessRunner.run(executable, ["-outfile", output.path, source.path])
        guard result.code == 0 else {
            throw ShrinkError.compressorFailed(tool: "cjpeg", code: result.code, message: result.stderr)
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw ShrinkError.outputNotWritten(output)
        }
    }
}
```

`PNGCompressor.swift`:

```swift
import Foundation

/// pngquant. Upstream invocation: `pngquant -fo OUT IN`
/// (`-f` overwrite existing, `-o` output path).
struct PNGCompressor: Compressor {

    let executable: URL

    func compress(input: URL, output: URL) throws {
        let result = try ProcessRunner.run(executable, ["-fo", output.path, input.path])
        guard result.code == 0 else {
            throw ShrinkError.compressorFailed(tool: "pngquant", code: result.code, message: result.stderr)
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw ShrinkError.outputNotWritten(output)
        }
    }
}
```

`GIFCompressor.swift`:

```swift
import Foundation

/// gifsicle. Upstream invocation: `gifsicle -o OUT IN -O=2 -i`
/// (`-O=2` optimization level 2, `-i` interlace).
struct GIFCompressor: Compressor {

    let executable: URL

    func compress(input: URL, output: URL) throws {
        let result = try ProcessRunner.run(
            executable, ["-o", output.path, input.path, "-O=2", "-i"]
        )
        guard result.code == 0 else {
            throw ShrinkError.compressorFailed(tool: "gifsicle", code: result.code, message: result.stderr)
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw ShrinkError.outputNotWritten(output)
        }
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
xcodebuild test -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData 2>&1 | grep -E 'BinaryCompressor|Test Suite' | head
```

Expected: all five `BinaryCompressorTests` tests PASS. If `testGIFCompression` fails because `sips`-produced GIFs are already minimal, regenerate the fixture from a more complex source image rather than weakening the assertion.

- [ ] **Step 7: Commit**

```bash
git add Sources/ShrinkerPro/Core/ProcessRunner.swift \
  Sources/ShrinkerPro/Core/HelperLocator.swift \
  Sources/ShrinkerPro/Core/JPEGCompressor.swift \
  Sources/ShrinkerPro/Core/PNGCompressor.swift \
  Sources/ShrinkerPro/Core/GIFCompressor.swift \
  Tests/ShrinkerProTests/BinaryCompressorTests.swift \
  Tests/ShrinkerProTests/Fixtures project.yml
git commit -m "Add JPEG/PNG/GIF compressors over vendored arm64 binaries"
```

---

### Task 7: ShrinkEngine

Ties path resolution and compressor dispatch together. This is what the UI calls.

**Files:**
- Create: `Sources/ShrinkerPro/Core/ShrinkEngine.swift`
- Create: `Tests/ShrinkerProTests/ShrinkEngineTests.swift`

**Interfaces:**
- Consumes: `Compressor`, `ShrinkError`, `OutputPathResolver`, `OutputSettings`, `HelperLocator`, the four compressors
- Produces:
  - `struct ShrinkResult { let input: URL; let output: URL; let originalBytes: Int; let shrunkBytes: Int; var savedPercent: Int }`
  - `final class ShrinkEngine { init(helperProvider:) throws; func shrink(_ input: URL, settings: OutputSettings) throws -> ShrinkResult }`
  - `static let supportedExtensions: Set<String>`

- [ ] **Step 1: Write the failing tests**

`Tests/ShrinkerProTests/ShrinkEngineTests.swift`:

```swift
import XCTest
@testable import ShrinkerPro

final class ShrinkEngineTests: XCTestCase {

    private func makeEngine() throws -> ShrinkEngine {
        let repoRoot = ProcessInfo.processInfo.environment["SRCROOT"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let vendor = repoRoot.appendingPathComponent("vendor/compressors")
        guard FileManager.default.isExecutableFile(atPath: vendor.appendingPathComponent("cjpeg").path) else {
            throw XCTSkip("compressors not built — run scripts/build-compressors.sh")
        }
        let bundle = Bundle(for: ShrinkEngineTests.self)
        guard let svgo = bundle.url(forResource: "svgo.jsc", withExtension: "js")
            ?? Bundle.main.url(forResource: "svgo.jsc", withExtension: "js") else {
            throw XCTSkip("svgo.jsc.js not bundled")
        }
        return try ShrinkEngine(
            helperProvider: { vendor.appendingPathComponent($0) },
            svgoScriptURL: svgo
        )
    }

    private func stagedFixture(_ name: String, _ ext: String) throws -> URL {
        let bundle = Bundle(for: ShrinkEngineTests.self)
        guard let source = bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: ext) else {
            throw XCTSkip("fixture \(name).\(ext) missing")
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let staged = dir.appendingPathComponent("\(name).\(ext)")
        try FileManager.default.copyItem(at: source, to: staged)
        return staged
    }

    private let defaults = OutputSettings(
        saveInSameFolder: true, savePath: nil, useSubfolder: false, addSuffix: true
    )

    func testShrinksEachSupportedFormat() throws {
        let engine = try makeEngine()
        for (name, ext) in [("sample", "jpg"), ("sample", "png"), ("sample", "gif"), ("sample", "svg")] {
            let input = try stagedFixture(name, ext)
            defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }

            let result = try engine.shrink(input, settings: defaults)

            XCTAssertEqual(result.output.lastPathComponent, "sample.min.\(ext)")
            XCTAssertGreaterThan(result.originalBytes, 0, "\(ext): no original size")
            XCTAssertLessThan(result.shrunkBytes, result.originalBytes, "\(ext): did not shrink")
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.output.path))
        }
    }

    func testUnsupportedExtensionThrows() throws {
        let engine = try makeEngine()
        let bogus = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("a.txt")
        try Data("hello".utf8).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }

        XCTAssertThrowsError(try engine.shrink(bogus, settings: defaults)) { error in
            guard case ShrinkError.unsupportedFormat(let ext) = error else {
                return XCTFail("expected .unsupportedFormat, got \(error)")
            }
            XCTAssertEqual(ext, "txt")
        }
    }

    func testExtensionMatchingIsCaseInsensitive() throws {
        let engine = try makeEngine()
        let input = try stagedFixture("sample", "png")
        let upper = input.deletingLastPathComponent().appendingPathComponent("SAMPLE.PNG")
        try FileManager.default.moveItem(at: input, to: upper)
        defer { try? FileManager.default.removeItem(at: upper.deletingLastPathComponent()) }

        let result = try engine.shrink(upper, settings: defaults)
        XCTAssertLessThan(result.shrunkBytes, result.originalBytes)
    }

    // Upstream: Math.round((100 / sizeBefore) * (sizeBefore - sizeAfter))
    func testSavedPercentMatchesUpstreamFormula() {
        XCTAssertEqual(ShrinkResult(input: URL(fileURLWithPath: "/a"), output: URL(fileURLWithPath: "/b"),
                                    originalBytes: 1000, shrunkBytes: 250).savedPercent, 75)
        XCTAssertEqual(ShrinkResult(input: URL(fileURLWithPath: "/a"), output: URL(fileURLWithPath: "/b"),
                                    originalBytes: 1000, shrunkBytes: 1000).savedPercent, 0)
        XCTAssertEqual(ShrinkResult(input: URL(fileURLWithPath: "/a"), output: URL(fileURLWithPath: "/b"),
                                    originalBytes: 3, shrunkBytes: 2).savedPercent, 33)
        // Guard against divide-by-zero on an empty input.
        XCTAssertEqual(ShrinkResult(input: URL(fileURLWithPath: "/a"), output: URL(fileURLWithPath: "/b"),
                                    originalBytes: 0, shrunkBytes: 0).savedPercent, 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData 2>&1 | grep -E 'ShrinkEngine|error:' | head`
Expected: FAIL — `cannot find 'ShrinkEngine' in scope`.

- [ ] **Step 3: Write ShrinkEngine.swift**

```swift
import Foundation

struct ShrinkResult: Equatable {
    let input: URL
    let output: URL
    let originalBytes: Int
    let shrunkBytes: Int

    /// Upstream formula: Math.round((100 / sizeBefore) * (sizeBefore - sizeAfter))
    var savedPercent: Int {
        guard originalBytes > 0 else { return 0 }
        let ratio = (100.0 / Double(originalBytes)) * Double(originalBytes - shrunkBytes)
        return Int(ratio.rounded())
    }
}

/// Dispatches a file to the right compressor and reports the size delta.
final class ShrinkEngine {

    static let supportedExtensions: Set<String> = ["svg", "png", "gif", "jpg", "jpeg"]

    private let helperProvider: (String) -> URL
    private let svgCompressor: SVGCompressor

    /// - Parameters:
    ///   - helperProvider: maps a helper name to its executable URL. Defaults to
    ///     `Contents/Helpers/` in the main bundle; tests inject `vendor/compressors/`.
    ///   - svgoScriptURL: the ESM-stripped svgo bundle produced by prepare-svgo.sh.
    init(
        helperProvider: ((String) -> URL)? = nil,
        svgoScriptURL: URL? = nil
    ) throws {
        self.helperProvider = helperProvider ?? { name in
            (try? HelperLocator.url(named: name))
                ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)")
        }

        guard let script = svgoScriptURL
            ?? Bundle.main.url(forResource: "svgo.jsc", withExtension: "js") else {
            throw ShrinkError.helperMissing("svgo.jsc.js")
        }
        self.svgCompressor = try SVGCompressor(scriptURL: script)
    }

    func shrink(_ input: URL, settings: OutputSettings) throws -> ShrinkResult {
        let ext = input.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else {
            throw ShrinkError.unsupportedFormat(ext)
        }

        let originalBytes = try byteCount(of: input)
        let output = try OutputPathResolver.resolve(input: input, settings: settings)
        let overwritesInput = output.standardizedFileURL == input.standardizedFileURL

        let compressor: Compressor
        switch ext {
        case "svg":
            compressor = svgCompressor
        case "jpg", "jpeg":
            compressor = JPEGCompressor(
                executable: helperProvider("cjpeg"), willOverwriteInput: overwritesInput
            )
        case "png":
            compressor = PNGCompressor(executable: helperProvider("pngquant"))
        case "gif":
            compressor = GIFCompressor(executable: helperProvider("gifsicle"))
        default:
            throw ShrinkError.unsupportedFormat(ext)
        }

        try compressor.compress(input: input, output: output)

        return ShrinkResult(
            input: input,
            output: output,
            originalBytes: originalBytes,
            shrunkBytes: try byteCount(of: output)
        )
    }

    private func byteCount(of url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return values.fileSize ?? 0
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData 2>&1 | grep -E 'ShrinkEngine|Test Suite' | head`
Expected: all four `ShrinkEngineTests` tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ShrinkerPro/Core/ShrinkEngine.swift Tests/ShrinkerProTests/ShrinkEngineTests.swift
git commit -m "Add ShrinkEngine dispatching by extension to the four compressors"
```

---

### Task 8: Settings store

**Files:**
- Create: `Sources/ShrinkerPro/Core/Settings.swift`
- Create: `Tests/ShrinkerProTests/SettingsTests.swift`

**Interfaces:**
- Consumes: `OutputSettings` (Task 5)
- Produces: `@MainActor final class Settings: ObservableObject` with published properties `notification`, `saveInSameFolder`, `savePath`, `clearList`, `addSuffix`, `updateCheck`, `useSubfolder`, and `var outputSettings: OutputSettings`

Defaults are copied from upstream `main.js` `defaultSettings`: notification true, folderswitch true, clearlist false, suffix true, updatecheck true, subfolder false.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import ShrinkerPro

@MainActor
final class SettingsTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "shrinker-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testDefaultsMatchUpstream() {
        let settings = Settings(defaults: makeDefaults())
        XCTAssertTrue(settings.notification)
        XCTAssertTrue(settings.saveInSameFolder)
        XCTAssertFalse(settings.clearList)
        XCTAssertTrue(settings.addSuffix)
        XCTAssertTrue(settings.updateCheck)
        XCTAssertFalse(settings.useSubfolder)
        XCTAssertNil(settings.savePath)
    }

    func testValuesPersist() {
        let defaults = makeDefaults()
        let first = Settings(defaults: defaults)
        first.addSuffix = false
        first.useSubfolder = true
        first.savePath = URL(fileURLWithPath: "/tmp/shrinker-dest")

        let second = Settings(defaults: defaults)
        XCTAssertFalse(second.addSuffix)
        XCTAssertTrue(second.useSubfolder)
        XCTAssertEqual(second.savePath?.path, "/tmp/shrinker-dest")
    }

    func testOutputSettingsProjection() {
        let settings = Settings(defaults: makeDefaults())
        settings.saveInSameFolder = false
        settings.savePath = URL(fileURLWithPath: "/tmp/dest")
        settings.useSubfolder = true
        settings.addSuffix = false

        let projected = settings.outputSettings
        XCTAssertFalse(projected.saveInSameFolder)
        XCTAssertEqual(projected.savePath?.path, "/tmp/dest")
        XCTAssertTrue(projected.useSubfolder)
        XCTAssertFalse(projected.addSuffix)
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `xcodebuild test -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData 2>&1 | grep -E 'SettingsTests|error:' | head`
Expected: FAIL — `cannot find 'Settings' in scope`.

- [ ] **Step 3: Write Settings.swift**

```swift
import Foundation
import Combine

/// UserDefaults-backed settings. Keys and defaults mirror upstream
/// image-shrinker's electron-settings store so behavior matches exactly.
@MainActor
final class Settings: ObservableObject {

    private enum Key {
        static let notification = "notification"
        static let folderswitch = "folderswitch"
        static let savepath = "savepath"
        static let clearlist = "clearlist"
        static let suffix = "suffix"
        static let updatecheck = "updatecheck"
        static let subfolder = "subfolder"
    }

    private let defaults: UserDefaults

    @Published var notification: Bool { didSet { defaults.set(notification, forKey: Key.notification) } }
    @Published var saveInSameFolder: Bool { didSet { defaults.set(saveInSameFolder, forKey: Key.folderswitch) } }
    @Published var clearList: Bool { didSet { defaults.set(clearList, forKey: Key.clearlist) } }
    @Published var addSuffix: Bool { didSet { defaults.set(addSuffix, forKey: Key.suffix) } }
    @Published var updateCheck: Bool { didSet { defaults.set(updateCheck, forKey: Key.updatecheck) } }
    @Published var useSubfolder: Bool { didSet { defaults.set(useSubfolder, forKey: Key.subfolder) } }

    @Published var savePath: URL? {
        didSet { defaults.set(savePath?.path, forKey: Key.savepath) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Upstream defaultSettings in main.js.
        defaults.register(defaults: [
            Key.notification: true,
            Key.folderswitch: true,
            Key.clearlist: false,
            Key.suffix: true,
            Key.updatecheck: true,
            Key.subfolder: false,
        ])
        notification = defaults.bool(forKey: Key.notification)
        saveInSameFolder = defaults.bool(forKey: Key.folderswitch)
        clearList = defaults.bool(forKey: Key.clearlist)
        addSuffix = defaults.bool(forKey: Key.suffix)
        updateCheck = defaults.bool(forKey: Key.updatecheck)
        useSubfolder = defaults.bool(forKey: Key.subfolder)
        savePath = defaults.string(forKey: Key.savepath).map(URL.init(fileURLWithPath:))
    }

    var outputSettings: OutputSettings {
        OutputSettings(
            saveInSameFolder: saveInSameFolder,
            savePath: savePath,
            useSubfolder: useSubfolder,
            addSuffix: addSuffix
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass, then commit**

```bash
xcodebuild test -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData 2>&1 | grep -E 'SettingsTests|Test Suite' | head
git add Sources/ShrinkerPro/Core/Settings.swift Tests/ShrinkerProTests/SettingsTests.swift
git commit -m "Add UserDefaults-backed settings matching upstream defaults"
```

---

### Task 9: Main window — drop zone and results

First task with visible UI. Behavior mirrors upstream `renderer.js`: dropping or picking files shrinks them, newest result appears at the top, clicking a result reveals it in Finder, and the list clears first when `clearList` is on.

**Files:**
- Create: `Sources/ShrinkerPro/AppModel.swift`, `Views/ContentView.swift`, `Views/DropZoneView.swift`, `Views/ResultsListView.swift`
- Modify: `Sources/ShrinkerPro/ShrinkerProApp.swift`

**Interfaces:**
- Consumes: `ShrinkEngine`, `ShrinkResult`, `ShrinkError`, `Settings`
- Produces:
  - `@MainActor final class AppModel: ObservableObject` with `@Published var rows: [ResultRow]`, `@Published var isProcessing: Bool`, `@Published var errorMessage: String?`, and `func handle(urls: [URL])`
  - `struct ResultRow: Identifiable { let id: UUID; let output: URL; let savedPercent: Int }`

Copy strings, kept close to upstream: drop zone reads **"Drag files here"** with subtitle **"only SVG, JPG, GIF and PNG allowed"**; each result reads **"You saved N%"** above the output path.

- [ ] **Step 1: Write the failing test for AppModel**

`Tests/ShrinkerProTests/AppModelTests.swift`:

```swift
import XCTest
@testable import ShrinkerPro

@MainActor
final class AppModelTests: XCTestCase {

    private func makeModel() throws -> (AppModel, Settings) {
        let repoRoot = ProcessInfo.processInfo.environment["SRCROOT"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let vendor = repoRoot.appendingPathComponent("vendor/compressors")
        guard FileManager.default.isExecutableFile(atPath: vendor.appendingPathComponent("cjpeg").path) else {
            throw XCTSkip("compressors not built")
        }
        let bundle = Bundle(for: AppModelTests.self)
        guard let svgo = bundle.url(forResource: "svgo.jsc", withExtension: "js")
            ?? Bundle.main.url(forResource: "svgo.jsc", withExtension: "js") else {
            throw XCTSkip("svgo.jsc.js not bundled")
        }
        let engine = try ShrinkEngine(
            helperProvider: { vendor.appendingPathComponent($0) }, svgoScriptURL: svgo
        )
        let settings = Settings(defaults: UserDefaults(suiteName: "appmodel-\(UUID().uuidString)")!)
        return (AppModel(engine: engine, settings: settings, notifier: nil), settings)
    }

    private func stagedPNG() throws -> URL {
        let bundle = Bundle(for: AppModelTests.self)
        guard let source = bundle.url(forResource: "sample", withExtension: "png", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "sample", withExtension: "png") else { throw XCTSkip("no fixture") }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("am-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let staged = dir.appendingPathComponent("sample.png")
        try FileManager.default.copyItem(at: source, to: staged)
        return staged
    }

    func testSuccessfulDropAddsRow() async throws {
        let (model, _) = try makeModel()
        let file = try stagedPNG()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        await model.process(urls: [file])

        XCTAssertEqual(model.rows.count, 1)
        XCTAssertGreaterThan(model.rows[0].savedPercent, 0)
        XCTAssertFalse(model.isProcessing)
        XCTAssertNil(model.errorMessage)
    }

    func testNewestResultAppearsFirst() async throws {
        let (model, _) = try makeModel()
        let a = try stagedPNG(), b = try stagedPNG()
        defer {
            try? FileManager.default.removeItem(at: a.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: b.deletingLastPathComponent())
        }
        await model.process(urls: [a])
        await model.process(urls: [b])

        XCTAssertEqual(model.rows.count, 2)
        XCTAssertEqual(model.rows.first?.output.path,
                       b.deletingLastPathComponent().appendingPathComponent("sample.min.png").path,
                       "newest result must be prepended, matching upstream resultBox.prepend")
    }

    func testClearListSettingResetsBetweenDrops() async throws {
        let (model, settings) = try makeModel()
        settings.clearList = true
        let a = try stagedPNG(), b = try stagedPNG()
        defer {
            try? FileManager.default.removeItem(at: a.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: b.deletingLastPathComponent())
        }
        await model.process(urls: [a])
        await model.process(urls: [b])

        XCTAssertEqual(model.rows.count, 1, "clearList should reset the list on each new batch")
    }

    func testUnsupportedFileSurfacesError() async throws {
        let (model, _) = try makeModel()
        let bogus = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("x.txt")
        try Data("no".utf8).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }

        await model.process(urls: [bogus])

        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isProcessing)
    }

    func testDroppedDirectoryIsExpanded() async throws {
        let (model, _) = try makeModel()
        let file = try stagedPNG()
        let folder = file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }

        await model.process(urls: [folder])

        XCTAssertEqual(model.rows.count, 1, "upstream traverseFileTree recurses into dropped folders")
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Expected: FAIL — `cannot find 'AppModel' in scope`.

- [ ] **Step 3: Write AppModel.swift**

```swift
import Foundation
import Combine

struct ResultRow: Identifiable, Equatable {
    let id = UUID()
    let output: URL
    let savedPercent: Int
}

@MainActor
final class AppModel: ObservableObject {

    @Published private(set) var rows: [ResultRow] = []
    @Published private(set) var isProcessing = false
    @Published var errorMessage: String?

    private let engine: ShrinkEngine
    private let settings: Settings
    private let notifier: Notifier?

    init(engine: ShrinkEngine, settings: Settings, notifier: Notifier?) {
        self.engine = engine
        self.settings = settings
        self.notifier = notifier
    }

    /// Entry point for drops, the file picker, and Finder open events.
    func handle(urls: [URL]) {
        Task { await process(urls: urls) }
    }

    func process(urls: [URL]) async {
        guard !urls.isEmpty else { return }

        if settings.clearList { rows.removeAll() }
        isProcessing = true
        defer { isProcessing = false }

        let files = Self.expand(urls)
        let outputSettings = settings.outputSettings

        for file in files {
            do {
                // Compression is blocking; keep it off the main actor.
                let result = try await Task.detached(priority: .userInitiated) { [engine] in
                    try engine.shrink(file, settings: outputSettings)
                }.value

                rows.insert(ResultRow(output: result.output, savedPercent: result.savedPercent), at: 0)
                NSDocumentController.shared.noteNewRecentDocumentURL(file)
                if settings.notification {
                    await notifier?.notify(title: "Image shrunk", body: result.output.lastPathComponent)
                }
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Upstream's renderer recurses into dropped directories via
    /// traverseFileTree; mirror that, filtering to supported extensions.
    static func expand(_ urls: [URL]) -> [URL] {
        var files: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }

            if isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(
                    at: url, includingPropertiesForKeys: [.isRegularFileKey]
                )
                while let child = enumerator?.nextObject() as? URL {
                    if ShrinkEngine.supportedExtensions.contains(child.pathExtension.lowercased()) {
                        files.append(child)
                    }
                }
            } else {
                files.append(url)
            }
        }
        return files
    }
}
```

`NSDocumentController` requires `import AppKit`; add it alongside `import Foundation`.

- [ ] **Step 4: Write the views**

`Views/DropZoneView.swift`:

```swift
import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 8) {
            if model.isProcessing {
                ProgressView().controlSize(.large)
            } else {
                Image(systemName: "arrow.down.circle").font(.system(size: 34, weight: .light))
            }
            Text("Drag files here").font(.title3.weight(.semibold))
            Text("only SVG, JPG, GIF and PNG allowed")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 190)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: pickFiles)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            Task {
                var urls: [URL] = []
                for provider in providers {
                    if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                       let resolved = URL(dataRepresentation: url, relativeTo: nil) {
                        urls.append(resolved)
                    }
                }
                model.handle(urls: urls)
            }
            return true
        }
        .padding()
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.svg, .png, .gif, .jpeg]
        if panel.runModal() == .OK { model.handle(urls: panel.urls) }
    }
}
```

`Views/ResultsListView.swift`:

```swift
import SwiftUI
import AppKit

struct ResultsListView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(model.rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("You saved \(row.savedPercent)%")
                            .font(.caption.weight(.semibold))
                        Button(row.output.lastPathComponent) {
                            NSWorkspace.shared.activateFileViewerSelecting([row.output])
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help(row.output.path)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal)
        }
    }
}
```

`Views/ContentView.swift`:

```swift
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            DropZoneView()
            Divider()
            ResultsListView()
        }
        .frame(minWidth: 340, minHeight: 550)
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            actions: { Button("OK", role: .cancel) { model.errorMessage = nil } },
            message: { Text(model.errorMessage ?? "") }
        )
    }
}
```

- [ ] **Step 5: Wire up ShrinkerProApp.swift**

```swift
import SwiftUI

@main
struct ShrinkerProApp: App {
    @StateObject private var settings: Settings
    @StateObject private var model: AppModel

    init() {
        let settings = Settings()
        // A failure here means the app bundle is damaged; surface it rather than
        // launching into a window where every drop fails.
        let engine = try! ShrinkEngine()
        _settings = StateObject(wrappedValue: settings)
        _model = StateObject(wrappedValue: AppModel(
            engine: engine, settings: settings, notifier: Notifier()
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(settings)
        }
        .windowResizability(.contentMinSize)
    }
}
```

- [ ] **Step 6: Run tests, then launch the app and drop a real file**

```bash
xcodebuild test -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData 2>&1 | grep -E 'AppModelTests|Test Suite' | head
open "build/DerivedData/Build/Products/Debug/Shrinker Pro.app"
```

Expected: all five `AppModelTests` pass, the window shows the drop zone, and dropping a PNG produces a `You saved N%` row that reveals in Finder when clicked.

- [ ] **Step 7: Commit**

```bash
git add Sources/ShrinkerPro Tests/ShrinkerProTests/AppModelTests.swift
git commit -m "Add main window with drop zone and results list"
```

---

### Task 10: Settings window

**Files:**
- Create: `Sources/ShrinkerPro/Views/SettingsView.swift`
- Modify: `Sources/ShrinkerPro/ShrinkerProApp.swift`

**Interfaces:**
- Consumes: `Settings` (Task 8)
- Produces: `struct SettingsView: View`

Labels are taken verbatim from upstream `index.html`, with upstream's "shrinked" corrected to "shrunken".

- [ ] **Step 1: Write SettingsView.swift**

```swift
import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var settings: Settings

    var body: some View {
        Form {
            Section {
                Toggle("Save shrunken files in same folder", isOn: $settings.saveInSameFolder)
                if !settings.saveInSameFolder {
                    HStack {
                        Text(settings.savePath?.path ?? "No folder chosen")
                            .font(.caption)
                            .foregroundStyle(settings.savePath == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer()
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Toggle("Add subfolder \"minified\"", isOn: $settings.useSubfolder)
                Toggle("Add .min suffix to shrunken files", isOn: $settings.addSuffix)
            }
            Section {
                Toggle("Enable notifications", isOn: $settings.notification)
                Toggle("Clear result list when shrinking new images", isOn: $settings.clearList)
                Toggle("Check for updates", isOn: $settings.updateCheck)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { settings.savePath = panel.url }
    }
}
```

- [ ] **Step 2: Add the Settings scene**

In `ShrinkerProApp.swift`, after the `WindowGroup`:

```swift
        Settings {
            SettingsView().environmentObject(settings)
        }
```

- [ ] **Step 3: Verify manually**

```bash
xcodebuild -scheme ShrinkerPro -configuration Debug -derivedDataPath build/DerivedData build | tail -3
open "build/DerivedData/Build/Products/Debug/Shrinker Pro.app"
```

Expected: `Cmd+,` opens Settings. Toggling "Save shrunken files in same folder" off reveals the folder chooser. Quit and relaunch — every toggle retains its value.

- [ ] **Step 4: Commit**

```bash
git add Sources/ShrinkerPro/Views/SettingsView.swift Sources/ShrinkerPro/ShrinkerProApp.swift
git commit -m "Add settings window with upstream parity toggles"
```

---

### Task 11: Notifications

**Files:**
- Create: `Sources/ShrinkerPro/Core/Notifier.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `final class Notifier { func notify(title: String, body: String) async }` — referenced by `AppModel` in Task 9, which passes `nil` in tests

Authorization is requested lazily on first use, not at launch, per the spec.

- [ ] **Step 1: Write Notifier.swift**

```swift
import Foundation
import UserNotifications

/// Posts completion notifications. Authorization is requested the first time a
/// notification would actually be posted rather than at launch, so a user who
/// never enables the setting is never prompted.
final class Notifier {

    private var authorized: Bool?

    func notify(title: String, body: String) async {
        guard await ensureAuthorized() else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // Upstream posts with silent: true.
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func ensureAuthorized() async -> Bool {
        if let authorized { return authorized }
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert])) ?? false
        authorized = granted
        return granted
    }
}
```

- [ ] **Step 2: Verify manually**

Notifications require a signed, installed bundle to appear reliably; a Debug build launched from DerivedData may not display them. Verify properly after Task 15, then confirm here that: with the setting on, shrinking a file posts one notification titled "Image shrunk"; with it off, none is posted.

- [ ] **Step 3: Commit**

```bash
git add Sources/ShrinkerPro/Core/Notifier.swift
git commit -m "Post completion notifications with lazy authorization"
```

---

### Task 12: File associations, Finder opens, and menus

Restores upstream's `open-file` handling, recent documents, and file type registration.

**Files:**
- Modify: `Sources/ShrinkerPro/Resources/Info.plist`, `Sources/ShrinkerPro/ShrinkerProApp.swift`
- Create: `Sources/ShrinkerPro/AppDelegate.swift`

**Interfaces:**
- Consumes: `AppModel.handle(urls:)` (Task 9)
- Produces: `final class AppDelegate: NSObject, NSApplicationDelegate`

- [ ] **Step 1: Declare document types in Info.plist**

Insert before the closing `</dict>`:

```xml
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Image</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.svg-image</string>
                <string>public.png</string>
                <string>com.compuserve.gif</string>
                <string>public.jpeg</string>
            </array>
        </dict>
    </array>
```

`LSHandlerRank` is `Alternate` deliberately: Shrinker Pro should appear in "Open With" without stealing double-click from Preview.

- [ ] **Step 2: Write AppDelegate.swift**

```swift
import AppKit

/// Handles files opened from Finder ("Open With", drops on the Dock icon, and
/// the Recent Documents menu) — upstream's `app.on('open-file')`.
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Set by ShrinkerProApp once the model exists. URLs arriving before that
    /// are queued so an open-at-launch is not dropped.
    var model: AppModel? {
        didSet {
            guard let model, !pending.isEmpty else { return }
            let queued = pending
            pending = []
            Task { @MainActor in model.handle(urls: queued) }
        }
    }
    private var pending: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let model else { pending.append(contentsOf: urls); return }
        Task { @MainActor in model.handle(urls: urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false  // Upstream keeps the app alive on macOS after the window closes.
    }
}
```

- [ ] **Step 3: Wire the delegate and add menu commands**

In `ShrinkerProApp.swift`:

```swift
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
```

and inside the `WindowGroup` content, after `.environmentObject(settings)`:

```swift
                .onAppear { appDelegate.model = model }
```

and after `.windowResizability(.contentMinSize)`:

```swift
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Files…") { openPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
```

with, in the same file:

```swift
    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.svg, .png, .gif, .jpeg]
        if panel.runModal() == .OK { model.handle(urls: panel.urls) }
    }
```

Add `import AppKit` and `import UniformTypeIdentifiers`.

- [ ] **Step 4: Verify manually**

```bash
xcodebuild -scheme ShrinkerPro -configuration Debug -derivedDataPath build/DerivedData build | tail -3
open "build/DerivedData/Build/Products/Debug/Shrinker Pro.app"
open -a "build/DerivedData/Build/Products/Debug/Shrinker Pro.app" Tests/ShrinkerProTests/Fixtures/sample.png
```

Expected: the second `open` shrinks the file and adds a row. `Cmd+O` opens the picker. The file appears under File ▸ Open Recent.

- [ ] **Step 5: Commit**

```bash
git add Sources/ShrinkerPro
git commit -m "Handle Finder opens, recent documents, and file associations"
```

---

### Task 13: Update check

Per the spec: a GitHub releases check, disabled until a repository URL is configured.

**Files:**
- Create: `Sources/ShrinkerPro/Core/UpdateChecker.swift`
- Create: `Tests/ShrinkerProTests/UpdateCheckerTests.swift`
- Modify: `Sources/ShrinkerPro/Resources/Info.plist`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `enum UpdateStatus: Equatable { case upToDate, available(version: String, url: URL), notConfigured }`
  - `struct UpdateChecker { static func compare(current: String, latestTag: String) -> Bool; func check() async -> UpdateStatus }`

- [ ] **Step 1: Write the failing test for version comparison**

```swift
import XCTest
@testable import ShrinkerPro

final class UpdateCheckerTests: XCTestCase {

    func testDetectsNewerVersions() {
        XCTAssertTrue(UpdateChecker.compare(current: "1.0.0", latestTag: "v1.0.1"))
        XCTAssertTrue(UpdateChecker.compare(current: "1.0.0", latestTag: "1.1.0"))
        XCTAssertTrue(UpdateChecker.compare(current: "1.9.0", latestTag: "v1.10.0"),
                      "1.10.0 is newer than 1.9.0 — must not compare as strings")
        XCTAssertTrue(UpdateChecker.compare(current: "1.0.0", latestTag: "v2.0"))
    }

    func testIgnoresSameOrOlderVersions() {
        XCTAssertFalse(UpdateChecker.compare(current: "1.0.0", latestTag: "v1.0.0"))
        XCTAssertFalse(UpdateChecker.compare(current: "1.2.0", latestTag: "v1.1.9"))
        XCTAssertFalse(UpdateChecker.compare(current: "2.0.0", latestTag: "v1.99.99"))
    }

    func testMalformedTagIsNotAnUpdate() {
        XCTAssertFalse(UpdateChecker.compare(current: "1.0.0", latestTag: "nightly"))
        XCTAssertFalse(UpdateChecker.compare(current: "1.0.0", latestTag: ""))
    }

    func testUnconfiguredRepositoryReportsNotConfigured() async {
        let status = await UpdateChecker(repository: nil).check()
        XCTAssertEqual(status, .notConfigured)
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Expected: FAIL — `cannot find 'UpdateChecker' in scope`.

- [ ] **Step 3: Write UpdateChecker.swift**

```swift
import Foundation

enum UpdateStatus: Equatable {
    case upToDate
    case available(version: String, url: URL)
    case notConfigured
}

/// Checks the GitHub releases API for a newer tag. Deliberately minimal —
/// Sparkle is the follow-on if silent updates are ever wanted.
struct UpdateChecker {

    /// "owner/repo", read from Info.plist key `SPRepository`. Nil until the
    /// project has a public home, in which case the check is disabled.
    let repository: String?

    init(repository: String? = Bundle.main.object(forInfoDictionaryKey: "SPRepository") as? String) {
        let trimmed = repository?.trimmingCharacters(in: .whitespaces)
        self.repository = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    func check() async -> UpdateStatus {
        guard let repository,
              let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")
        else { return .notConfigured }

        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 10
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { return .upToDate }

            guard Self.compare(current: current, latestTag: tag) else { return .upToDate }
            let page = (json["html_url"] as? String).flatMap(URL.init(string:))
                ?? URL(string: "https://github.com/\(repository)/releases")!
            return .available(version: tag, url: page)
        } catch {
            return .upToDate  // Never interrupt the user over a failed check.
        }
    }

    /// True when `latestTag` is a strictly newer semantic version than `current`.
    /// Compares numerically, so 1.10.0 correctly beats 1.9.0.
    static func compare(current: String, latestTag: String) -> Bool {
        func parts(_ value: String) -> [Int]? {
            let cleaned = value.hasPrefix("v") ? String(value.dropFirst()) : value
            guard !cleaned.isEmpty else { return nil }
            let numbers = cleaned.split(separator: ".").map { Int($0) }
            guard !numbers.contains(where: { $0 == nil }), !numbers.isEmpty else { return nil }
            return numbers.compactMap { $0 }
        }
        guard let latest = parts(latestTag), let now = parts(current) else { return false }

        for index in 0..<max(latest.count, now.count) {
            let l = index < latest.count ? latest[index] : 0
            let n = index < now.count ? now[index] : 0
            if l != n { return l > n }
        }
        return false
    }
}
```

- [ ] **Step 4: Add the Info.plist key and call it at launch**

Add to Info.plist (empty until the repo is public — this is what makes the check inert by default):

```xml
    <key>SPRepository</key>
    <string></string>
```

In `ShrinkerProApp.swift`, on the `ContentView`:

```swift
                .task {
                    guard settings.updateCheck else { return }
                    if case let .available(version, url) = await UpdateChecker().check() {
                        model.announceUpdate(version: version, url: url)
                    }
                }
```

Add to `AppModel`:

```swift
    @Published var availableUpdate: (version: String, url: URL)?

    func announceUpdate(version: String, url: URL) {
        availableUpdate = (version, url)
    }
```

and surface it in `ContentView` as a dismissible banner above the drop zone:

```swift
            if let update = model.availableUpdate {
                HStack {
                    Text("Version \(update.version) is available")
                        .font(.caption)
                    Spacer()
                    Button("View") { NSWorkspace.shared.open(update.url) }
                        .buttonStyle(.link).font(.caption)
                    Button { model.availableUpdate = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                }
                .padding(8)
                .background(Color.accentColor.opacity(0.12))
            }
```

- [ ] **Step 5: Run tests to verify they pass, then commit**

```bash
xcodebuild test -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData 2>&1 | grep -E 'UpdateChecker|Test Suite' | head
git add Sources/ShrinkerPro Tests/ShrinkerProTests/UpdateCheckerTests.swift
git commit -m "Add GitHub releases update check, inert until a repo is configured"
```

---

### Task 14: App icon

New artwork for Shrinker Pro, drawn programmatically with CoreGraphics so every size is generated from one source and no external rendering tool is needed.

**Files:**
- Create: `scripts/make-icon.swift`, `scripts/make-icon.sh`
- Output: `Sources/ShrinkerPro/Resources/Assets.xcassets/AppIcon.appiconset/`

**Interfaces:**
- Consumes: nothing
- Produces: `AppIcon` asset catalog entry referenced by `ASSETCATALOG_COMPILER_APPICON_NAME`

**Design:** a macOS-style rounded square with a deep indigo-to-violet vertical gradient, containing a white rounded rectangle standing in for an image, flanked by two chevrons pointing inward — the compression metaphor — with a subtle inner highlight along the top edge.

- [ ] **Step 1: Write make-icon.swift**

```swift
#!/usr/bin/env swift
import AppKit
import CoreGraphics

// Emits square PNGs of the Shrinker Pro icon at every size macOS asks for.

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let outputDir = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: "icon-out")
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

func draw(size: Int) -> Data? {
    let s = CGFloat(size)
    guard let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // Rounded-square mask, matching macOS icon proportions.
    let inset = s * 0.055
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let corner = rect.width * 0.2237
    let squircle = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    context.addPath(squircle)
    context.clip()

    // Indigo -> violet gradient.
    let colors = [
        CGColor(red: 0.298, green: 0.259, blue: 0.749, alpha: 1),
        CGColor(red: 0.529, green: 0.259, blue: 0.831, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 colors: colors, locations: [0, 1]) {
        context.drawLinearGradient(
            gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: []
        )
    }

    // Top inner highlight.
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.16))
    context.fill(CGRect(x: rect.minX, y: rect.maxY - rect.height * 0.09,
                        width: rect.width, height: rect.height * 0.09))

    // Central "image" plate.
    let plateW = rect.width * 0.34, plateH = rect.height * 0.44
    let plate = CGRect(x: rect.midX - plateW / 2, y: rect.midY - plateH / 2,
                       width: plateW, height: plateH)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    context.addPath(CGPath(roundedRect: plate, cornerWidth: plateW * 0.14,
                           cornerHeight: plateW * 0.14, transform: nil))
    context.fillPath()

    // Inward chevrons: compression.
    let lw = max(1, s * 0.045)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.92))
    context.setLineWidth(lw)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    let gap = rect.width * 0.10, arm = rect.width * 0.075
    for direction in [-1.0, 1.0] {
        let tipX = plate.midX + CGFloat(direction) * (plateW / 2 + gap)
        context.move(to: CGPoint(x: tipX + CGFloat(direction) * arm, y: rect.midY + arm))
        context.addLine(to: CGPoint(x: tipX, y: rect.midY))
        context.addLine(to: CGPoint(x: tipX + CGFloat(direction) * arm, y: rect.midY - arm))
    }
    context.strokePath()

    guard let image = context.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])
}

for size in sizes {
    guard let data = draw(size: size) else { fatalError("failed to render \(size)") }
    try data.write(to: outputDir.appendingPathComponent("icon_\(size).png"))
    print("rendered \(size)x\(size)")
}
```

- [ ] **Step 2: Write make-icon.sh to assemble the iconset and asset catalog**

```bash
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
```

- [ ] **Step 3: Generate and inspect**

```bash
chmod +x scripts/make-icon.sh scripts/make-icon.swift
./scripts/make-icon.sh
xcodegen generate
xcodebuild -scheme ShrinkerPro -configuration Debug -derivedDataPath build/DerivedData build | tail -3
open "build/DerivedData/Build/Products/Debug/Shrinker Pro.app"
```

Expected: the Dock icon shows the new artwork. Open `Sources/ShrinkerPro/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png` in Preview and confirm the chevrons and plate read clearly. Also check `icon_16x16.png` — if the chevrons blur together at 16px, increase `gap` and `lw` and regenerate.

- [ ] **Step 4: Commit**

```bash
git add scripts/make-icon.swift scripts/make-icon.sh \
  Sources/ShrinkerPro/Resources/Assets.xcassets build/ShrinkerPro.icns project.yml
git commit -m "Add generated Shrinker Pro app icon"
```

---

### Task 15: Signed, notarized DMG

**Files:**
- Create: `scripts/release.sh`, `build/ExportOptions.plist`

**Interfaces:**
- Consumes: `scripts/verify-arch.sh` (Task 2), `build/ShrinkerPro.icns` (Task 14)
- Produces: `dist/Shrinker Pro-<version>.dmg`, notarized and stapled

Credentials come from the environment. Store them once in the keychain:

```bash
xcrun notarytool store-credentials shrinkerpro-notary \
  --apple-id "<your-apple-id>" --team-id LY424U3HLD --password "<app-specific-password>"
```

- [ ] **Step 1: Write ExportOptions.plist**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>LY424U3HLD</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
```

- [ ] **Step 2: Write release.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

IDENTITY="Developer ID Application: Eight-Seven Inc. (LY424U3HLD)"
KEYCHAIN_PROFILE="${NOTARY_PROFILE:-shrinkerpro-notary}"
ARCHIVE="build/ShrinkerPro.xcarchive"
EXPORT="build/export"
APP="$EXPORT/Shrinker Pro.app"

echo "==> regenerating project"
xcodegen generate

echo "==> archiving"
rm -rf "$ARCHIVE" "$EXPORT"
xcodebuild archive \
  -scheme ShrinkerPro \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  -destination 'generic/platform=macOS' \
  ARCHS=arm64 EXCLUDED_ARCHS=x86_64 \
  | tail -5

echo "==> signing helpers inside-out"
# Helpers must be signed before the app that contains them, or the outer
# signature is invalidated the moment they change.
for helper in "$ARCHIVE/Products/Applications/Shrinker Pro.app/Contents/Helpers/"*; do
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$helper"
  echo "    signed $(basename "$helper")"
done

echo "==> exporting"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" \
  -exportOptionsPlist build/ExportOptions.plist | tail -5

echo "==> ARCHITECTURE GATE"
./scripts/verify-arch.sh "$APP"

echo "==> verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose "$APP" || echo "    (spctl will pass only after notarization)"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="dist/Shrinker Pro-$VERSION.dmg"
STAGE="build/dmg-stage"

echo "==> building DMG $DMG"
mkdir -p dist
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Shrinker Pro" -srcfolder "$STAGE" -ov -format ULFO "$DMG"

echo "==> signing DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

echo "==> notarizing (this takes a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$KEYCHAIN_PROFILE" --wait

echo "==> stapling"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo
echo "Release ready: $DMG"
```

- [ ] **Step 3: Run a release**

```bash
chmod +x scripts/release.sh
./scripts/release.sh
```

Expected: the architecture gate prints PASS, notarization returns `status: Accepted`, and stapler validates.

**If notarization is rejected**, read the log before changing anything:

```bash
xcrun notarytool log <submission-id> --keychain-profile shrinkerpro-notary
```

The likeliest cause is a helper missing the hardened runtime — confirm with `codesign -d --entitlements - "$APP/Contents/Helpers/cjpeg"`.

- [ ] **Step 4: Verify the DMG on a clean install path**

```bash
hdiutil attach "dist/Shrinker Pro-1.0.0.dmg"
cp -R "/Volumes/Shrinker Pro/Shrinker Pro.app" /Applications/
hdiutil detach "/Volumes/Shrinker Pro"
spctl --assess --type execute --verbose "/Applications/Shrinker Pro.app"
./scripts/verify-arch.sh "/Applications/Shrinker Pro.app"
open "/Applications/Shrinker Pro.app"
```

Expected: `spctl` reports `accepted / source=Notarized Developer ID`, the arch gate passes on the installed copy, and the app launches without a Gatekeeper warning. Drop a PNG, a JPG, a GIF, and an SVG; all four should shrink. Confirm a notification appears now that the app is signed and installed (deferred from Task 11).

- [ ] **Step 5: Commit**

```bash
git add scripts/release.sh build/ExportOptions.plist
git commit -m "Add signed, notarized DMG release pipeline with architecture gate"
```

---

### Task 16: Parity verification, README, and cleanup

Confirms Shrinker Pro actually matches Image Shrinker before the reference clone is deleted.

**Files:**
- Create: `README.md`, `scripts/parity-check.sh`
- Delete: `upstream-image-shrinker/`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: everything above
- Produces: nothing further

- [ ] **Step 1: Write parity-check.sh**

```bash
#!/usr/bin/env bash
# Compares Shrinker Pro's output against upstream Image Shrinker's for the
# same inputs. Upstream's x64 binaries run under Rosetta; ours run native.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UP="$ROOT/upstream-image-shrinker"
WORK="$ROOT/vendor/src/parity"

[ -d "$UP/node_modules" ] || { echo "run 'npm install' in $UP first"; exit 1; }
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
  else
    delta=$(( (ours - theirs) * 100 / theirs ))
    verdict="differs (${delta}% size delta — expected, newer upstream tool versions)"
  fi
  printf '%-6s %12s %12s   %s\n' "$ext" "$ours" "$theirs" "$verdict"
done
```

- [ ] **Step 2: Run it and record the results**

```bash
cd upstream-image-shrinker && npm install --ignore-scripts=false 2>&1 | tail -3; cd ..
chmod +x scripts/parity-check.sh && ./scripts/parity-check.sh
```

Expected: all three formats produce valid, smaller output. Byte-identical results are **not** required — Shrinker Pro ships newer compressor versions than upstream's npm wrappers (mozjpeg 4.1.5 vs. the npm package's build, pngquant 3.0.3 vs. 2.x). A size delta within roughly ±10% is fine. A wildly larger output, or a failure, means the arguments were transcribed wrongly — recheck against `upstream-image-shrinker/main.js`.

Record the observed numbers in the commit message.

- [ ] **Step 3: Manual parity walkthrough**

Against `/Applications/Shrinker Pro.app`, confirm each behavior matches upstream:

- Drop a PNG → row reads "You saved N%", file written beside the original as `name.min.png`
- Drop four files at once → four rows, newest first
- Drop a folder → every supported image inside is shrunk
- Settings ▸ suffix off, subfolder off → file is replaced in place and is not corrupt (upstream issue #54)
- Settings ▸ subfolder on → output lands in `minified/`
- Settings ▸ "save in same folder" off + a chosen folder → output lands there
- Settings ▸ clear list on → list resets on each new drop
- Drop a `.txt` → error alert, no crash
- Click a result row → Finder opens with the file selected
- Quit and relaunch → all settings persist

- [ ] **Step 4: Write README.md**

```markdown
# Shrinker Pro

Minify images and graphics with one drop. A native, Apple Silicon macOS app.

Drag PNG, JPG, GIF, or SVG files onto the window and Shrinker Pro writes a
smaller copy beside the original — or wherever you tell it to. Originals are
never replaced unless you ask for that.

## Why this exists

Shrinker Pro is a native rewrite of [Image Shrinker](https://github.com/stefansl/image-shrinker)
by Stefan Schulz-Lauterbach. The original is an Electron app whose compression
binaries ship as x64-only builds, so on Apple Silicon they run through Rosetta 2
and fail outright without it. With Intel support ending in macOS 26 and Rosetta
on a sunset path, that foundation has a deadline.

Shrinker Pro replaces the Electron shell with SwiftUI and rebuilds the same
compressors as static arm64 binaries. Every Mach-O in the bundle is arm64-only,
verified by a release gate that blocks notarization if anything else appears.

## Compression

| Format | Tool |
|---|---|
| JPEG | [mozjpeg](https://github.com/mozilla/mozjpeg) 4.1.5 |
| PNG | [pngquant](https://pngquant.org/) 3.0.3 |
| GIF | [gifsicle](https://github.com/kohler/gifsicle) 1.96 |
| SVG | [svgo](https://github.com/svg/svgo) 4.1.0, run in JavaScriptCore |

## Requirements

macOS 14 Sonoma or later, Apple Silicon.

## Build

```shell
./scripts/bootstrap.sh          # Xcode path, xcodegen, cmake, Rust
./scripts/build-compressors.sh  # static arm64 mozjpeg, pngquant, gifsicle
./scripts/prepare-svgo.sh       # svgo bundle, ESM export stripped for JSContext
./scripts/make-icon.sh          # app icon
xcodegen generate
xcodebuild -scheme ShrinkerPro build
```

Release a signed, notarized DMG with `./scripts/release.sh`.

## Credits

- [Image Shrinker](https://github.com/stefansl/image-shrinker) by Stefan
  Schulz-Lauterbach, released under CC0-1.0 — the original this is based on.
- mozjpeg, pngquant, gifsicle, and svgo, which do the actual compression.
```

- [ ] **Step 5: Remove the upstream clone**

Only after Steps 2 and 3 pass — the clone is the reference they check against.

```bash
rm -rf upstream-image-shrinker
python3 - <<'PY'
import pathlib
p = pathlib.Path(".gitignore")
s = p.read_text().replace(
    "# Upstream reference clone (kept locally for parity checking, not part of this repo)\nupstream-image-shrinker/\n\n", ""
)
p.write_text(s)
PY
git add README.md scripts/parity-check.sh .gitignore
git commit -m "Add README, parity check, and remove upstream reference clone"
```

---

## Self-Review

Run against the spec before handing off.

**1. Spec coverage**

| Spec section | Task |
|---|---|
| App shell (SwiftUI) | 9, 10, 12 |
| ShrinkEngine | 7 |
| Compressors (JPEG/PNG/GIF) | 6 |
| SVG via JavaScriptCore | 4 |
| OutputPathResolver | 5 |
| Settings | 8 |
| Notifications + lazy authorization | 11 |
| arm64 compressors built from source | 3 |
| Build prerequisites | 1 |
| JPEG temp-file workaround (#54) | 6 |
| Architecture enforcement — build settings | 1 |
| Architecture enforcement — release gate | 2, 15 |
| Build & distribution | 15 |
| Signing / entitlements | 1, 15 |
| Cut: TouchBar → Choose Files | 9, 12 |
| Cut: auto-update → version check | 13 |
| Testing (all five categories) | 2, 4, 5, 6, 7 |
| Repository layout | 1 |
| Icon | 14 |
| README / upstream credit | 16 |

No spec section is unimplemented.

**2. Placeholder scan** — no TBD/TODO, no "add error handling" without code, no "similar to Task N". Every code step carries the actual code. The one intentionally-empty value is `SPRepository` in Info.plist, which the spec specifies as empty until the project has a public home.

**3. Type consistency** — verified across tasks:
- `OutputSettings(saveInSameFolder:savePath:useSubfolder:addSuffix:)` — identical in Tasks 5, 7, 8
- `ShrinkError` cases used in Tasks 4, 5, 6, 7 all exist in the Task 4 definition
- `Compressor.compress(input:output:)` — one signature across Tasks 4, 6, 7
- `ShrinkEngine(helperProvider:svgoScriptURL:)` — matches its use in Tasks 7 and 9
- `AppModel(engine:settings:notifier:)` — `notifier` is optional, so Task 9's tests pass `nil` before Task 11 exists
- `ShrinkResult.savedPercent` — defined in Task 7, consumed in Task 9

**4. Ambiguity check** — two resolved during review:
- Upstream's `folderswitch` reads as its own inverse; Swift uses `saveInSameFolder` with the mapping stated explicitly in Task 5.
- Parity does **not** mean byte-identical output, since Shrinker Pro ships newer compressor versions. Task 16 states the acceptance criterion as "valid and smaller, within ~10%".

## Risks carried from the spec

| Risk | Where it surfaces | Fallback |
|---|---|---|
| pngquant Rust static link fails | Task 3 Step 2 | pngquant 2.17.0 (pure C), script provided inline |
| Notarization rejects a helper | Task 15 Step 3 | `notarytool log` diagnosis path given |
| mozjpeg wants `nasm` | Task 3 Step 2 | arm64 uses NEON, not x86 SIMD; no nasm expected |
| svgo bundle format changes | Task 4 Step 1 | `prepare-svgo.sh` fails loudly on unexpected export shape |

**Already retired:** svgo-in-JavaScriptCore was proven in a spike before this plan was written — svgo 4.1.0 loaded and optimized a fixture from 155 to 109 bytes with correct output.
