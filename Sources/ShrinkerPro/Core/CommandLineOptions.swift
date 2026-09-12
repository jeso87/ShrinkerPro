import Foundation

/// Everything the `shrinker` command line can express, parsed from argv.
///
/// Lives in `Core/` rather than beside the tool's entry point because it is a
/// pure argv-to-options transformation with no IO: the existing test target
/// covers it without the CLI needing a test target of its own, and every flag
/// is assertable without spawning a process. The app target compiles it and
/// never calls it, which costs nothing.
///
/// Parsing is hand-rolled. This project has never had an SPM dependency —
/// there is no `Package.swift` anywhere, and every third-party component is
/// vendored, built from source, and accounted for in `THIRD-PARTY-LICENSES.md`.
/// A flag surface this small does not justify being the first exception, and
/// `--help` is the only discovery surface an AI agent has, so it is worth
/// writing deliberately rather than generating.
struct CommandLineOptions: Equatable {

    /// Paths to shrink, in the order given. Directories are walked by the
    /// caller, not here — this type does not touch the filesystem.
    var inputs: [String] = []

    /// `--out <dir>`: write results here instead of beside each input.
    var outputDirectory: String?

    /// `--in-place`: overwrite each original rather than writing a `.min`
    /// copy beside it.
    ///
    /// Defaults to `false`, and that default is the safety-critical part of
    /// this type. `ShrinkEngine` resolves the output path *to the input path*
    /// when `keepOriginal` is false, so this flag is the difference between
    /// producing a copy and destroying the user's file. An agent that shells
    /// out to this tool without having read the flags must not lose
    /// originals by accident.
    var inPlace: Bool = false

    /// `--json`: emit one machine-readable object per file instead of prose.
    var json: Bool = false

    /// `--quality`: a named level, or a bare number. Defaults to the same
    /// `.standard` the app does, so a command line that says nothing about
    /// quality produces what the GUI produces.
    var quality: QualityChoice = .level(.standard)

    /// `--to`: convert every raster input to this format.
    ///
    /// `nil` — the default — means every file keeps its own format. Unlike
    /// the app, there is no set of stored per-format rules to fall back on:
    /// those live in the user's preferences, which a headless run
    /// deliberately never reads. So the absence of this flag is the absence
    /// of any conversion at all.
    var convertTo: SessionFormat?

    /// `--metadata`: what survives compression. Defaults to `.all`, matching
    /// the app, which is the only value that doesn't silently discard EXIF
    /// the tool would otherwise have carried across.
    var metadata: MetadataPolicy = .all

    var showsHelp: Bool = false
    var showsVersion: Bool = false
}

/// Why a command line was rejected. `Equatable` so tests can assert the exact
/// case and payload rather than merely that something threw.
enum CommandLineParseError: Error, Equatable {
    /// A `-`-prefixed argument this build does not recognise. Deliberately an
    /// error rather than being taken as a filename: treating `--dry-run` as a
    /// path would report "no such file: --dry-run", naming the wrong problem.
    case unknownFlag(String)
    /// A flag that takes a value reached the end of the arguments without one.
    case missingValue(String)
    /// A flag got a value it cannot mean. Carries both halves so the message
    /// can name the flag *and* quote what was actually passed — "invalid
    /// value" alone leaves the reader to guess which of several flags.
    case invalidValue(flag: String, value: String)
}

extension CommandLineParseError {
    /// `EX_USAGE` from BSD `sysexits.h`.
    ///
    /// Deliberately far away from the shrink failures below, because the two
    /// mean different things to a caller: this one says "the command line was
    /// wrong", which retrying verbatim will never fix, while those say "the
    /// work failed", which may well be worth retrying or reporting per-file.
    var exitCode: Int32 { 64 }
}

extension ShrinkError {
    /// One code per failure, so a caller can branch on *why* rather than
    /// parsing prose out of stderr.
    ///
    /// These are a compatibility surface the moment anything scripts against
    /// them, which is why `CommandLineOptionsTests` pins each value and
    /// asserts they stay distinct and non-zero. 1 is left unused as the
    /// conventional catch-all for anything not classified here.
    var exitCode: Int32 {
        switch self {
        case .unsupportedFormat: return 2
        case .helperMissing: return 3
        case .compressorFailed: return 4
        case .javascriptFailed: return 5
        case .outputNotWritten: return 6
        case .conversionFailed: return 7
        }
    }
}

/// What `--quality` accepted: one of the app's named levels, or a bare
/// number.
///
/// Numbers exist for the agent case. An agent asked to bring a file under a
/// size budget needs to sweep values; three named stops give it three
/// attempts and then nowhere to go. The GUI deliberately offers only the
/// named levels — a slider was rejected twice in this project's specs — but a
/// command line has no such reason to withhold the dial.
enum QualityChoice: Equatable {
    case level(QualityLevel)
    case numeric(Int)

    var settings: QualitySettings {
        switch self {
        case .level(let level):
            return level.settings
        case .numeric(let value):
            // Taken literally on every axis, cjpeg's included — where
            // `.standard` deliberately passes no flag at all. Someone who
            // writes `--quality 75` has asked for an explicit 75, which is
            // genuinely not the same bytes as omitting it (see
            // `QualitySettings.cjpegQuality`). Honouring the request beats
            // silently second-guessing it.
            return QualitySettings(
                unitScale: Double(value) / 100,
                cwebpScale: value,
                cjpegQuality: value
            )
        }
    }

    /// `nil` when the value is neither a level this build knows nor a number
    /// the encoders accept.
    ///
    /// Names match case-insensitively and ignore hyphens, so `super-low`,
    /// `superlow` and `superLow` all work. Nobody types Swift's camelCase at
    /// a shell prompt, and an agent reading `--help` should not have to
    /// reverse-engineer it either.
    static func parse(_ value: String) -> QualityChoice? {
        if let number = Int(value) {
            guard (0...100).contains(number) else { return nil }
            return .numeric(number)
        }

        let normalised = value.lowercased().replacingOccurrences(of: "-", with: "")
        return QualityLevel.allCases
            .first { $0.rawValue.lowercased() == normalised }
            .map(QualityChoice.level)
    }
}

extension CommandLineOptions {

    /// What `--help` prints, and what a bare `shrinker` prints.
    ///
    /// This is the entire discovery surface for anything meeting the tool
    /// for the first time — a person, or an agent that will read this once
    /// and then compose command lines from it. So it states the things that
    /// are guessed wrong: that output is a copy rather than a replacement,
    /// that `super-low` takes a hyphen, that two formats ignore `--quality`
    /// entirely, and that compressing never inflates a file.
    ///
    /// `CommandLineOptionsTests` asserts that every flag `parse` accepts
    /// appears here. A flag the parser honours but help never mentions is
    /// invisible, and that drift is easy to introduce and impossible to
    /// notice.
    static let helpText = """
    shrinker — minify images and graphics

    USAGE
      shrinker [options] <file-or-folder>...

    Writes a shrunken copy beside each original with a .min suffix, leaving
    your own files untouched. Folders are searched for supported images.

    OPTIONS
      --quality <level|0-100>  super-low, low, standard (default), high — or a
                               number, for a value no level names
      --to <format>            convert every image: jpeg, webp, avif, png
      --metadata <policy>      all (default), copyright, none
      --out <directory>        write results here instead of beside each input
      --in-place               overwrite each original instead of writing a
                               .min copy. This destroys the source
      --json                   one JSON object per file on stdout
      --help, -h               this text
      --version                version number only

    FORMATS
      Reads PNG, JPEG, GIF, SVG, WebP, AVIF and HEIC.
      SVG and GIF are always kept in their own format and never converted.
      PNG and GIF ignore --quality — the tools that optimise them have no
      comparable setting, so those files are identical at every level.

    Compressing never makes a file bigger. If a same-format result comes out
    larger than its source it is discarded, your original is kept, and the
    saving is reported as 0%. Converting is exempt: growth there is the thing
    you asked for.

    EXAMPLES
      shrinker photo.jpg
      shrinker --quality super-low --to webp ./screenshots
      shrinker --json --quality 85 diagram.png
    """

    /// These options as the engine wants them.
    ///
    /// Two fields are deliberately fixed rather than exposed as flags.
    /// `useSubfolder` is always false — the app's `minified/` subfolder is a
    /// convenience for people dropping files on a window, whereas a command
    /// line already says exactly where output goes. And `conversionRules`
    /// stays entirely "keep": those are the app's *stored* per-format
    /// preferences, which a headless run deliberately never reads, so
    /// conversion happens only when `--to` asks for it.
    var outputSettings: OutputSettings {
        OutputSettings(
            // No --out means "beside the original", which is what the app
            // calls saving in the same folder.
            saveInSameFolder: outputDirectory == nil,
            savePath: outputDirectory.map { URL(fileURLWithPath: $0) },
            useSubfolder: false,
            keepOriginal: !inPlace,
            conversionRules: ConversionRules(),
            metadataPolicy: metadata,
            quality: quality.settings,
            sessionFormat: convertTo
        )
    }

    /// `--to`'s vocabulary. Kept here rather than added to `SessionFormat`
    /// itself: the shell spellings are the CLI's concern, and a Core type
    /// that already documents why it exists separately from
    /// `ConversionFormat` should not also grow argv trivia.
    ///
    /// "jpg" is accepted because it is what people and agents actually
    /// write. Refusing it on the grounds that the enum spells the case
    /// `jpeg` would be a gratuitous failure on the commonest format there
    /// is.
    private static func parseFormat(_ value: String) -> SessionFormat? {
        let normalised = value.lowercased()
        if normalised == "jpg" { return .jpeg }
        return SessionFormat.allCases.first { $0.rawValue.lowercased() == normalised }
    }

    /// `--metadata`'s vocabulary, matched against the stored rawValues.
    ///
    /// That matters for one case: `MetadataPolicy.stripped` carries the
    /// rawValue `"none"`, and is named `stripped` in Swift only to avoid
    /// colliding with `Optional.none`. "none" is both what the defaults
    /// database holds and the word a person reaches for, so it is the
    /// spelling this accepts — matching on the Swift case name instead
    /// would reject the obvious input.
    private static func parseMetadata(_ value: String) -> MetadataPolicy? {
        let normalised = value.lowercased()
        return MetadataPolicy.allCases.first { $0.rawValue.lowercased() == normalised }
    }

    /// Parses `arguments` — argv *without* the executable name.
    ///
    /// Flags and paths may be interleaved in any order: agents assemble
    /// command lines in whatever order they think of the parts, and
    /// order-dependence would be a gratuitous failure mode. `--` ends flag
    /// parsing so a file genuinely named `--json` stays reachable; that is
    /// cheap now and impossible to add later without changing what existing
    /// command lines mean.
    static func parse(_ arguments: [String]) throws -> CommandLineOptions {
        var options = CommandLineOptions()
        var index = arguments.startIndex
        var flagsEnded = false

        /// Consumes the argument after a flag, or reports that the flag was
        /// left dangling at the end of the command line.
        func nextValue(for flag: String) throws -> String {
            guard index < arguments.endIndex else {
                throw CommandLineParseError.missingValue(flag)
            }
            defer { index += 1 }
            return arguments[index]
        }

        while index < arguments.endIndex {
            let argument = arguments[index]
            index += 1

            if flagsEnded {
                options.inputs.append(argument)
                continue
            }

            switch argument {
            case "--":
                flagsEnded = true
            case "--help", "-h":
                options.showsHelp = true
            case "--version":
                options.showsVersion = true
            case "--in-place":
                options.inPlace = true
            case "--json":
                options.json = true
            case "--out":
                options.outputDirectory = try nextValue(for: argument)
            case "--quality":
                let raw = try nextValue(for: argument)
                guard let choice = QualityChoice.parse(raw) else {
                    throw CommandLineParseError.invalidValue(flag: argument, value: raw)
                }
                options.quality = choice
            case "--to":
                let raw = try nextValue(for: argument)
                guard let format = Self.parseFormat(raw) else {
                    throw CommandLineParseError.invalidValue(flag: argument, value: raw)
                }
                options.convertTo = format
            case "--metadata":
                let raw = try nextValue(for: argument)
                guard let policy = Self.parseMetadata(raw) else {
                    throw CommandLineParseError.invalidValue(flag: argument, value: raw)
                }
                options.metadata = policy
            default:
                // A bare "-" is conventionally a stream, not a flag, so it is
                // never reported as an unknown one.
                if argument.hasPrefix("-"), argument != "-" {
                    throw CommandLineParseError.unknownFlag(argument)
                }
                options.inputs.append(argument)
            }
        }

        // A bare `shrinker` explains itself rather than failing: for an agent
        // meeting the tool for the first time, the no-argument invocation is
        // the first thing it will try. `--version` is exempt so it stays a
        // one-line answer rather than printing the whole help text.
        if options.inputs.isEmpty && !options.showsVersion {
            options.showsHelp = true
        }

        return options
    }
}
