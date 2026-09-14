import Foundation
import Combine
import AppKit

struct ResultRow: Identifiable, Equatable {
    let id = UUID()
    let output: URL
    let originalBytes: Int
    let shrunkBytes: Int
    let savedPercent: Int

    /// `"3.1 MB → 1.2 MB"`, built with `ByteCountFormatter`'s `.file` count
    /// style so the numbers match what Finder would show for the same
    /// files.
    var sizeSummary: String {
        "\(Self.formatBytes(originalBytes)) → \(Self.formatBytes(shrunkBytes))"
    }

    private static func formatBytes(_ count: Int) -> String {
        // A fresh formatter per call rather than a shared static instance:
        // ByteCountFormatter is a mutable Foundation class, and a stored
        // global instance would be a concurrency-unsafe shared mutable
        // value under Swift 6 strict checking. Construction is cheap
        // relative to how rarely this is called (once per rendered row).
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(count))
    }
}

/// Count of files shrunk and total bytes saved since the list was last
/// cleared (either by the `clearList` setting wiping rows at the start of a
/// batch, or app launch). Backs the "Recent" header's "`N` files · `X`
/// saved" trailing text.
struct SessionSummary: Equatable {
    private(set) var fileCount = 0
    private(set) var bytesSaved = 0

    /// The accent-coloured portion of the header text, e.g. `"1.2 MB"`.
    /// Kept separate from `fileCount` rather than one fully-composed string
    /// so the view can style only this part in `Theme.savingsAccent`.
    var bytesSavedFormatted: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytesSaved))
    }

    /// Records one completed shrink. `originalBytes - shrunkBytes` can be
    /// negative (a file that grew) — summed as-is rather than clamped, so
    /// the aggregate stays an honest total instead of silently hiding a
    /// regression the same way individual rows don't hide a negative
    /// `savedPercent`.
    mutating func record(originalBytes: Int, shrunkBytes: Int) {
        fileCount += 1
        bytesSaved += originalBytes - shrunkBytes
    }
}

@MainActor
final class AppModel: ObservableObject {

    @Published private(set) var rows: [ResultRow] = []
    @Published private(set) var session = SessionSummary()
    @Published private(set) var isProcessing = false
    @Published var errorMessage: String?

    /// Convert every raster file to this format for the rest of this run,
    /// whatever the stored per-format rules say. `nil` — the default — means
    /// the stored rules apply, which is the behaviour the app has always had.
    ///
    /// Session state, deliberately: it lives here rather than in `Settings`
    /// so there is no code path that can persist it, and it is reset by
    /// nothing more elaborate than quitting. `2026-09-10-format-conversion.md`
    /// rejected a *stored* global override as too blunt — it would convert
    /// silently and forever. This answers both halves of that: the footer
    /// showing it is on is pinned below the results list the whole time, and
    /// it is gone next launch. (It sat *above* the list until the footer
    /// landed — the position changed, the argument did not: what mattered
    /// was the control never being off screen while an override is in
    /// force. See `WindowFooterView`.)
    ///
    /// SVG and GIF are unaffected. They are short-circuited in
    /// `ShrinkEngine.plan` before any rule or override is consulted, so they
    /// need no exemption of their own here.
    @Published var sessionFormat: SessionFormat?

    /// The sheet the window should be showing, if any. One category at a
    /// time: the originals-at-risk question is asked and answered before the
    /// second is raised, so each carries its own independent answer.
    @Published private(set) var pendingOverwrite: OverwriteRequest?

    /// Resumed exactly once per request — including when the window goes
    /// away, since a continuation that is never resumed leaks the task that
    /// is awaiting it and the batch would hang forever.
    private var overwriteContinuation: CheckedContinuation<OverwriteAnswer, Never>?

    private let engine: ShrinkEngine
    private let settings: Settings
    private let notifier: Notifier?

    init(engine: ShrinkEngine, settings: Settings, notifier: Notifier?) {
        self.engine = engine
        self.settings = settings
        self.notifier = notifier
    }

    /// Entry point for drops, the file picker, and Finder open events.
    func handle(urls: [URL]) {
        Task { await process(urls: urls) }
    }

    /// Empties the results history: both the row list and the session
    /// aggregate. This is the explicit user action (the "RECENT" header's
    /// pill and the "Clear History" menu item) — distinct from the
    /// `clearList` *setting*, which is an automatic policy that wipes the
    /// list at the start of each new batch. `process(urls:)` reuses this
    /// same method for that setting rather than resetting `rows`/`session`
    /// a second, separate way. Safe to call when the history is already
    /// empty — it's just idempotent assignment.
    func clearHistory() {
        rows.removeAll()
        session = SessionSummary()
    }

    /// Called by the sheet's buttons. Dismissing counts as `.skip`.
    ///
    /// Safe to call with nothing pending — it clears a nil and resumes
    /// nothing — which is what lets the window hand it a `.skip` on its way
    /// out without having to know whether a question was on screen.
    func answerOverwrite(_ answer: OverwriteAnswer) {
        pendingOverwrite = nil
        overwriteContinuation?.resume(returning: answer)
        overwriteContinuation = nil
    }

    /// Puts one question on screen and waits for its answer.
    private func ask(_ request: OverwriteRequest) async -> OverwriteAnswer {
        // Only one continuation can be stored, and two batches genuinely can
        // overlap: `handle(urls:)` starts a task per drop, and a Finder "Open
        // With", a Dock drop or an Open Recent click all reach it while a
        // sheet is up. Simply overwriting the stored continuation would
        // strand the earlier batch's — nobody could ever resume it, and it
        // would hang its task for the life of the process. So the displaced
        // question is answered here instead, with `.skip`: the one answer
        // that writes nothing, and therefore the only safe thing to decide on
        // a user's behalf. Resuming enqueues that task rather than running it
        // now, and the continuation below is stored without an intervening
        // suspension point, so this cannot displace itself.
        if let displaced = overwriteContinuation {
            overwriteContinuation = nil
            displaced.resume(returning: .skip)
        }
        return await withCheckedContinuation { continuation in
            overwriteContinuation = continuation
            pendingOverwrite = request
        }
    }

    func process(urls: [URL]) async {
        guard !urls.isEmpty else { return }

        if settings.clearList {
            clearHistory()
        }
        isProcessing = true
        defer { isProcessing = false }

        let files = InputExpander.expand(urls)
        // One snapshot per batch, with the session override layered on top
        // of the stored settings. Taken once, before anything is planned, so
        // changing a setting mid-batch — the override, or the warning itself
        // — cannot split one drop across two behaviours.
        // A `let`, not a mutated `var`: this value is captured by the
        // detached task below, and capturing a `var` is what Swift 6 strict
        // concurrency rejects as a potential race.
        let outputSettings: OutputSettings = {
            var snapshot = settings.outputSettings
            snapshot.sessionFormat = sessionFormat
            return snapshot
        }()

        // Plan the whole batch first. Planning creates nothing, so a drop the
        // user then declines leaves no trace — not even an empty minified/.
        // It is not free: `plan` reads an orientation header and builds a
        // compressor per file, so a hundred-file drop pays a hundred header
        // reads before anyone is asked anything. That is the price of knowing
        // where each file would land, and it is why the batch is planned and
        // scanned exactly once rather than once per sheet.
        var plans: [ShrinkPlan] = []
        for file in files {
            do {
                plans.append(try engine.plan(file, settings: outputSettings))
            } catch {
                // A supported-extension file that doesn't exist on disk (or
                // otherwise fails Foundation-level I/O before ShrinkEngine
                // gets a chance to classify it) surfaces as a raw NSError,
                // not a typed ShrinkError. `localizedDescription` still
                // renders something sane for those; LocalizedError cases
                // use their own tailored text.
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }

        // With the warning turned off, none of this runs: no scan, no extra
        // `stat` per file, no sheet. The path is the one 1.2.0 took, which is
        // the whole point of the setting — a user who declines the warning
        // pays nothing for it.
        if settings.warnBeforeOverwrite {
            let (originals, existing) = OverwriteScan.classify(plans)
            // Stakes first: the irreversible question is asked before the
            // recoverable one. Two questions, each with its own answer, so
            // "keep both of my originals but replace the stale copies" is
            // expressible.
            for group in [(OverwriteCategory.original, originals), (.existingFile, existing)]
            where !group.1.isEmpty {
                let colliding = Set(group.1.map(\.destination.path))
                let answer = await ask(OverwriteRequest(
                    category: group.0,
                    paths: group.1.map(\.destination),
                    unaffectedCount: plans.count - colliding.count
                ))
                switch answer {
                case .replace:
                    break
                case .skip:
                    // Declines these files and only these files — every
                    // non-colliding file in the same drop still runs, which
                    // is why the button says Skip rather than Cancel. A
                    // skipped file produces no row and no error: it is a
                    // choice the user made, not a failure.
                    plans.removeAll { colliding.contains($0.destination.path) }
                case .keepBoth:
                    plans = plans.map { plan in
                        // Only the destination moves. `writing(to:)` accepts
                        // any path without policing its extension, while
                        // `shrink` takes its scratch extension from the
                        // input's route — so the number goes into the name
                        // and the extension is left exactly as planned.
                        colliding.contains(plan.destination.path)
                            ? plan.writing(to: OutputPathResolver.uniqueDestination(for: plan.destination))
                            : plan
                    }
                }
            }
        }

        var succeeded: [ShrinkResult] = []

        for plan in plans {
            do {
                // Compression is blocking; keep it off the main actor. `engine`
                // is a plain reference type with no shared mutable state
                // across calls, so sharing it into a detached task per file
                // (rather than one detached task for the whole batch) is
                // safe and keeps each file's error isolated to itself.
                // `ShrinkPlan` is already `Sendable`, so the decided plan
                // crosses into that task the same way the settings snapshot
                // does.
                let engine = engine
                let result = try await Task.detached(priority: .userInitiated) {
                    try engine.shrink(plan)
                }.value

                rows.insert(
                    ResultRow(
                        output: result.output,
                        originalBytes: result.originalBytes,
                        shrunkBytes: result.shrunkBytes,
                        savedPercent: result.savedPercent
                    ),
                    at: 0
                )
                session.record(originalBytes: result.originalBytes, shrunkBytes: result.shrunkBytes)
                NSDocumentController.shared.noteNewRecentDocumentURL(plan.input)
                // Deliberately NOT notified here. See the summary after the
                // loop: one notification per batch, not one per file.
                succeeded.append(result)
            } catch {
                // Same reasoning as the planning loop above: not every failure
                // that reaches here is a typed ShrinkError.
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }

        // One notification for the whole batch, posted once every file has
        // been through. Notifying inside the loop meant a six-file drop
        // posted six banners, which is noise rather than information — and
        // the useful number, how much the batch saved in total, is only
        // known here.
        if settings.notification, !succeeded.isEmpty {
            await notifier?.notify(
                title: Self.notificationTitle(count: succeeded.count),
                body: Self.notificationBody(for: succeeded)
            )
        }
    }

    /// "Image shrunk" for one file, matching upstream's wording, and a count
    /// for a batch.
    static func notificationTitle(count: Int) -> String {
        count == 1 ? "Image shrunk" : "\(count) images shrunk"
    }

    /// The filename for a single file (upstream's behaviour — with one file
    /// the name is the useful fact), and the total saved for a batch, which
    /// is the only thing a six-file summary can usefully say.
    static func notificationBody(for results: [ShrinkResult]) -> String {
        if let only = results.first, results.count == 1 {
            return only.output.lastPathComponent
        }
        let original = results.reduce(0) { $0 + $1.originalBytes }
        let shrunk = results.reduce(0) { $0 + $1.shrunkBytes }
        let saved = max(0, original - shrunk)
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: Int64(saved))) saved"
    }

}
