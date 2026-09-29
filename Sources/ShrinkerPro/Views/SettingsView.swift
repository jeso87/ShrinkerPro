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

    /// The Settings window's designed width, and the floor every language gets.
    static let baseContentWidth: CGFloat = 420

    /// Everything in a Form row that is not the label or the value: the form's
    /// own insets either side, the gap between the label column and the
    /// control, and the popup button's padding and chevron.
    ///
    /// Measured with headroom, for the same reason `chromeAllowance` is:
    /// erring high costs a strip of unused window, while erring low puts the
    /// value back under an ellipsis, which is the whole defect. English's
    /// widest row measures 284pt, so at 120 it still lands on the floor with
    /// room to spare.
    static let rowChrome: CGFloat = 120

    /// How wide the window must be for no row to clip its own value.
    ///
    /// Phase 1's pseudolocalization run caught the Metadata popup rendering
    /// "All metadata All meta…" inside a hardcoded 420pt window. The height
    /// beside this was already measured rather than fixed; this is the same
    /// idea one axis over. English measures under the floor, so
    /// `baseContentWidth` is a floor rather than a starting point and nothing
    /// moves for an English reader.
    ///
    /// Both halves are measured because either can be the long one: German
    /// tends to lengthen the label, while a language with no short word for
    /// "metadata" lengthens the value.
    static func contentWidth(rowLabels: [String], optionLabels: [String]) -> CGFloat {
        let widestLabel = rowLabels.map(textWidth).max() ?? 0
        let widestOption = optionLabels.map(textWidth).max() ?? 0
        return max(baseContentWidth, widestLabel + widestOption + rowChrome)
    }

    /// How wide a string draws in the Form's own 13pt system font.
    static func textWidth(_ string: String) -> CGFloat {
        (string as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)])
            .width
            .rounded(.up)
    }
}

/// The Settings window: two tabs over one shared frame.
///
/// This view owns the window's size and the display it sits on; each tab owns
/// its own sections. The split is by what a setting decides — where a file is
/// written and what survives the trip, against what the image is encoded as.
struct SettingsView: View {
    @EnvironmentObject private var settings: Settings

    /// The usable height of the display this window is **actually on**,
    ///
    /// It was `NSScreen.main?.visibleFrame.height`, read inline, and that was
    /// wrong twice over. `NSScreen.main` is the screen with keyboard focus,
    /// not the screen this window is on — measured on a four-display setup it
    /// reported 1804pt while the window sat somewhere else entirely — and it
    /// is a plain global, so SwiftUI had no reason to re-evaluate the body
    /// when a display's resolution changed. The window kept whatever height it
    /// had been given at launch.

    /// Whether this display is too short to show every setting at once.

    /// Starts as `.notDetermined` (which renders nothing) and is replaced
    /// with the real answer by the `.task` below, so the warning can never
    /// flash on screen before the system has been asked.
    @State private var notificationPermission: NotificationPermission = .notDetermined
    /// Whether the Files/Filenames radio pair is choosing between keeping
    /// and replacing the user's own files, or merely naming a copy that
    /// lands somewhere else. Recomputed from the two rows above it, so
    /// switching on the subfolder relabels it immediately.
    /// The row labels that can actually get long enough to widen the window.
    ///
    /// The conversion rows are deliberately absent: their labels are format
    /// names (PNG, JPEG, HEIC / HEIF) which stay English in every language, so
    /// measuring them would only ever return the same number.
    static func measuredRowLabels(naming: OutputNaming) -> [String] {
        [
            String(localized: "Where", comment: "Settings row label for where output files are saved."),
            naming.rowLabel,
            String(localized: "Encode at", comment: "Settings row label for the quality picker."),
            String(localized: "When shrinking, keep", comment: "Settings row label for the metadata picker."),
        ]
    }

    /// Every value a popup in this window can display. The metadata policies
    /// are the long ones in English and were what clipped; a different
    /// language may well make a different row the widest, which is why all of
    /// them are measured rather than just that one.
    static func measuredOptionLabels(naming: OutputNaming) -> [String] {
        MetadataPolicy.allCases.map(\.displayName)
            + QualityLevel.allCases.map(\.displayName)
            + ConversionTarget.allCases.map(\.displayName)
            + [naming.suffixOnTitle, naming.suffixOffTitle]
    }

    /// Derived from `settings` rather than stored, and static so the output
    /// tab can share it without either view keeping its own copy.
    static func naming(for settings: Settings) -> OutputNaming {
        OutputNaming.style(
            saveInSameFolder: settings.saveInSameFolder,
            savePath: settings.savePath,
            useSubfolder: settings.useSubfolder
        )
    }

    private var naming: OutputNaming { Self.naming(for: settings) }

    var body: some View {
        TabView {
            SettingsOutputPane(notificationPermission: $notificationPermission)
                .tabItem { Label("Output", systemImage: "folder") }
            SettingsConversionPane()
                .tabItem { Label("Conversion", systemImage: "arrow.triangle.2.circlepath") }
        }
        // Width only. The height is the content's own: two tabs put every
        // section inside about 470 points, which fits any display macOS runs
        // on, so the window no longer has to be told how tall to be.
        .frame(
            width: SettingsWindowMetrics.contentWidth(
                rowLabels: Self.measuredRowLabels(naming: naming),
                optionLabels: Self.measuredOptionLabels(naming: naming)
            )
        )
        .task { notificationPermission = await .current() }
        // Re-check when the app is brought back to the front: the whole
        // point of the button above is that the user leaves for System
        // Settings and changes the answer, and the warning has to
        // disappear when they come back without needing a relaunch.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { notificationPermission = await .current() }
        }
    }
}

/// Where a file is written, what it is called, what survives the trip, and how
/// the app behaves around it.
private struct SettingsOutputPane: View {
    @EnvironmentObject private var settings: Settings
    @Binding var notificationPermission: NotificationPermission

    private var naming: OutputNaming { SettingsView.naming(for: settings) }

    /// One radio's label: the choice, and — where the choice is only about a
    /// filename — the filename it produces, in secondary text so the option
    /// still reads as one short phrase. Can't be an `HStack` because
    /// `.radioGroup` lays out its own options.
    ///
    /// This used to build the label from two concatenated `Text` views, one
    /// holding the title and the other the em dash and the example. That
    /// fixed the example after the title, English's word order and its
    /// left-to-right assumption, and handed a translator "  —  %@" as an
    /// isolated fragment with no sentence to place it in. Now the whole label is one
    /// catalog entry with both the title and the example as placeholders,
    /// and the example run is located within the formatted result by its
    /// own content (as `RecentHeaderFormatter.aggregate` does for the size
    /// run) — never a fixed offset, since a reordered translation would
    /// move it. A translation is free to put the words in whatever order
    /// its grammar wants; the right run still gets the secondary colour.
    private func optionLabel(_ title: String, example: String?) -> Text {
        guard let example else { return Text(title) }

        let label = String(localized: "\(title)  —  \(example)",
                            comment: "One radio option's label in the Files/Filenames setting: the choice, then the filename it produces, in secondary text. Placeholders are the option's own title and the example filename it produces.")

        var attributed = AttributedString(label)
        if let range = attributed.range(of: example, options: .backwards) {
            attributed[range].foregroundColor = .secondary
        }
        return Text(attributed)
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
                        Text(settings.savePath?.path
                            ?? String(localized: "No folder chosen",
                                      comment: "Shown in place of a path when no output folder has been picked yet."))
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
        // Pins the Form to its intrinsic height so the window sizes to the
        // content instead of the other way round.
        //
        // This modifier used to be here, was removed as the cause of a bug,
        // and is correct again now for the reason it was wrong then. A
        // grouped `Form` is a scrollable list: unpinned it reports no height
        // and simply fills whatever it is handed. Pinned, it can only
        // overflow — which at 1000 points of single-column content pushed the
        // window's bottom off any display shorter than about 1030, with no
        // way to reach it. Two tabs put each pane near 470, so there is
        // nothing left to overflow, and pinning is what makes the window fit
        // its content rather than clip it.
        .fixedSize(horizontal: false, vertical: true)
        // A grouped `Form` is a scroll view whatever height it is given, so
        // pinning it above stops it needing to scroll without stopping it
        // being able to. What was left was a scroller flashing on every tab
        // change and a pane that rubber-banded under the trackpad and sprang
        // back — motion that says "there is more here" about a pane where
        // there never is. Since the window is sized to the content, scrolling
        // has nothing left to reach.
        .scrollDisabled(true)
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

/// What the image is encoded as: the per-format rules, and the quality the
/// encoders those rules select are run at.
private struct SettingsConversionPane: View {
    @EnvironmentObject private var settings: Settings

    var body: some View {
        Form {
            // A separate Section (not folded into either toggle group above)
            // so the five rules read as one group of related controls, per
            // the spec, rather than being mixed in with unrelated toggles.
            Section {
                ConversionRuleRow(rowLabel: "PNG", ownFormatName: "PNG", selection: $settings.pngConversion)
                ConversionRuleRow(rowLabel: "JPEG", ownFormatName: "JPEG", selection: $settings.jpegConversion)
                HEICConversionRuleRow(rowLabel: "HEIC / HEIF", selection: $settings.heicConversion)
                ConversionRuleRow(rowLabel: "WebP", ownFormatName: "WebP", selection: $settings.webpConversion)
                ConversionRuleRow(rowLabel: "AVIF", ownFormatName: "AVIF", selection: $settings.avifConversion)
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
        }
        .formStyle(.grouped)
        // Pins the Form to its intrinsic height so the window sizes to the
        // content instead of the other way round.
        //
        // This modifier used to be here, was removed as the cause of a bug,
        // and is correct again now for the reason it was wrong then. A
        // grouped `Form` is a scrollable list: unpinned it reports no height
        // and simply fills whatever it is handed. Pinned, it can only
        // overflow — which at 1000 points of single-column content pushed the
        // window's bottom off any display shorter than about 1030, with no
        // way to reach it. Two tabs put each pane near 470, so there is
        // nothing left to overflow, and pinning is what makes the window fit
        // its content rather than clip it.
        .fixedSize(horizontal: false, vertical: true)
        // A grouped `Form` is a scroll view whatever height it is given, so
        // pinning it above stops it needing to scroll without stopping it
        // being able to. What was left was a scroller flashing on every tab
        // change and a pane that rubber-banded under the trackpad and sprang
        // back — motion that says "there is more here" about a pane where
        // there never is. Since the window is sized to the content, scrolling
        // has nothing left to reach.
        .scrollDisabled(true)
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
                Text(target == .keep
                     ? String(localized: "Keep \(ownFormatName)",
                              comment: "Conversion rule option meaning 'do not convert'. The placeholder is a format name such as PNG, which stays English.")
                     : target.displayName).tag(target)
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

