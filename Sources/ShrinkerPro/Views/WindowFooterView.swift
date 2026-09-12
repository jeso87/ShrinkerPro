import SwiftUI

/// Pure derivations for `WindowFooterView` — factored out for the same
/// reason `RecentHeaderFormatter` is factored out of `RecentHeaderView`:
/// this project carries no view-tree testing dependency, so anything left
/// inline in a `body` is logic no test can reach. Driving the footer's menu
/// through the accessibility API to observe it was tried and is not
/// reliable, which makes the separation worth more than its size suggests.
/// See `WindowFooterStateTests`.
enum WindowFooterState {

    /// Whether the "Convert all to" label is emphasised — semibold and
    /// accent-coloured — so an override in force reads at a glance rather
    /// than only on inspection.
    static func isOverrideActive(_ override: SessionFormat?) -> Bool {
        override != nil
    }

    /// PNG is the one override target whose consequence is genuinely
    /// surprising: it is lossless, so photographs converted to it routinely
    /// come out *larger* than they started. Every other target is lossy and
    /// has no growth to warn about.
    static func showsGrowthWarning(for override: SessionFormat?) -> Bool {
        override == .png
    }

    /// Empty whenever the glyph is invisible. The warning holds its space
    /// permanently so neither the footer's height nor its width shifts when
    /// the override changes — which leaves it a hover target even while
    /// hidden, and an empty string is what stops it showing a tooltip for
    /// something nobody can see.
    static func growthWarningHelp(for override: SessionFormat?) -> String {
        showsGrowthWarning(for: override)
            ? "PNG is lossless — photos will usually get larger."
            : ""
    }
}

/// The main window's persistent footer: the session-scoped format override
/// and the persisted encoder quality, side by side when the window is wide
/// enough and stacked when it is not, pinned below the scrolling history.
///
/// **Why a footer is still faithful to the original argument.** The override
/// lives in the window rather than in Settings because
/// `2026-09-10-format-conversion.md` rejected a persistent global override
/// for converting "silently, and forever" — and the answer to the "silently"
/// half was the control being visible for exactly as long as it is switched
/// on. Moving it from above the list to below it keeps that: it is on screen
/// permanently either way, so an override can never be in force unseen.
///
/// **It binds two different objects, deliberately.** `sessionFormat` lives on
/// `AppModel`, is never persisted, and dies with the process. `quality` lives
/// on `Settings` and is written to UserDefaults on every change. They sit
/// together because they are the two things a user adjusts *per drop*, not
/// because they share a lifetime.
struct WindowFooterView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: Settings

    private var isOverrideActive: Bool {
        WindowFooterState.isOverrideActive(model.sessionFormat)
    }

    var body: some View {
        HStack(spacing: 0) {
            // "Side by side if the space fits" declared rather than
            // hand-computed. The pair needs roughly 400pt; ContentView's
            // floor is 340, so at the minimum window width this falls back
            // to two rows instead of clipping a menu. The Spacer is outside
            // the ViewThatFits on purpose — a greedy child inside it always
            // "fits", which would defeat the fallback entirely.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    convertControl
                    qualityControl
                }
                VStack(alignment: .leading, spacing: 8) {
                    convertControl
                    qualityControl
                }
            }
            Spacer(minLength: 0)
        }
        // 18 to line up with the result rows and the "RECENT" header this
        // now sits beneath, rather than the 16 the control used when it was
        // grouped with the drop zone above.
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var convertControl: some View {
        HStack(spacing: 8) {
            Text("Convert all to")
                .font(.system(size: 12, weight: isOverrideActive ? .semibold : .regular))
                .foregroundStyle(isOverrideActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .fixedSize()

            Picker("Convert all to", selection: $model.sessionFormat) {
                // The "no override" case is still the absence of a value
                // rather than a case on `SessionFormat` — there is no such
                // thing as converting a file "to off". Only the wording
                // changed: "App default" says what actually happens (your
                // stored per-format rules apply) where "Off" only said what
                // doesn't.
                Text("App default").tag(SessionFormat?.none)
                ForEach(SessionFormat.allCases, id: \.self) { format in
                    Text(format.displayName).tag(SessionFormat?.some(format))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .help("Converts every raster file for the rest of this session. SVG and GIF are always left in their own format. Not saved — it resets when you quit.")

            // PNG is the one choice with a genuinely surprising consequence,
            // so it keeps a visible signal rather than hiding in a tooltip.
            //
            // Reserved with `opacity` rather than inserted conditionally:
            // appearing and disappearing would change the footer's WIDTH,
            // and at a borderline window size that is enough to flip
            // `ViewThatFits` into its stacked layout the instant someone
            // picks PNG. Holding the space costs 11pt and keeps both
            // dimensions stable. The help text is emptied when hidden so an
            // invisible glyph never shows a tooltip.
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .opacity(WindowFooterState.showsGrowthWarning(for: model.sessionFormat) ? 1 : 0)
                .accessibilityHidden(!WindowFooterState.showsGrowthWarning(for: model.sessionFormat))
                .help(WindowFooterState.growthWarningHelp(for: model.sessionFormat))
        }
    }

    private var qualityControl: some View {
        HStack(spacing: 8) {
            Text("Quality")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize()

            Picker("Quality", selection: $settings.quality) {
                ForEach(QualityLevel.allCases, id: \.self) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            // Same exemption note as the Settings footer, and for the same
            // reason: an exclusion the user cannot see reads as a bug.
            .help("Applies to JPEG, WebP, AVIF and HEIC. PNG and GIF are optimised by tools with no comparable setting, so they look the same whichever you choose.")
        }
    }
}
