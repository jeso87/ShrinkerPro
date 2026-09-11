import SwiftUI

/// The main window's "Convert all to" control: a session-scoped override
/// that replaces every stored per-format rule until the app quits.
///
/// It lives in the window rather than in Settings on purpose. A global
/// override was rejected in `2026-09-10-format-conversion.md` for being too
/// blunt — it would convert silently, and forever. Being visible above the
/// results list for exactly as long as it is switched on is what answers
/// the "silently" half; being session-scoped answers the "forever" half.
/// Moving this into Settings would give back both objections.
struct SessionOverrideBar: View {
    @EnvironmentObject private var model: AppModel

    private var isActive: Bool { model.sessionFormat != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Convert all to")
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))

                Picker("Convert all to", selection: $model.sessionFormat) {
                    // The "off" case is the absence of an override, so it is
                    // tagged with `nil` rather than being a case on
                    // `SessionFormat` — there is no such thing as converting
                    // a file "to off", and giving the enum a case for it
                    // would mean every switch over a target having to
                    // consider one that can never be a destination.
                    Text("Off").tag(SessionFormat?.none)
                    ForEach(SessionFormat.allCases, id: \.self) { format in
                        Text(format.displayName).tag(SessionFormat?.some(format))
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()

                Spacer(minLength: 0)
            }

            // Only shown while an override is active: with it off there is
            // nothing surprising to explain, and a permanent caption would
            // be noise in the window's resting state.
            if let format = model.sessionFormat {
                Text(note(for: format))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    /// SVG and GIF are named every time, for the same reason the Settings
    /// footer names them: an exemption the user cannot see is one they will
    /// take for a bug. PNG additionally warns about growth — it is lossless,
    /// so a photograph converted to it routinely comes out larger than it
    /// started, and finding that out from the results list afterwards is a
    /// worse way to learn it.
    private func note(for format: SessionFormat) -> String {
        let exemption = "SVG and GIF are always left in their own format."
        switch format {
        case .png:
            return "PNG is lossless — photos will usually get larger. \(exemption)"
        case .jpeg, .webp, .avif:
            return exemption
        }
    }
}
