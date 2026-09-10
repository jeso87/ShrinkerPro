import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Whether there's any results history to clear, published up from
/// ContentView (`.focusedSceneValue`) so the "Clear History" command below
/// — declared at the App/Scene level, outside ContentView's own body and
/// so not otherwise observing `AppModel` — can enable/disable itself.
private struct HasHistoryFocusedValueKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var hasHistory: Bool? {
        get { self[HasHistoryFocusedValueKey.self] }
        set { self[HasHistoryFocusedValueKey.self] = newValue }
    }
}

@main
struct ShrinkerProApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: Settings
    @State private var model: AppModel?
    @State private var launchError: String?
    // Constructed unconditionally, independent of whether ShrinkEngine
    // initializes below: like Settings, updating has no dependency on the
    // engine, so "Check for Updates…" stays functional even in the
    // launch-failure state — arguably more useful there, since it's exactly
    // how a user on a broken install would get to a fixed release.
    @State private var appUpdater: AppUpdater

    init() {
        let settings = Settings()
        _settings = StateObject(wrappedValue: settings)
        _appUpdater = State(wrappedValue: AppUpdater(settings: settings))

        // ShrinkEngine.init can throw ShrinkError.helperMissing when
        // svgo.jsc.js is missing from the bundle — a damaged or
        // incompletely-built install. `try!` would turn that into a crash
        // on launch with no explanation, which is the worst possible
        // presentation of a diagnosable problem. Instead, capture the
        // error and let the Scene body render a window that explains what
        // is wrong (ShrinkError already carries good, actionable text) —
        // a window that explains beats a bounce in the Dock.
        do {
            let engine = try ShrinkEngine()
            _model = State(wrappedValue: AppModel(engine: engine, settings: settings, notifier: Notifier()))
            _launchError = State(wrappedValue: nil)
        } catch {
            _model = State(wrappedValue: nil)
            _launchError = State(wrappedValue: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    var body: some Scene {
        // `Window`, not `WindowGroup`: Shrinker Pro is a single-window app.
        //
        // A WindowGroup treats every Finder open — and every `open -a` — as a
        // request for a NEW window, so dropping three files onto the app icon
        // produced four cascaded windows, all backed by the same AppModel and
        // therefore all showing identical results. Functionally harmless,
        // visually broken, and not what upstream did. `Window` declares a
        // single unique scene, so opens are routed to the one window that
        // already exists (via AppDelegate.application(_:open:)) instead of
        // spawning siblings.
        Window("Shrinker Pro", id: "main") {
            Group {
                if let model {
                    ContentView()
                        .environmentObject(model)
                        .environmentObject(settings)
                } else {
                    LaunchFailureView(message: launchError ?? "Shrinker Pro couldn't start.")
                }
            }
            // Fires once the scene has resolved which branch above is
            // showing — i.e. once we know, for this launch, whether an
            // AppModel exists at all. Handing that resolved value
            // (possibly nil) to appDelegate is what lets it distinguish
            // "not configured yet" from "confirmed no model coming"; see
            // AppDelegate.swift.
            .onAppear { appDelegate.model = model }
            // The only place settings.updateCheck ever changes is the
            // "Check for updates" toggle in SettingsView, so observing it
            // here (rather than a Combine subscription held for the app's
            // whole lifetime) is sufficient to keep Sparkle's background
            // polling live-synced with it, with no ObjC-KVO/Sendable-closure
            // concerns to work around.
            .onChange(of: settings.updateCheck) { _, newValue in
                appUpdater.setAutomaticChecksEnabled(newValue)
            }
        }
        .defaultSize(width: 500, height: 620)
        .windowResizability(.contentMinSize)
        .commands {
            // Replaces the stock About panel so the credits name the author
            // and the upstream project this is a rewrite of. The standard
            // panel would otherwise show only the bundle name and version.
            CommandGroup(replacing: .appInfo) {
                Button("About Shrinker Pro") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .credits: ShrinkerProApp.aboutCredits()
                    ])
                }
            }

            // Sparkle's conventional placement: directly below About, above
            // Settings/Preferences.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { appUpdater.checkForUpdates() }
            }

            CommandGroup(replacing: .newItem) {
                Button("Open Files…") { openPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(model == nil)

                // A manually-built AppKit "Open Recent" NSMenuItem, inserted
                // straight into NSApp.mainMenu (e.g. from AppDelegate), does
                // not survive here: verified empirically that SwiftUI
                // resyncs this File NSMenu against its own Commands-derived
                // structure a couple of seconds after launch and strips
                // anything it didn't itself put there. Declaring the menu
                // through Commands' own `Menu` support instead means SwiftUI
                // owns it and won't fight itself. `Menu`'s content closure
                // is re-evaluated by AppKit each time the submenu is about
                // to open, so this reads NSDocumentController's recent list
                // fresh on every click — no manual refresh plumbing needed.
                // Clicks route through `appDelegate.application(_:open:)`,
                // the same entry point Finder uses, so a recent-document
                // click during the launch-failure state surfaces the same
                // "can't open" alert rather than silently doing nothing.
                Menu("Open Recent") {
                    let recents = NSDocumentController.shared.recentDocumentURLs
                    if recents.isEmpty {
                        Text("No Recent Files")
                    } else {
                        ForEach(recents, id: \.self) { url in
                            Button(url.lastPathComponent) {
                                appDelegate.application(NSApp, open: [url])
                            }
                        }
                        Divider()
                        Button("Clear Menu") {
                            NSDocumentController.shared.clearRecentDocuments(nil)
                        }
                    }
                }
            }

            // Explicit user action to empty the results history — distinct
            // from the `clearList` *setting*, which is an automatic policy
            // that wipes the list at the start of each new batch. Reads
            // `hasHistory` (from ContentView's `.focusedSceneValue`) via
            // its own `Commands`-conforming struct rather than a
            // `@FocusedValue` property directly on `ShrinkerProApp`:
            // verified empirically that the latter does not re-invalidate
            // this command's `.disabled()` as `hasHistory` changes at
            // runtime — the item stayed permanently disabled from its
            // launch-time value. A dedicated `Commands` struct, the
            // pattern Apple's own FocusedValue sample code uses, tracks
            // it correctly.
            ClearHistoryCommands(clearHistory: { model?.clearHistory() })
        }

        // Kept available even when the engine failed to initialize
        // (`model == nil`, LaunchFailureView showing): these preferences
        // (notifications, save location, suffix, subfolder, update
        // checks) are plain UserDefaults-backed values with no
        // dependency on ShrinkEngine, so there is nothing engine-related
        // for the user to be locked out of. Cmd+, being reliably
        // available is more useful — e.g. a user reinstalling to fix a
        // missing helper can still confirm/adjust their save-location
        // preference — than hiding it would be protective.
        SwiftUI.Settings {
            SettingsView().environmentObject(settings)
        }
    }

    static let websiteURL = URL(string: "https://shrinkerpro.app")!

    /// The body of the About panel.
    ///
    /// Built as an attributed string rather than a plain one so the site
    /// is a real clickable link — `orderFrontStandardAboutPanel` renders
    /// `.link` attributes in the credits, and a bare URL printed as text
    /// gives the reader nothing to click.
    ///
    /// What this deliberately does *not* contain is a copyright line.
    /// That belongs to `NSHumanReadableCopyright`, which the panel already
    /// renders in bold underneath; putting it here as well is what
    /// produced the duplicated "Made by Joshua Omilian. Based on Image
    /// Shrinker…" paragraph sitting directly below its own restatement.
    static func aboutCredits() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 8

        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]

        let credits = NSMutableAttributedString()
        credits.append(NSAttributedString(string: "Made by Joshua Omilian\n", attributes: base))

        var link = base
        link[.link] = websiteURL
        link[.foregroundColor] = NSColor.linkColor
        credits.append(NSAttributedString(string: "shrinkerpro.app", attributes: link))

        // Paragraph breaks come from `paragraphSpacing`, not from blank
        // lines. The panel's credits area is a fixed-height scroll view
        // that does not grow with its content: an earlier draft used
        // explicit blank lines as well and the final line was clipped
        // mid-sentence, below the fold, with nothing to indicate it was
        // there.
        credits.append(NSAttributedString(
            string: """
                \nA native Apple Silicon rewrite of Image Shrinker \
                by Stefan Schulz-Lauterbach (CC0-1.0).
                Compression by mozjpeg, pngquant, gifsicle, cwebp and SVGO.
                """,
            attributes: base
        ))
        return credits
    }

    private func openPanel() {
        guard let model else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = ShrinkEngine.supportedContentTypes
        if panel.runModal() == .OK { model.handle(urls: panel.urls) }
    }
}

/// A dedicated `Commands` struct — rather than a `@FocusedValue` property
/// declared directly on `ShrinkerProApp` — so `hasHistory` changes actually
/// re-invalidate this command's `.disabled()` at runtime. See the call site
/// in `ShrinkerProApp.body` for why the more obvious approach didn't work.
private struct ClearHistoryCommands: Commands {
    let clearHistory: () -> Void
    @FocusedValue(\.hasHistory) private var hasHistory

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Clear History", action: clearHistory)
                .keyboardShortcut(.delete, modifiers: .command)
                // `hasHistory` is `nil` — treated as false — whenever no
                // window is publishing it, e.g. the launch-failure state.
                .disabled(!(hasHistory ?? false))
        }
    }
}

/// Shown in place of the main window when `ShrinkEngine` failed to
/// initialize (e.g. a missing bundled `svgo.jsc.js`). The same
/// `ShrinkError.helperMissing` case can also surface later from
/// `shrink()` itself when a compressor binary is missing from
/// `Contents/Helpers/` — both mean a damaged or incompletely-built
/// install, and both deserve a clear, actionable message rather than a
/// silent crash or a window where every drop mysteriously fails.
private struct LaunchFailureView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.orange)
            Text("Shrinker Pro can't start")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .padding(.top, 4)
        }
        .padding(32)
        .frame(minWidth: 340, minHeight: 420)
    }
}
