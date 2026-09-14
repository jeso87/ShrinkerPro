import Foundation

/// Which kind of file a collision would destroy.
enum OverwriteCategory {
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

    private var names: String {
        paths.map(\.lastPathComponent).joined(separator: ", ")
    }

    var title: String {
        switch category {
        case .original:
            return paths.count == 1 ? "Replace 1 original?" : "Replace \(paths.count) originals?"
        case .existingFile:
            return paths.count == 1 ? "Replace 1 file?" : "Replace \(paths.count) files?"
        }
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
