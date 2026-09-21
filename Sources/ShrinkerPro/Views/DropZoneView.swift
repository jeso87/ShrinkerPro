import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DropZoneView: View {
    @EnvironmentObject private var model: AppModel

    /// Owned by `ContentView`, which hosts the `.onDrop` for the WHOLE window
    /// — upstream accepted a drop anywhere via `document.ondrop`, not only
    /// inside the dashed rectangle. This view is the visual affordance and the
    /// click target; it highlights when a drag is over the window, wherever
    /// the pointer happens to be.
    let isTargeted: Bool

    var body: some View {
        HStack(spacing: 16) {
            iconOrSpinner
            VStack(alignment: .leading, spacing: 2) {
                Text("Drag files here")
                    .font(.system(size: 16, weight: .semibold))
                    // Off for Arabic, Persian and Hebrew (see
                    // `needsRelaxedTracking`): negative letter-spacing
                    // crowds those scripts, and breaks outright the glyph
                    // joining that the two cursive ones depend on.
                    .tracking(Self.needsRelaxedTracking ? 0 : -0.16)
                    .foregroundStyle(.primary)
                Text("PNG, JPG, HEIC, WebP, AVIF, GIF and SVG — or press ⌘O")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(glowGradient)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .fill(isTargeted ? Color.accentColor.opacity(0.1) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.primary.opacity(0.2),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: pickFiles)
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    /// Radial glow from top-centre, per the spec's
    /// `radial-gradient(120% 160% at 50% 0%, dropGlow 0%, transparent 60%)`.
    /// `EllipticalGradient` is the closest SwiftUI primitive to a CSS radial
    /// gradient with independent x/y radii.
    private var glowGradient: EllipticalGradient {
        EllipticalGradient(
            colors: [Theme.dropGlow, Theme.dropGlow.opacity(0)],
            center: .top,
            startRadiusFraction: 0,
            endRadiusFraction: 0.85
        )
    }

    @ViewBuilder
    private var iconOrSpinner: some View {
        // Swaps the gradient circle for the spinner while a batch is
        // processing — no separate progress card, per the spec (1c is
        // descoped).
        if model.isProcessing {
            ProgressView()
                .controlSize(.small)
                .frame(width: 38, height: 38)
        } else {
            Circle()
                .fill(Theme.iconGradient)
                .frame(width: 38, height: 38)
                .overlay(
                    Image(systemName: "arrow.down")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                )
        }
    }

    /// Resolves the dropped `NSItemProvider`s to file URLs. Uses
    /// `loadObject(ofClass: URL.self)` (URL conforms to
    /// `NSItemProviderReading` for file-URL drags) rather than the
    /// `loadItem(forTypeIdentifier:)` + `Data` cast shown in the original
    /// brief — that form is illustrative, not prescriptive; this is the
    /// modern, equally-correct way to get real dropped files into
    /// `model.handle(urls:)`. Providers are resolved one at a time (not via
    /// a `TaskGroup`) — a drop is rarely more than a handful of files, and
    /// sequential awaits sidestep Swift 6 strict-concurrency "sending"
    /// diagnostics around capturing a main-actor-associated `NSItemProvider`
    /// into a concurrently-executing closure.
    ///
    /// Internal (not `private`) so `ShrinkerProTests` can call it directly
    /// with hand-built `NSItemProvider`s via `@testable import`, exercising
    /// the real resolution path without simulating a drag.
    static func resolveURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if let url = await loadURL(from: provider) {
                urls.append(url)
            }
        }
        return urls
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    /// Whether the headline should skip the Latin, tightened letter-spacing:
    /// Arabic and Persian join their letters, and
    /// tightening pulls those joins apart; Hebrew does not join, but the
    /// tightening buys it nothing either.
    ///
    /// Reads `Bundle.main.preferredLocalizations` rather than
    /// `Locale.current`: the locale reflects the user's *region* setting,
    /// which is independent of which language the app actually renders.
    /// `String(localized:)` and SwiftUI resolve strings through
    /// `preferredLocalizations` — the user's language list intersected with
    /// the app's declared localizations, honouring a per-app language
    /// override in System Settings — so that is the signal to match.
    /// `preferredLocalizations` returns a localization identifier, which
    /// may carry a script or region subtag (e.g. `zh-Hans`), so the
    /// language subtag is extracted via `Locale` rather than comparing the
    /// whole string. Urdu is not among the app's 36 declared languages
    /// (`LocalizationGuardTests.expectedRegions`), so it can never be
    /// resolved and is left out.
    private static var needsRelaxedTracking: Bool {
        guard let identifier = Bundle.main.preferredLocalizations.first else { return false }
        guard let code = Locale(identifier: identifier).language.languageCode?.identifier else { return false }
        return ["ar", "fa", "he"].contains(code)
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = ShrinkEngine.supportedContentTypes
        if panel.runModal() == .OK { model.handle(urls: panel.urls) }
    }
}
