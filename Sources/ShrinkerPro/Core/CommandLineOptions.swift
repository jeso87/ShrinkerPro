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

    /// `--max-size`: scale any image whose longest side exceeds this down to
    /// it, preserving the aspect ratio. `nil` — the default — leaves every
    /// image at the size it arrived.
    ///
    /// The app's equivalent is a session-scoped field in the window footer,
    /// not a stored preference, so there is nothing here for a headless run
    /// to decline to read: the flag is the only way to ask for it, in both
    /// places by design.
    var maxDimension: Int?

    /// `--metadata`: what survives compression. Defaults to `.all`, matching
    /// the app, which is the only value that doesn't silently discard EXIF
    /// the tool would otherwise have carried across.
    var metadata: MetadataPolicy = .all

    /// `--if-exists`: what to do when the destination already exists.
    /// Defaults to `.replace`, which is exactly what every earlier version of
    /// this tool did — the guard is opt-in precisely so no existing script
    /// changes behaviour on upgrade.
    var ifExists: IfExists = .replace

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
    /// Two flags that cannot both be honoured. Carries both so the message
    /// can name the pair rather than picking one and leaving the reader to
    /// work out what it conflicted with — and the reason, supplied by the
    /// check that refused them, because each pair conflicts for its own
    /// reason and no one sentence is true of all of them.
    case contradictoryFlags(String, String, reason: String)
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

extension CommandLineParseError: LocalizedError {
    /// What goes to stderr when a command line is rejected.
    ///
    /// This is a discovery surface in its own right, not just a courtesy.
    /// When an agent's command line is refused, stderr is the only thing it
    /// receives, and it has to work out what to change without a human
    /// reading over its shoulder — so each message names the offending flag,
    /// quotes the offending value, and an unrecognised flag says where the
    /// real list lives. "invalid arguments" would be worse than silence: it
    /// implies the caller has been told something.
    ///
    /// Lowercase and unpunctuated at the start because the caller prefixes
    /// these with `shrinker: `, the usual `tool: message` shape for stderr.
    var errorDescription: String? {
        switch self {
        case .unknownFlag(let flag):
            return "unknown option '\(flag)'. Run 'shrinker --help' for the list of options."
        case .missingValue(let flag):
            return "'\(flag)' needs a value."
        case .invalidValue(let flag, let value):
            return "'\(value)' is not a valid value for '\(flag)'. "
                + "Run 'shrinker --help' for the accepted values."
        case .contradictoryFlags(let one, let other, let reason):
            return "'\(one)' and '\(other)' cannot be used together — \(reason)."
        }
    }
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

/// Detects inputs that would be written to the same place.
///
/// `--out` flattens every result into one directory, so two files with the
/// same name in different folders resolve to the same output path and the
/// second silently replaces the first — the user asked for two results and
/// got one, with no mention of it.
///
/// Only relevant when `--out` is set: writing beside each original keeps
/// results in separate directories by construction. And `--in-place` is
/// refused alongside `--out`, so the `.min` suffix is always present here,
/// which is why nothing below needs to know about it.
enum OutputCollision {

    /// The filename an input would land on inside the `--out` directory.
    ///
    /// Mirrors `ShrinkEngine.outputExtension(for:)` and the routing rules it
    /// reads from. Duplicated rather than shared because that method is
    /// private to the engine and takes a `ConversionRoute` this side has no
    /// way to compute — but the three rules it encodes are stable and
    /// individually tested elsewhere:
    ///
    ///   - SVG and GIF never convert, whatever `--to` says.
    ///   - `--to` otherwise decides the extension.
    ///   - HEIC has no "keep" option anywhere, so it becomes JPEG on its own.
    ///
    /// That last one is why a plain basename comparison is wrong: `photo.heic`
    /// and `photo.jpg` have different input extensions and still collide.
    static func outputName(for input: URL, convertingTo target: SessionFormat?) -> String {
        let stem = input.deletingPathExtension().lastPathComponent
        let ext = input.pathExtension.lowercased()

        let resolved: String
        switch ext {
        case "svg", "gif":
            resolved = ext
        default:
            if let target {
                resolved = target.outputExtension
            } else if ext == "heic" || ext == "heif" {
                resolved = "jpg"
            } else {
                resolved = ext
            }
        }
        return "\(stem).min.\(resolved)"
    }

    /// Inputs grouped by the output filename they share, for every name
    /// claimed by more than one of them. Ordered by filename, and each group
    /// in the order the inputs were given, so the report is stable.
    static func groups(in inputs: [URL], convertingTo target: SessionFormat?) -> [(name: String, inputs: [URL])] {
        var byName: [String: [URL]] = [:]
        for input in inputs {
            byName[outputName(for: input, convertingTo: target), default: []].append(input)
        }
        return byName
            .filter { $0.value.count > 1 }
            .sorted { $0.key < $1.key }
            .map { (name: $0.key, inputs: $0.value) }
    }
}

extension SessionFormat {
    /// The extension this format's output actually carries. JPEG is written
    /// `.jpg`, matching `ShrinkEngine.outputExtension(for:)`.
    var outputExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .webp: return "webp"
        case .avif: return "avif"
        case .png: return "png"
        }
    }
}

/// One object of `--json` output: what happened to a single file.
///
/// A separate type rather than `Codable` on `ShrinkResult`, for two
/// reasons. Serialisation for one front end has no business being welded
/// onto the engine's own result type; and the encoding `ShrinkResult` would
/// synthesize is the wrong one anyway — `URL` encodes as
/// `file:///photos/a.png`, which is useless to a caller that wants to hand
/// the path to the next command, and `savedPercent` is computed, so it
/// would silently not appear at all despite being the single number a
/// caller most wants.
///
/// `Encodable`, not `Codable`: the CLI writes these and never reads them
/// back, and claiming a decode path that nothing exercises would be a lie
/// in the type signature.
struct ShrinkReport: Encodable {
    /// What actually happened to this file.
    ///
    /// Additive to a contract that is already a compatibility surface:
    /// `.sortedKeys` places it deterministically and a consumer reading the
    /// five older keys is unaffected. It exists because "nothing happened"
    /// had two causes and only one spelling — a skipped file and a declined
    /// re-encode both reported `output == input` at 0% saved.
    enum Status: String, Encodable {
        case shrunk
        case declined
        case skipped
    }

    let input: String
    let output: String
    let originalBytes: Int
    let shrunkBytes: Int
    let savedPercent: Int
    let status: Status

    /// One `--json` line, exactly as the tool emits it.
    ///
    /// The encoder's configuration is part of the output contract, so it
    /// belongs here where a test can reach it — not at the call site, which
    /// is where both of the defects this method exists to fix were living
    /// and where nothing could have caught them:
    ///
    ///   - `.withoutEscapingSlashes`, because `JSONEncoder` renders a path
    ///     as `\/photos\/a.png` by default. Valid JSON, but an agent that
    ///     greps the path out of the line instead of parsing it gets
    ///     something that is not a path — and paths are the point.
    ///   - `.sortedKeys`, because the default order follows dictionary
    ///     iteration and is not stable. Two objects from a single run came
    ///     back in different orders, which makes stdout undiffable between
    ///     runs and useless as a cache key.
    ///
    /// Not pretty-printed: one object per line, so the output can be read by
    /// anything that consumes a stream line by line.
    static func jsonLine(for result: ShrinkResult, status: Status? = nil) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return String(decoding: try encoder.encode(ShrinkReport(result, status: status)), as: UTF8.self)
    }

    init(_ result: ShrinkResult, status: Status? = nil) {
        // `.path`, not the URL itself — see the note above.
        self.input = result.input.path
        // The engine's own answer for where the file ended up, which is not
        // always where the path resolver aimed: `replaceItemAt` can relocate
        // it on a file provider such as iCloud Drive, and a declined
        // re-encode reports the untouched original instead of a `.min` file
        // that was never written.
        self.output = result.output.path
        self.originalBytes = result.originalBytes
        self.shrunkBytes = result.shrunkBytes
        self.savedPercent = result.savedPercent
        // The engine reports a declined re-encode by pointing the result at
        // the untouched original — the same signal main.swift branches on to
        // print "left alone".
        self.status = status ?? (result.output == result.input ? .declined : .shrunk)
    }
}

/// What to do when a result's destination already exists.
///
/// The vocabulary is deliberately the app's sheet buttons plus this tool's
/// own long-standing refusal stance, so the two surfaces answer the same
/// question with the same words.
enum IfExists: String, Equatable, CaseIterable {
    case replace
    case skip
    case keepBoth
    case fail

    /// What a person types, which is not what Swift spells.
    var flagName: String { self == .keepBoth ? "keep-both" : rawValue }

    static func parse(_ raw: String) -> IfExists? {
        let normalised = raw.lowercased().replacingOccurrences(of: "-", with: "")
        return allCases.first { $0.rawValue.lowercased() == normalised }
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
                // Capped just below 1.0, because ImageIO's AVIF encoder
                // fails outright at exactly 1.0: CGImageDestinationFinalize
                // returns false and writes nothing, so `--quality 100 --to
                // avif` died with conversionFailed and exit 7 for a value
                // --help advertises as valid. Measured: 0.99 and 0.999 both
                // encode fine, 1.0 produces 0 bytes. HEIC is unaffected.
                //
                // The cap is on this axis only. cjpeg and cwebp both accept
                // their full 0...100 range, and silently lowering what a
                // caller asked those encoders for would be its own bug.
                unitScale: min(Double(value) / 100, 0.99),
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
      --max-size <pixels>      shrink any image whose longest side is bigger
                               than this, keeping its aspect ratio
      --metadata <policy>      all (default), copyright, none
      --out <directory>        write results here instead of beside each input
      --in-place               overwrite each original instead of writing a
                               .min copy. This destroys the source
      --if-exists <what>       when the destination already exists:
                               replace (default), skip, keep-both, fail
      --json                   one JSON object per file on stdout
      --help, -h               this text
      --version                version number only

    FORMATS
      Reads PNG, JPEG, GIF, SVG, WebP, AVIF and HEIC.
      SVG and GIF are always kept in their own format and never converted.
      HEIC is always converted, to JPEG unless --to says otherwise. There is
      no HEIC-to-HEIC path: most tools outside Apple's ecosystem still
      cannot open one, so keeping it is rarely what anyone wants.
      PNG and GIF ignore --quality — the tools that optimise them have no
      comparable setting, so those files are identical at every level.
      SVG ignores --max-size: it is vector, so it has no pixel size to cap.
      An image already within --max-size is left at the size it arrived.

    Compressing never makes a file bigger. If a same-format result comes out
    larger than its source it is discarded, your original is kept, and the
    saving is reported as 0%. Converting and resizing are exempt: growth
    there is the thing you asked for.

    EXAMPLES
      shrinker photo.jpg
      shrinker --quality super-low --to webp ./screenshots
      shrinker --json --quality 85 diagram.png
      shrinker --if-exists keep-both --quality 60 photo.jpg
      shrinker --max-size 2000 ./camera-roll
    """

    /// These options as the engine wants them.
    ///
    /// Two fields are deliberately fixed rather than exposed as flags.
    /// `useSubfolder` is always false — the app's `minified/` subfolder is a
    /// convenience for people dropping files on a window, whereas a command
    /// line already says exactly where output goes. And `conversionRules` is
    /// left at its own defaults: those are the app's *stored* per-format
    /// preferences, which a headless run deliberately never reads.
    ///
    /// That is "keep" for every format except HEIC, and the distinction is
    /// worth stating because an earlier version of this comment claimed
    /// conversion happens only when `--to` asks for it. It does not.
    /// `ConversionRules.heic` is a `ConversionFormat`, which has no `.keep`
    /// case at all — HEIC always converts, defaulting to JPEG — so
    /// `shrinker photo.heic` writes `photo.min.jpg`. There is no
    /// HEIC-to-HEIC route to fall back on: `.sameFormat(.heic)` is
    /// unreachable by construction. `--help` says so under FORMATS.
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
            sessionFormat: convertTo,
            maxDimension: maxDimension
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
            case "--max-size":
                let raw = try nextValue(for: argument)
                // Rejected rather than clamped: zero and negatives are not a
                // quieter way of saying "no resizing", they are a value that
                // cannot mean anything, and silently treating one as "off"
                // would run a whole batch at full size while looking like it
                // had been told otherwise. Omitting the flag is how you say
                // off.
                guard let size = Int(raw), size > 0 else {
                    throw CommandLineParseError.invalidValue(flag: argument, value: raw)
                }
                options.maxDimension = size
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
            case "--if-exists":
                let raw = try nextValue(for: argument)
                guard let mode = IfExists.parse(raw) else {
                    throw CommandLineParseError.invalidValue(flag: argument, value: raw)
                }
                options.ifExists = mode
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

        // --in-place and --out have no coherent combined meaning, and
        // accepting both silently produced a third behaviour that is neither:
        // output written to the --out directory without the .min suffix,
        // originals left untouched. Refused at the door rather than resolved
        // by a precedence rule nobody could guess, and never documented.
        if options.inPlace, options.outputDirectory != nil, !options.showsHelp {
            throw CommandLineParseError.contradictoryFlags(
                "--in-place", "--out",
                reason: "one overwrites each original, the other writes copies elsewhere"
            )
        }

        // --in-place makes the destination the input, so there is nothing for
        // --if-exists to decide. Refused rather than ignored, for the same
        // reason as above: a flag that is accepted and does nothing is worse
        // than one that is rejected and says why. An explicit `replace` is
        // the default and contradicts nothing.
        if options.inPlace, options.ifExists != .replace, !options.showsHelp {
            throw CommandLineParseError.contradictoryFlags(
                "--in-place", "--if-exists",
                reason: "'--in-place' always overwrites the original itself, "
                    + "so there is no separate destination for '--if-exists' to decide about"
            )
        }

        return options
    }
}
