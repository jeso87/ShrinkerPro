import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isTargeted = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            DropZoneView(isTargeted: isTargeted)
                // Clicking anywhere above the bar closes its panel, the third
                // of the three ways out (Done and Escape are the others).
                // Applied to the content rather than as a full-window overlay
                // so it never sits between the window and its drop handler.
                .simultaneousGesture(dismissPanelGesture)
            // No divider directly under the drop zone: the "Recent" header's
            // own top hairline (inside ResultsListView) is the only
            // separator, and it appears only once there's history to
            // separate from.
            ResultsListView()
                .simultaneousGesture(dismissPanelGesture)
            // The footer is pinned and the history scrolls above it.
            // ResultsListView has no explicit frame, so it absorbs all the
            // leftover height and everything after it is already anchored to
            // the window's bottom edge — no safeAreaInset needed.
            //
            // No `Divider()` here any more: the session bar draws its own
            // 0.5pt top hairline *inside* itself, so the separation survives
            // the panel expanding without the divider moving or the bar
            // gaining height it did not ask for.
            SessionBarView()
                // The bar stays visible but inert while a drag is over the
                // window — the drop is the thing being aimed at, and a menu
                // opening under the pointer mid-drag would be nobody's
                // intention. `allowsHitTesting` rather than `.disabled`,
                // which would grey the controls out for the length of a
                // hover.
                .allowsHitTesting(!isTargeted)
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

    /// Closes the session panel on a click outside it. A
    /// `simultaneousGesture` rather than `onTapGesture`, so it never consumes
    /// a click the results list or the drop zone wanted for themselves.
    private var dismissPanelGesture: some Gesture {
        TapGesture().onEnded {
            guard model.isSessionPanelExpanded else { return }
            withAnimation(.easeOut(duration: 0.22)) { model.isSessionPanelExpanded = false }
        }
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
