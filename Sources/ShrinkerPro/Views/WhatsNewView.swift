import SwiftUI

/// Shrinker Pro ▸ What's New: the update notes of the last few versions, newest first, in the
/// language the app is running in (English where a version wasn't translated).
struct WhatsNewView: View {
    static let windowID = "whats-new"

    private let notes: [ReleaseNotes] = {
        guard let folder = Bundle.main.url(forResource: "release-notes", withExtension: nil) else { return [] }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        return ReleaseNotes.load(from: folder, current: version, language: language)
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ForEach(notes, id: \.version) { release in
                    VStack(alignment: .leading, spacing: 10) {
                        // A product name and a version number: nothing to translate.
                        Text(verbatim: "Shrinker Pro \(release.version)")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(LinearGradient(colors: [Theme.gradientStart, Theme.gradientEnd],
                                                            startPoint: .leading, endPoint: .trailing))
                        ForEach(Array(release.blocks.enumerated()), id: \.offset) { _, block in
                            blockView(block)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if release.version != notes.last?.version { Divider() }
                }
            }
            .padding(28)
            .textSelection(.enabled)
        }
        .frame(minWidth: 420, idealWidth: 540, minHeight: 360, idealHeight: 620)
    }

    @ViewBuilder private func blockView(_ block: ReleaseNotes.Block) -> some View {
        switch block {
        case .heading(let text):
            Text(Self.inline(text)).font(.headline).padding(.top, 6)
        case .paragraph(let text):
            Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "•").foregroundStyle(.secondary)
                Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Bold, italics and links from the notes' Markdown; the text as it is if it won't parse.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// The menu item, as a view so it can reach `openWindow`.
struct WhatsNewMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("What's New") { openWindow(id: WhatsNewView.windowID) }
    }
}
