import Foundation

/// Turns what the user handed over — files, folders, or a mix — into the
/// list of images to actually work on.
///
/// Lives in `Core` because both front ends need it and neither owns it. It
/// began on `AppModel`, where a drop was the only way in; the CLI takes
/// paths the same way and must treat a folder identically, so leaving it
/// there would have meant either reaching into the app layer or writing a
/// second walker that drifts from this one.
///
/// It is also why there is no `--recursive` flag: folders are always
/// searched, exactly as dropping one on the window always has.
enum InputExpander {

    /// Upstream's renderer recurses into dropped directories via
    /// traverseFileTree; mirror that, filtering to supported extensions.
    static func expand(_ urls: [URL]) -> [URL] {
        var files: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }

            // `.skipsPackageDescendants` below only skips packages found
            // *while* enumerating — it has no effect on the enumeration
            // root itself (verified: without this branch, dropping
            // Fake.app directly still yielded
            // Fake.app/Contents/Resources/icon.png). A package dropped
            // directly is therefore short-circuited here and passed
            // through whole, so it reaches the engine as one item and is
            // reported as an unsupported format rather than silently
            // having every PNG inside an app bundle rewritten.
            let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true

            if isDirectory.boolValue && !isPackage {
                // .skipsPackageDescendants: a bundle (.app, .photoslibrary,
                // .rtfd, …) is a directory to FileManager but a single
                // opaque document to the user. Without this, dropping a
                // folder that happens to contain an app writes
                // "icon.min.png" into Foo.app/Contents/Resources/ — which
                // breaks that bundle's code signature — and in in-place
                // mode (no suffix, no subfolder) rewrites the app's real
                // resources instead. Dropping ~/Pictures would likewise
                // descend into a .photoslibrary and rewrite the library's
                // internals. Nobody dropping a folder means "and also
                // rewrite the insides of every app and library in it".
                // Note .skipsPackageDescendants does NOT apply to the
                // enumeration root, so it alone does not stop a package
                // dropped *directly* from being expanded — that case is
                // short-circuited explicitly above, before this enumerator
                // is ever reached.
                //
                // .skipsHiddenFiles: same reasoning for dot-directories
                // (.git, .Trash, caches) — invisible to the user, so
                // silently rewriting files inside them is never what a drop
                // meant.
                let enumerator = FileManager.default.enumerator(
                    at: url, includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
                while let child = enumerator?.nextObject() as? URL {
                    if ShrinkEngine.supportedExtensions.contains(child.pathExtension.lowercased()) {
                        files.append(child)
                    }
                }
            } else {
                files.append(url)
            }
        }
        return files
    }
}
