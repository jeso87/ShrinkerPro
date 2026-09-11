import XCTest
@testable import ShrinkerPro

/// Exercises `ConversionRouter.route` — the pure, IO-free decision that
/// determines which pipeline compresses a file. This is deliberately
/// exhaustive: all 4 native formats with a `ConversionTarget` rule (PNG,
/// JPEG, WebP, AVIF) × all 4 rule values, plus HEIC separately against its
/// own `ConversionFormat` rule (3 values, no `.keep`) — since the whole
/// point of `ConversionRouter` is that this matrix is cheap to check
/// completely without touching a binary, a temp file, or ImageIO.
final class ConversionRouterTests: XCTestCase {

    // MARK: - .keep always stays in the native format

    /// HEIC is deliberately not included here: its rule is a
    /// `ConversionFormat`, which has no `.keep` case to test in the first
    /// place. `route(native:rule:ConversionTarget)` can still technically
    /// be called with `native: .heic` (nothing at the router level forbids
    /// it), so `testHEICNeverActuallyRoutedWithAConversionTargetKeepInProduction`
    /// below documents that this path, while callable, is not one
    /// production code exercises.
    func testKeepAlwaysSameFormat() {
        for native: NativeFormat in [.png, .jpeg, .webp, .avif] {
            XCTAssertEqual(
                ConversionRouter.route(native: native, rule: ConversionTarget.keep), .sameFormat(native),
                "\(native) with rule .keep should never convert"
            )
        }
    }

    // MARK: - Same-format target short-circuits (spec: "still compression")

    func testExplicitSameFormatTargetShortCircuits() {
        XCTAssertEqual(ConversionRouter.route(native: .jpeg, rule: ConversionTarget.jpeg), .sameFormat(.jpeg))
        XCTAssertEqual(ConversionRouter.route(native: .webp, rule: ConversionTarget.webp), .sameFormat(.webp))
        XCTAssertEqual(ConversionRouter.route(native: .avif, rule: ConversionTarget.avif), .sameFormat(.avif))
    }

    // MARK: - PNG source (no ConversionTarget case of its own — always a real conversion when rule != .keep)

    func testPNGSource() {
        XCTAssertEqual(ConversionRouter.route(native: .png, rule: ConversionTarget.jpeg),
                        .viaIntermediate(target: .jpeg, intermediate: .tga))
        XCTAssertEqual(ConversionRouter.route(native: .png, rule: ConversionTarget.webp), .direct(target: .webp))
        XCTAssertEqual(ConversionRouter.route(native: .png, rule: ConversionTarget.avif), .direct(target: .avif))
    }

    // MARK: - JPEG source

    func testJPEGSource() {
        XCTAssertEqual(ConversionRouter.route(native: .jpeg, rule: ConversionTarget.webp), .direct(target: .webp))
        XCTAssertEqual(ConversionRouter.route(native: .jpeg, rule: ConversionTarget.avif), .direct(target: .avif))
    }

    // MARK: - WebP source

    func testWebPSource() {
        XCTAssertEqual(ConversionRouter.route(native: .webp, rule: ConversionTarget.jpeg),
                        .viaIntermediate(target: .jpeg, intermediate: .tga))
        XCTAssertEqual(ConversionRouter.route(native: .webp, rule: ConversionTarget.avif), .direct(target: .avif))
    }

    /// The case that used to `preconditionFailure("webp-to-webp did not
    /// short-circuit")`. `route` itself never reaches this combination —
    /// `testExplicitSameFormatTargetShortCircuits` above proves it returns
    /// `.sameFormat(.webp)` first — so this calls `convert(native:to:)`
    /// directly, the same lower-level function `route` delegates to once
    /// same-format has been ruled out, to prove the WebP branch is
    /// genuinely correct on its own terms rather than merely "a crash
    /// nobody has observed yet". cwebp reads WebP input natively (see
    /// `WebPCompressor`'s doc comment), so `.direct(target: .webp)` is the
    /// right answer, not an impossible state.
    func testWebPSourceWithWebPTargetRoutesDirectlyInsteadOfCrashing() {
        XCTAssertEqual(ConversionRouter.convert(native: .webp, to: .webp), .direct(target: .webp))
    }

    // MARK: - AVIF source — cwebp can't read it, so WebP needs an intermediate

    func testAVIFSource() {
        XCTAssertEqual(ConversionRouter.route(native: .avif, rule: ConversionTarget.jpeg),
                        .viaIntermediate(target: .jpeg, intermediate: .tga))
        XCTAssertEqual(ConversionRouter.route(native: .avif, rule: ConversionTarget.webp),
                        .viaIntermediate(target: .webp, intermediate: .png))
    }

    // MARK: - HEIC/HEIF source — routed via `ConversionFormat`, same shape as AVIF: cwebp can't read it either

    /// HEIC's rule is a `ConversionFormat` (no `.keep`), so this calls the
    /// `ConversionFormat` overload directly, exactly as `ShrinkEngine` does
    /// for `rules.heic` — unlike PNG/JPEG/WebP/AVIF above, which go through
    /// the `ConversionTarget` overload.
    func testHEICSource() {
        XCTAssertEqual(ConversionRouter.route(native: .heic, rule: ConversionFormat.jpeg),
                        .viaIntermediate(target: .jpeg, intermediate: .tga))
        XCTAssertEqual(ConversionRouter.route(native: .heic, rule: ConversionFormat.webp),
                        .viaIntermediate(target: .webp, intermediate: .png))
        XCTAssertEqual(ConversionRouter.route(native: .heic, rule: ConversionFormat.avif),
                        .direct(target: .avif))
    }

    /// Documents a deliberate asymmetry: `route(native:rule:ConversionTarget)`
    /// is a general function over any `NativeFormat`, so calling it with
    /// `native: .heic` still type-checks and still behaves sensibly — but
    /// production code (`ShrinkEngine.plan`) never does this; it always
    /// calls the `ConversionFormat` overload for HEIC, because
    /// `Settings.heicConversion`/`ConversionRules.heic` are typed
    /// `ConversionFormat`, which has no `.keep` to pass in the first place.
    func testHEICNeverActuallyRoutedWithAConversionTargetKeepInProduction() {
        XCTAssertEqual(ConversionRouter.route(native: .heic, rule: ConversionTarget.keep), .sameFormat(.heic))
    }

    // MARK: - Exhaustive cross-check

    /// The individual tests above double as documentation of *why* each
    /// route is what it is; this one just makes sure nothing in the full
    /// matrix was missed or drifted from that documented shape. PNG/JPEG/
    /// WebP/AVIF are checked against every `ConversionTarget` case; HEIC
    /// is checked separately against every `ConversionFormat` case, since
    /// it has no `.keep` to include.
    func testFullMatrixMatchesExpectedTable() {
        let expected: [NativeFormat: [ConversionTarget: ConversionRoute]] = [
            .png: [
                .keep: .sameFormat(.png),
                .jpeg: .viaIntermediate(target: .jpeg, intermediate: .tga),
                .webp: .direct(target: .webp),
                .avif: .direct(target: .avif),
            ],
            .jpeg: [
                .keep: .sameFormat(.jpeg),
                .jpeg: .sameFormat(.jpeg),
                .webp: .direct(target: .webp),
                .avif: .direct(target: .avif),
            ],
            .webp: [
                .keep: .sameFormat(.webp),
                .jpeg: .viaIntermediate(target: .jpeg, intermediate: .tga),
                .webp: .sameFormat(.webp),
                .avif: .direct(target: .avif),
            ],
            .avif: [
                .keep: .sameFormat(.avif),
                .jpeg: .viaIntermediate(target: .jpeg, intermediate: .tga),
                .webp: .viaIntermediate(target: .webp, intermediate: .png),
                .avif: .sameFormat(.avif),
            ],
        ]

        for (native, rules) in expected {
            for (rule, route) in rules {
                XCTAssertEqual(
                    ConversionRouter.route(native: native, rule: rule), route,
                    "native=\(native) rule=\(rule)"
                )
            }
        }

        let expectedHEIC: [ConversionFormat: ConversionRoute] = [
            .jpeg: .viaIntermediate(target: .jpeg, intermediate: .tga),
            .webp: .viaIntermediate(target: .webp, intermediate: .png),
            .avif: .direct(target: .avif),
        ]
        for (rule, route) in expectedHEIC {
            XCTAssertEqual(
                ConversionRouter.route(native: .heic, rule: rule), route,
                "native=heic rule=\(rule)"
            )
        }
    }

    // MARK: - NativeFormat extension mapping

    func testNativeFormatFromExtension() {
        XCTAssertEqual(NativeFormat(extension: "png"), .png)
        XCTAssertEqual(NativeFormat(extension: "jpg"), .jpeg)
        XCTAssertEqual(NativeFormat(extension: "jpeg"), .jpeg)
        XCTAssertEqual(NativeFormat(extension: "webp"), .webp)
        XCTAssertEqual(NativeFormat(extension: "avif"), .avif)
        XCTAssertEqual(NativeFormat(extension: "heic"), .heic)
        XCTAssertEqual(NativeFormat(extension: "heif"), .heic)
        XCTAssertNil(NativeFormat(extension: "svg"))
        XCTAssertNil(NativeFormat(extension: "gif"))
        XCTAssertNil(NativeFormat(extension: "txt"))
    }

    // MARK: - ConversionFormat has no .keep case (Change 1)

    /// The load-bearing guarantee behind "the HEIC picker offers exactly
    /// three options": `ConversionFormat` simply has no `.keep` case to
    /// offer, store, or route — not merely "the UI doesn't show one today".
    func testConversionFormatHasNoKeepCase() {
        XCTAssertEqual(ConversionFormat.allCases, [.jpeg, .webp, .avif])
        XCTAssertNil(ConversionFormat(rawValue: "keep"),
                      "a stored \"keep\" must not resolve to any ConversionFormat case")
    }

    /// Contrast case: every other format's type is untouched by Change 1 —
    /// still four cases, `.keep` included.
    func testConversionTargetStillHasFourCasesIncludingKeep() {
        XCTAssertEqual(ConversionTarget.allCases, [.keep, .jpeg, .webp, .avif])
    }

    // MARK: - DirectTarget/RelayedTarget have no case for the impossible combination (Change 2)

    /// The load-bearing guarantee behind deleting `compressor(for:)`'s two
    /// `preconditionFailure`s in `ShrinkEngine`: `.direct`'s target type
    /// simply has no `.jpeg` case to route to a JPEG encoder that could
    /// never have decoded the source in the first place — not merely
    /// "the router happens to never produce it today".
    func testDirectTargetHasNoJPEGCase() {
        XCTAssertEqual(DirectTarget.allCases, [.webp, .avif])
        XCTAssertNil(DirectTarget(rawValue: "jpeg"),
                      "a JPEG target must never be representable as a DirectTarget")
    }

    /// Mirror guarantee for the other route: `.viaIntermediate`'s target
    /// type has no `.avif` case, because ImageIO decodes every supported
    /// input directly and an AVIF target therefore never needs a carrier.
    func testRelayedTargetHasNoAVIFCase() {
        // `.png` joined this list with the session override's PNG target:
        // pngquant reads only PNG, so every other source reaches it through
        // a carrier, exactly as cjpeg and cwebp do. The guarantee this test
        // exists for is the assertion below, not the length of the list.
        XCTAssertEqual(RelayedTarget.allCases, [.jpeg, .webp, .png])
        XCTAssertNil(RelayedTarget(rawValue: "avif"),
                      "an AVIF target must never be representable as a RelayedTarget")
    }

    // MARK: - PNG is reachable only from a session override

    /// The counterpart to `TargetFormat` having a `.png` case: neither of
    /// the two *persisted* types may gain one. Both drive a Settings picker
    /// through `allCases`, so a case added to either would appear in the UI
    /// as a stored rule — and `Settings` would then accept and write "png"
    /// for a rule the user could not otherwise express.
    func testThePersistedRuleTypesHaveNoPNGCase() {
        XCTAssertNil(ConversionTarget(rawValue: "png"),
                     "PNG must not be storable as a per-format rule")
        XCTAssertNil(ConversionFormat(rawValue: "png"),
                     "PNG must not be storable as the HEIC rule")
        XCTAssertEqual(ConversionFormat.allCases, [.jpeg, .webp, .avif],
                       "the HEIC/HEIF row offers exactly three options; PNG is session-only")
    }

    /// ...and the session-only type is the one place it does exist.
    func testTheSessionTypeOffersAllFourTargets() {
        XCTAssertEqual(SessionFormat.allCases, [.jpeg, .webp, .avif, .png])
        XCTAssertEqual(SessionFormat.allCases.map(\.targetFormat), [.jpeg, .webp, .avif, .png])
    }
}

// MARK: - Orientation and metadata routing

/// The rule these cover: a file whose pixels are not already upright can
/// never be handed straight to a vendored CLI encoder, because none of them
/// can rotate. Each such route must be rewritten to the relayed equivalent
/// of the *same destination* — the output format must never change as a
/// side effect of the input being rotated.
final class RoutingContextTests: XCTestCase {

    private let rotated = RoutingContext(isUpright: false, policy: .all)
    private let upright = RoutingContext(isUpright: true, policy: .all)

    func testUprightSourcesKeepTheirDirectCLIRoutes() {
        XCTAssertEqual(
            ConversionRouter.route(native: .jpeg, rule: .keep, context: upright),
            .sameFormat(.jpeg)
        )
        XCTAssertEqual(
            ConversionRouter.route(native: .png, rule: .keep, context: upright),
            .sameFormat(.png)
        )
        XCTAssertEqual(
            ConversionRouter.route(native: .webp, rule: .keep, context: upright),
            .sameFormat(.webp)
        )
        XCTAssertEqual(
            ConversionRouter.route(native: .jpeg, rule: ConversionTarget.webp, context: upright),
            .direct(target: .webp)
        )
    }

    func testRotatedSourcesAreReroutedThroughImageIO() {
        XCTAssertEqual(
            ConversionRouter.route(native: .jpeg, rule: .keep, context: rotated),
            .viaIntermediate(target: .jpeg, intermediate: .tga),
            "cjpeg cannot rotate, so a rotated JPEG must decode through ImageIO first"
        )
        XCTAssertEqual(
            ConversionRouter.route(native: .png, rule: .keep, context: rotated),
            .viaIntermediate(target: .png, intermediate: .png)
        )
        XCTAssertEqual(
            ConversionRouter.route(native: .webp, rule: .keep, context: rotated),
            .viaIntermediate(target: .webp, intermediate: .png)
        )
        XCTAssertEqual(
            ConversionRouter.route(native: .jpeg, rule: ConversionTarget.webp, context: rotated),
            .viaIntermediate(target: .webp, intermediate: .png)
        )
    }

    /// AVIF and HEIC are ImageIO end to end already, which is where the
    /// rotation happens — so being rotated must not change their route.
    func testImageIORoutesAreUnaffectedByOrientation() {
        XCTAssertEqual(
            ConversionRouter.route(native: .avif, rule: .keep, context: rotated),
            .sameFormat(.avif)
        )
        XCTAssertEqual(
            ConversionRouter.route(native: .heic, rule: ConversionTarget.avif, context: rotated),
            .direct(target: .avif)
        )
    }

    /// Rerouting must preserve the destination exactly. A rotated file
    /// silently coming out as a different format would be a far worse bug
    /// than the one being fixed.
    func testReroutingNeverChangesTheDestinationFormat() {
        for native in [NativeFormat.png, .jpeg, .webp, .avif, .heic] {
            for target in TargetFormat.allCases {
                let up = ConversionRouter.route(native: native, target: target, context: upright)
                let turned = ConversionRouter.route(native: native, target: target, context: rotated)
                XCTAssertEqual(
                    destination(of: up), destination(of: turned),
                    "\(native) -> \(target) changed destination when rotated"
                )
            }
        }
    }

    /// cwebp's `-metadata` flag can say "all" or "none" but cannot name
    /// individual tags, so "copyright only" is the one policy it cannot be
    /// trusted with — those jobs must be relayed through a PNG intermediate
    /// authored with exactly the tags to keep.
    func testCopyrightPolicyForcesWebPThroughAnIntermediate() {
        let copyright = RoutingContext(isUpright: true, policy: .copyright)
        XCTAssertEqual(
            ConversionRouter.route(native: .jpeg, rule: ConversionTarget.webp, context: copyright),
            .viaIntermediate(target: .webp, intermediate: .png)
        )
        XCTAssertEqual(
            ConversionRouter.route(native: .webp, rule: .keep, context: copyright),
            .viaIntermediate(target: .webp, intermediate: .png)
        )
    }

    func testAllAndStrippedPoliciesLeaveTheDirectWebPRouteAlone() {
        for policy in [MetadataPolicy.all, .stripped] {
            let context = RoutingContext(isUpright: true, policy: policy)
            XCTAssertEqual(
                ConversionRouter.route(native: .jpeg, rule: ConversionTarget.webp, context: context),
                .direct(target: .webp),
                "cwebp can state \(policy.rawValue) with its own flag; no relay needed"
            )
        }
    }

    /// The policy only ever matters to cwebp. Everything else either writes
    /// metadata at encode time (ImageIO) or gets a post-pass (cjpeg,
    /// pngquant), so no other route should move because of it.
    func testPolicyDoesNotDisturbNonWebPRoutes() {
        for policy in MetadataPolicy.allCases {
            let context = RoutingContext(isUpright: true, policy: policy)
            XCTAssertEqual(ConversionRouter.route(native: .jpeg, rule: .keep, context: context), .sameFormat(.jpeg))
            XCTAssertEqual(ConversionRouter.route(native: .png, rule: .keep, context: context), .sameFormat(.png))
            XCTAssertEqual(ConversionRouter.route(native: .heic, rule: ConversionFormat.jpeg, context: context),
                           .viaIntermediate(target: .jpeg, intermediate: .tga))
            XCTAssertEqual(ConversionRouter.route(native: .png, rule: ConversionTarget.avif, context: context), .direct(target: .avif))
        }
    }

    private func destination(of route: ConversionRoute) -> String {
        switch route {
        case .sameFormat(let native): return "\(native)"
        case .direct(let target): return target.rawValue
        case .viaIntermediate(let target, _): return target.rawValue
        }
    }
}

// MARK: - The PNG target

/// PNG is reachable only through the session override. These cover the
/// route itself; that it stays out of the persisted rules is covered by the
/// absence of a `.png` case on `ConversionTarget`/`ConversionFormat`, which
/// the compiler enforces.
final class PNGTargetRoutingTests: XCTestCase {

    func testEveryNonPNGSourceReachesPNGThroughAnIntermediate() {
        for native in [NativeFormat.jpeg, .webp, .avif, .heic] {
            XCTAssertEqual(
                ConversionRouter.route(native: native, target: .png),
                .viaIntermediate(target: .png, intermediate: .png),
                "pngquant reads only PNG, so \(native) must decode through ImageIO first"
            )
        }
    }

    /// Same-format conversion is still compression: a PNG asked to become a
    /// PNG must take pngquant directly, not a pointless decode/re-encode.
    func testAPNGTargetingPNGIsJustCompression() {
        XCTAssertEqual(
            ConversionRouter.route(native: .png, target: .png),
            .sameFormat(.png)
        )
    }

    func testAPNGOutputIsOwedAMetadataPostPass() {
        XCTAssertTrue(ConversionRoute.sameFormat(.png).needsMetadataPostPass)
        XCTAssertTrue(ConversionRoute.viaIntermediate(target: .png, intermediate: .png).needsMetadataPostPass)
    }
}

// MARK: - Which outputs are owed a metadata post-pass

final class MetadataPostPassRoutingTests: XCTestCase {

    /// cjpeg and pngquant cannot be told what metadata to emit, so their
    /// output is rewritten afterwards.
    func testCLIEncodedJPEGAndPNGAreOwedAPostPass() {
        XCTAssertTrue(ConversionRoute.sameFormat(.jpeg).needsMetadataPostPass)
        XCTAssertTrue(ConversionRoute.sameFormat(.png).needsMetadataPostPass)
        XCTAssertTrue(ConversionRoute.viaIntermediate(target: .jpeg, intermediate: .tga).needsMetadataPostPass)
    }

    /// ImageIO writes its own metadata at encode time, and cwebp's output
    /// ImageIO cannot open for writing at all — attempting a post-pass on a
    /// WebP would fail, so it must never be asked for.
    func testImageIOAndWebPOutputsAreNotOwedAPostPass() {
        XCTAssertFalse(ConversionRoute.sameFormat(.avif).needsMetadataPostPass)
        XCTAssertFalse(ConversionRoute.sameFormat(.heic).needsMetadataPostPass)
        XCTAssertFalse(ConversionRoute.sameFormat(.webp).needsMetadataPostPass)
        XCTAssertFalse(ConversionRoute.direct(target: .avif).needsMetadataPostPass)
        XCTAssertFalse(ConversionRoute.direct(target: .webp).needsMetadataPostPass)
        XCTAssertFalse(ConversionRoute.viaIntermediate(target: .webp, intermediate: .png).needsMetadataPostPass)
    }
}
