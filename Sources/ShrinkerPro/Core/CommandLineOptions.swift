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
                guard index < arguments.endIndex else {
                    throw CommandLineParseError.missingValue(argument)
                }
                options.outputDirectory = arguments[index]
                index += 1
            case "--quality":
                guard index < arguments.endIndex else {
                    throw CommandLineParseError.missingValue(argument)
                }
                let raw = arguments[index]
                index += 1
                guard let choice = QualityChoice.parse(raw) else {
                    throw CommandLineParseError.invalidValue(flag: argument, value: raw)
                }
                options.quality = choice
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
