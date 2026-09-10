import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var settings: Settings

    /// Starts as `.notDetermined` (which renders nothing) and is replaced
    /// with the real answer by the `.task` below, so the warning can never
    /// flash on screen before the system has been asked.
    @State private var notificationPermission: NotificationPermission = .notDetermined

    var body: some View {
        Form {
            Section {
                Toggle("Save shrunken files in same folder", isOn: $settings.saveInSameFolder)
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
                Toggle("Add subfolder \"minified\"", isOn: $settings.useSubfolder)
                Toggle("Add .min suffix to shrunken files", isOn: $settings.addSuffix)
            }
            Section {
                Toggle("Enable notifications", isOn: $settings.notification)
                // Spec: a denial must be reflected here and link to System
                // Settings, not leave the toggle switched on doing nothing.
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
                Toggle("Check for updates", isOn: $settings.updateCheck)
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
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
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
