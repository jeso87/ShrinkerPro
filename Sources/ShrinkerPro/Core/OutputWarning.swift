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
/// It mirrors `OutputPathResolver.destination`, which is the only reason it
/// can be trusted: the resolver redirects only when a save path actually
/// exists, appends `minified/` when asked, and appends `.min` when originals
/// are kept. Any of those three moves the output off the input's path.
enum OutputWarning {

    static func replacesOriginals(
        keepOriginal: Bool,
        saveInSameFolder: Bool,
        savePath: URL?,
        useSubfolder: Bool
    ) -> Bool {
        // `.min` alone guarantees a different name.
        if keepOriginal { return false }
        // minified/ is a different directory.
        if useSubfolder { return false }
        // A redirect only happens when there is somewhere to redirect to.
        if !saveInSameFolder, savePath != nil { return false }
        return true
    }
}
