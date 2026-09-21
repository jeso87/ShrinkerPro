import Foundation
import Combine
import AppKit
import SwiftUI

struct ResultRow: Identifiable, Equatable {
    let id = UUID()
    let output: URL
    let originalBytes: Int
    let shrunkBytes: Int
    let savedPercent: Int

    /// `"3.1 MB → 1.2 MB"`, built with `ByteCountFormatter`'s `.file` count
    /// style so the numbers match what Finder would show for the same files.
    ///
    /// The arrow is part of the catalog entry rather than hardcoded between
    /// the placeholders: it encodes reading direction, and in a
    /// right-to-left language it must point the other way.
    var sizeSummary: String {
        String(localized: "\(Self.formatBytes(originalBytes)) → \(Self.formatBytes(shrunkBytes))",
               comment: "A result row's before-and-after sizes. The arrow points from the original size to the shrunk size; in right-to-left languages it should point the other way (←).")
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
    /// force, and the bar's summary states it in words even when the control
    /// itself is collapsed. See `SessionBarView`.)
    ///
    /// SVG and GIF are unaffected. They are short-circuited in
    /// `ShrinkEngine.plan` before any rule or override is consulted, so they
    /// need no exemption of their own here.
    @Published var sessionFormat: SessionFormat?

    /// The max size field's contents, as typed. Session-scoped exactly like
    /// `sessionFormat` above, and for the same reasons.
    ///
    /// Text rather than `Int?` because the field is the source of truth and
    /// is parsed on every keystroke — see `MaxSizeField`, which owns the
    /// rules and is where they are tested. The `didSet` filters in place, so
    /// a character the field will not accept never appears in it; `filter` is
    /// idempotent, which is what stops the assignment below recurring.
    @Published var sessionMaxSizeText: String = "" {
        didSet {
            let filtered = MaxSizeField.filter(sessionMaxSizeText)
            if filtered != sessionMaxSizeText { sessionMaxSizeText = filtered }
        }
    }

    /// What the field above means to the engine: the longest side an image
    /// may keep, or `nil` for no resizing.
    var sessionMaxDimension: Int? {
        MaxSizeField.dimension(from: sessionMaxSizeText)
    }

    /// The crop fields' contents, as typed, and which of the two modes those
    /// numbers are in. Session-scoped exactly like the settings above, and for
    /// the same reasons — with the argument against persisting a crop being
    /// the strongest of the three, because a crop throws pixels away.
    ///
    /// Two strings and a mode rather than a `CropTarget?`, because the fields
    /// are the source of truth and are parsed on every keystroke. The `didSet`
    /// filters in place; `CropField.filter` is idempotent, which is what stops
    /// the assignment recurring.
    @Published var sessionCropWidthText: String = "" {
        didSet {
            let filtered = CropField.filter(sessionCropWidthText)
            if filtered != sessionCropWidthText { sessionCropWidthText = filtered }
        }
    }

    @Published var sessionCropHeightText: String = "" {
        didSet {
            let filtered = CropField.filter(sessionCropHeightText)
            if filtered != sessionCropHeightText { sessionCropHeightText = filtered }
        }
    }

    /// Whether the two numbers are a pixel size or a bare ratio.
    ///
    /// **Ratio is the default**, because it is the mode that composes with
    /// everything else the bar does: a shape says nothing about size, so the
    /// max size still applies and nothing has to be switched off to make room
    /// for it. Pixel mode states a size outright, which is a stronger and
    /// narrower thing to ask for, and it takes the max size out of play.
    ///
    /// Changing it deliberately does **not** clear the numbers: someone
    /// comparing "1200 × 1200" with "1200 : 1200" is asking one question about
    /// the same pair, and emptying the fields under them would make the
    /// comparison impossible to make twice.
    @Published var sessionCropMode: CropTarget.Mode = .ratio

    /// Exactly one of the two crop fields holds a number.
    ///
    /// **A blocking state, not a warning.** A crop needs both sides, and one
    /// number crops nothing — so rather than let a batch run as though the
    /// number had never been typed, the panel refuses to close and a drop
    /// refuses to start until the pair is finished or cleared. There are two
    /// ways out and both are in the panel: type the other number, or Reset.
    ///
    /// This is a stricter answer than the rest of the bar gives, and
    /// deliberately so. Every other session setting has a meaningful off
    /// state that the summary can name; half a crop has none. It is not "no
    /// crop" — that is an empty pair — it is an instruction that cannot be
    /// carried out, and the only honest thing to do with one is to stop.
    var cropIsIncomplete: Bool {
        CropField.isHalfFilled(
            width: sessionCropWidthText, height: sessionCropHeightText
        )
    }

    /// What the fields above mean to the engine, or `nil` for no cropping —
    /// which is what a half-filled pair means too. See `CropField.target`.
    var sessionCropTarget: CropTarget? {
        CropField.target(
            width: sessionCropWidthText, height: sessionCropHeightText, mode: sessionCropMode
        )
    }

    /// The encoder quality this session is using, or `nil` to use the stored
    /// default from Settings.
    ///
    /// Quality is the one value in the bar that *used* to persist: the old
    /// footer's picker was bound straight to `Settings.quality` and wrote to
    /// UserDefaults on every change. It stopped doing that when the bar
    /// became a statement about one session — "applies to this session only,
    /// defaults live in Settings" has to be true of everything in the bar or
    /// it is true of nothing in it. The stored preference is untouched and
    /// still owns what each launch starts from; this only ever sits on top
    /// of it.
    ///
    /// `nil` rather than a copy of the stored value, so that changing the
    /// default in Settings mid-session is still felt by a session that never
    /// overrode it.
    @Published var sessionQuality: QualityLevel?

    /// Whether the bar is showing its controls rather than its summary.
    ///
    /// On the model rather than in the view because the panel is closed by
    /// things the view does not own — a drop, in particular, which arrives
    /// through `handle(urls:)`.
    @Published private(set) var isSessionPanelExpanded = false

    /// Opens or closes the panel, and on the way closed, settles the max size
    /// field.
    ///
    /// Closing is where an out-of-range number snaps into range, because it
    /// is the one moment every route out of the panel shares — Done, Escape,
    /// a click outside, and a drop all arrive here. Leaving that to the
    /// field's own end-of-editing left "99999" on screen whenever the panel
    /// was closed by something that did not first take focus away from it,
    /// while the engine was already being handed the clamped 20000.
    func setSessionPanel(expanded: Bool) {
        if !expanded {
            // Half a crop keeps the panel open, whichever way it was asked to
            // close — Done, Escape, a click above it, or a drop. All four
            // arrive here, which is the whole reason the refusal lives in the
            // model rather than on the Done button.
            guard !cropIsIncomplete else { return }

            sessionMaxSizeText = MaxSizeField.committed(sessionMaxSizeText)
            sessionCropWidthText = CropField.committed(sessionCropWidthText)
            sessionCropHeightText = CropField.committed(sessionCropHeightText)
        }
        isSessionPanelExpanded = expanded
    }

    /// Returns every session setting to the app's own defaults, which is what
    /// the bar's Reset does. Deliberately not a "clear everything" — it
    /// touches nothing that persists, so Settings is left exactly as it was.
    func resetSessionSettings() {
        sessionFormat = nil
        sessionQuality = nil
        sessionMaxSizeText = ""
        sessionCropWidthText = ""
        sessionCropHeightText = ""
        sessionCropMode = .ratio
    }

    /// The sheet the window should be showing, if any. One category at a
    /// time: the originals-at-risk question is asked and answered before the
    /// second is raised, so each carries its own independent answer.
    @Published private(set) var pendingOverwrite: OverwriteRequest?

    /// Resumed exactly once per request — including when the window goes
    /// away, since a continuation that is never resumed leaks the task that
    /// is awaiting it and the batch would hang forever.
    private var overwriteContinuation: CheckedContinuation<OverwriteAnswer, Never>?

    /// Whether there is a window on screen to present a sheet in.
    ///
    /// Starts `true` rather than waiting to be told: an `AppModel` built
    /// before its window exists — and every test's, which has no window at
    /// all — must still be able to ask, or the guard in `ask` would make the
    /// whole feature dead code outside the running app.
    private var windowIsPresent = true

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
        // An unfinished crop stops the batch before it starts. Shrinking these
        // files as though the number had never been typed is the one outcome
        // that cannot be undone from here — the originals may be replaced, and
        // a crop cannot be re-applied to pixels that have already been thrown
        // away.
        //
        // Every way files arrive comes through this method — a drop, ⌘O, and
        // Finder's own open — so this is the only place it has to be said.
        guard !cropIsIncomplete else {
            if !isSessionPanelExpanded {
                withAnimation(.easeOut(duration: 0.22)) { isSessionPanelExpanded = true }
            }
            errorMessage = String(
                localized: "The crop is missing a side, so it is not clear what these files should be cropped to. Fill in both numbers, or clear the crop, and drop them again.",
                comment: "Alert body when a whole drop is refused because the crop has only one of its two sides filled in."
            )
            return
        }

        // A drop is an answer to "what should happen to these?", so the panel
        // that was asking the question steps out of the way — and the summary
        // it collapses to states what is about to happen to them.
        if isSessionPanelExpanded {
            withAnimation(.easeOut(duration: 0.22)) { setSessionPanel(expanded: false) }
        }
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
    ///
    /// The continuation is taken out of the slot *before* it is resumed, so
    /// the resume-exactly-once invariant is structural rather than resting on
    /// there being no synchronous observer able to re-enter between the two
    /// lines. Same shape as the displacement in `ask`.
    func answerOverwrite(_ answer: OverwriteAnswer) {
        let continuation = overwriteContinuation
        overwriteContinuation = nil
        pendingOverwrite = nil
        continuation?.resume(returning: answer)
    }

    /// A window is on screen and can present a sheet.
    func windowAppeared() {
        windowIsPresent = true
    }

    /// The window has gone, and whatever sheet it was showing went with it.
    ///
    /// Answers the question that was on screen, and — via `windowIsPresent` —
    /// every question raised after this point, until a window comes back.
    func windowDisappeared() {
        windowIsPresent = false
        answerOverwrite(.skip)
    }

    /// Puts one question on screen and waits for its answer.
    private func ask(_ request: OverwriteRequest) async -> OverwriteAnswer {
        // No window, nobody to ask. Storing a continuation here would suspend
        // this batch on an answer that cannot arrive: no sheet would ever be
        // presented, `isProcessing` would stay true, and the drop zone would
        // spin for the life of the process.
        //
        // This is the gap a one-shot `.onDisappear` could not close. That
        // fires once, as the window goes; a batch can reach this line
        // afterwards — the second category of a batch whose first sheet the
        // teardown answered, or any batch that starts while no window is up.
        guard windowIsPresent else { return .skip }

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

    /// The first name free both on disk and among the destinations this batch
    /// has already claimed.
    ///
    /// "Claimed" means every destination some plan in the batch is going to
    /// write — not only the ones Keep Both has already handed out. A plan that
    /// collided with nothing never appears in a sheet, but its destination is
    /// spoken for all the same: with originals replaced into `minified/`, a
    /// redirect for `photo.png` would otherwise pick a free
    /// `minified/photo 2.png` that `photo 2.png` is itself about to write.
    ///
    /// `OutputPathResolver.uniqueDestination` answers the first half, and is
    /// left exactly as it is — it belongs to a closed task and the CLI depends
    /// on it. The second half is this batch's own business: `InputExpander`
    /// does not de-duplicate, so dropping a folder together with a file inside
    /// it plans that file twice. Two plans asking the resolver the same
    /// question get the same answer, both would be written to
    /// `photo.min 2.png`, and the second would destroy the first — data loss
    /// in the one path whose entire purpose is not losing data.
    ///
    /// The numbering below repeats the resolver's scheme rather than calling
    /// it in a loop, deliberately: given a name that is free on disk the
    /// resolver returns it unchanged, so feeding its own answer back to it
    /// would never terminate.
    private static func freeDestination(
        for destination: URL, isClaimed: (String) -> Bool
    ) -> URL {
        let first = OutputPathResolver.uniqueDestination(for: destination)
        guard isClaimed(first.path) else { return first }

        let ext = destination.pathExtension
        let stem = destination.deletingPathExtension()
        var counter = 2
        while true {
            let numbered = URL(fileURLWithPath: stem.path + " \(counter)")
            let candidate = ext.isEmpty ? numbered : numbered.appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path),
               !isClaimed(candidate.path) {
                return candidate
            }
            counter += 1
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
            snapshot.maxDimension = sessionMaxDimension
            snapshot.cropTarget = sessionCropTarget
            // `outputSettings` has already resolved the stored quality, so
            // this replaces it only when the session says otherwise.
            if let sessionQuality { snapshot.quality = sessionQuality.settings }
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
                // AppDisplayableError first: errorDescription is the CLI's
                // English, this is the app's translated text. See the
                // localization spec's "The Core seam".
                errorMessage = (error as? AppDisplayableError)?.localizedMessage
                    ?? (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }

        // With the warning turned off, none of this runs: no scan, no extra
        // `stat` per file, no sheet. The path is the one 1.2.0 took, which is
        // the whole point of the setting — a user who declines the warning
        // pays nothing for it.
        if settings.warnBeforeOverwrite {
            let (originals, existing) = OverwriteScan.classify(plans)
            // How many files in this drop no question touches at all — counted
            // once, across BOTH categories, before anything is asked or
            // applied.
            //
            // Deriving it per-sheet from the category being asked about is
            // wrong in the exact way this feature exists to prevent: on the
            // first sheet, every file queued for the second would be counted
            // as unaffected, so a drop with one original at risk and one
            // existing file to replace would say "The other file is
            // unaffected" about a file the very next sheet offers to destroy.
            //
            // Counting plans rather than distinct paths is deliberate too: two
            // plans for the same input (see `freeDestination`) are two files
            // the user is being asked about, not one. And computing it before
            // any answer is applied keeps a `.skip` in the first category from
            // driving the second sheet's count negative.
            let collidingTotal = originals.count + existing.count
            let unaffectedCount = plans.count - collidingTotal
            // Every destination this batch is going to write, counted per
            // path, reserved before either question is asked.
            //
            // Batch-scoped, and seeded with *every* plan rather than only the
            // ones a sheet redirects: a plan with no collision never appears
            // in a sheet, yet a Keep Both redirect must not land on the path
            // it is about to write — see `freeDestination`. And it outlives
            // the first sheet, so the second sheet's redirects see the first
            // sheet's.
            //
            // A count, not a set, so that a plan's own entry never blocks that
            // plan while a *second* plan wanting the same path still does. The
            // two cases are indistinguishable in a set, and the duplicate one
            // (a folder dropped with a file inside it) is real.
            var claims: [String: Int] = [:]
            for plan in plans {
                claims[plan.destination.path, default: 0] += 1
            }
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
                    unaffectedCount: unaffectedCount
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
                    for plan in plans where colliding.contains(plan.destination.path) {
                        claims[plan.destination.path, default: 0] -= 1
                    }
                    plans.removeAll { colliding.contains($0.destination.path) }
                case .keepBoth:
                    // Nothing is written until every plan has been decided,
                    // so the filesystem alone cannot tell two plans apart —
                    // the batch's own `claims` does. See `freeDestination`.
                    plans = plans.map { plan in
                        guard colliding.contains(plan.destination.path) else { return plan }
                        let own = plan.destination.path
                        // Only the destination moves. `writing(to:)` accepts
                        // any path without policing its extension, while
                        // `shrink` takes its scratch extension from the
                        // input's route — so the number goes into the name
                        // and the extension is left exactly as planned.
                        let free = Self.freeDestination(for: plan.destination) { path in
                            // This plan's own claim on its own path does not
                            // count against it; anyone else's does.
                            (claims[path] ?? 0) > (path == own ? 1 : 0)
                        }
                        claims[own, default: 0] -= 1
                        claims[free.path, default: 0] += 1
                        return plan.writing(to: free)
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
                // AppDisplayableError first: errorDescription is the CLI's
                // English, this is the app's translated text. See the
                // localization spec's "The Core seam".
                errorMessage = (error as? AppDisplayableError)?.localizedMessage
                    ?? (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
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
    ///
    /// The singular/plural split lives in the string catalog rather than in
    /// a ternary here. English needs two forms; Arabic needs six and
    /// Japanese needs one, and a `count == 1 ? :` can only ever express
    /// English's shape. See the localization spec's "Plural forms".
    static func notificationTitle(count: Int) -> String {
        String(localized: "\(count) images shrunk",
               comment: "Notification title after a batch finishes. The one-file form reads 'Image shrunk' with no number.")
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
