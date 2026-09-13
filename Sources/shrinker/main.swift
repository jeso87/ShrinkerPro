import Foundation

// The `shrinker` command-line tool.
//
// Deliberately thin. Everything with a decision in it — argument parsing,
// the mapping onto OutputSettings, input expansion, help text, exit codes,
// the JSON shape — lives in Core and is unit-tested there. What is left here
// is wiring, plus the one thing that genuinely cannot exist anywhere else:
// finding the helper binaries when there is no app bundle to look inside.

func writeLine(_ text: String, to handle: FileHandle) {
    handle.write(Data((text + "\n").utf8))
}

func die(_ message: String, code: Int32) -> Never {
    writeLine("shrinker: " + message, to: .standardError)
    exit(code)
}

// MARK: - Arguments

let options: CommandLineOptions
do {
    options = try CommandLineOptions.parse(Array(CommandLine.arguments.dropFirst()))
} catch let error as CommandLineParseError {
    die(error.errorDescription ?? "bad arguments", code: error.exitCode)
} catch {
    die(error.localizedDescription, code: 64)
}

if options.showsVersion {
    // From Core, so a test can hold it against project.yml — see
    // ShrinkerVersion.
    print(ShrinkerVersion.current)
    exit(0)
}

if options.showsHelp {
    // To stdout, not stderr: help was asked for, so it is this run's output
    // rather than a complaint about it. A bare `shrinker` lands here too.
    print(CommandLineOptions.helpText)
    exit(0)
}

// MARK: - Locating the compressors

/// Where cjpeg, pngquant, gifsicle, cwebp and svgo.jsc.js live.
///
/// The app finds these inside its own bundle; a standalone binary has no
/// bundle, so the layout has to be discovered instead:
///
///   1. `SHRINKER_HELPERS`, which exists so a packager (or a test) can say
///      outright rather than rely on any of the guesses below.
///   2. `../libexec/shrinker` relative to the executable — the Homebrew
///      layout, where `bin/shrinker` is a symlink into the Cellar. The path
///      is resolved first, so the hop through that symlink lands in the real
///      keg rather than in `/opt/homebrew/libexec`.
///   3. Alongside the binary, which is what an unpacked zip looks like.
func helperDirectory() -> URL {
    let environment = ProcessInfo.processInfo.environment
    if let override = environment["SHRINKER_HELPERS"], !override.isEmpty {
        return URL(fileURLWithPath: override, isDirectory: true)
    }

    let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
        .resolvingSymlinksInPath()
    let binDirectory = executable.deletingLastPathComponent()

    let libexec = binDirectory
        .deletingLastPathComponent()
        .appendingPathComponent("libexec/shrinker", isDirectory: true)
    if FileManager.default.fileExists(atPath: libexec.path) {
        return libexec
    }

    return binDirectory
}

let helpers = helperDirectory()

let engine: ShrinkEngine
do {
    engine = try ShrinkEngine(
        helperProvider: { name in
            let url = helpers.appendingPathComponent(name)
            // The same check HelperLocator performs for the app: a typed
            // error naming the missing tool, rather than letting Process
            // fail later with a raw file-not-found.
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw ShrinkError.helperMissing(name)
            }
            return url
        },
        svgoScriptURL: helpers.appendingPathComponent("svgo.jsc.js")
    )
} catch let error as ShrinkError {
    die(error.errorDescription ?? "could not start", code: error.exitCode)
} catch {
    die(error.localizedDescription, code: 1)
}

// MARK: - Doing the work

/// The first failure's exit code. Declared here rather than beside the loop
/// because a missing input is already a failure, before anything is
/// compressed.
var firstFailure: Int32 = 0

// Checked before expansion, because the expander silently drops anything
// that does not exist — so a mistyped path would otherwise vanish into a
// successful-looking run, or be reported as "no images found", which names
// the wrong problem entirely.
//
// Printing the message is not sufficient on its own, which is how the first
// attempt at this was wrong: with one good file and one typo, the good file
// succeeded, `firstFailure` stayed 0, and the run exited 0 while stderr said
// the path did not exist. A caller reading the exit code — which is the
// whole point of having one — was told it worked.
let requested = options.inputs.map { URL(fileURLWithPath: $0) }
let missing = requested.filter { !FileManager.default.fileExists(atPath: $0.path) }
for path in missing {
    writeLine("shrinker: \(path.path): no such file or directory", to: .standardError)
    // EX_NOINPUT. Recorded rather than fatal: the other paths are still
    // worth doing, and the run reports the failure at the end.
    if firstFailure == 0 { firstFailure = 66 }
}

let inputs = InputExpander.expand(requested)

if inputs.isEmpty {
    if missing.isEmpty {
        die("no supported images found in what you gave me.", code: 66)
    }
    exit(firstFailure)
}

// Two inputs that would land on the same filename inside --out: the second
// overwrites the first, and the run reports success for both. Refused rather
// than disambiguated — inventing `logo-1.min.png` would invent a name nobody
// asked for, and picking a winner is exactly what the bug already did.
//
// Checked before any work starts, so the run does not half-finish and leave
// the user guessing which results survived.
if options.outputDirectory != nil {
    let collisions = OutputCollision.groups(in: inputs, convertingTo: options.convertTo)
    if !collisions.isEmpty {
        for collision in collisions {
            writeLine(
                "shrinker: these would all be written as \(collision.name):",
                to: .standardError
            )
            for path in collision.inputs {
                writeLine("shrinker:     \(path.path)", to: .standardError)
            }
        }
        writeLine(
            "shrinker: rename them, or drop --out to write each result beside its own original.",
            to: .standardError
        )
        // EX_DATAERR, not EX_USAGE: the flags are well formed, it is the set
        // of inputs that cannot all be honoured at once.
        exit(65)
    }
}

let settings = options.outputSettings

for file in inputs {
    do {
        let result = try engine.shrink(file, settings: settings)

        if options.json {
            // Formatting lives on ShrinkReport, not here — see jsonLine.
            print(try ShrinkReport.jsonLine(for: result))
        } else {
            // Whether the file was declined is `output == input`, not a
            // percentage. Branching on `savedPercent > 0` announced "left
            // alone" for any conversion that grew — a file that had just
            // been written — which was both false and alarming.
            let summary: String
            if result.output == result.input {
                summary = "left alone — compressing it would have made it bigger"
            } else if result.savedPercent > 0 {
                summary = "\(result.savedPercent)% smaller"
            } else {
                // Written, and no smaller: a conversion the user asked for
                // that cost bytes. Say so rather than dressing it up.
                summary = "\(abs(result.savedPercent))% larger"
            }
            print("\(result.output.path)  \(summary)")
        }
    } catch let error as ShrinkError {
        // Keep going. One unsupported file in a folder of hundreds should
        // not abandon the rest, but the run still has to exit non-zero or a
        // caller will believe everything worked.
        writeLine("shrinker: \(file.path): \(error.errorDescription ?? "failed")", to: .standardError)
        if firstFailure == 0 { firstFailure = error.exitCode }
    } catch {
        writeLine("shrinker: \(file.path): \(error.localizedDescription)", to: .standardError)
        if firstFailure == 0 { firstFailure = 1 }
    }
}

exit(firstFailure)
