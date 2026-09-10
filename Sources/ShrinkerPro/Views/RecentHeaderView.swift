import SwiftUI

/// Pure formatting for the "Recent" header's trailing aggregate text —
/// factored out of `RecentHeaderView` so pluralisation and the
/// negative-aggregate wording are unit-testable without SwiftUI (see
/// `RecentHeaderFormatterTests`).
enum RecentHeaderFormatter {

    /// `"1 file"` / `"6 files"`.
    static func fileCountLabel(_ count: Int) -> String {
        count == 1 ? "1 file" : "\(count) files"
    }

    /// Splits the aggregate into three runs so the caller can colour only
    /// the middle (size) run in `Theme.savingsAccent` and leave the rest
    /// secondary — building one composed `Text`, not two views jammed
    /// together with a space.
    ///
    /// `SessionSummary.bytesSaved` can be negative when this session's
    /// outputs grew overall — summed honestly rather than clamped (see
    /// `SessionSummary.record`). `SessionSummary.bytesSavedFormatted` would
    /// render that as e.g. `"-1.2 MB"`, and pairing a bare minus sign with
    /// "saved" reads as nonsense ("you saved -1.2 MB"). Instead this formats
    /// the *magnitude* of the regression and swaps the trailing word, so a
    /// net-growth session reads as "1.2 MB larger" — an honest, plain-English
    /// statement of what happened, matching how individual rows already
    /// render a negative `savedPercent` as "File grew by N%" rather than a
    /// negative percentage.
    static func aggregateParts(for session: SessionSummary) -> (prefix: String, size: String, suffix: String) {
        let grew = session.bytesSaved < 0
        return (
            prefix: "\(fileCountLabel(session.fileCount)) · ",
            size: formatMagnitude(abs(session.bytesSaved)),
            suffix: grew ? " larger" : " saved"
        )
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
        let parts = RecentHeaderFormatter.aggregateParts(for: session)
        return Text(parts.prefix).foregroundColor(.secondary)
            + Text(parts.size).foregroundColor(Theme.savingsAccent).fontWeight(.semibold)
            + Text(parts.suffix).foregroundColor(.secondary)
    }
}
