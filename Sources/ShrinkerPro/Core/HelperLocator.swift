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
