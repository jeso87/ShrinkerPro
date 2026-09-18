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
        format: SessionFormat?, quality: QualityLevel?, storedQuality: QualityLevel,
        maxDimension: Int?, crop: CropTarget?
    ) -> Bool {
        format != nil
            || (quality != nil && quality != storedQuality)
            || maxDimension != nil
            || crop != nil
    }

    /// The one-line summary of what will happen to the next files dropped.
    ///
    /// Reads as a sentence of values rather than of labels — "WebP · High ·
    /// Max 2000px" — because the bar's job when collapsed is to answer "what
    /// is this about to do?", not to name its own controls.
    static func summary(
        format: SessionFormat?, quality: QualityLevel?, storedQuality: QualityLevel,
        maxDimension: Int?, crop: CropTarget?
    ) -> String {
        [
            format?.displayName ?? "App default",
            (quality ?? storedQuality).displayName,
            maxDimension.map { "Max \($0)px" } ?? "No limit",
            crop.map(cropFragment) ?? "No crop",
        ].joined(separator: " · ")
    }

    /// `Crop 1200×1200` or `Crop 1:1`.
    ///
    /// The separator is the same glyph the field shows, so the summary reads
    /// back as what was typed — and it is the only thing distinguishing "a
    /// 1200 by 1200 image" from "a square, whatever size the source allows".
    static func cropFragment(_ crop: CropTarget) -> String {
        switch crop.mode {
        case .pixels: return "Crop \(crop.width)×\(crop.height)"
        case .ratio: return "Crop \(crop.width):\(crop.height)"
        }
    }

    /// Whether the max size will override the crop's exact size, and what the
    /// result will actually be.
    ///
    /// Both settings compose in one order — crop, then the crop's own pixel
    /// target, then the cap — and the cap can win. Someone who typed
    /// 1200×1200 into the crop field and left 500 in the max size field gets a
    /// 500×500 file, which is the correct composition and a genuine surprise.
    /// The bar says so rather than the engine quietly picking a winner.
    ///
    /// Only in pixel mode: a ratio crop makes no promise about size, so a cap
    /// deciding it is not overriding anything.
    static func capOverridesCrop(crop: CropTarget?, maxDimension: Int?) -> Bool {
        guard let crop, crop.mode == .pixels, let maxDimension else { return false }
        return max(crop.width, crop.height) > maxDimension
    }

    /// Empty whenever the warning is not shown, for the reason
    /// `growthWarningHelp` is: the glyph holds its space permanently so the
    /// row's height never shifts, and an empty string is what stops it showing
    /// a tooltip for something nobody can see.
    static func capOverridesCropHelp(crop: CropTarget?, maxDimension: Int?) -> String {
        guard capOverridesCrop(crop: crop, maxDimension: maxDimension),
              let crop, let maxDimension
        else { return "" }
        let longest = max(crop.width, crop.height)
        let scale = Double(maxDimension) / Double(longest)
        let width = max(1, Int((Double(crop.width) * scale).rounded()))
        let height = max(1, Int((Double(crop.height) * scale).rounded()))
        return "Your max size is smaller than the crop — images will come out "
            + "\(width)×\(height), not \(crop.width)×\(crop.height)."
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

    /// The crop row's widths, and whether they fit.
    ///
    /// The expanded panel has no narrow-width fallback: its rows fit at
    /// `ContentView`'s 340pt floor or they overflow it, and SwiftUI's response
    /// to overflow is to squeeze the children rather than to complain. The
    /// first version of this row did overflow — 220pt of content in 202pt of
    /// space — and looked almost right on screen, which is exactly why the fit
    /// is arithmetic pinned by a test rather than a layout somebody eyeballed.
    enum CropRow {
        /// Every control in this panel is this wide, because the max size
        /// field is — see `SessionBarView.maxSizeField`. Matching it is what
        /// gives the four rows one right edge; the crop's first attempt put
        /// the mode picker beside the fields instead, which ran 170pt past
        /// everything above it and made the panel look accidental.
        static let controlWidth: CGFloat = 112

        /// Inside the recessed capsule, each side.
        static let capsulePadding: CGFloat = 9
        /// Between the fields and the separator.
        static let innerSpacing: CGFloat = 4
        /// The `×` / `:` between them.
        static let separatorWidth: CGFloat = 10

        /// Each of the two number fields: whatever is left of the capsule once
        /// its padding and the separator are taken out, shared equally.
        /// Derived rather than written down, so the three cannot disagree.
        static var fieldWidth: CGFloat {
            (controlWidth - capsulePadding * 2 - separatorWidth - innerSpacing * 2) / 2
        }

        /// Between the fields and the mode control stacked beneath them.
        static let rowSpacing: CGFloat = 6

        static var width: CGFloat { controlWidth }
    }

    /// The panel's own chrome: 13pt gutters either side, a 104pt label column,
    /// and 8pt between the label and its control.
    static let panelGutters: CGFloat = 26
    static let labelColumnWidth: CGFloat = 104
    static let labelSpacing: CGFloat = 8

    static func cropRowFits(atWindowWidth width: CGFloat) -> Bool {
        width - panelGutters - labelColumnWidth - labelSpacing >= CropRow.width
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

/// The crop fields' contents, and what the pair of them means.
///
/// Beside `MaxSizeField` and for the same reason: a rule left inline in a
/// `body` is a rule no test can reach. It delegates filtering and clamping to
/// that type rather than restating them, so the three numeric fields in this
/// panel cannot drift apart — one range, one set of keystroke rules, one place
/// to change them.
enum CropField {

    /// Digits only, no leading zeros, capped at five — `MaxSizeField`'s rules
    /// exactly. Nothing special is done to a ratio like 20000:1: it asks for a
    /// one-pixel strip, which is what was typed. Second-guessing it would
    /// contradict the rule the whole feature rests on, that the target is
    /// applied literally.
    static func filter(_ text: String) -> String { MaxSizeField.filter(text) }

    /// The text a field should settle on once editing ends, snapped into
    /// range. Blank stays blank.
    static func committed(_ text: String) -> String { MaxSizeField.committed(text) }

    /// Whether exactly one side has been typed — the state the panel shows its
    /// hint for. Not an error: someone halfway through typing a crop has not
    /// done anything wrong yet.
    static func isHalfFilled(width: String, height: String) -> Bool {
        (MaxSizeField.dimension(from: width) == nil)
            != (MaxSizeField.dimension(from: height) == nil)
    }

    /// The crop these two fields ask for, or `nil` for no cropping.
    ///
    /// **Both sides are required, and this is the rule that matters most
    /// here.** A half-filled crop has to mean no crop, or someone types
    /// "1200", drags a folder in, and every file is cropped to a height nobody
    /// chose. It is the same failure the live parse was introduced to prevent,
    /// one field along — and worse, because a wrong size can be redone from
    /// the original while a wrong crop has thrown pixels away.
    static func target(width: String, height: String, mode: CropTarget.Mode) -> CropTarget? {
        guard let width = MaxSizeField.dimension(from: width),
              let height = MaxSizeField.dimension(from: height)
        else { return nil }
        return CropTarget(width: width, height: height, mode: mode)
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
            storedQuality: settings.quality, maxDimension: model.sessionMaxDimension,
            crop: model.sessionCropTarget
        )
    }

    private var summary: String {
        SessionBarState.summary(
            format: model.sessionFormat, quality: model.sessionQuality,
            storedQuality: settings.quality, maxDimension: model.sessionMaxDimension,
            crop: model.sessionCropTarget
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
                    // chrome: given a wider frame it centers the same button
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
                // The crop's exact size loses to a smaller cap. Held in place
                // with `opacity` rather than inserted conditionally, like the
                // PNG growth warning above, so the row's height never shifts.
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 11))
                    .opacity(capOverridesCrop ? 1 : 0)
                    .help(
                        SessionBarState.capOverridesCropHelp(
                            crop: model.sessionCropTarget, maxDimension: model.sessionMaxDimension
                        )
                    )
            }

            stackedRow("Crop to") {
                cropFields
            }

            HStack(spacing: 8) {
                // Wraps rather than truncates. It was "Applies to this
                // session only. Defaults live…" at every width the window
                // actually gets used at, which is a sentence explaining the
                // panel that the panel would not let you read.
                Text("Applies to this session only. Defaults live in Settings.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
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
        HStack(spacing: SessionBarState.labelSpacing) {
            rowLabel(label)
            control()
        }
    }

    /// A row whose control is taller than one line, with the label centered
    /// against the whole of it.
    ///
    /// The crop needs two: the numbers, and what they mean. Setting the mode
    /// beside them instead made the row far wider than the three above it and
    /// left the panel with a ragged right edge, so it goes underneath and the
    /// label spans both — which also reads as one grouped control rather than
    /// two unrelated ones that happen to share a line.
    private func stackedRow<Control: View>(
        _ label: String, @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: SessionBarState.labelSpacing) {
            rowLabel(label)
            control()
        }
    }

    private func rowLabel(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .frame(width: SessionBarState.labelColumnWidth, alignment: .leading)
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

    private var capOverridesCrop: Bool {
        SessionBarState.capOverridesCrop(
            crop: model.sessionCropTarget, maxDimension: model.sessionMaxDimension
        )
    }

    /// `[ W ] × [ H ]  [ px | ratio ]`.
    ///
    /// **The separator does double duty**: `×` in pixel mode and `:` in ratio
    /// mode. It is the cheapest possible signal that the mode has changed,
    /// placed exactly where the numbers are, and it makes both modes read as
    /// what people already write — `1200×1200`, `16:9`. The collapsed
    /// summary uses the same two glyphs so the bar reads back as what was
    /// typed.
    ///
    /// The mode is a segmented control rather than a third `.menu` picker,
    /// which is a third control idiom in a four-row panel and is recorded as a
    /// deviation in `2026-09-17-center-crop-design.md` §7 rather than left for
    /// the designer to find. The reason: the mode is binary, and the two
    /// numbers mean something entirely different depending on it, so it has to
    /// be readable without opening anything.
    private var cropFields: some View {
        VStack(alignment: .leading, spacing: SessionBarState.CropRow.rowSpacing) {
            HStack(spacing: SessionBarState.CropRow.innerSpacing) {
                DigitsOnlyField(
                    text: $model.sessionCropWidthText,
                    placeholder: "W",
                    onCommit: {
                        model.sessionCropWidthText =
                            CropField.committed(model.sessionCropWidthText)
                    }
                )
                .accessibilityLabel("Crop width")
                .frame(width: SessionBarState.CropRow.fieldWidth)

                Text(model.sessionCropMode == .pixels ? "×" : ":")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .frame(width: SessionBarState.CropRow.separatorWidth)

                DigitsOnlyField(
                    text: $model.sessionCropHeightText,
                    placeholder: "H",
                    onCommit: {
                        model.sessionCropHeightText =
                            CropField.committed(model.sessionCropHeightText)
                    }
                )
                .accessibilityLabel("Crop height")
                .frame(width: SessionBarState.CropRow.fieldWidth)
            }
            .padding(.horizontal, SessionBarState.CropRow.capsulePadding)
            .padding(.vertical, 5)
            .frame(width: SessionBarState.CropRow.controlWidth)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Theme.SessionBar.fieldFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Theme.SessionBar.controlStroke, lineWidth: 0.5)
                    )
            )

            Picker("Crop mode", selection: $model.sessionCropMode) {
                Text("px").tag(CropTarget.Mode.pixels)
                Text("ratio").tag(CropTarget.Mode.ratio)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            // `alignment: .leading`, because a segmented picker draws itself
            // at its natural width and centres that inside whatever frame it
            // is given — so the plain `width:` form left it indented under the
            // capsule by half the difference. The same trap the `.menu`
            // pickers above are documented for, in the other direction.
            .frame(width: SessionBarState.CropRow.controlWidth, alignment: .leading)
        }
        .help(cropHelp)
    }

    /// Mode-dependent, and the only place the two rules people are most likely
    /// to be surprised by are stated: that the shape is used exactly as typed,
    /// and that nothing is ever enlarged.
    private var cropHelp: String {
        let shared = "Both sides are needed. The shape is used exactly as typed, "
            + "so a portrait photo cropped to 16:9 comes out as a landscape strip. "
            + "SVG is unaffected. Not saved — it resets when you quit."
        switch model.sessionCropMode {
        case .pixels:
            return "Crops the center of each image to this shape, then scales it down to "
                + "this size. Images already smaller are cropped but never enlarged, so a "
                + "mixed batch may not come out all one size. " + shared
        case .ratio:
            return "Crops the center of each image to this shape and leaves the size "
                + "alone. The session's max size, if set, still applies. " + shared
        }
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
