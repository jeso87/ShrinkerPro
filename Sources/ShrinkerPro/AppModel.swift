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
    /// silently and forever. This answers both halves of that: the bar
    /// showing it is on sits above the results list the whole time, and it
    /// is gone next launch.
    ///
    /// SVG and GIF are unaffected. They are short-circuited in
    /// `ShrinkEngine.plan` before any rule or override is consulted, so they
    /// need no exemption of their own here.
    @Published var sessionFormat: SessionFormat?

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

    func process(urls: [URL]) async {
        guard !urls.isEmpty else { return }

        if settings.clearList {
            clearHistory()
        }
        isProcessing = true
        defer { isProcessing = false }

        let files = Self.expand(urls)
        // One snapshot per batch, with the session override layered on top
        // of the stored settings. Taken once, before the loop, so changing
        // the override mid-batch cannot convert half a drop to one format
        // and half to another.
        // A `let`, not a mutated `var`: this value is captured by the
        // detached task below, and capturing a `var` is what Swift 6 strict
        // concurrency rejects as a potential race.
        let outputSettings: OutputSettings = {
            var snapshot = settings.outputSettings
            snapshot.sessionFormat = sessionFormat
            return snapshot
        }()
        var succeeded: [ShrinkResult] = []

        for file in files {
            do {
                // Compression is blocking; keep it off the main actor. `engine`
                // is a plain reference type with no shared mutable state
                // across calls, so sharing it into a detached task per file
                // (rather than one detached task for the whole batch) is
                // safe and keeps each file's error isolated to itself.
                let engine = engine
                let result = try await Task.detached(priority: .userInitiated) {
                    try engine.shrink(file, settings: outputSettings)
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
                NSDocumentController.shared.noteNewRecentDocumentURL(file)
                // Deliberately NOT notified here. See the summary after the
                // loop: one notification per batch, not one per file.
                succeeded.append(result)
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

    /// Upstream's renderer recurses into dropped directories via
    /// traverseFileTree; mirror that, filtering to supported extensions.
    static func expand(_ urls: [URL]) -> [URL] {
        var files: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }

            // `.skipsPackageDescendants` below only skips packages found
            // *while* enumerating — it has no effect on the enumeration
            // root itself (verified: without this branch, dropping
            // Fake.app directly still yielded
            // Fake.app/Contents/Resources/icon.png). A package dropped
            // directly is therefore short-circuited here and passed
            // through whole, so it reaches the engine as one item and is
            // reported as an unsupported format rather than silently
            // having every PNG inside an app bundle rewritten.
            let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true

            if isDirectory.boolValue && !isPackage {
                // .skipsPackageDescendants: a bundle (.app, .photoslibrary,
                // .rtfd, …) is a directory to FileManager but a single
                // opaque document to the user. Without this, dropping a
                // folder that happens to contain an app writes
                // "icon.min.png" into Foo.app/Contents/Resources/ — which
                // breaks that bundle's code signature — and in in-place
                // mode (no suffix, no subfolder) rewrites the app's real
                // resources instead. Dropping ~/Pictures would likewise
                // descend into a .photoslibrary and rewrite the library's
                // internals. Nobody dropping a folder means "and also
                // rewrite the insides of every app and library in it".
                // Note .skipsPackageDescendants does NOT apply to the
                // enumeration root, so it alone does not stop a package
                // dropped *directly* from being expanded — that case is
                // short-circuited explicitly above, before this enumerator
                // is ever reached.
                //
                // .skipsHiddenFiles: same reasoning for dot-directories
                // (.git, .Trash, caches) — invisible to the user, so
                // silently rewriting files inside them is never what a drop
                // meant.
                let enumerator = FileManager.default.enumerator(
                    at: url, includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
                while let child = enumerator?.nextObject() as? URL {
                    if ShrinkEngine.supportedExtensions.contains(child.pathExtension.lowercased()) {
                        files.append(child)
                    }
                }
            } else {
                files.append(url)
            }
        }
        return files
    }
}
