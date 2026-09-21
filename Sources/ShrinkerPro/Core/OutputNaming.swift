import Foundation

/// How the Output section's second radio pair should describe itself.
///
/// That pair binds `Settings.keepOriginal`, and `keepOriginal` does exactly
/// one thing in the engine: it appends `.min` to the stem
/// (`OutputPathResolver.swift:107`). It does *not* decide whether the user
/// still has their file afterwards — the directory decides that. When the
/// output lands in the original's own folder, the suffix is the only thing
/// standing between the two, and "Keep originals / Replace originals" is
/// exactly right. Send the output to a chosen folder or a `minified/`
/// subfolder and the original is untouchable either way; the same radio is
/// then choosing a filename and nothing more, and must say so.
///
/// `2026-09-14-suffix-settings-and-overwrite-warning.md` §2 worked out this
/// table for the *warning* and left the labels alone, which is why the panel
/// could offer "Replace originals" for a combination that replaces nothing.
/// `OutputWarning.replacesOriginals` is now expressed in terms of this type
/// so the label and the warning read one table rather than two.
///
/// A pure type, in `Core` rather than inline in `SettingsView`, for the
/// reason given on `OutputWarning` and `NotificationPermission`: this
/// project carries no view-tree testing dependency, so a condition left in a
/// `body` is logic no test can reach.
///
/// The CLI has never had this problem — `--in-place` and `--out` are refused
/// together (`CommandLineOptions.swift:616-626`), so the incoherent
/// combination cannot be expressed there at all.
enum OutputNaming: Equatable {

    /// The shrunken file lands in the original's own folder, so the suffix
    /// decides whether the original survives.
    case besideOriginals

    /// The shrunken file lands somewhere else — a chosen folder, or
    /// `minified/` — so the suffix only decides what it is called.
    case separateDestination

    /// Mirrors `OutputPathResolver.destination`, which is the only reason
    /// this can be trusted: it appends `minified/` when asked, and redirects
    /// *only when a save path actually exists*. "Choose folder…" selected
    /// with nothing chosen yet still writes beside the originals, and the
    /// labels have to keep saying so until a folder is picked.
    ///
    /// Deliberately does not take `keepOriginal`. These labels describe what
    /// each choice would do, so deriving them from the choice already made
    /// would let a radio rewrite its own label the moment it was clicked.
    static func style(
        saveInSameFolder: Bool,
        savePath: URL?,
        useSubfolder: Bool
    ) -> OutputNaming {
        if useSubfolder { return .separateDestination }
        if !saveInSameFolder, savePath != nil { return .separateDestination }
        return .besideOriginals
    }

    /// The picker's own label — the left-hand column of the row.
    var rowLabel: String {
        switch self {
        case .besideOriginals: return String(localized: "Files",
                                             comment: "Settings row label when outputs land beside the originals, so the choice is about the files themselves.")
        case .separateDestination: return String(localized: "Filenames",
                                                 comment: "Settings row label when outputs land in a separate folder, so the choice is only about naming.")
        }
    }

    /// Title for `keepOriginal == true`.
    var suffixOnTitle: String {
        switch self {
        case .besideOriginals: return String(localized: "Keep originals, save a .min copy",
                                             comment: "Output option: write alongside the original and leave it in place. '.min' is a filename suffix and stays as-is.")
        case .separateDestination: return String(localized: "Add .min",
                                                 comment: "Output option: add the '.min' suffix to the written filename. '.min' stays as-is.")
        }
    }

    /// Title for `keepOriginal == false`.
    var suffixOffTitle: String {
        switch self {
        case .besideOriginals: return String(localized: "Replace originals",
                                             comment: "Output option: overwrite the original file in place.")
        case .separateDestination: return String(localized: "Leave as is",
                                                 comment: "Output option: write the file under its original name, with no suffix added.")
        }
    }

    /// A worked example of the resulting filename, or `nil` where the titles
    /// already carry the consequence and an example would only dilute it.
    var suffixOnExample: String? {
        switch self {
        case .besideOriginals: return nil
        case .separateDestination: return "photo.min.png"
        }
    }

    /// See `suffixOnExample`.
    var suffixOffExample: String? {
        switch self {
        case .besideOriginals: return nil
        case .separateDestination: return "photo.png"
        }
    }
}
