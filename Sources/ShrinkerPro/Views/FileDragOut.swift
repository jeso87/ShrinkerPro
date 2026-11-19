import AppKit
import SwiftUI

/// Dragging finished files out of the app: into Finder, Mail, Messages, a browser's upload
/// field, anything that takes a file.
///
/// Both windows also take dropped files, and a click that wanders a few points turns into a
/// drag, so each window ignores what it is itself dragging out. Otherwise letting go over the
/// same window would shrink the result again, or add the exports to the batch they came from.
/// Dragging between the two windows is left alone: a result from the main window dropped on
/// Studio is a reasonable thing to want.
enum FileDragOut {
    /// Carried by every row dragged out of the main window, visible to this process only, so
    /// its drop handler can recognise its own results.
    static let markerType = "com.eightseven.shrinkerpro.finished-file"

    /// True while a drag started by `FileDragSourceView` is in flight. That drag reports
    /// when it ends, which SwiftUI's own `onDrag` doesn't, so a flag is safe here.
    @MainActor static var isDraggingExports = false

    /// One finished file, for SwiftUI's `onDrag`.
    static func provider(for url: URL) -> NSItemProvider {
        let provider = NSItemProvider(contentsOf: url) ?? NSItemProvider()
        provider.suggestedName = url.lastPathComponent
        provider.registerDataRepresentation(forTypeIdentifier: markerType, visibility: .ownProcess) { done in
            done(Data(), nil)
            return nil
        }
        return provider
    }

    /// Whether every dropped item is one of the main window's own results.
    static func isOwnResults(_ providers: [NSItemProvider]) -> Bool {
        !providers.isEmpty && providers.allSatisfy { $0.hasItemConformingToTypeIdentifier(markerType) }
    }
}

extension View {
    /// Lets these files be dragged out of the view, all at once. For a view with no click of
    /// its own: the drag source sits over it and takes the mouse.
    func dragsFilesOut(_ urls: [URL], help: String? = nil) -> some View {
        overlay(FileDragSource(urls: urls, help: help))
    }
}

private struct FileDragSource: NSViewRepresentable {
    let urls: [URL]
    let help: String?

    func makeNSView(context: Context) -> FileDragSourceView { FileDragSourceView() }

    func updateNSView(_ view: FileDragSourceView, context: Context) {
        view.urls = urls
        view.toolTip = help
    }
}

/// Starts an AppKit drag of `urls` as file URLs, with each file's icon, fanned a little.
final class FileDragSourceView: NSView, NSDraggingSource {
    var urls: [URL] = []

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        let files = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)
        let items = files.enumerated().map { offset, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            let fan = CGFloat(min(offset, 4)) * 4
            item.setDraggingFrame(NSRect(x: point.x - 16 + fan, y: point.y - 16 - fan, width: 32, height: 32),
                                  contents: icon)
            return item
        }
        FileDragOut.isDraggingExports = true
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        FileDragOut.isDraggingExports = false
    }
}
