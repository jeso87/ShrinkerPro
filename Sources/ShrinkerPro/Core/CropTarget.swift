import Foundation

/// The shape — and in `.pixels` mode the size — every raster image is cropped
/// to for the length of a session.
///
/// One value for both modes because they are the same instruction with one
/// step added: cut the largest centered rectangle of `width`:`height` out of
/// the oriented image, and in `.pixels` mode scale that rectangle down to
/// `width` × `height`. Never up — see `2026-09-17-center-crop-design.md` §1.
///
/// A struct with a `Mode` rather than a two-case enum: both cases would carry
/// an identical pair of `Int`s, so an enum would buy nothing but a `switch` at
/// every site that only wants the numbers.
///
/// The target is applied **literally**. A portrait photo with a 16:9 target
/// comes out a 16:9 landscape strip; there is deliberately no orientation
/// matching, and `CropGeometryTests` names a test after it so that nobody
/// later mistakes the rule for a bug.
struct CropTarget: Equatable, Sendable {

    /// What the two numbers mean.
    ///
    /// Declared ratio first because that is the order they are offered in and
    /// the one that is chosen by default — this project's other pickers are
    /// driven straight off `allCases`, so keeping the declaration and the
    /// control in step is the convention rather than a coincidence.
    enum Mode: String, Equatable, Sendable, CaseIterable {
        /// `1 : 1` — crop to that shape and leave the resolution alone. The
        /// session's max size, if one is set, still applies to what is left.
        /// The default, because it composes with everything else the bar does.
        case ratio
        /// `1200 × 1200` — crop to that shape, then scale down to that size.
        /// States the output size outright, which takes the max size out of
        /// play.
        case pixels
    }

    /// The smallest side worth expressing. Zero has no shape, and a negative
    /// one has no meaning.
    static let minimumSide = 1

    /// The largest. Past this a "crop" stops describing anything anyone is
    /// shrinking, and the bound exists so a slipped keypress cannot ask for
    /// one. Shared with `MaxSizeField`, so the three numeric fields in the
    /// session bar cannot drift apart.
    static let maximumSide = 20_000

    /// Both sides are `minimumSide...maximumSide`, enforced by `CropField` on
    /// one side and `--crop` on the other. `CropGeometry` treats anything else
    /// as no crop rather than trusting it.
    let width: Int
    let height: Int
    let mode: Mode

    init(width: Int, height: Int, mode: Mode) {
        self.width = width
        self.height = height
        self.mode = mode
    }

    /// The shape, which both modes mean.
    var aspect: AspectRatio { AspectRatio(width: width, height: height) }

    /// The size the crop is scaled down to, or `nil` in `.ratio` mode where
    /// there is no scaling step at all.
    var exactSize: PixelSize? {
        mode == .pixels ? PixelSize(width: width, height: height) : nil
    }
}

/// An integer aspect ratio.
///
/// Two `Int`s rather than a `Double` so the crop is computed in exact
/// arithmetic: 16:9 of a 1080-tall image is 1920 wide, not 1919.9999 rounded
/// whichever way the last bit happened to fall.
///
/// **Never reduced by `gcd`.** `1920:1080` stays `1920:1080` in the field, in
/// the summary and here. The user typed it; showing them `16:9` instead is the
/// kind of helpfulness that reads as a bug.
struct AspectRatio: Equatable, Sendable {
    let width: Int
    let height: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// A size in whole pixels.
///
/// Not `CGSize`, so that the `Core` types which only `import Foundation` —
/// `OutputSettings`, `ConversionRouter`, `CommandLineOptions` — can hold one
/// without taking a dependency on CoreGraphics. Pixels are integers anyway;
/// the places that need a `CGRect` convert at the edge.
struct PixelSize: Equatable, Sendable {
    let width: Int
    let height: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    var longestSide: Int { max(width, height) }
}
