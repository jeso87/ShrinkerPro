import SwiftUI

/// Pure formatting for the "Recent" header's trailing aggregate text —
/// factored out of `RecentHeaderView` so pluralisation and the
/// negative-aggregate wording are unit-testable without SwiftUI (see
/// `RecentHeaderFormatterTests`).
enum RecentHeaderFormatter {

    /// `"1 file"` / `"6 files"`. The plural lives in the catalog.
    static func fileCountLabel(_ count: Int) -> String {
        String(localized: "\(count) files",
               comment: "File count in the Recent header's trailing aggregate.")
    }

    /// The Recent header's trailing aggregate, as one localized sentence
    /// with the size run accented.
    ///
    /// This used to return (prefix, size, suffix) so the view could colour
    /// the middle. That worked, but it fixed " saved" after the number —
    /// English's word order, and not every language's. Now the whole
    /// sentence is one catalog entry and the size run is located within the
    /// result, so a translation may put the words wherever its grammar wants
    /// and the right run is still the accented one.
    ///
    /// `SessionSummary.bytesSaved` can be negative when this session's
    /// outputs grew overall (summed honestly rather than clamped — see
    /// `SessionSummary.record`). Pairing a bare minus sign with "saved"
    /// reads as nonsense, so a net-growth session formats the *magnitude*
    /// and swaps the word: "1.2 MB larger".
    static func aggregate(for session: SessionSummary) -> AttributedString {
        let grew = session.bytesSaved < 0
        let size = formatMagnitude(abs(session.bytesSaved))
        let files = fileCountLabel(session.fileCount)

        let sentence = grew
            ? String(localized: "\(files) · \(size) larger",
                     comment: "Recent header aggregate when this session's outputs grew overall. First placeholder is a file count such as '3 files', second is a size such as '1.2 MB'.")
            : String(localized: "\(files) · \(size) saved",
                     comment: "Recent header aggregate. First placeholder is a file count such as '3 files', second is a size such as '1.2 MB'.")

        var attributed = AttributedString(sentence)
        // The size is our own substring, so locating it is exact rather than
        // a guess. `.last` because a file count can never contain a byte
        // size, but a size could in principle repeat.
        if let range = attributed.range(of: size, options: .backwards) {
            attributed[range].foregroundColor = Theme.savingsAccent
            attributed[range].font = .system(size: 11.5, weight: .semibold)
        }
        return attributed
    }

    private static func formatMagnitude(_ bytes: Int) -> String {
        // A fresh formatter per call, matching SessionSummary.bytesSavedFormatted's
        // own reasoning: ByteCountFormatter is a mutable Foundation class, and a
        // shared static instance would be a concurrency-unsafe shared mutable
        // value under Swift 6 strict checking.
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

/// "RECENT" header between the drop band and the result rows. Hidden
/// entirely by `ResultsListView` when there is no history — this view
/// assumes it is only ever shown alongside at least one row.
struct RecentHeaderView: View {
    let session: SessionSummary
    /// Explicit user action, wired to `AppModel.clearHistory()`. Distinct
    /// from the `clearList` *setting*, which is an automatic policy — this
    /// is the header's own "wipe it now" control.
    let onClear: () -> Void

    var body: some View {
        HStack {
            Text("RECENT")
                .font(.system(size: 10.5, design: .monospaced))
                .tracking(1.26)
                .foregroundStyle(.secondary)

            Spacer()

            aggregateText
                .font(.system(size: 11.5))

            // Styled like the result rows' "Reveal" pill (shared
            // PillButtonView) so it reads as the same family of control
            // rather than a stray button, right-aligned after the
            // aggregate.
            PillButtonView(title: "Clear", action: onClear)
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 9)
    }

    private var aggregateText: Text {
        Text(RecentHeaderFormatter.aggregate(for: session))
            .foregroundColor(.secondary)
    }
}
