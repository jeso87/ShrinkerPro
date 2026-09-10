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
    /// Per-input-format conversion rules — see `ConversionRules`. Defaults
    /// to "keep everything", i.e. pre-conversion-feature behavior, so
    /// existing call sites that don't mention it are unaffected.
    var conversionRules: ConversionRules = ConversionRules()
}

/// Port of upstream `generateNewPath` in image-shrinker's main.js.
///
/// Order matters and matches upstream: redirect the directory, then append the
/// subfolder, then create it, then build the filename.
enum OutputPathResolver {

    static func resolve(
        input: URL,
        settings: OutputSettings,
        targetExtension: String? = nil,
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

        // `targetExtension` is nil for same-format compression (the
        // pre-conversion behavior: keep whatever extension the input
        // had) and set to the conversion's target extension — "jpg",
        // "webp", or "avif" — whenever `ShrinkEngine` actually converts
        // the file. That's also why a converting output never collides
        // with its input even with suffix and subfolder both off: the
        // extension itself differs, so the in-place case below only ever
        // applies to same-format compression, exactly as before.
        let ext = targetExtension ?? input.pathExtension
        let stem = input.deletingPathExtension().lastPathComponent
        let name = settings.addSuffix ? stem + ".min" : stem

        return ext.isEmpty
            ? directory.appendingPathComponent(name)
            : directory.appendingPathComponent(name).appendingPathExtension(ext)
    }
}
