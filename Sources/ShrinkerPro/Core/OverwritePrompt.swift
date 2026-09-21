import Foundation

/// Which kind of file a collision would destroy.
enum OverwriteCategory: Equatable {
    /// The destination *is* the input. The user's own file, unrecoverable.
    case original
    /// Something else is already at that path. It may be a `.min` copy from
    /// an earlier run, or an unrelated file that happens to share a name —
    /// and the difference is not knowable from here, which is why nothing in
    /// the copy below pretends otherwise.
    case existingFile
}

/// What the user decided about one category of collision.
enum OverwriteAnswer {
    /// Leave those files alone; everything else in the batch still runs.
    case skip
    case keepBoth
    case replace
}

/// One sheet's worth of question.
struct OverwriteRequest: Identifiable {
    let id = UUID()
    let category: OverwriteCategory
    let paths: [URL]
    /// How many files in this batch are not affected either way, so the sheet
    /// can say the drop is not being abandoned.
    let unaffectedCount: Int

    /// How many names the message lists before summarising the rest. An
    /// alert is not a scrolling list, and a hundred-file drop must not turn
    /// the sheet into a wall of text with the buttons pushed off screen.
    static let listedNameLimit = 5

    /// The folder every path sits directly in, when there is exactly one.
    ///
    /// When there is, the folder goes in the title and the message lists
    /// bare filenames. When there is not, a bare filename is not enough: a
    /// tree of same-named files would read "photo.png, photo.png, photo.png"
    /// and tell the user nothing about which ones.
    private var sharedParent: URL? {
        let parents = Set(paths.map { $0.standardizedFileURL.deletingLastPathComponent().path })
        guard parents.count == 1, let only = parents.first else { return nil }
        return URL(fileURLWithPath: only, isDirectory: true)
    }

    /// Each path as the message spells it: a bare filename under a shared
    /// parent, otherwise the path below the deepest folder they all share, so
    /// the part that tells them apart is what is shown. Full paths when the
    /// only thing they share is the root.
    private var displayNames: [String] {
        if sharedParent != nil {
            return paths.map(\.lastPathComponent)
        }
        let components = paths.map { $0.standardizedFileURL.pathComponents }
        var common = components.first ?? []
        for other in components.dropFirst() {
            common = Array(zip(common, other).prefix { $0 == $1 }.map(\.0))
        }
        guard common.count > 1 else { return paths.map { $0.standardizedFileURL.path } }
        return components.map { $0.dropFirst(common.count).joined(separator: "/") }
    }

    private var names: String {
        let all = displayNames
        // Deliberately not ListFormatter: in English it would insert an
        // "and" this list does not have, and the truncated case would read
        // "…, and 5.png, …and 3 more". This is a truncated enumeration, not
        // a grammatical list. The separator is a catalog entry so CJK can
        // use "、" without English changing.
        let separator = String(localized: "filename list separator",
                               defaultValue: ", ",
                               comment: "Separates filenames in the overwrite sheet's list. English uses a comma and a space; CJK languages use 、")
        let listed = all.prefix(Self.listedNameLimit).joined(separator: separator)
        let rest = all.count - Self.listedNameLimit
        guard rest > 0 else { return listed }
        return String(localized: "\(listed), …and \(rest) more",
                      comment: "Tail of a truncated filename list. First placeholder is the listed names, second is how many were not listed.")
    }

    var title: String {
        guard let folder = sharedParent else {
            switch category {
            case .original:
                return String(localized: "Replace \(paths.count) originals?",
                              comment: "Overwrite sheet title when the user's own originals would be destroyed and they are not all in one folder.")
            case .existingFile:
                return String(localized: "Replace \(paths.count) files?",
                              comment: "Overwrite sheet title when existing files would be replaced and they are not all in one folder.")
            }
        }
        let name = folder.lastPathComponent
        switch category {
        case .original:
            return String(localized: "Replace \(paths.count) originals in “\(name)”?",
                          comment: "Overwrite sheet title for originals sharing one folder. Second placeholder is the folder name.")
        case .existingFile:
            return String(localized: "Replace \(paths.count) files in “\(name)”?",
                          comment: "Overwrite sheet title for existing files sharing one folder. Second placeholder is the folder name.")
        }
    }

    var message: String {
        var lines: [String] = []
        switch category {
        case .original:
            lines.append(String(localized: "\(paths.count) originals will be overwritten: \(names)",
                                comment: "Overwrite sheet body for originals. First placeholder is the file count and drives the plural; the singular form does not print it. Second is the filename list."))
        case .existingFile:
            lines.append(String(localized: "\(paths.count) files are already there: \(names)",
                                comment: "Overwrite sheet body for existing files. First placeholder is the file count and drives the plural; the singular form does not print it. Second is the filename list."))
        }
        if unaffectedCount > 0 {
            lines.append(String(localized: "The other \(unaffectedCount) files are unaffected.",
                                comment: "Reassurance that the rest of the batch still runs."))
        }
        return lines.joined(separator: "\n\n")
    }

    /// Not "Cancel": it does not cancel the drop, it declines these files.
    ///
    /// Not a catalog plural variation: `xcstringstool` requires a plural
    /// entry to reference the number in at least one of its forms, and
    /// neither "Skip This" nor "Skip These" does — this is demonstrative
    /// ("this"/"these") agreement, not a count being spelled out. Two
    /// top-level strings, chosen here, is what the compiler itself
    /// recommends for that case.
    var skipButtonTitle: String {
        paths.count == 1
            ? String(localized: "Skip This",
                     comment: "Overwrite sheet's cancel-role button when exactly one file is affected. Declines these files; the rest of the batch still runs.")
            : String(localized: "Skip These",
                     comment: "Overwrite sheet's cancel-role button when more than one file is affected. Declines these files; the rest of the batch still runs.")
    }
}

/// Sorts a batch's plans into the two kinds of collision.
enum OverwriteScan {

    static func classify(
        _ plans: [ShrinkPlan],
        fileManager: FileManager = .default
    ) -> (originals: [ShrinkPlan], existing: [ShrinkPlan]) {
        var originals: [ShrinkPlan] = []
        var existing: [ShrinkPlan] = []

        for plan in plans {
            // Standardised so the same file spelled two ways is still one
            // file — otherwise an in-place plan reads as "some other file",
            // and gets the reassuring sheet instead of the alarming one.
            let destination = plan.destination.standardizedFileURL
            guard fileManager.fileExists(atPath: destination.path) else { continue }

            if destination == plan.input.standardizedFileURL {
                originals.append(plan)
            } else {
                existing.append(plan)
            }
        }
        return (originals, existing)
    }
}
