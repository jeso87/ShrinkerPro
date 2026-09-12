import Foundation

// The `shrinker` command-line tool.
//
// Deliberately thin. Everything with a decision in it — argument parsing,
// the mapping onto OutputSettings, input expansion, help text, exit codes,
// the JSON shape — lives in Core and is unit-tested there. What is left here
// is wiring, plus the one thing that genuinely cannot exist anywhere else:
// finding the helper binaries when there is no app bundle to look inside.

/// Must track `MARKETING_VERSION` in project.yml.
///
/// A bare tool has no Info.plist to read it from, so this is a hand-kept
/// copy and therefore a drift risk. A test comparing the two is worth
/// adding before this ships.
let shrinkerVersion = "1.1.0"

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
    print(shrinkerVersion)
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

let inputs = InputExpander.expand(options.inputs.map { URL(fileURLWithPath: $0) })

if inputs.isEmpty {
    die("no images found in what you gave me.", code: 66)
}

let settings = options.outputSettings

var firstFailure: Int32 = 0

for file in inputs {
    do {
        let result = try engine.shrink(file, settings: settings)

        if options.json {
            // Formatting lives on ShrinkReport, not here — see jsonLine.
            print(try ShrinkReport.jsonLine(for: result))
        } else {
            let saved = result.savedPercent
            // A declined re-encode reports 0%, which is a real outcome and
            // not a failure — say so plainly rather than printing "0% saved"
            // and leaving the reader to wonder what went wrong.
            let summary = saved > 0
                ? "\(saved)% smaller"
                : "left alone — compressing it would have made it bigger"
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
