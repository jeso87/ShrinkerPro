import SwiftUI
import AppKit

/// Where File ▸ Open Files… sends what it opens, when the window in front takes
/// files of its own. Shrinker Studio's window publishes one (`.focusedSceneValue`), so opening
/// from the menu while it is in front does what a drop on it does, instead of shrinking the
/// files in the main window. With no window publishing one, the menu feeds the main window as
/// it always has.
struct FileOpenDestination {
    let open: ([URL]) -> Void
}

private struct FileOpenDestinationKey: FocusedValueKey {
    typealias Value = FileOpenDestination
}

extension FocusedValues {
    var fileOpenDestination: FileOpenDestination? {
        get { self[FileOpenDestinationKey.self] }
        set { self[FileOpenDestinationKey.self] = newValue }
    }
}

/// File ▸ Open Files… (⌘O). There is no Open Recent: the app shrinks files rather than editing
/// documents, so reopening one has nothing to come back to, and a shrink no longer adds to the
/// recent list (removed in 1.8.2).
///
/// A `Commands` struct of its own, not `@FocusedValue` on the App, for the reason
/// `ClearHistoryCommands` gives: only here does the focused value re-invalidate the menu as
/// the front window changes.
struct OpenFilesCommands: Commands {
    /// False in the launch-failure state, when there is no model to open into.
    let canOpenInMain: Bool
    let openInMain: ([URL]) -> Void

    @FocusedValue(\.fileOpenDestination) private var destination

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Files…") {
                guard let urls = Self.chooseFiles() else { return }
                Self.route(urls, to: destination, otherwise: openInMain)
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(destination == nil && !canOpenInMain)
        }
    }

    /// The front window's destination when it has one, otherwise the main window's.
    static func route(_ urls: [URL], to destination: FileOpenDestination?, otherwise: ([URL]) -> Void) {
        guard !urls.isEmpty else { return }
        if let destination { destination.open(urls) } else { otherwise(urls) }
    }

    /// The open panel, over every format the engine reads, folders included.
    @MainActor private static func chooseFiles() -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = ShrinkEngine.supportedContentTypes
        return panel.runModal() == .OK ? panel.urls : nil
    }
}
