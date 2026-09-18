import SwiftUI
import AppKit

/// How tall the Settings window is allowed to get.
///
/// This exists because it once had no answer. `SettingsView`'s `Form` carried
/// `.fixedSize(horizontal: false, vertical: true)`, which pins a view to its
/// full intrinsic height — and a grouped `Form` on macOS is otherwise a
/// scrollable list. Pinned, it never compressed and never scrolled, so the
/// window grew to whatever its five sections added up to (roughly 850pt) and
/// on a 13" display the bottom of it went off the screen with no way to
/// reach it.
///
/// The bound is **measured, not chosen**. A constant would be the same defect
/// wearing a different number: the window was too tall for a screen nobody
/// had measured, so the fix has to ask the screen. `SettingsView` reads
/// `NSScreen.visibleFrame` — which already excludes the menu bar and the Dock
/// — and hands the height here.
///
/// Pure, and out of the `body`, for the reason `MaxSizeField`,
/// `SessionBarState`, `OutputNaming` and `OutputWarning` are: this project
/// carries no view-tree testing dependency, so a rule left inline in a view
/// is a rule no test can reach. See `SettingsWindowMetricsTests`.
enum SettingsWindowMetrics {

    /// Room for the title bar and the window's own frame, plus a little air so
    /// the window is not shoved flush against the Dock or the menu bar.
    /// Measured at 28 points of title bar; the rest is that margin.
    ///
    /// Erring high costs a strip of unused height. Erring low puts the bottom
    /// of the window back off the screen, which is the whole defect, so this
    /// leans high on purpose.
    static let chromeAllowance: CGFloat = 60

    /// Below this a Settings window stops being usable — too short to show a
    /// section header and a control together, so scrolling it would be all
    /// the user ever did.
    static let minimumContentHeight: CGFloat = 320

    /// The tallest the `Form` may be on a screen with `visible` points of
    /// usable height.
    ///
    /// The outer `min` is what keeps `minimumContentHeight` a floor rather
    /// than an override: on a display shorter than the floor itself, honouring
    /// the floor would hand back a window taller than the screen and
    /// reintroduce exactly the defect above. The screen always wins.
    ///
    /// A non-positive reading — `NSScreen` reporting nothing mid-reconfiguration,
    /// or no main screen at all — falls back to the floor rather than to zero,
    /// because a window with no height is worse than one that has to scroll.
    static func maxContentHeight(forVisibleHeight visible: CGFloat) -> CGFloat {
        guard visible > 0 else { return minimumContentHeight }
        return min(visible, max(minimumContentHeight, visible - chromeAllowance))
    }

    /// How much has to be hidden before the window bothers saying so.
    ///
    /// `SettingsView.contentHeight` is a measurement, not a guarantee — it can
    /// be a few points out from what the `Form` actually lays out, and it will
    /// drift the first time a row changes. Without this tolerance a display
    /// that misses by ten points would draw a fade and a chevron over a pane
    /// that is, to the eye, entirely visible. Observed exactly that way on a
    /// display with 1050 points of usable height.
    ///
    /// The cost is a narrow band — less than one row — where something is
    /// clipped and nothing announces it. That is the better failure: a
    /// chevron pointing at nothing teaches people to ignore chevrons.
    static let scrollAffordanceThreshold: CGFloat = 24

    /// Whether enough of `content` is hidden on a screen with `visible` points
    /// of usable height to be worth telling the user about.
    ///
    /// Drives the fade and chevron at the bottom of the window, and is its own
    /// function so they appear on exactly the displays that need them. A
    /// permanent affordance would be a lie on a large monitor, where nothing
    /// is hidden and there is nothing to scroll to.
    static func contentScrolls(contentHeight content: CGFloat, visibleHeight visible: CGFloat) -> Bool {
        content - maxContentHeight(forVisibleHeight: visible) > scrollAffordanceThreshold
    }
}

struct SettingsView: View {
    @EnvironmentObject private var settings: Settings

    /// How tall the five sections come to, measured from the build that still
    /// pinned them: a 1027 point window, less 28 points of title bar.
    ///
    /// A constant here, unlike the screen bound below, and the difference is
    /// who owns the number. The display belongs to the user, and guessing it
    /// is the defect being fixed. This describes our own five sections, which
    /// nobody can change without editing the `Form` a few lines down — and if
    /// it ever goes stale the window simply scrolls a little sooner or shows a
    /// little slack, rather than losing anything.
    private static let contentHeight: CGFloat = 1000

    /// The usable height of the display this window is **actually on**,
    /// reported by `SettingsWindowScreen` below and updated whenever the
    /// window moves or the screens are reconfigured.
    ///
    /// It was `NSScreen.main?.visibleFrame.height`, read inline, and that was
    /// wrong twice over. `NSScreen.main` is the screen with keyboard focus,
    /// not the screen this window is on — measured on a four-display setup it
    /// reported 1804pt while the window sat somewhere else entirely — and it
    /// is a plain global, so SwiftUI had no reason to re-evaluate the body
    /// when a display's resolution changed. The window kept whatever height it
    /// had been given at launch.
    @State private var visibleHeight: CGFloat = SettingsWindowScreen.conservativeHeight()

    private var maxContentHeight: CGFloat {
        SettingsWindowMetrics.maxContentHeight(forVisibleHeight: visibleHeight)
    }

    /// Whether this display is too short to show every setting at once.
    private var isScrollable: Bool {
        SettingsWindowMetrics.contentScrolls(
            contentHeight: Self.contentHeight, visibleHeight: visibleHeight
        )
    }

    /// Starts as `.notDetermined` (which renders nothing) and is replaced
    /// with the real answer by the `.task` below, so the warning can never
    /// flash on screen before the system has been asked.
    @State private var notificationPermission: NotificationPermission = .notDetermined

    /// Whether the Files/Filenames radio pair is choosing between keeping
    /// and replacing the user's own files, or merely naming a copy that
    /// lands somewhere else. Recomputed from the two rows above it, so
    /// switching on the subfolder relabels it immediately.
    private var naming: OutputNaming {
        OutputNaming.style(
            saveInSameFolder: settings.saveInSameFolder,
            savePath: settings.savePath,
            useSubfolder: settings.useSubfolder
        )
    }

    /// One radio's label: the choice, and — where the choice is only about a
    /// filename — the filename it produces, in secondary text so the option
    /// still reads as one short phrase. Concatenated `Text` rather than an
    /// `HStack` because `.radioGroup` lays out its options itself.
    private func optionLabel(_ title: String, example: String?) -> Text {
        guard let example else { return Text(title) }
        return Text(title) + Text("  —  \(example)").foregroundStyle(.secondary)
    }

    var body: some View {
        Form {
            Section {
                Picker("Where", selection: $settings.saveInSameFolder) {
                    Text("Same folder as original").tag(true)
                    Text("Choose folder…").tag(false)
                }
                .pickerStyle(.radioGroup)

                if !settings.saveInSameFolder {
                    HStack {
                        Text(settings.savePath?.path ?? "No folder chosen")
                            .font(.caption)
                            .foregroundStyle(settings.savePath == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer()
                        Button("Choose…", action: chooseFolder)
                    }
                }

                Toggle("Put them in a \"minified\" subfolder", isOn: $settings.useSubfolder)

                // A radio pair, not a checkbox: the defect being fixed is a
                // switch whose off-state you had to infer. Both branches now
                // state their own consequence. The binding and its "suffix"
                // key are unchanged — this is presentation only.
                //
                // Which consequence they state depends on where the output
                // lands, because `keepOriginal` only appends `.min`; the
                // rows above decide whether an original is in the firing
                // line at all. See `OutputNaming`, which owns that table and
                // is what `OutputWarning` below reads too.
                Picker(naming.rowLabel, selection: $settings.keepOriginal) {
                    optionLabel(naming.suffixOnTitle, example: naming.suffixOnExample)
                        .tag(true)
                    optionLabel(naming.suffixOffTitle, example: naming.suffixOffExample)
                        .tag(false)
                }
                .pickerStyle(.radioGroup)

                Toggle("Warn before replacing a file", isOn: $settings.warnBeforeOverwrite)

                // Only when the current combination genuinely puts originals
                // at risk. The old caption asserted this unconditionally and
                // was wrong in three of four combinations — see OutputWarning.
                if OutputWarning.replacesOriginals(
                    keepOriginal: settings.keepOriginal,
                    saveInSameFolder: settings.saveInSameFolder,
                    savePath: settings.savePath,
                    useSubfolder: settings.useSubfolder
                ) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Your originals will be overwritten and cannot be recovered. Converted files keep a separate extension, so those originals are left alone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("Output")
            }
            // A separate Section (not folded into either toggle group above)
            // so the five rules read as one group of related controls, per
            // the spec, rather than being mixed in with unrelated toggles.
            Section {
                ConversionRuleRow(rowLabel: "PNG", ownFormatName: "PNG", selection: $settings.pngConversion)
                ConversionRuleRow(rowLabel: "JPEG", ownFormatName: "JPEG", selection: $settings.jpegConversion)
                HEICConversionRuleRow(rowLabel: "HEIC / HEIF", selection: $settings.heicConversion)
                ConversionRuleRow(rowLabel: "WebP", ownFormatName: "WebP", selection: $settings.webpConversion)
                ConversionRuleRow(rowLabel: "AVIF", ownFormatName: "AVIF", selection: $settings.avifConversion)
            } header: {
                Text("Conversion")
            } footer: {
                // Required copy (spec): SVG and GIF have no row above, and
                // their absence needs explaining, not leaving the user to
                // wonder whether it's an oversight. Must name both formats
                // and give the reason for each — "some formats are
                // excluded" is not actionable.
                Text("SVG and GIF files are always optimised in their own format. SVG is vector, and GIF is usually animated — converting either would lose what makes it useful.")
            }
            // Its own Section, placed directly after the conversion rules:
            // quality governs the encoders those rules select, but it also
            // applies to same-format compression, so folding it into the
            // Conversion group would understate its reach.
            Section {
                Picker("Encode at", selection: $settings.quality) {
                    ForEach(QualityLevel.allCases, id: \.self) { level in
                        Text(level.displayName).tag(level)
                    }
                }
            } header: {
                Text("Quality")
            } footer: {
                // Naming the excluded formats for the same reason the
                // Conversion footer names SVG and GIF: an exemption the user
                // can't see is one they'll take for a bug. Deliberately does
                // NOT claim PNG is lossless — pngquant quantises to a 256
                // colour palette, so it very much isn't; it simply has no
                // comparable quality dial, and neither does gifsicle's -O2.
                // Says "every session starts at" rather than simply "the
                // quality" because the window's session bar can now sit on
                // top of this without writing back to it — a user who
                // changes quality there and then finds this row unmoved
                // needs the two to explain each other.
                Text("Applies to JPEG, WebP, AVIF and HEIC. PNG and GIF are optimised by tools with no comparable setting, so they look the same whichever you choose. Standard matches what earlier versions of Shrinker Pro produced. Every session starts here; the window's session bar can change it for one session without changing this.")
            }
            Section {
                Picker("When shrinking, keep", selection: $settings.metadataPolicy) {
                    ForEach(MetadataPolicy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
            } header: {
                Text("Metadata")
            } footer: {
                // Rotation is stated here because it is the one thing this
                // setting does NOT control, and a user who has just been
                // offered "No metadata" has every reason to assume turning
                // it on would leave their photos sideways again. It is also
                // the fix for the bug that prompted the setting, so saying
                // it plainly is worth the line.
                Text("Rotation is always applied to the image itself, so photos stay upright in any app whichever option you choose.")
            }
            Section {
                Toggle("Enable notifications", isOn: $settings.notification)
                if notificationPermission.showsDeniedNotice(toggleIsOn: settings.notification) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Notifications are turned off for Shrinker Pro in System Settings, so none will appear.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Open Notification Settings…") {
                                NSWorkspace.shared.open(NotificationPermission.systemSettingsURL)
                            }
                            .controlSize(.small)
                        }
                    }
                }
                Toggle("Clear result list when shrinking new images", isOn: $settings.clearList)
            } header: {
                Text("General")
            }
        }
        .formStyle(.grouped)
        // The scroll bar is asked for explicitly rather than left to the
        // system's "show on scrolling" default. The window is taller than it
        // can show on most displays, so whether there is more below is the
        // first thing someone needs to know — and a scroll bar that only
        // appears once you have already scrolled cannot tell them.
        .scrollIndicators(.visible)
        // `fixedSize(horizontal: false, vertical: true)` used to stand here,
        // and it was the bug. It pins a view to its intrinsic height, and a
        // grouped `Form` is otherwise a scrollable list — pinned, it could
        // only overflow, so on any display shorter than about 1030 points the
        // bottom of this window went off the screen with no way to reach it.
        //
        // Given a height instead, the `Form` fills it and scrolls. The height
        // is the content's own where the screen allows it, and the screen's
        // where it does not.
        .frame(
            width: 420,
            height: min(Self.contentHeight, maxContentHeight)
        )
        // Something has to say "there is more below", because macOS will not.
        // `scrollIndicators(.visible)` above asks for a scroll bar, but
        // AppKit's overlay scrollers still fade out when idle unless the user
        // has set Appearance ▸ Show scroll bars to Always — verified here, on
        // a clamped window that showed no indicator at all. So the window says
        // it itself.
        //
        // Only when there is genuinely something below: on a display tall
        // enough to show all of it, a fade would be claiming hidden content
        // that does not exist.
        .overlay(alignment: .bottom) {
            if isScrollable {
                ZStack(alignment: .bottom) {
                    LinearGradient(
                        colors: [
                            Color(nsColor: .windowBackgroundColor).opacity(0),
                            Color(nsColor: .windowBackgroundColor),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    // A fade alone is the conventional cue and was tried
                    // first. It is nearly invisible here, because it fades to
                    // the very colour it sits on — so it gets a glyph.
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 6)
                }
                .frame(height: 44)
                // Decoration. Clicks belong to whatever row is underneath it.
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .background(SettingsWindowScreen(visibleHeight: $visibleHeight))
        .task { notificationPermission = await .current() }
        // Re-check when the app is brought back to the front: the whole
        // point of the button above is that the user leaves for System
        // Settings and changes the answer, and the warning has to
        // disappear when they come back without needing a relaunch.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { notificationPermission = await .current() }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { settings.savePath = panel.url }
    }
}

/// Reports the usable height of the display the Settings window is on, and
/// keeps reporting it as that changes.
///
/// A zero-sized `NSView` in the window's background, because this is a
/// question only AppKit can answer: SwiftUI has no notion of which screen a
/// window landed on, and `NSScreen.main` answers a different question — which
/// screen has keyboard focus. On a multi-display setup those are routinely
/// different, and a window sized against the wrong one is exactly the defect
/// this whole bound exists to prevent.
///
/// Two notifications keep it honest. `didChangeScreenParameters` fires when a
/// display is added, removed, or has its resolution changed — the case that
/// reported this bug. `NSWindow.didMoveNotification` fires when the window is
/// dragged between displays, which changes the answer without changing
/// anything about the screens themselves.
private struct SettingsWindowScreen: NSViewRepresentable {
    @Binding var visibleHeight: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = ReporterView()
        view.onChange = { height in
            // Assigned asynchronously: this fires during layout, and writing
            // to SwiftUI state inside a layout pass is what produces
            // "Modifying state during view update".
            DispatchQueue.main.async {
                if visibleHeight != height { visibleHeight = height }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ReporterView)?.report()
    }

    final class ReporterView: NSView {
        var onChange: ((CGFloat) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard window != nil else { return }

            let centre = NotificationCenter.default
            for name in [
                NSApplication.didChangeScreenParametersNotification,
                NSWindow.didMoveNotification,
            ] {
                observers.append(
                    centre.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                        self?.report()
                    }
                )
            }
            report()
        }

        // No `deinit` cleanup: `viewDidMoveToWindow` fires again with a nil
        // window when the view is removed, and unsubscribes there. Swift 6
        // will not let a nonisolated deinit touch the token array anyway, and
        // reaching for an unchecked box to get around that would be papering
        // over a lifetime AppKit already tells us about.
        func report() {
            // `window.screen` is the display the window is actually on. It is
            // nil while the window is being placed, which is what the
            // conservative fallback is for: too short for a moment is
            // recoverable, too tall is the bug.
            let height = window?.screen?.visibleFrame.height
                ?? SettingsWindowScreen.conservativeHeight()
            onChange?(height)
        }
    }

    /// The shortest display attached, used until the window says which one it
    /// is on.
    ///
    /// Deliberately pessimistic. Guessing high means the window opens taller
    /// than the screen it lands on, which is the defect; guessing low means it
    /// opens a little short and corrects itself on the next layout pass, which
    /// nobody notices.
    static func conservativeHeight() -> CGFloat {
        NSScreen.screens.map(\.visibleFrame.height).min() ?? 800
    }
}

/// One input format's conversion rule: a label naming the input format and
/// a picker over every `ConversionTarget.allCases` value, in declaration
/// order. The "no change" option is spelled out as "Keep <format>" (not a
/// bare "None"/"Off") so the row states its own behaviour without the user
/// needing to infer it — per the spec's Settings-copy requirement. Iterating
/// `allCases` (rather than four hand-written `Text`s) means this row always
/// offers exactly the cases `ConversionTarget` has — including `.keep` —
/// with nothing to fall out of sync.
private struct ConversionRuleRow: View {
    let rowLabel: String
    let ownFormatName: String
    @Binding var selection: ConversionTarget

    var body: some View {
        Picker(rowLabel, selection: $selection) {
            ForEach(ConversionTarget.allCases, id: \.self) { target in
                Text(target == .keep ? "Keep \(ownFormatName)" : target.displayName).tag(target)
            }
        }
    }
}

/// HEIC/HEIF's conversion rule row: the same idea as `ConversionRuleRow`,
/// but over `ConversionFormat.allCases` — which has no `.keep` case at all
/// (see that type's doc comment) — so this row offers exactly three
/// options, JPEG/WebP/AVIF, and there is no "Keep HEIC / HEIF" wording to
/// even consider.
private struct HEICConversionRuleRow: View {
    let rowLabel: String
    @Binding var selection: ConversionFormat

    var body: some View {
        Picker(rowLabel, selection: $selection) {
            ForEach(ConversionFormat.allCases, id: \.self) { format in
                Text(format.displayName).tag(format)
            }
        }
    }
}
