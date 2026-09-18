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
    /// Encoder quality for the lossy paths, already resolved to the numbers
    /// each encoder takes.
    ///
    /// Resolved rather than a `QualityLevel` on purpose. A level is a *user
    /// interface* concept — four named stops that a picker can iterate and
    /// UserDefaults can persist — and it lives on `Settings`, which owns
    /// both of those jobs. What the engine consumes is numbers, and the CLI
    /// can supply numbers a level cannot express (`--quality 85`). Carrying
    /// the level this far would mean inventing a case for every value
    /// someone might type, and putting it in the Settings picker.
    ///
    /// Defaults to `.standard`'s numbers, so every call site that doesn't
    /// mention quality keeps its existing behaviour. PNG and GIF ignore this
    /// entirely; that is deliberate and explained on `QualityLevel`.
    var quality: QualitySettings = QualityLevel.standard.settings
    /// The main window's session override, when set: every raster format is
    /// converted to this, in place of `conversionRules`. Not persisted, and
    /// deliberately not folded into `conversionRules` — that type cannot
    /// express a PNG target, and flattening the override into it would lose
    /// the distinction between "the user's stored rules" and "what this
    /// session is doing instead". SVG and GIF ignore it, the same way they
    /// ignore the rules.
    var sessionFormat: SessionFormat? = nil
    /// The longest side, in pixels, an image is allowed to keep — the main
    /// window's other session-scoped setting. `nil` means no resizing, and
    /// means it *thoroughly*: with this unset no dimension is read and every
    /// file takes exactly the route it took before the setting existed.
    ///
    /// Shares `sessionFormat`'s lifetime and its reasoning. A stored
    /// dimension cap would be the same object
    /// `2026-09-10-format-conversion.md` rejected for conversion — a setting
    /// that quietly changes every file forever — so this is not persisted
    /// either, and the control stays visible for as long as it is switched
    /// on. See `2026-09-16-max-size-resize-design.md` §2.
    ///
    /// SVG ignores it (a vector has no pixel size to cap); GIF honours it,
    /// via gifsicle rather than ImageIO, because it is the only resizer here
    /// that leaves an animation animated.
    var maxDimension: Int? = nil
    /// The shape — and in `.pixels` mode the size — every raster image is
    /// cropped to from its center, the window's third session-scoped setting.
    ///
    /// `nil` means no cropping, and means it as thoroughly as `maxDimension`
    /// does: with this and the cap both unset no dimension is read and every
    /// file takes byte-for-byte the route it took before either existed.
    ///
    /// Shares `sessionFormat`'s lifetime and its reasoning, and the argument
    /// against persisting it is the strongest of the three — a crop throws
    /// pixels away. See `2026-09-17-center-crop-design.md` §2.
    ///
    /// Composes with `maxDimension` only in `.ratio` mode, where the crop says
    /// nothing about size and the cap is the only thing sizing the result. In
    /// `.pixels` mode the crop has already stated the size and the cap is not
    /// applied at all — two answers to one question, of which the crop is the
    /// more specific. Both front ends refuse the combination rather than
    /// letting it arrive here silently.
    ///
    /// SVG ignores it (a vector has no pixels to cut); GIF honours it, via
    /// gifsicle rather than ImageIO, for the reason it honours the cap there.
    var cropTarget: CropTarget? = nil
}

/// Port of upstream `generateNewPath` in image-shrinker's main.js.
///
/// Order matters and matches upstream: redirect the directory, then append
/// the subfolder, then build the filename. Creating the directory is split
/// out into `prepareDirectory` so a caller can ask where a file would land
/// without anything appearing on disk — see the two methods' own docs.
enum OutputPathResolver {

    /// Where a file will be written, computed without touching the disk.
    ///
    /// Split out of `resolve` so a caller can ask "where would this land?"
    /// before anything is created. Order matches upstream `generateNewPath`:
    /// redirect the directory, then append the subfolder, then build the
    /// filename.
    static func destination(
        input: URL,
        settings: OutputSettings,
        targetExtension: String? = nil
    ) -> URL {

        var directory = input.deletingLastPathComponent()

        // Upstream only redirects when a savepath actually exists; otherwise it
        // leaves the original directory in place.
        if !settings.saveInSameFolder, let savePath = settings.savePath {
            directory = savePath
        }

        if settings.useSubfolder {
            directory = directory.appendingPathComponent("minified", isDirectory: true)
        }

        // `targetExtension` is nil for same-format compression (keep whatever
        // extension the input had) and set to the conversion's target
        // extension whenever `ShrinkEngine` actually converts the file. That
        // is also why a converting output never collides with its input even
        // with suffix and subfolder both off: the extension itself differs.
        let ext = targetExtension ?? input.pathExtension
        let stem = input.deletingPathExtension().lastPathComponent
        let name = settings.keepOriginal ? stem + ".min" : stem

        return ext.isEmpty
            ? directory.appendingPathComponent(name)
            : directory.appendingPathComponent(name).appendingPathExtension(ext)
    }

    /// Creates the directory a destination will be written into.
    ///
    /// Deliberately separate from `destination`: this is the half with a side
    /// effect, and it must not run until the user has consented to the write.
    static func prepareDirectory(
        for destination: URL,
        fileManager: FileManager = .default
    ) throws {
        let directory = destination.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ShrinkError.outputNotWritten(directory)
        }
    }

    /// The first free Finder-style name at or after `destination`.
    ///
    /// `photo.min.png` → `photo.min 2.png`, numbering from 2 and skipping any
    /// that are taken. The whole filename minus its final extension is the
    /// stem, so `.min` is carried along rather than split apart.
    ///
    /// The check-then-write gap is a benign race: the caller writes with a
    /// plain move to a path observed free, and losing it would require another
    /// process to create that exact name in the intervening moment.
    static func uniqueDestination(
        for destination: URL,
        fileManager: FileManager = .default
    ) -> URL {
        guard fileManager.fileExists(atPath: destination.path) else { return destination }

        let ext = destination.pathExtension
        let stem = destination.deletingPathExtension()

        var counter = 2
        while true {
            let numbered = URL(fileURLWithPath: stem.path + " \(counter)")
            let candidate = ext.isEmpty ? numbered : numbered.appendingPathExtension(ext)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }

    /// Both halves, in the order they have always run. No shipped code calls
    /// it any more — the engine plans with `destination` and prepares the
    /// directory only once a write is consented to. It is kept because its
    /// tests pin the combined behaviour the split must still add up to.
    static func resolve(
        input: URL,
        settings: OutputSettings,
        targetExtension: String? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let output = destination(input: input, settings: settings, targetExtension: targetExtension)
        try prepareDirectory(for: output, fileManager: fileManager)
        return output
    }
}
