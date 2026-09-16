import SwiftUI

/// Pure derivations for `SessionBarView` — factored out for the same reason
/// `RecentHeaderFormatter` is factored out of `RecentHeaderView`: this
/// project carries no view-tree testing dependency, so anything left inline
/// in a `body` is logic no test can reach. Driving the bar's menus through
/// the accessibility API to observe them was tried and is not reliable,
/// which makes the separation worth more than its size suggests.
/// See `SessionBarStateTests`.
enum SessionBarState {

    /// Whether any session setting differs from what the app would do on its
    /// own. Drives the override dot, the summary's colour, and whether Reset
    /// exists at all.
    ///
    /// Quality is compared against the *stored* default rather than against
    /// a constant: "modified" means "this session is doing something your
    /// settings would not", so someone whose stored quality is High and who
    /// has not touched the bar is not overriding anything.
    static func isModified(
        format: SessionFormat?, quality: QualityLevel?, storedQuality: QualityLevel, maxDimension: Int?
    ) -> Bool {
        format != nil || (quality != nil && quality != storedQuality) || maxDimension != nil
    }

    /// The one-line summary of what will happen to the next files dropped.
    ///
    /// Reads as a sentence of values rather than of labels — "WebP · High ·
    /// Max 2000px" — because the bar's job when collapsed is to answer "what
    /// is this about to do?", not to name its own controls.
    static func summary(
        format: SessionFormat?, quality: QualityLevel?, storedQuality: QualityLevel, maxDimension: Int?
    ) -> String {
        [
            format?.displayName ?? "App default",
            (quality ?? storedQuality).displayName,
            maxDimension.map { "Max \($0)px" } ?? "No limit",
        ].joined(separator: " · ")
    }

    /// The width below which the bar drops its optional parts — the "This
    /// session" prefix and the inline Reset — keeping the dot, the summary
    /// and Adjust, which are what carry the meaning.
    ///
    /// A threshold rather than a `ViewThatFits`: the summary is allowed to
    /// truncate, and a truncating child always "fits", which would defeat
    /// the fallback entirely. The footer above this one learned that the
    /// hard way — see the `Spacer` note in its layout.
    static let inlineDetailsMinimumWidth: CGFloat = 380

    static func showsInlineDetails(atWidth width: CGFloat) -> Bool {
        width >= inlineDetailsMinimumWidth
    }

    /// PNG is the one override target whose consequence is genuinely
    /// surprising: it is lossless, so photographs converted to it routinely
    /// come out *larger* than they started. Every other target is lossy and
    /// has no growth to warn about.
    static func showsGrowthWarning(for override: SessionFormat?) -> Bool {
        override == .png
    }

    /// Empty whenever the glyph is invisible. The warning holds its space
    /// permanently so the row's height never shifts when the override
    /// changes — which leaves it a hover target even while hidden, and an
    /// empty string is what stops it showing a tooltip for something nobody
    /// can see.
    static func growthWarningHelp(for override: SessionFormat?) -> String {
        showsGrowthWarning(for: override)
            ? "PNG is lossless — photos will usually get larger."
            : ""
    }
}

/// The max size field's text, and what it means.
///
/// Its own type for the same reason `SessionBarState` is: a rule left inline
/// in a `body` — or in a `TextField` formatter — is a rule no test can reach.
///
/// The field stores **text**, not a parsed `Int?`, and every keystroke is
/// filtered and re-parsed. That is deliberate, and it is the difference
/// between working and almost working: a field that only committed on Return
/// would let someone type "2000", drag a folder in, and get no resizing at
/// all, with the number they typed still sitting on screen as evidence that
/// it should have.
enum MaxSizeField {

    /// The largest cap worth expressing. Past this, "resize" stops meaning
    /// anything — no image the app can open is 20,000px on its longest side
    /// and still something a person is shrinking — and the number exists so
    /// a slipped keypress cannot ask for one.
    static let maximum = 20_000
    static let minimum = 1

    /// Five digits, which is `maximum`'s own width. Longer values are not
    /// rejected keystroke by keystroke so much as never accepted into the
    /// field in the first place.
    static let maximumDigits = 5

    /// `text` reduced to something the field is willing to hold: digits only,
    /// no leading zeros, and no longer than `maximumDigits`.
    ///
    /// Applied on every change rather than on commit, so a rejected character
    /// never appears at all. Idempotent — filtering filtered text returns it
    /// unchanged — which is what makes it safe to run from a `didSet` that
    /// assigns back to the property it observes.
    static func filter(_ text: String) -> String {
        let digits = text.filter(\.isNumber)
        // Leading zeros are dropped rather than rejected, so pasting "02000"
        // leaves "2000" instead of refusing the paste. An all-zero string
        // collapses to empty, which is the off state — the same place "0"
        // means, arrived at by the same route.
        let withoutLeadingZeros = String(digits.drop(while: { $0 == "0" }))
        return String(withoutLeadingZeros.prefix(maximumDigits))
    }

    /// The cap this text asks for, or `nil` for "no resizing".
    ///
    /// Blank and zero are both `nil`, and that equivalence is the point:
    /// clearing the field and typing a zero are the same instruction, so
    /// neither can leave a resize quietly switched on.
    ///
    /// Out-of-range values are clamped here rather than refused, so the
    /// engine can never be handed a cap outside the range — but the text is
    /// left as typed until the field is committed (see `committed`), because
    /// rewriting it mid-keystroke would fight anyone typing "20000" one digit
    /// at a time.
    static func dimension(from text: String) -> Int? {
        guard let value = Int(filter(text)), value > 0 else { return nil }
        return min(max(value, minimum), maximum)
    }

    /// The text the field should settle on once editing ends: what was typed,
    /// snapped into range. Blank stays blank.
    static func committed(_ text: String) -> String {
        guard let dimension = dimension(from: text) else { return "" }
        return String(dimension)
    }
}

/// The window's session settings bar: one line saying what will happen to the
/// next files dropped, and an Adjust button that expands the three controls
/// in place.
///
/// **Why a bar at the bottom is still faithful to the original argument.**
/// The format override lives in the window rather than in Settings because
/// `2026-09-10-format-conversion.md` rejected a persistent global override
/// for converting "silently, and forever" — and the answer to the "silently"
/// half was the control being visible for exactly as long as it is switched
/// on. Collapsing the controls behind Adjust keeps that promise and
/// strengthens it: the summary states every session value in words, at all
/// times, where three separate menus only stated them if you read all three.
///
/// **Everything here is session state.** Format, quality and max size all
/// live on `AppModel`, are never persisted, and are gone at quit. Quality
/// used to be the exception — the footer wrote it straight to UserDefaults —
/// and it stopped being one so that this bar means one thing rather than two:
/// the settings in it apply to this session, and the defaults live in
/// Settings. A quality left untouched is the stored default, so nothing
/// changed for anyone who never opens the panel.
struct SessionBarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: Settings

    private var isModified: Bool {
        SessionBarState.isModified(
            format: model.sessionFormat, quality: model.sessionQuality,
            storedQuality: settings.quality, maxDimension: model.sessionMaxDimension
        )
    }

    private var summary: String {
        SessionBarState.summary(
            format: model.sessionFormat, quality: model.sessionQuality,
            storedQuality: settings.quality, maxDimension: model.sessionMaxDimension
        )
    }

    var body: some View {
        Group {
            if model.isSessionPanelExpanded {
                expanded
            } else {
                collapsed
            }
        }
        .background(Theme.SessionBar.fill)
        // Drawn inside the bar rather than as a `Divider` above it, so
        // showing it costs no height and the panel and the bar share one
        // edge that never moves.
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.SessionBar.hairline)
                .frame(height: 0.5)
        }

    }

    // MARK: Collapsed

    /// Measured rather than assumed, because the bar must never wrap: below
    /// `SessionBarState.inlineDetailsMinimumWidth` the optional items are
    /// dropped instead.
    ///
    /// A `GeometryReader` is safe here specifically because the row's height
    /// is fixed: it takes all the space offered, which is 38pt tall and as
    /// wide as the window, rather than collapsing the way one wrapped around
    /// intrinsically-sized content would.
    private var collapsed: some View {
        GeometryReader { proxy in
            collapsedRow(width: proxy.size.width)
        }
        .frame(height: 38)
    }

    private func collapsedRow(width: CGFloat) -> some View {
        HStack(spacing: 8) {
            if isModified {
                Circle()
                    .fill(Theme.SessionBar.overrideDot)
                    .frame(width: 5, height: 5)
                    .accessibilityHidden(true)
            }

            if SessionBarState.showsInlineDetails(atWidth: width) {
                Text("This session")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            // The only element allowed to shrink. Everything else is
            // `fixedSize`, so a long summary truncates rather than squeezing
            // the Adjust button off the end.
            Text(summary)
                .font(.system(size: 12.5))
                .foregroundStyle(isModified ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityLabel("This session: \(summary)")

            if isModified && SessionBarState.showsInlineDetails(atWidth: width) {
                resetButton
                    .padding(.leading, 6)
            }

            Spacer(minLength: 0)

            adjustButton
        }
        .padding(.horizontal, 13)
        .frame(height: 38)
    }

    // MARK: Expanded

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Text("SESSION SETTINGS")
                    .font(.system(size: 11))
                    .tracking(0.99)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if isModified { resetButton }
            }

            row("Convert all to") {
                HStack(spacing: 8) {
                    Picker("Convert all to", selection: $model.sessionFormat) {
                        // The "no override" case is still the absence of a
                        // value rather than a case on `SessionFormat` — there
                        // is no such thing as converting a file "to off".
                        Text("App default").tag(SessionFormat?.none)
                        ForEach(SessionFormat.allCases, id: \.self) { format in
                            Text(format.displayName).tag(SessionFormat?.some(format))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    // Left at its intrinsic width, and the handoff's
                    // full-width popups are the one place this bar departs
                    // from it. A macOS `.menu` picker does not stretch its
                    // chrome: given a wider frame it centres the same button
                    // inside it, which leaves the two popups' left edges
                    // ragged against the label column. Drawing the popup by
                    // hand would buy the design's exact fill at the cost of
                    // the menu behaviour, keyboard handling and
                    // accessibility that come free here.

                    // PNG is the one choice with a genuinely surprising
                    // consequence, so it keeps a visible signal rather than
                    // hiding in a tooltip. Reserved with `opacity` so the row
                    // does not change width the instant someone picks PNG.
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .opacity(SessionBarState.showsGrowthWarning(for: model.sessionFormat) ? 1 : 0)
                        .accessibilityHidden(!SessionBarState.showsGrowthWarning(for: model.sessionFormat))
                        .help(SessionBarState.growthWarningHelp(for: model.sessionFormat))
                }
                .help("Converts every raster file for the rest of this session. SVG and GIF are always left in their own format.")
            }

            row("Quality") {
                // Bound to the session value, defaulting to the stored one:
                // picking a level here changes this session, not the
                // preference the next launch starts from.
                Picker("Quality", selection: sessionQualityBinding) {
                    ForEach(QualityLevel.allCases, id: \.self) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .help("Applies to JPEG, WebP, AVIF and HEIC. PNG and GIF are optimised by tools with no comparable setting, so they look the same whichever you choose.")
            }

            row("Max size") {
                maxSizeField
            }

            HStack(spacing: 8) {
                Text("Applies to this session only. Defaults live in Settings.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                doneButton
            }
            // Escape closes the panel, the same as Done. Values are kept:
            // there is nothing to cancel, since every change has already
            // applied.
            //
            // A zero-sized button carrying the cancel shortcut rather than
            // `.onExitCommand`, which never fired here: the key press goes to
            // whatever holds focus inside the panel — the max size field,
            // usually — and does not travel back out to the container the
            // modifier was attached to. In the `background` rather than in
            // the row, because even a zero-width child still takes the
            // stack's 8pt of spacing and shifted the helper text sideways.
            .background {
                Button("Close session settings") { setExpanded(false) }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        .padding(.top, 12)
        .padding(.horizontal, 13)
        .padding(.bottom, 13)
    }

    private func row<Control: View>(
        _ label: String, @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .frame(width: 104, alignment: .leading)
            control()
        }
    }

    private var maxSizeField: some View {
        HStack(spacing: 6) {
            // A value typed here is in force the moment it is typed — no
            // Return to press — so dropping files straight after typing does
            // what it looks like it will do. Out-of-range values snap only
            // once editing ends, which is what stops "20000" being rewritten
            // while it is still being typed.
            DigitsOnlyField(
                text: $model.sessionMaxSizeText,
                placeholder: "No limit",
                onCommit: { model.sessionMaxSizeText = MaxSizeField.committed(model.sessionMaxSizeText) }
            )
            .accessibilityLabel("Max size in pixels")

            Text("px")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Theme.SessionBar.fieldFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Theme.SessionBar.controlStroke, lineWidth: 0.5)
                )
        )
        // Sized to the number it holds rather than stretched across the row:
        // five digits is the most it will ever contain, and a field several
        // times wider than its longest value reads as though something much
        // longer belongs in it. It also leaves the three controls a similar
        // size, which a full-width field did not.
        .frame(width: 112)
        .help("Shrinks images so the longest side is at most this many pixels. Smaller images are left alone. SVG is unaffected.")
    }

    // MARK: Buttons

    private var adjustButton: some View {
        SessionBarButton(title: "Adjust", chevron: "chevron.up") { setExpanded(true) }
            .accessibilityLabel("Adjust session settings")
            .accessibilityHint("Shows the format, quality and max size controls")
    }

    private var doneButton: some View {
        SessionBarButton(title: "Done", chevron: "chevron.down") { setExpanded(false) }
            .accessibilityLabel("Done adjusting session settings")
    }

    private var resetButton: some View {
        Button("Reset") { model.resetSessionSettings() }
            .buttonStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.savingsAccent)
            .help("Returns format, quality and max size to the app's defaults")
    }

    private func setExpanded(_ expanded: Bool) {
        withAnimation(.easeOut(duration: 0.22)) {
            model.setSessionPanel(expanded: expanded)
        }
    }

    /// Quality with the stored default standing in for "not chosen this
    /// session". The setter records `nil` when the chosen level *is* the
    /// stored default, so picking your own default back is not an override
    /// and the dot goes out.
    private var sessionQualityBinding: Binding<QualityLevel> {
        Binding(
            get: { model.sessionQuality ?? settings.quality },
            set: { model.sessionQuality = $0 == settings.quality ? nil : $0 }
        )
    }
}

/// The max size field itself, as an `NSTextField` rather than a SwiftUI
/// `TextField`.
///
/// Not a preference: a SwiftUI `TextField` could not be made to reject what
/// it is given. Filtering in the model's `didSet` and again in the binding's
/// setter both left "2a000" on screen while the model held "2000" and the
/// engine was being handed 2000 — an AppKit field owns its text for as long
/// as it is being edited, and a value changed underneath it mid-edit does not
/// win. The two SwiftUI-shaped fixes for that (`TextField(value:formatter:)`,
/// or committing on submit) both give up the property that matters more: the
/// value applying as it is typed.
///
/// So the rejection happens where the typing does. The formatter's
/// `isPartialStringValid` refuses a keystroke outright — which covers pasting
/// too, where a keystroke-level filter would not — and the delegate publishes
/// every accepted change immediately.
private struct DigitsOnlyField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onCommit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.formatter = DigitsOnlyFormatter()
        field.isBordered = false
        field.drawsBackground = false
        // AppKit's own focus ring, not the design's 2pt accent one. Drawing
        // that ring meant telling SwiftUI when editing began, and the state
        // change that followed rebuilt this view mid-edit: the field lost
        // first responder and the keystrokes that arrived during the rebuild
        // went nowhere. A focus ring is not worth a field that silently drops
        // what you type.
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 12.5)
        field.lineBreakMode = .byClipping
        // The field is 112pt wide by design, so it must not insist on being
        // as wide as its own placeholder plus padding.
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // Only when it actually differs: assigning during editing would move
        // the insertion point to the end on every keystroke.
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: DigitsOnlyField

        init(parent: DigitsOnlyField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = MaxSizeField.filter(field.stringValue)
        }

        /// Editing ending — focus lost, Return, or Tab — is where an
        /// out-of-range number snaps into range.
        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onCommit()
        }
    }
}

/// Refuses anything that is not a short run of digits, at the point the
/// character is typed or pasted. AppKit beeps and keeps the previous text.
private final class DigitsOnlyFormatter: Formatter {

    override func string(for obj: Any?) -> String? {
        obj as? String
    }

    override func getObjectValue(
        _ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?,
        for string: String,
        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
        obj?.pointee = string as NSString
        return true
    }

    override func isPartialStringValid(
        _ partialString: String,
        newEditingString: AutoreleasingUnsafeMutablePointer<NSString?>?,
        errorDescription: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
        // An empty field is valid — it is how "no limit" is said.
        partialString.allSatisfy(\.isNumber)
            && partialString.count <= MaxSizeField.maximumDigits
    }
}

/// Adjust and Done: the same button in two directions.
private struct SessionBarButton: View {
    let title: String
    let chevron: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 12))
                Image(systemName: chevron)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isHovering ? Theme.SessionBar.controlFillHover : Theme.SessionBar.controlFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Theme.SessionBar.controlStroke, lineWidth: 0.5)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
