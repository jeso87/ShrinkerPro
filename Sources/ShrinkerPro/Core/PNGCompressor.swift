import Foundation

/// pngquant. Upstream invocation: `pngquant -fo OUT IN`
/// (`-f` overwrite existing, `-o` output path).
///
/// pngquant writes to a private tempname and renames it over `-o` only on
/// success (vendor/src/pngquant/pngquant.c:640-676), and a truncated PNG
/// does leave the target untouched (checked against the vendored binary:
/// exit 25, file byte-identical). That is an observation about this
/// version, not a contract — so it is not what the user's original is
/// protected by. `output` here is never the user's file: `ShrinkEngine`
/// hands every compressor a scratch path it owns. See `Compressor`.
struct PNGCompressor: Compressor {

    let executable: URL

    func compress(input: URL, output: URL) throws {
        let result = try ProcessRunner.run(executable, ["-fo", output.path, input.path])
        guard result.code == 0 else {
            throw ShrinkError.compressorFailed(tool: "pngquant", code: result.code, message: result.stderr)
        }
    }
}
