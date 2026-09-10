import Foundation
import JavaScriptCore

/// Runs svgo 4.1.0 inside JavaScriptCore.
///
/// svgo ships `dist/svgo.browser.js` as an ES module, which `JSContext` cannot
/// load. `scripts/prepare-svgo.sh` rewrites its single trailing `export{...}`
/// into a `globalThis.svgo = {...}` assignment; this class consumes that
/// rewritten script. JavaScriptCore's JIT requires the
/// `com.apple.security.cs.allow-jit` entitlement under the hardened runtime.
final class SVGCompressor: Compressor {

    private let context: JSContext
    private let lock = NSLock()

    init(scriptURL: URL) throws {
        guard let context = JSContext() else {
            throw ShrinkError.javascriptFailed("could not create a JavaScript context")
        }
        self.context = context

        var thrown: String?
        context.exceptionHandler = { _, exception in
            thrown = exception?.toString() ?? "unknown JavaScript exception"
        }

        let source = try String(contentsOf: scriptURL, encoding: .utf8)
        context.evaluateScript(source, withSourceURL: scriptURL)
        if let thrown { throw ShrinkError.javascriptFailed("loading svgo: \(thrown)") }

        guard context.objectForKeyedSubscript("svgo")?.isObject == true else {
            throw ShrinkError.javascriptFailed(
                "svgo did not register itself — re-run scripts/prepare-svgo.sh"
            )
        }
    }

    func compress(input: URL, output: URL) throws {
        let svg = try String(contentsOf: input, encoding: .utf8)

        // Only JSContext access needs serializing; the lock is released
        // before the disk write below so concurrent compressions (Task 7
        // calls this from a detached task per file) don't needlessly
        // serialize on file I/O.
        let optimized: String = try {
            lock.lock()
            defer { lock.unlock() }

            var thrown: String?
            context.exceptionHandler = { _, exception in
                thrown = exception?.toString() ?? "unknown JavaScript exception"
            }

            context.setObject(svg, forKeyedSubscript: "__shrinkerInput" as NSString)
            let result = context.evaluateScript("globalThis.svgo.optimize(__shrinkerInput).data")
            context.setObject(nil, forKeyedSubscript: "__shrinkerInput" as NSString)

            if let thrown { throw ShrinkError.javascriptFailed(thrown) }
            guard let optimized = result?.toString(), !optimized.isEmpty, optimized != "undefined" else {
                throw ShrinkError.outputNotWritten(output)
            }
            return optimized
        }()

        do {
            try optimized.write(to: output, atomically: true, encoding: .utf8)
        } catch {
            throw ShrinkError.outputNotWritten(output)
        }
    }
}
