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
// `--if-exists keep-both` is the one exception, and it is not an exception to
// the principle: numbering is wrong when nobody asked for it and right when
// somebody did. Those runs fall through to the per-destination numbering
// below, which lets the first input in the list keep `logo.min.png` and
// numbers every later input that shares it — `logo.min 2.png` and up.
//
// Checked before any work starts, so the run does not half-finish and leave
// the user guessing which results survived.
if options.outputDirectory != nil, options.ifExists != .keepBoth {
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

// One slot per (expanded) input, in input order. A planning failure and an
// execution failure can never both land in the same slot — an input that
// fails to plan never reaches the execution loop — so there is never a
// collision to resolve, only which *index* failed first.
//
// This exists because the plan/decide/execute split below runs the whole
// planning sweep before a single file is executed: with the two loops each
// setting `firstFailure` directly (the naive approach), a later input's
// planning failure would outrank an earlier input's execution failure,
// changing the exit code for command lines that type no --if-exists flag at
// all. Recording failures by index and resolving in input order afterwards
// keeps the exit code exactly what the single-loop version would have
// produced: whichever input, first in the list, failed at all.
var failureByIndex: [Int32?] = Array(repeating: nil, count: inputs.count)

// Plan every input before writing anything, so --if-exists fail can refuse
// the whole run rather than stopping halfway with some results written.
var planned: [(index: Int, plan: ShrinkPlan)] = []
for (index, file) in inputs.enumerated() {
    do {
        planned.append((index, try engine.plan(file, settings: settings)))
    } catch let error as ShrinkError {
        writeLine("shrinker: \(file.path): \(error.errorDescription ?? "failed")", to: .standardError)
        failureByIndex[index] = error.exitCode
    } catch {
        writeLine("shrinker: \(file.path): \(error.localizedDescription)", to: .standardError)
        failureByIndex[index] = 1
    }
}

// --in-place makes the destination the input, and the parser refuses any
// non-default --if-exists alongside it, so nothing any case below checks for
// "already exists" can be an original.
//
// Whether a destination already exists is only computed inside the cases
// that consult it, not once up front: `.replace` — the default, and the only
// mode most command lines ever use — must not pay for a stat per input that
// nothing here would use.
switch options.ifExists {
case .replace:
    break
case .fail:
    let occupied = planned.filter { FileManager.default.fileExists(atPath: $0.plan.destination.path) }
    if !occupied.isEmpty {
        for entry in occupied {
            writeLine("shrinker: \(entry.plan.destination.path): already exists", to: .standardError)
        }
        writeLine(
            "shrinker: nothing was written. Use --if-exists skip, keep-both, or replace.",
            to: .standardError
        )
        // EX_DATAERR, matching the input-vs-input refusal above: the flags are
        // well formed, it is the state of the destination that cannot be honoured.
        exit(65)
    }
case .skip:
    let occupied = planned.filter { FileManager.default.fileExists(atPath: $0.plan.destination.path) }
    let skipped = Set(occupied.map { $0.plan.destination.path })
    for path in skipped.sorted() {
        writeLine("shrinker: \(path): already exists, skipped", to: .standardError)
    }
    if options.json {
        // A declined re-encode reports the file's real size on both sides —
        // equal counts, an honest 0% saved — so `originalBytes` means "the
        // real size of the input file" on every line a caller sees. A
        // skipped file mirrors that convention rather than reporting 0/0:
        // zero would read as "we didn't look" here and nowhere else, and
        // paired with an `output` path that was never written, it would read
        // as "a 0-byte file was written here", which is false. If the size
        // genuinely can't be read, 0 is the fallback rather than aborting a
        // run over a file that was, after all, only skipped.
        for entry in occupied.sorted(by: { $0.plan.destination.path < $1.plan.destination.path }) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: entry.plan.input.path)
            let size = (attributes?[.size] as? Int) ?? 0
            let untouched = ShrinkResult(
                input: entry.plan.input, output: entry.plan.destination,
                originalBytes: size, shrunkBytes: size
            )
            print(try ShrinkReport.jsonLine(for: untouched, status: .skipped))
        }
    }
    planned.removeAll { skipped.contains($0.plan.destination.path) }
case .keepBoth:
    // Seeded with every surviving plan's destination, not just the ones being
    // redirected: a plan that collides with nothing still intends to write
    // its own path, and numbering another plan onto it would destroy that
    // result just as surely as the collision this mode exists to avoid.
    //
    // Two different questions get two different sets, because one predicate
    // answering both put the numbering backwards: "may I keep my own name?"
    // must not be blocked by a plan that has not been decided yet — the
    // other half of a two-way collision on the same path is not "taken" by
    // anyone until one of the two loses the tie — while "is this numbered
    // candidate free?" must be blocked by a not-yet-decided plan's natural
    // destination, or a later, non-colliding plan's own name could still be
    // numbered out from under it.
    //
    // `decided`: destinations already settled on by a plan processed so far
    // in this loop — these are real obstacles to everyone after them.
    // `undecidedCounts`: how many plans not yet processed still have this as
    // their *natural* (pre-renumbering) destination. A plain set cannot
    // record "two different plans both want this exact path" — inserting an
    // already-present string is a no-op — which matters exactly when two
    // plans start out wanting the identical destination, the central case
    // here; counting makes releasing one plan's own entry leave any other
    // plan that shares the path still counted.
    var decided = Set<String>()
    var undecidedCounts: [String: Int] = [:]
    for entry in planned {
        undecidedCounts[entry.plan.destination.path, default: 0] += 1
    }

    func releaseUndecided(_ path: String) {
        guard let count = undecidedCounts[path] else { return }
        if count <= 1 {
            undecidedCounts.removeValue(forKey: path)
        } else {
            undecidedCounts[path] = count - 1
        }
    }

    func canKeepOwnDestination(_ url: URL) -> Bool {
        !FileManager.default.fileExists(atPath: url.path) && !decided.contains(url.path)
    }

    func isCandidateFree(_ url: URL) -> Bool {
        !FileManager.default.fileExists(atPath: url.path)
            && !decided.contains(url.path)
            && (undecidedCounts[url.path] ?? 0) == 0
    }

    planned = planned.map { entry in
        // This plan is being decided now, regardless of whether it ends up
        // keeping its own name or being renumbered — either way it stops
        // being one of the undecided plans a later candidate must dodge.
        releaseUndecided(entry.plan.destination.path)

        if canKeepOwnDestination(entry.plan.destination) {
            decided.insert(entry.plan.destination.path)
            return entry
        }

        // Local numbering, not a call to OutputPathResolver.uniqueDestination
        // in a loop: given a name that is free on disk that resolver returns
        // it unchanged, so feeding its own answer back is a fixed point that
        // never terminates. This mirrors its convention exactly — stem,
        // space, integer from 2, extension reattached — while also checking
        // both sets on each candidate.
        let ext = entry.plan.destination.pathExtension
        let stem = entry.plan.destination.deletingPathExtension()
        var counter = 2
        while true {
            let numbered = URL(fileURLWithPath: stem.path + " \(counter)")
            let candidate = ext.isEmpty ? numbered : numbered.appendingPathExtension(ext)
            if isCandidateFree(candidate) {
                decided.insert(candidate.path)
                return (entry.index, entry.plan.writing(to: candidate))
            }
            counter += 1
        }
    }
}

for entry in planned {
    do {
        let result = try engine.shrink(entry.plan)

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
        writeLine("shrinker: \(entry.plan.input.path): \(error.errorDescription ?? "failed")", to: .standardError)
        failureByIndex[entry.index] = error.exitCode
    } catch {
        writeLine("shrinker: \(entry.plan.input.path): \(error.localizedDescription)", to: .standardError)
        failureByIndex[entry.index] = 1
    }
}

// The missing-path check above already set `firstFailure` (66) if anything
// was typed that doesn't exist, and that outranks everything decided here —
// unchanged from before this task. Otherwise, take whichever input, first in
// the list, failed in either phase.
if firstFailure == 0 {
    for code in failureByIndex {
        if let code {
            firstFailure = code
            break
        }
    }
}

exit(firstFailure)
