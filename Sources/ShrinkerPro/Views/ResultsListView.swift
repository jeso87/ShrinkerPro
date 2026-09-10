import SwiftUI
import AppKit

struct ResultsListView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            // The "Recent" header is hidden entirely when there is no
            // history, per the spec — an empty list is not a header over
            // blank space, it's nothing at all.
            if !model.rows.isEmpty {
                RecentHeaderView(session: model.session, onClear: model.clearHistory)
                Divider()
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.rows) { row in
                        ResultRowView(row: row)
                        Divider()
                    }
                }
            }
        }
    }
}

private struct ResultRowView: View {
    let row: ResultRow
    @State private var isHovering = false

    /// `−62%` for a saving, `+62%` for a file that grew. `savedPercent` can
    /// be negative (upstream's own formula, verbatim) — mirrored here rather
    /// than clamped, matching the old sentence-based row's "File grew by N%"
    /// meaning without printing a nonsensical "−N%" savings figure.
    private var percentText: String {
        row.savedPercent >= 0 ? "\u{2212}\(row.savedPercent)%" : "+\(-row.savedPercent)%"
    }

    private var percentColor: Color {
        row.savedPercent >= 0 ? Theme.savingsAccent : .orange
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                // Middle, not tail: filenames here carry a shared prefix and a
                // distinguishing tail. Tail-truncating
                // "CleanShot 2026-09-09 at 11.08.37 PM@2x.min.png" drops the
                // ".min.png" — the part that says what format was produced and
                // whether the suffix setting applied — while keeping the
                // "CleanShot 2026-09-09 at" that every such file shares.
                // Eliding the middle preserves both ends, which is why Finder
                // truncates filenames the same way. The full path remains in
                // the row's tooltip.
                Text(row.output.lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                // Bar above, sizes beneath it. Stacking them removes the
                // horizontal competition that previously forced the bar to
                // shrink below its intended width on rows whose sizes render
                // in "bytes" rather than "KB"/"MB" — the bar now always gets
                // its full 150pt, and the size text always gets a full line.
                SavingsBarView(percent: row.savedPercent)
                    .frame(width: 150, height: 3)

                Text(row.sizeSummary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(percentText)
                .font(.system(size: 13.5, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(percentColor)

            PillButtonView(title: "Reveal", action: reveal)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 18)
        .background(isHovering ? Color.primary.opacity(0.045) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: reveal)
        .onHover { isHovering = $0 }
        // The full path is no longer displayed in the row itself — carried
        // here instead, since a user comparing two same-named files written
        // to different folders (or checking where a redirected save landed)
        // still needs to see it.
        .help(row.output.path)
    }

    private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([row.output])
    }
}

/// 150×3pt savings bar: a hairline track with a gradient fill proportional
/// to `percent`. A negative `percent` (file grew) clamps to an empty bar —
/// there is no "saving" to visualise, and the row's percent figure and
/// colour already carry that meaning.
private struct SavingsBarView: View {
    let percent: Int

    private var fraction: Double {
        max(0, min(1, Double(percent) / 100))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.primary.opacity(0.1))
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.barGradient)
                    .frame(width: geo.size.width * fraction)
            }
        }
    }
}

// The "Reveal" pill itself lives in PillButtonView.swift, shared with the
// "RECENT" header's "Clear" pill so both read as the same family of
// control. No separate tooltip is added on top of it here: the row's own
// `.help(row.output.path)` already covers this button (verified
// empirically — the row's help wins over a more local one on this nested
// Button, since the row's tap-gesture container isn't its own
// accessibility element). Duplicating a different string here would be
// misleading dead code.
