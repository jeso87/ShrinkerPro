import Foundation

/// The update notes Sparkle shows before an update, read back for the What's New window.
///
/// They are the same files: `docs/release-notes/<version>.md` in English and
/// `<version>.<language>.md` for each translation, bundled as the `release-notes` folder. One
/// source means the window and the update feed can never disagree.
struct ReleaseNotes: Equatable {
    let version: String
    let blocks: [Block]

    enum Block: Equatable {
        case heading(String)
        case bullet(String)
        case paragraph(String)
    }

    /// How many versions the window shows, newest first.
    static let shownCount = 5

    /// The newest `limit` versions up to and including `current`, each in `language` when it was
    /// translated, else in English. Versions newer than the running app (notes written ahead of
    /// a release) are left out.
    static func load(from directory: URL, current: String, language: String, limit: Int = shownCount) -> [ReleaseNotes] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let versions = Set(names.compactMap(englishVersion(ofFileNamed:)))
            .filter { compare($0, current) != .orderedDescending }
            .sorted { compare($0, $1) == .orderedDescending }
            .prefix(limit)
        return versions.compactMap { version in
            let file = fileName(for: version, language: language, among: Set(names))
            guard let text = try? String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8) else { return nil }
            return ReleaseNotes(version: version, blocks: parse(text))
        }
    }

    /// "1.7.0" for "1.7.0.md"; nil for a translation ("1.7.0.fr.md") or anything else.
    static func englishVersion(ofFileNamed name: String) -> String? {
        guard name.hasSuffix(".md") else { return nil }
        let stem = String(name.dropLast(3))
        let parts = stem.split(separator: ".")
        guard parts.count >= 2, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        return stem
    }

    /// The translation for `language` ("pt-BR", "fr", "zh-Hant"), else its base language's,
    /// else the English file.
    static func fileName(for version: String, language: String, among names: Set<String>) -> String {
        let candidates = [language, String(language.split(separator: "-").first ?? "")]
        for code in candidates where !code.isEmpty && code != "en" {
            let name = "\(version).\(code).md"
            if names.contains(name) { return name }
        }
        return "\(version).md"
    }

    /// Numeric, part by part: "1.10.0" is newer than "1.9.1".
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// The small Markdown the notes use: `###` headings, `- ` bullets whose wrapped lines are
    /// indented, and plain paragraphs. Inline Markdown (bold, links) is left in the text for
    /// the view to render.
    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var current: (kind: Character, text: String)?
        func flush() {
            guard let open = current else { return }
            let text = open.text.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { blocks.append(open.kind == "-" ? .bullet(text) : .paragraph(text)) }
            current = nil
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("#") {
                flush()
                let title = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { blocks.append(.heading(title)) }
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                current = ("-", String(line.dropFirst(2)))
            } else if let open = current {
                current = (open.kind, open.text + " " + line)
            } else {
                current = ("p", line)
            }
        }
        flush()
        return blocks
    }
}
