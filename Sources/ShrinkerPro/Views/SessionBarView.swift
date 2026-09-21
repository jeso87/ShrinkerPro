import SwiftUI
import AppKit

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
    /// The summary has no case for a half-typed crop, and does not need one:
    /// the panel cannot be closed while one exists, so the bar is never
    /// collapsed in that state. `AppModel.cropIsIncomplete` is what enforces
    /// that, and the panel says it there instead.
    static func summary(
        format: SessionFormat?, quality: QualityLevel?, storedQuality: QualityLevel,
        maxDimension: Int?, crop: CropTarget?
    ) -> String {
        [
            format?.displayName ?? String(localized: "App default",
                                          comment: "Collapsed session-bar summary when no format override is set."),
            (quality ?? storedQuality).displayName,
            maxDimension.map {
                String(localized: "Max \($0, format: .number.grouping(.never))px",
                       comment: "Collapsed session-bar summary of the max size. Placeholder is a pixel count; 'px' placement varies by language.")
            } ?? String(localized: "No limit",
                        comment: "Collapsed session-bar summary when no max size is set."),
            // Named only when there is one. The other three always state
            // themselves, including their off values, because each has exactly
            // one line's worth to say — but a fourth "No crop" pushed the
            // default summary past the width of the default window, and a
            // summary that truncates while saying nothing is worse than a
            // shorter one. A crop that *is* set is worth the characters.
            crop.map(cropFragment),
        ].compactMap { $0 }.joined(separator: " · ")
    }

    /// `Crop 1200×1200` or `Crop 1:1`.
    ///
    /// The separator is the same glyph the field shows, so the summary reads
    /// back as what was typed — and it is the only thing distinguishing "a
    /// 1200 by 1200 image" from "a square, whatever size the source allows".
    static func cropFragment(_ crop: CropTarget) -> String {
        switch crop.mode {
        case .pixels:
            return String(localized: "Crop \(crop.width, format: .number.grouping(.never))×\(crop.height, format: .number.grouping(.never))",
                          comment: "Collapsed session-bar summary of a pixel crop. Placeholders are width and height in pixels; the × is the same glyph the field shows.")
        case .ratio:
            return String(localized: "Crop \(crop.width, format: .number.grouping(.never)):\(crop.height, format: .number.grouping(.never))",
                          comment: "Collapsed session-bar summary of a ratio crop. Placeholders are the two sides of the ratio.")
        }
    }

    /// Whether the max size is out of play because a pixel crop has already
    /// stated the output size.
    ///
    /// The two are answers to one question, and the crop is the more specific
    /// of them: there is nothing a cap could add that typing smaller numbers
    /// into the crop would not say better. Composing them meant "Crop
    /// 1200×1200, Max 500px" quietly writing 500×500 files, which needed a
    /// warning in the window to be survivable — and a warning about two
    /// controls fighting is a sign that one of them should not be there.
    ///
    /// So the field is disabled rather than overruled. A ratio crop is the
    /// opposite case and leaves it alone entirely: a shape says nothing about
    /// size, so the cap is the only thing sizing the result.
    ///
    /// Keyed on a *complete* pixel crop rather than on the mode alone. With
    /// the fields empty there is no crop, nothing has stated a size, and
    /// disabling the one control that could would leave the panel unable to
    /// resize anything at all.
    static func maxSizeIsSupersededByCrop(crop: CropTarget?) -> Bool {
        crop?.exactSize != nil
    }

    /// Empty when the field is live, for the reason `growthWarningHelp` is:
    /// a tooltip nobody can see is worse than none.
    static func maxSizeSupersededHelp(crop: CropTarget?) -> String {
        guard let crop, maxSizeIsSupersededByCrop(crop: crop) else { return "" }
        return String(localized: "The crop already sets the size — every image comes out \(crop.width, format: .number.grouping(.never))×\(crop.height, format: .number.grouping(.never)). Switch the crop to a ratio, or clear it, to use a max size.",
                      comment: "Help text when a pixel crop makes the max size field irrelevant. Placeholders are the crop's width and height in pixels.")
    }

    /// The crop row's widths, and whether they fit.
    ///
    /// The expanded panel has no narrow-width fallback: its rows fit at
    /// `ContentView`'s 340pt floor or they overflow it, and SwiftUI's response
    /// to overflow is to squeeze the children rather than to complain. The
    /// first version of this row did overflow — 220pt of content in 202pt of
    /// space — and looked almost right on screen, which is exactly why the fit
    /// is arithmetic pinned by a test rather than a layout somebody eyeballed.
    /// The crop row's widths, and whether they fit.
    ///
    /// Every number here is doing the same job: getting two fields and a mode
    /// control onto one line inside the 202pt a 340pt window leaves after its
    /// gutters and label column. The row was tried at 220pt, which overflowed
    /// and which SwiftUI answered by squeezing rather than complaining, and
    /// then stacked onto two lines, which fitted easily and looked cheap. This
    /// is the width that makes one line work.
    enum CropRow {
        /// Each of the two number fields. Holds five digits, which is the most
        /// either can contain.
        static let fieldWidth: CGFloat = 36
        /// The `×` / `:` between them.
        static let separatorWidth: CGFloat = 8
        /// Between the fields and the separator.
        static let innerSpacing: CGFloat = 4
        /// Inside the recessed capsule, each side.
        static let capsulePadding: CGFloat = 9
        /// Between the capsule and the mode control.
        static let spacing: CGFloat = 8
        /// The px / ratio segmented control, at its natural drawn width — it
        /// does not stretch, and anything narrower clips "ratio".
        static let modeWidth: CGFloat = 88

        static var capsuleWidth: CGFloat {
            fieldWidth * 2 + separatorWidth + innerSpacing * 2 + capsulePadding * 2
        }

        static var width: CGFloat { capsuleWidth + spacing + modeWidth }
    }

    /// The panel's own chrome: 13pt gutters either side, a 104pt label column,
    /// and 8pt between the label and its control.
    static let panelGutters: CGFloat = 26
    static let labelColumnWidth: CGFloat = 104
    static let labelSpacing: CGFloat = 8

    static func cropRowFits(atWindowWidth width: CGFloat) -> Bool {
        width - panelGutters - labelColumnWidth - labelSpacing >= CropRow.width
    }

    /// The narrowest the window is allowed to get — `ContentView`'s own
    /// `minWidth`. Repeated here because the panel's widths are derived from
    /// it, and a silent disagreement between the two would show up as a
    /// clipped control rather than as a build error.
    static let minimumWindowWidth: CGFloat = 340

    /// The max size field's designed width, and the floor every language gets.
    ///
    /// Five digits is the most the field will ever contain, and a field
    /// several times wider than its longest value reads as though something
    /// much longer belongs in it.
    static let baseMaxSizeFieldWidth: CGFloat = 112

    /// 9pt either side of the field group's contents.
    static let maxSizeFieldPadding: CGFloat = 18
    /// Between the number and its unit.
    static let maxSizeFieldUnitSpacing: CGFloat = 6

    /// The widest the max size field group may be and still leave its row
    /// fitting the narrowest window.
    ///
    /// Note this is the whole group — the number, the gap and the unit — so it
    /// does not vary with the unit's own width. A longer unit eats into the
    /// group rather than enlarging it.
    static var maxSizeFieldWidthCap: CGFloat {
        minimumWindowWidth - panelGutters - labelColumnWidth - labelSpacing
    }

    /// The width of the max size field group, measured from the placeholder
    /// and unit actually loaded.
    ///
    /// Phase 1's pseudolocalization run caught this clipping: the group was a
    /// hardcoded 112pt and the field inside it used `.byClipping`, so a
    /// doubled "No limit" rendered as "No limit N". English measures under
    /// 112pt, so `baseMaxSizeFieldWidth` is a floor rather than a starting
    /// point and nothing moves for an English reader. A longer placeholder —
    /// German's "Keine Begrenzung" is twice the length — is given room up to
    /// `maxSizeFieldWidthCap`, past which the field stops growing and
    /// `DigitsOnlyField` ellipsises rather than cutting mid-glyph.
    static func maxSizeFieldWidth(placeholder: String, unit: String) -> CGFloat {
        let needed = maxSizeFieldPadding
            + textWidth(placeholder)
            + maxSizeFieldUnitSpacing
            + textWidth(unit)
        return min(max(baseMaxSizeFieldWidth, needed), maxSizeFieldWidthCap)
    }

    /// How wide a string draws in the session bar's own 12.5pt system font —
    /// the size `DigitsOnlyField` and the unit label both use.
    static func textWidth(_ string: String) -> CGFloat {
        (string as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.5)])
            .width
            .rounded(.up)
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
            ? String(localized: "PNG is lossless — photos will usually get larger.",
                     comment: "Warning when the session's format override is PNG, which usually grows photographs.")
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

    /// Half a crop blocks the panel and blocks a drop — see
    /// `AppModel.cropIsIncomplete`, which owns the rule.
    private var cropIsIncomplete: Bool { model.cropIsIncomplete }

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

    /// One line while it fits, and two when it does not.
    ///
    /// **`ViewThatFits` works here, and the warning against it does not
    /// apply.** The old bar could not use it because its summary truncated,
    /// and a child that truncates always "fits" — it shrinks to whatever it is
    /// given and reports success, so the fallback never runs. The one-line
    /// candidate below is `fixedSize`, so it reports the width it genuinely
    /// needs and is rejected the moment the window cannot give it.
    ///
    /// That is also why the fallback is a layout rather than a smaller font or
    /// a dropped element: nothing here is decoration. The summary states what
    /// will happen to the next files dropped, and a value hidden behind an
    /// ellipsis is a value not stated.
    private var collapsed: some View {
        ViewThatFits(in: .horizontal) {
            oneLineBar
            stackedBar
        }
    }

    /// Everything on one line: the shipped shape, and what the bar still looks
    /// like at any reasonable window size.
    private var oneLineBar: some View {
        HStack(spacing: 8) {
            overrideDot
            sessionLabel
            summaryText
                // The whole point of this candidate: no truncation, so it
                // measures what it actually needs and `ViewThatFits` can tell
                // whether it has it.
                .fixedSize()
            if isModified {
                resetButton
                    .padding(.leading, 6)
            }
            Spacer(minLength: 0)
            adjustButton
        }
        .padding(.horizontal, 13)
        .frame(height: 38)
    }

    /// The narrow fallback: the label and the controls on a header line, and
    /// the summary beneath them with the whole width of the bar.
    ///
    /// The summary carries no line limit even here. Two lines are what it
    /// normally needs; at the very narrowest it takes three, and that is still
    /// better than an ellipsis over the one thing the bar exists to say.
    private var stackedBar: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                overrideDot
                sessionLabel
                Spacer(minLength: 0)
                if isModified { resetButton }
                adjustButton
            }
            summaryText
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var overrideDot: some View {
        if isModified {
            Circle()
                .fill(Theme.SessionBar.overrideDot)
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
        }
    }

    private var sessionLabel: some View {
        Text("This session")
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    private var summaryText: some View {
        Text(summary)
            .font(.system(size: 12.5))
            .foregroundStyle(isModified ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .accessibilityLabel("This session: \(summary)")
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

            row(String(localized: "Convert all to",
                       comment: "Session bar row label for the format-override picker.")) {
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

            row(String(localized: "Quality",
                       comment: "Session bar row label for the quality picker.")) {
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

            row(String(localized: "Max size",
                       comment: "Session bar row label for the max-dimension field.")) {
                maxSizeField
                    .disabled(maxSizeIsSuperseded)
                    // Dimmed rather than hidden: the value stays readable and
                    // comes back the moment the crop is cleared or switched to
                    // a ratio, so nothing the user typed is lost and the rule
                    // is visible rather than remembered.
                    .opacity(maxSizeIsSuperseded ? 0.4 : 1)
                    .help(
                        maxSizeIsSuperseded
                            ? SessionBarState.maxSizeSupersededHelp(crop: model.sessionCropTarget)
                            : String(localized: "Shrinks images so the longest side is at most this many pixels. Smaller images are left alone. SVG is unaffected.",
                                    comment: "Help text for the max size field when it is live.")
                    )
            }

            row(String(localized: "Crop to",
                       comment: "Session bar row label for the crop width/height fields.")) {
                cropFields
                // Holds its space with `opacity`, like the two warnings above,
                // so the row's height never shifts as it is typed into.
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 11))
                    .opacity(cropIsIncomplete ? 1 : 0)
                    .help(
                        cropIsIncomplete
                            ? String(localized: "A crop needs both sides. Fill in the other number, or clear this one — files cannot be shrunk until you do.",
                                    comment: "Help text for the warning glyph shown while a crop has only one side filled in.")
                            : ""
                    )
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
                    .disabled(cropIsIncomplete)
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

    private func rowLabel(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .frame(width: SessionBarState.labelColumnWidth, alignment: .leading)
    }

    private var maxSizeField: some View {
        // Hoisted so the same strings that are drawn are the ones measured —
        // a width computed from a different literal than the one on screen is
        // the bug this replaces, one step removed.
        let placeholder = String(localized: "No limit",
                                 comment: "Placeholder in the max size field when no limit is set.")
        let unit = String(localized: "px",
                          comment: "Unit beside the max size field. Abbreviation for pixels.")

        return HStack(spacing: SessionBarState.maxSizeFieldUnitSpacing) {
            // A value typed here is in force the moment it is typed — no
            // Return to press — so dropping files straight after typing does
            // what it looks like it will do. Out-of-range values snap only
            // once editing ends, which is what stops "20000" being rewritten
            // while it is still being typed.
            DigitsOnlyField(
                text: $model.sessionMaxSizeText,
                placeholder: placeholder,
                onCommit: { model.sessionMaxSizeText = MaxSizeField.committed(model.sessionMaxSizeText) }
            )
            .accessibilityLabel("Max size in pixels")

            Text(unit)
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
        //
        // Measured rather than fixed, because 112pt fits "No limit" and not
        // "Keine Begrenzung". English measures under the floor, so this is
        // still exactly 112pt for an English reader.
        .frame(width: SessionBarState.maxSizeFieldWidth(placeholder: placeholder, unit: unit))
    }

    private var maxSizeIsSuperseded: Bool {
        SessionBarState.maxSizeIsSupersededByCrop(crop: model.sessionCropTarget)
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
        HStack(spacing: SessionBarState.CropRow.spacing) {
            HStack(spacing: SessionBarState.CropRow.innerSpacing) {
                DigitsOnlyField(
                    text: $model.sessionCropWidthText,
                    placeholder: String(localized: "W",
                                        comment: "One-letter placeholder for the crop WIDTH field. Keep it to a single character if the language allows."),
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
                    placeholder: String(localized: "H",
                                        comment: "One-letter placeholder for the crop HEIGHT field. Keep it to a single character if the language allows."),
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
            .frame(width: SessionBarState.CropRow.capsuleWidth)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Theme.SessionBar.fieldFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Theme.SessionBar.controlStroke, lineWidth: 0.5)
                    )
            )

            // Ratio first, because it is the default and the milder of the
            // two: a shape leaves every other control alone, where a pixel
            // size switches the max size off.
            Picker("Crop mode", selection: $model.sessionCropMode) {
                Text("ratio").tag(CropTarget.Mode.ratio)
                Text("px").tag(CropTarget.Mode.pixels)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: SessionBarState.CropRow.modeWidth)
        }
        .help(cropHelp)
    }

    /// Mode-dependent, and the only place the two rules people are most likely
    /// to be surprised by are stated: that the shape is used exactly as typed,
    /// and that nothing is ever enlarged.
    private var cropHelp: String {
        let shared = String(localized: "Both sides are needed. The shape is used exactly as typed, so a portrait photo cropped to 16:9 comes out as a landscape strip. SVG is unaffected. Not saved — it resets when you quit.",
                            comment: "Shared tail of both crop help texts.")
        switch model.sessionCropMode {
        case .pixels:
            return String(localized: "Crops the center of each image to this shape, then scales it down to this size. Images already smaller are cropped but never enlarged, so a mixed batch may not come out all one size. This sets the output size outright, so the max size above does not apply.",
                          comment: "Crop help in pixel mode, where the crop states the output size outright.") + " " + shared
        case .ratio:
            return String(localized: "Crops the center of each image to this shape and leaves the size alone. The session's max size, if set, still applies.",
                          comment: "Crop help in ratio mode, where the crop sets shape but not size.") + " " + shared
        }
    }

    // MARK: Buttons

    private var adjustButton: some View {
        SessionBarButton(title: String(localized: "Adjust",
                                       comment: "Button that opens the session settings panel."),
                         chevron: "chevron.up") { setExpanded(true) }
            .accessibilityLabel("Adjust session settings")
            .accessibilityHint("Shows the format, quality and max size controls")
    }

    /// Disabled while the crop is missing a side, so that the one control
    /// whose whole job is "close this" says plainly that it cannot. The model
    /// refuses the close in any case — Escape and a click above the bar arrive
    /// at the same guard — but a Done button that simply did nothing when
    /// pressed would read as a bug rather than as a rule.
    private var doneButton: some View {
        SessionBarButton(title: String(localized: "Done",
                                       comment: "Button that closes the session settings panel."),
                         chevron: "chevron.down") { setExpanded(false) }
            .disabled(cropIsIncomplete)
            .help(
                cropIsIncomplete
                    ? String(localized: "Finish the crop, or clear it, before closing.",
                            comment: "Help text on the disabled Done button while the crop is missing a side.")
                    : ""
            )
            .accessibilityLabel("Done adjusting session settings")
    }

    private var resetButton: some View {
        Button("Reset") { model.resetSessionSettings() }
            .buttonStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.savingsAccent)
            .help("Returns format, quality, max size and crop to the app's defaults")
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
        // Truncating, not clipping: the frame is measured to fit the
        // placeholder, but a language that needs more than the row can give
        // is capped, and an ellipsis says so where a hard clip mid-glyph
        // just looks broken.
        field.lineBreakMode = .byTruncatingTail
        // The frame is measured by SessionBarState, so the field must not
        // insist on being as wide as its own placeholder plus padding.
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
