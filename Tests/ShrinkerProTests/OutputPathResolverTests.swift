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

    // MARK: - Format conversion (targetExtension)

    // Spec's own example: "photo.heic" -> "photo.min.jpg"
    func testTargetExtensionOverridesInputExtension() throws {
        let out = try OutputPathResolver.resolve(
            input: input("photo.heic"), settings: settings(), targetExtension: "jpg", fileManager: .default
        )
        XCTAssertEqual(out.lastPathComponent, "photo.min.jpg")
    }

    /// The spec is explicit that a converting output must never collide
    /// with its input even with suffix and subfolder both off — the
    /// original is "correctly left in place beside the new file", not
    /// something to be "fixed" into deleting the source. With a target
    /// extension that differs from the input's, the in-place case simply
    /// can't produce the same path pngquant/cjpeg/etc. rely on colliding
    /// with today.
    func testConvertingOutputNeverCollidesWithInputEvenWithoutSuffixOrSubfolder() throws {
        let out = try OutputPathResolver.resolve(
            input: input("photo.heic"), settings: settings(suffix: false), targetExtension: "jpg",
            fileManager: .default
        )
        XCTAssertNotEqual(out.path, input("photo.heic").path)
        XCTAssertEqual(out.lastPathComponent, "photo.jpg")
        XCTAssertEqual(out.deletingLastPathComponent(), input("photo.heic").deletingLastPathComponent())
    }

    // targetExtension composes with subfolder/savePath exactly like the
    // input's own extension does today.
    func testTargetExtensionComposesWithSubfolderAndSavePath() throws {
        let dest = root.appendingPathComponent("elsewhere")
        let out = try OutputPathResolver.resolve(
            input: input("photo.avif"),
            settings: settings(sameFolder: false, savePath: dest, subfolder: true),
            targetExtension: "webp",
            fileManager: .default
        )
        XCTAssertEqual(out.deletingLastPathComponent().path, dest.appendingPathComponent("minified").path)
        XCTAssertEqual(out.lastPathComponent, "photo.min.webp")
    }

    // Omitting targetExtension (the default) must reproduce the exact
    // pre-conversion behavior: the input's own extension.
    func testNilTargetExtensionKeepsInputExtension() throws {
        let withDefault = try OutputPathResolver.resolve(input: input(), settings: settings(), fileManager: .default)
        let explicitNil = try OutputPathResolver.resolve(
            input: input(), settings: settings(), targetExtension: nil, fileManager: .default
        )
        XCTAssertEqual(withDefault, explicitNil)
        XCTAssertEqual(withDefault.pathExtension, "png")
    }
}
