import AppKit

/// Handles files opened from Finder ("Open With", drops on the Dock icon, and
/// the Recent Documents menu) — upstream's `app.on('open-file')`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Set by `ShrinkerProApp`'s `.onAppear` exactly once, to whatever the
    /// scene resolved: the real `AppModel` on a normal launch, or `nil` when
    /// `ShrinkEngine` failed to initialize and `LaunchFailureView` is showing
    /// instead. Either assignment flips `isConfigured`, which is how this
    /// delegate tells "model not assigned *yet*" (queue and wait) apart from
    /// "model was assigned, and it's nil" (launch failed — nothing is ever
    /// coming, tell the user rather than swallowing the files).
    var model: AppModel? {
        didSet {
            isConfigured = true
            guard !pending.isEmpty else { return }
            let queued = pending
            pending = []
            if let model {
                model.handle(urls: queued)
            } else {
                presentLaunchFailureAlert(queued.count)
            }
        }
    }
    private var isConfigured = false
    private var pending: [URL] = []

    /// How a confirmed-no-model open is surfaced to the user. A production
    /// `NSAlert().runModal()` would block a test runner indefinitely (no one
    /// is there to dismiss it), so this is a substitutable hook rather than
    /// a hardcoded call — tests inject a recording no-op, the app itself
    /// leaves the default in place.
    var presentLaunchFailureAlert: (_ fileCount: Int) -> Void = { fileCount in
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Shrinker Pro Can't Open \(fileCount == 1 ? "This File" : "These Files")"
        alert.informativeText = "Shrinker Pro failed to start, so it can't compress \(fileCount == 1 ? "the file" : "the files") you opened. Quit and relaunch to try again."
        alert.runModal()
    }

    /// Upstream's `open-file` handler. Also reused directly by
    /// `ShrinkerProApp`'s "Open Recent" submenu (see there) so a click on a
    /// recent-document entry goes through the exact same
    /// launch-failure-aware path as a real Finder open.
    func application(_ application: NSApplication, open urls: [URL]) {
        if let model {
            model.handle(urls: urls)
        } else if isConfigured {
            // The app already finished launching in the failure state (no
            // AppModel exists because ShrinkEngine couldn't initialize).
            // There is no model to hand these URLs to, ever, for this
            // process's lifetime — say so instead of silently dropping
            // the files the user just tried to open.
            presentLaunchFailureAlert(urls.count)
        } else {
            // Launch is still in progress (Finder opened us with a file,
            // or handed us one at launch): `.onAppear` hasn't run yet, so
            // we don't yet know whether the model will exist. Queue; the
            // `model` didSet above flushes this either into `handle(urls:)`
            // or into the same failure alert once launch resolves.
            pending.append(contentsOf: urls)
        }
    }

    /// Upstream keeps the app alive on macOS after the window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Shrinker Pro opens at its declared default size every launch rather
    /// than reopening at whatever size it was last dragged to.
    ///
    /// AppKit persists each window's frame under an "NSWindow Frame …" key in
    /// the app's own defaults domain and restores it before the scene's
    /// `.defaultSize` can apply, so `.defaultSize` alone only ever takes
    /// effect on a first run. Clearing those keys before any window is
    /// created leaves nothing to restore.
    ///
    /// This runs in `willFinishLaunching`, before windows exist — doing it
    /// later would clear the keys only after AppKit had already read them.
    /// Only this app's own frame keys are touched; every other preference is
    /// left alone.
    func applicationWillFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("NSWindow Frame") {
            defaults.removeObject(forKey: key)
        }
    }

    /// The size the main window opens at, every launch.
    /// Width chosen by measurement, not by copying the mock: the redesign's
    /// 616pt artboard is wider than this app needs. At 500pt the longest
    /// realistic filenames — "product-photography-hero-final-v3-retina@2x.min.png"
    /// and a full CleanShot timestamp — both render without truncation, with a
    /// little margin left over. 440pt truncated them; 620pt bought nothing
    /// beyond that except screen. The window is still freely resizable; this is
    /// only where it opens.
    static let defaultWindowSize = NSSize(width: 500, height: 620)

    /// Applies `defaultWindowSize` once the scene's window actually exists.
    ///
    /// `.defaultSize` on the `Window` scene is not enough on its own here:
    /// with `.windowResizability(.contentMinSize)` the content's own ideal
    /// height wins, which is why the window was opening at 365x603 rather
    /// than the declared size. Setting the content size directly on the
    /// NSWindow is unambiguous.
    ///
    /// Hopped to the next run-loop pass because SwiftUI creates the window
    /// after `applicationDidFinishLaunching` returns — reading `NSApp.windows`
    /// synchronously here finds nothing.
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain })
            else { return }
            window.setContentSize(Self.defaultWindowSize)
            window.center()
        }
    }

    /// Staying alive after the last window closes (above) plus replacing
    /// `.newItem` with "Open Files…" (no Cmd+N) means Cmd+W can otherwise
    /// strand the user: a running app, no window, no menu affordance to
    /// get one back. Returning `true` here — the default AppKit takes when
    /// this method isn't implemented at all — tells AppKit to run its
    /// normal reopen behavior (unminiaturize an existing window, or spin up
    /// a fresh one from the `WindowGroup` scene) when the Dock icon is
    /// clicked or the app is reactivated with no visible windows. Verified
    /// interactively (`open -a` on an already-running, windowless instance)
    /// that this does produce a working window rather than assuming it —
    /// see task-12-report.md. Made explicit rather than left to the
    /// undocumented default, since leaving Open Recent to an assumed
    /// default is exactly what broke earlier in this task.
    ///
    /// This applies unchanged to the launch-failure state: reopening then
    /// re-renders whichever branch `ShrinkerProApp`'s `body` currently
    /// resolves to, i.e. `LaunchFailureView` — which explains the problem
    /// and offers Quit, strictly better than no window at all.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        true
    }
}
