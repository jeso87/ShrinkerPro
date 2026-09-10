import XCTest

final class ArchitectureGuardTests: XCTestCase {

    /// Every Mach-O *shipped inside the app* must be arm64-only.
    /// Guards against Xcode's default ARCHS_STANDARD (arm64 x86_64).
    ///
    /// Excludes the hosted `.xctest` bundle and Apple's own XCTest/Testing
    /// support frameworks: the test target is hosted (has a TEST_HOST) so
    /// `@testable import ShrinkerPro` works, which makes Xcode embed those
    /// into "Shrinker Pro.app" for test runs only. They are Apple-provided
    /// universal binaries we don't control and are never present in a real
    /// Release build of the app, so asserting on them would be testing
    /// Xcode's toolchain, not this project.
    func testAppBundleIsArm64Only() throws {
        let appURL = try Self.builtAppURL()
        let binaries = try Self.machOFiles(in: appURL).filter { !Self.isTestInfrastructure($0) }
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
        let testBundle = Bundle(for: ArchitectureGuardTests.self)

        // Hosted layout (ShrinkerProTests has a TEST_HOST): the .xctest is
        // nested at "Shrinker Pro.app/Contents/PlugIns/ShrinkerProTests.xctest".
        // Walk up from the test bundle looking for the first ".app" ancestor
        // rather than assuming a fixed nesting depth.
        var candidate = testBundle.bundleURL
        while candidate.pathComponents.count > 1 {
            candidate = candidate.deletingLastPathComponent()
            if candidate.pathExtension == "app" {
                return candidate
            }
        }

        // Non-hosted fallback: the app as a sibling of the test bundle in
        // the products directory.
        let sibling = testBundle.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("Shrinker Pro.app")
        guard FileManager.default.fileExists(atPath: sibling.path) else {
            throw XCTSkip("""
                app bundle not found from \(testBundle.bundleURL.path). Build it first with:
                DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
                -scheme ShrinkerPro -destination 'platform=macOS,arch=arm64' \
                -derivedDataPath build/DerivedData
                """)
        }
        return sibling
    }

    /// Apple's testing-support frameworks/dylibs that Xcode embeds into a
    /// *hosted* test target's app bundle (Contents/Frameworks) purely to run
    /// tests. Shipped universal by Apple; not part of this project's output.
    static let appleTestSupportFrameworkNames: Set<String> = [
        "XCTest.framework", "XCTestCore.framework", "XCTestSupport.framework",
        "XCUnit.framework", "XCUIAutomation.framework", "XCTAutomationSupport.framework",
        "Testing.framework", "libXCTestSwiftSupport.dylib", "libXCTestBundleInject.dylib",
    ]

    static func isTestInfrastructure(_ url: URL) -> Bool {
        let components = url.pathComponents
        // The embedded test bundle itself (Contents/PlugIns/ShrinkerProTests.xctest/...).
        if components.contains(where: { $0.hasSuffix(".xctest") }) { return true }
        // Apple's test-support frameworks/dylibs under Contents/Frameworks.
        if components.contains(where: { appleTestSupportFrameworkNames.contains($0) }) { return true }
        return false
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
        // 64-bit Mach-O (LE/BE), 32-bit fat/universal (LE/BE), and 64-bit
        // fat/universal (LE/BE). The last pair — FAT_MAGIC_64/FAT_CIGAM_64,
        // used when a fat archive has many slices or large offsets — was
        // added to scripts/verify-arch.sh in Task 2 but never backported
        // here. Missing them didn't make this test fail, it made it stop
        // looking: a fat64 binary in the bundle was simply never collected,
        // never lipo'd, and testAppBundleIsArm64Only went on passing while
        // the invariant it guards was violated. Keep this list in sync with
        // verify-arch.sh's is_macho().
        return [
            0xfeedfacf, 0xcffaedfe,
            0xcafebabe, 0xbebafeca,
            0xcafebabf, 0xbfbafeca,
        ].contains(magic)
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

// MARK: - verify-arch.sh anti-vacuity tests

extension ArchitectureGuardTests {

    func testVerifyArchRejectsUniversalBinary() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("archgate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // /bin/ls ships as a universal binary on macOS; copy it in as a poisoned artifact.
        let fat = tmp.appendingPathComponent("fatbinary")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: fat)
        // Hard assertion, not XCTSkipUnless: this is the only test proving
        // the gate rejects a non-arm64 slice, so "the fixture stopped being
        // universal" must fail loudly and force a replacement rather than
        // quietly disarming the one check that matters. macOS 26 ended
        // Intel support, so the first OS shipping a thin /bin/ls would
        // otherwise turn this into a permanent silent skip.
        let archs = try Self.architectures(of: fat)
        XCTAssertGreaterThan(
            archs.count, 1,
            "/bin/ls reports \(archs) and is no longer universal on this system — this test's "
                + "fixture is gone. Replace it with a fat binary built here (e.g. `lipo -create "
                + "<arm64 binary> <other-arch binary> -output fat`); do not weaken this to a skip."
        )

        let exit = try Self.runVerifyArch(on: tmp)
        XCTAssertEqual(exit, 1, "verify-arch.sh accepted a universal binary — the gate is not working")
    }

    /// Ruling 8: the accept-path fixture is sourced from this project's own
    /// built app executable, not from a system binary. `/bin/ls` cannot
    /// serve this role on modern macOS: its "64-bit" slice is `arm64e`
    /// (Apple's pointer-authentication ABI), not plain `arm64` — a distinct
    /// architecture as far as `lipo` is concerned — so it can never be
    /// thinned down to an `arm64`-only artifact. Our own executable is
    /// guaranteed arm64-only by `ARCHS: arm64` in project.yml and needs no
    /// such external, OS-version-dependent dependency. `XCTSkip` is used
    /// only for the one case that means "nothing to test yet": the app
    /// bundle hasn't been built at all (`Self.builtAppURL()` names the exact
    /// build command in that skip's message). Any other failure to obtain
    /// or verify an arm64-only binary is a genuine test failure, not a skip.
    func testVerifyArchAcceptsArm64OnlyBinary() throws {
        let appURL = try Self.builtAppURL()
        let executable = appURL.appendingPathComponent("Contents/MacOS/ShrinkerPro")

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("archgate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let copy = tmp.appendingPathComponent("thinbinary")
        try FileManager.default.copyItem(at: executable, to: copy)

        // Fail loudly, don't skip: if this isn't arm64-only, arch pinning
        // has regressed, and testAppBundleIsArm64Only should be failing too.
        let archs = try Self.architectures(of: copy)
        XCTAssertEqual(
            archs, ["arm64"],
            "app executable at \(executable.path) reports architectures \(archs), "
                + "expected exactly [\"arm64\"] — arch pinning may have regressed"
        )

        let exit = try Self.runVerifyArch(on: tmp)
        XCTAssertEqual(exit, 0, "verify-arch.sh rejected a valid arm64-only binary")
    }

    /// Ruling 9: the gate must fail closed on target-resolution problems,
    /// not just on bad binaries. A target that doesn't exist (e.g. a stale
    /// path from a wrong --configuration flag) must never report PASS.
    func testVerifyArchRejectsNonexistentTarget() throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("archgate-missing-\(UUID().uuidString)")
        // Deliberately not created — this path must not exist.
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))

        let exit = try Self.runVerifyArch(on: missing)
        XCTAssertEqual(
            exit, 1,
            "verify-arch.sh reported success (or a non-1 exit) on a target that does not "
                + "exist — the gate is failing open"
        )
    }

    /// Ruling 9: an existing-but-empty target (e.g. a build that silently
    /// produced nothing) must also fail closed — no Mach-O examined means
    /// nothing was actually verified, which is not the same as "PASS".
    func testVerifyArchRejectsEmptyDirectory() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("archgate-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let exit = try Self.runVerifyArch(on: tmp)
        XCTAssertEqual(
            exit, 1,
            "verify-arch.sh reported success on an empty directory with no Mach-O files — "
                + "the gate is failing open"
        )
    }

    /// The detector above is what decides which files
    /// `testAppBundleIsArm64Only` even looks at, so a magic number it
    /// doesn't know isn't a failure — it's an omission that keeps the suite
    /// green. This builds a genuine 64-bit fat archive (FAT_MAGIC_64,
    /// `cafebabf`) with `lipo -fat64` from this project's own arm64-only
    /// executable — no system binary, no OS-version dependency — and
    /// asserts both that `isMachO` recognizes it and that `machOFiles(in:)`
    /// actually collects it from a directory. Before the magic numbers were
    /// added, both assertions failed.
    func testMachODetectorRecognizesFat64Archives() throws {
        let appURL = try Self.builtAppURL()
        let executable = appURL.appendingPathComponent("Contents/MacOS/ShrinkerPro")

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fat64-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fat64 = tmp.appendingPathComponent("fat64binary")
        let lipo = Process()
        lipo.executableURL = URL(fileURLWithPath: "/usr/bin/lipo")
        lipo.arguments = ["-create", executable.path, "-fat64", "-output", fat64.path]
        lipo.standardOutput = FileHandle.nullDevice
        lipo.standardError = FileHandle.nullDevice
        try lipo.run()
        lipo.waitUntilExit()
        XCTAssertEqual(lipo.terminationStatus, 0, "lipo -fat64 failed to build the fixture")

        // Confirm the fixture really is a fat64 archive and not something
        // lipo quietly emitted as a thin file — otherwise this test would
        // pass for the wrong reason.
        let magic = try Data(contentsOf: fat64).prefix(4)
        XCTAssertEqual(
            Array(magic), [0xca, 0xfe, 0xba, 0xbf],
            "fixture is not a FAT_MAGIC_64 archive; lipo -fat64 behavior changed"
        )

        XCTAssertTrue(
            try Self.isMachO(fat64),
            "isMachO does not recognize a 64-bit fat archive — such a binary would be skipped "
                + "by testAppBundleIsArm64Only rather than rejected"
        )
        XCTAssertEqual(
            try Self.machOFiles(in: tmp).map(\.lastPathComponent), ["fat64binary"],
            "machOFiles did not collect a 64-bit fat archive"
        )
    }

    static func runVerifyArch(on path: URL) throws -> Int32 {
        // Tests run from DerivedData, not the repo root, and SRCROOT is only
        // set for Xcode build phases — not for the test runner's runtime
        // environment. Resolve the repo root from this file's own location
        // instead (Ruling 4): this file lives at
        // Tests/ShrinkerProTests/ArchitectureGuardTests.swift, so walking up
        // three directories reaches the repo root regardless of where the
        // test executable happens to run from.
        let repoRoot = ProcessInfo.processInfo.environment["SRCROOT"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // Tests/ShrinkerProTests
                .deletingLastPathComponent()  // Tests
                .deletingLastPathComponent()  // repo root
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
