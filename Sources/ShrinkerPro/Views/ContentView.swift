import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isTargeted = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            DropZoneView(isTargeted: isTargeted)
            // No divider directly under the drop zone: the "Recent" header's
            // own top hairline (inside ResultsListView) is the only
            // separator, and it appears only once there's history to
            // separate from.
            ResultsListView()
            // The footer is pinned and the history scrolls above it.
            // ResultsListView has no explicit frame, so it absorbs all the
            // leftover height and everything after it is already anchored to
            // the window's bottom edge — no safeAreaInset needed.
            //
            // This divider, unlike the one above, is unconditional: rows
            // scroll right up to the footer's edge, so without it the last
            // visible row bleeds into the controls.
            Divider()
            WindowFooterView()
        }
        .frame(minWidth: 340, minHeight: 420)
        // Publishes whether there's history to clear up to the Scene, so
        // ShrinkerProApp's "Clear History" menu command (which lives
        // outside this view's own body and so does not otherwise observe
        // `model`) can enable/disable itself via @FocusedValue.
        .focusedSceneValue(\.hasHistory, !model.rows.isEmpty)
        // The settings gear moves to a native toolbar item (a real
        // NSToolbar, not a custom title-bar overlay) — the standard macOS
        // affordance, reachable without going to the menu bar. The "Settings"
        // help text is preserved verbatim on the new button.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
            }
        }
        // The ENTIRE window is a drop target, matching upstream, which bound
        // `document.ondrop` rather than scoping the handler to the dashed
        // rectangle. Dropping onto the results list — or onto empty space
        // below it — works exactly like dropping onto the zone itself. The
        // zone remains the visual affordance and the click-to-pick target.
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            Task {
                let urls = await DropZoneView.resolveURLs(from: providers)
                model.handle(urls: urls)
            }
            return true
        }
        .modifier(ModelAlerts(model: model))
        // Window *presence*, not a one-shot answer on the way out.
        //
        // A batch that goes away mid-question must not be stranded: this app
        // deliberately stays running after its last window closes (see
        // AppDelegate), so nothing else would ever resume that continuation.
        // But `.onDisappear` alone only covered the question already on
        // screen — a batch reaching `ask` afterwards would suspend on a sheet
        // nobody could present, leaving `isProcessing` true and the drop zone
        // spinning. Telling the model whether a window exists at all closes
        // both halves: the pending question is answered here, and later ones
        // are answered immediately in `ask`.
        .onAppear { model.windowAppeared() }
        .onDisappear { model.windowDisappeared() }
    }
}

/// Both of the window's alerts, in one place and — just as importantly — in
/// their own function body.
///
/// Stacked inline on `ContentView.body` alongside the toolbar, the drop
/// handler and the focused-scene value, the two alerts' four closures pushed
/// the whole chain past the type checker's budget: Xcode reported "unable to
/// type-check this expression in reasonable time" on the body. It still
/// compiled, which is precisely why it was worth fixing before it stopped.
/// A `ViewModifier` is solved as its own function body, so neither this nor
/// `ContentView.body` is one giant expression any more.
private struct ModelAlerts: ViewModifier {
    @ObservedObject var model: AppModel

    func body(content: Content) -> some View {
        content
            .alert(
                "Something went wrong",
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.errorMessage = nil } }
                ),
                actions: { Button("OK", role: .cancel) { model.errorMessage = nil } },
                message: { Text(model.errorMessage ?? "") }
            )
            // Beside the error alert deliberately, rather than reaching for a
            // second presentation mechanism: there is one pattern here for
            // "the model wants the window to say something", and this is it.
            .alert(
                model.pendingOverwrite?.title ?? "",
                isPresented: Binding(
                    get: { model.pendingOverwrite != nil },
                    // Dismissing without choosing is Skip: it declines these
                    // files, it does not cancel the drop.
                    set: { if !$0 { model.answerOverwrite(.skip) } }
                ),
                presenting: model.pendingOverwrite,
                actions: { request in
                    Button(request.skipButtonTitle, role: .cancel) { model.answerOverwrite(.skip) }
                    Button("Keep Both") { model.answerOverwrite(.keepBoth) }
                    Button("Replace", role: .destructive) { model.answerOverwrite(.replace) }
                },
                message: { request in Text(request.message) }
            )
    }
}
