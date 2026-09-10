import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isTargeted = false
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var settings: Settings

    var body: some View {
        VStack(spacing: 0) {
            if let update = model.availableUpdate {
                UpdateBannerView(version: update.version, url: update.url) {
                    model.availableUpdate = nil
                }
            }
            DropZoneView(isTargeted: isTargeted)
            // No divider directly under the band: the "Recent" header's own
            // top hairline (inside ResultsListView) is the only separator,
            // and it appears only once there's history to separate from.
            ResultsListView()
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
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            actions: { Button("OK", role: .cancel) { model.errorMessage = nil } },
            message: { Text(model.errorMessage ?? "") }
        )
        // Only reachable when ContentView itself is on screen — i.e. only
        // when ShrinkEngine initialized and an AppModel exists (see
        // ShrinkerProApp: LaunchFailureView is shown instead of ContentView
        // otherwise). A failed launch has no window worth checking for
        // updates from and no AppModel to report one to, so gating this
        // `.task` on ContentView's own lifetime — rather than adding a
        // separate always-present task at the App level — is deliberate,
        // not an oversight: it keeps "no engine, no update check" implicit
        // in the existing view hierarchy instead of a second nil-check.
        .task {
            guard settings.updateCheck else { return }
            if case let .available(version, url) = await UpdateChecker().check() {
                model.announceUpdate(version: version, url: url)
            }
        }
    }
}

/// Dismissible banner shown above the drop zone when `UpdateChecker` finds a
/// newer GitHub release than the running build. Never appears while
/// `SPRepository` is unconfigured, since `UpdateChecker.check()` then always
/// resolves to `.notConfigured`.
private struct UpdateBannerView: View {
    let version: String
    let url: URL
    let dismiss: () -> Void

    var body: some View {
        HStack {
            Text("Version \(version) is available")
                .font(.caption)
            Spacer()
            Button("View") { NSWorkspace.shared.open(url) }
                .buttonStyle(.link)
                .font(.caption)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.12))
    }
}
