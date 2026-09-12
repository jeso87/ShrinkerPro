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
