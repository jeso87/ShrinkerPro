import Foundation

/// The subset of settings that determine where a shrunken file is written.
struct OutputSettings: Equatable {
    /// Upstream calls this `folderswitch`. True means "save beside the original".
    var saveInSameFolder: Bool
    /// Destination used when `saveInSameFolder` is false.
    var savePath: URL?
    /// Write into a `minified/` subdirectory of the destination.
    var useSubfolder: Bool
    /// Keep the user's original file: append `.min` before the extension so
    /// the shrunken file is written alongside it rather than over it.
    ///
    /// Named for the stake rather than the mechanism. With this false — and
    /// no subfolder and no redirected save path — the resolved output path
    /// *is* the input path, and the original is replaced. The UserDefaults
    /// key behind it is still `"suffix"` and its polarity is unchanged, so
    /// no stored preference had to be migrated when it was renamed.
    var keepOriginal: Bool
    /// Per-input-format conversion rules — see `ConversionRules`. Defaults
    /// to "keep everything", i.e. pre-conversion-feature behavior, so
    /// existing call sites that don't mention it are unaffected.
    var conversionRules: ConversionRules = ConversionRules()
    /// What metadata survives — see `MetadataPolicy`. Defaults to `.all`,
    /// which is the only value that preserves what the app already does.
    var metadataPolicy: MetadataPolicy = .all
    /// The main window's session override, when set: every raster format is
    /// converted to this, in place of `conversionRules`. Not persisted, and
    /// deliberately not folded into `conversionRules` — that type cannot
    /// express a PNG target, and flattening the override into it would lose
    /// the distinction between "the user's stored rules" and "what this
    /// session is doing instead". SVG and GIF ignore it, the same way they
    /// ignore the rules.
    var sessionFormat: SessionFormat? = nil
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
        let name = settings.keepOriginal ? stem + ".min" : stem

        return ext.isEmpty
            ? directory.appendingPathComponent(name)
            : directory.appendingPathComponent(name).appendingPathExtension(ext)
    }
}
