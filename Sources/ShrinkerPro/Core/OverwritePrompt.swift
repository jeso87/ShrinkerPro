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
        let listed = all.prefix(Self.listedNameLimit).joined(separator: ", ")
        let rest = all.count - Self.listedNameLimit
        return rest > 0 ? "\(listed), …and \(rest) more" : listed
    }

    var title: String {
        let counted: String
        switch category {
        case .original:
            counted = paths.count == 1 ? "1 original" : "\(paths.count) originals"
        case .existingFile:
            counted = paths.count == 1 ? "1 file" : "\(paths.count) files"
        }
        guard let folder = sharedParent else { return "Replace \(counted)?" }
        return "Replace \(counted) in “\(folder.lastPathComponent)”?"
    }

    var message: String {
        var lines: [String] = []
        switch category {
        case .original:
            lines.append(
                paths.count == 1
                    ? "\(names) will be overwritten and cannot be recovered."
                    : "These will be overwritten and cannot be recovered: \(names)"
            )
        case .existingFile:
            lines.append(
                paths.count == 1
                    ? "\(names) is already there and will be replaced."
                    : "These are already there and will be replaced: \(names)"
            )
        }
        if unaffectedCount > 0 {
            lines.append(
                unaffectedCount == 1
                    ? "The other file is unaffected."
                    : "The other \(unaffectedCount) files are unaffected."
            )
        }
        return lines.joined(separator: "\n\n")
    }

    /// Not "Cancel": it does not cancel the drop, it declines these files.
    var skipButtonTitle: String {
        paths.count == 1 ? "Skip This" : "Skip These"
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
