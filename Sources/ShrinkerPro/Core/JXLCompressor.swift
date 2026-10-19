import Foundation

/// cjxl (libjxl 0.12.0, vendored static arm64 — see
/// scripts/build-compressors.sh). Reads PNG, JPEG, or JPEG XL directly; it
/// has no WebP, AVIF or HEIC decoder, so those go through
/// `IntermediateConversionCompressor` first (see `ConversionRouter`).
///
/// **Two encodes, chosen by what cjxl is handed.** A JPEG is transcoded
/// losslessly: cjxl keeps the original's DCT coefficients rather than
/// decoding them to pixels, so nothing is lost, the result is typically
/// around a fifth smaller, and the exact original JPEG can be rebuilt from it
/// byte for byte (checked against the vendored binary with djxl, on a 12.2MB
/// JPEG that came out at 9.8MB). Anything else — a PNG, a JPEG XL, or the
/// carrier a relayed route hands over — is encoded lossily at `quality`.
///
/// Decided here, from the input's extension, rather than by the router,
/// because it is a fact about what cjxl reads rather than a route: a JPEG
/// that arrives through the relay (rotated, resized, cropped) reaches this
/// type as a PNG carrier, and lossy is then the only encode that exists. The
/// one cost is that `quality` does nothing on the lossless path, which is
/// the point of it: a lossless transcode has no quality to choose.
///
/// Both modes are spelled out on every run. cjxl's default for a JPEG input
/// is the lossless transcode, but adding `-q` to it is a hard error ("Must
/// not set quality below 100 in combination with --lossless_jpeg=1"), and
/// relying on which flags happen to imply which mode is how the wrong encode
/// gets picked silently.
///
/// `output` is never the user's file — `ShrinkEngine.shrink` hands every
/// compressor a scratch path it owns. See the contract on `Compressor`.
struct JXLCompressor: Compressor {

    let executable: URL
    var policy: MetadataPolicy = .all
    /// cjxl's `-q`, 0...100. Ignored when the input is a JPEG.
    var quality: Int = 80

    /// Whether cjxl will be handed a JPEG to transcode losslessly.
    static func transcodesLosslessly(_ input: URL) -> Bool {
        ["jpg", "jpeg"].contains(input.pathExtension.lowercased())
    }

    /// ImageIO cannot write JPEG XL, so like WebP there is no post-pass:
    /// whatever cjxl emits is final, and these flags are the only lever.
    ///
    /// `.copyright` is deliberately treated as `.all` here. `-x strip=` names
    /// whole boxes, and the rights tags live inside the same EXIF and XMP
    /// boxes as everything else, so the router never hands cjxl the user's
    /// original under that policy — it authors a PNG carrier holding exactly
    /// the tags to keep, and cjxl then copies all of that. See
    /// `ConversionRouter.cjxlNeedsNoHelp`.
    ///
    /// Stripping on the lossless path needs one more flag. The data cjxl
    /// keeps to rebuild the original JPEG includes the metadata, so it
    /// refuses to strip anything while that data is being kept; turning it
    /// off still transcodes losslessly, but djxl can then only give back the
    /// pixels, not the original file.
    private func metadataArguments(lossless: Bool) -> [String] {
        switch policy {
        case .all, .copyright:
            return []
        case .stripped:
            let strip = ["-x", "strip=exif", "-x", "strip=xmp", "-x", "strip=jumbf"]
            return lossless ? strip + ["--allow_jpeg_reconstruction=0"] : strip
        }
    }

    func compress(input: URL, output: URL) throws {
        let lossless = Self.transcodesLosslessly(input)
        let mode = lossless
            ? ["--lossless_jpeg=1"]
            : ["-q", "\(quality)", "--lossless_jpeg=0"]
        let result = try ProcessRunner.run(
            executable,
            [input.path, output.path] + mode + metadataArguments(lossless: lossless)
        )
        guard result.code == 0 else {
            throw ShrinkError.compressorFailed(tool: "cjxl", code: result.code, message: result.stderr)
        }
    }
}
