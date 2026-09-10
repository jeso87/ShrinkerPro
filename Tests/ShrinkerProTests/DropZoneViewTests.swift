import XCTest
@testable import ShrinkerPro

/// Covers `DropZoneView.resolveURLs`, the async loop that turns dropped
/// `NSItemProvider`s into file URLs before handing them to
/// `AppModel.handle(urls:)`. Earlier manual verification used `open -a`,
/// which reaches `AppModel.handle(urls:)` directly and never exercises this
/// provider-resolution step — so it had zero coverage from any source until
/// this file. `NSItemProvider` is constructed directly here (no drag
/// simulation needed) and handed to the exact function the drop handler's
/// `.onDrop` closure calls.
final class DropZoneViewTests: XCTestCase {

    private func tempFileURL(named name: String = "sample.txt") throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dropzone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name)
        try Data("contents".utf8).write(to: file)
        return file
    }

    func testSingleValidFileURLResolves() async throws {
        let file = try tempFileURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let provider = NSItemProvider(object: file as NSURL)

        let urls = await DropZoneView.resolveURLs(from: [provider])

        XCTAssertEqual(urls, [file])
    }

    func testMultipleProvidersResolveInOrder() async throws {
        let first = try tempFileURL(named: "first.txt")
        let second = try tempFileURL(named: "second.txt")
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }
        let providers = [
            NSItemProvider(object: first as NSURL),
            NSItemProvider(object: second as NSURL),
        ]

        let urls = await DropZoneView.resolveURLs(from: providers)

        XCTAssertEqual(urls, [first, second], "resolution order must match provider order — it decides list order downstream")
    }

    func testUnresolvableProviderIsSkippedNotFatal() async throws {
        let valid = try tempFileURL()
        defer { try? FileManager.default.removeItem(at: valid.deletingLastPathComponent()) }
        // A provider carrying a plain NSString cannot yield a URL via
        // loadObject(ofClass: URL.self) — it must be skipped, not crash or
        // abort the whole batch.
        let unresolvable = NSItemProvider(object: "not a url" as NSString)
        let providers = [unresolvable, NSItemProvider(object: valid as NSURL)]

        let urls = await DropZoneView.resolveURLs(from: providers)

        XCTAssertEqual(urls, [valid], "the unresolvable provider must be skipped while the valid one still comes through")
    }
}
