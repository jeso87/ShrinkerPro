import Foundation

/// Whether a given combination of output settings genuinely replaces the
/// user's own files.
///
/// Factored out of `SettingsView` for the same reason
/// `NotificationPermission.showsDeniedNotice(toggleIsOn:)` is: this project
/// carries no view-tree testing dependency, so a condition left inline in a
/// `body` is logic no test can reach — and this one decides whether a
/// destructive-action warning appears at all.
///
/// It now defers to `OutputNaming.style` for the half of the question that
/// is about *where* the file lands. That type mirrors
/// `OutputPathResolver.destination` and is documented against it; keeping a
/// second copy of the same three conditions here is how the warning and the
/// radio labels above it would eventually come to disagree about which
/// combinations are dangerous.
enum OutputWarning {

    static func replacesOriginals(
        keepOriginal: Bool,
        saveInSameFolder: Bool,
        savePath: URL?,
        useSubfolder: Bool
    ) -> Bool {
        // `.min` alone guarantees a different name.
        guard !keepOriginal else { return false }

        // Everything else — the subfolder, and a redirect that has somewhere
        // to redirect to — is a question about the destination directory,
        // which is `OutputNaming`'s to answer.
        return OutputNaming.style(
            saveInSameFolder: saveInSameFolder,
            savePath: savePath,
            useSubfolder: useSubfolder
        ) == .besideOriginals
    }
}
