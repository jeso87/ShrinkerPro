import XCTest
@testable import ShrinkerPro

/// Finished files dragged out of the app, and each window ignoring its own coming back.
final class FileDragOutTests: XCTestCase {

    private let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("drag-\(UUID().uuidString).min.jpg")

    override func setUpWithError() throws {
        try Data([0xFF, 0xD8, 0xFF]).write(to: file)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: file)
    }

    func testAResultRowCarriesTheFileAndItsName() {
        let provider = FileDragOut.provider(for: file)
        XCTAssertEqual(provider.suggestedName, file.lastPathComponent)
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier("public.jpeg"))
    }

    func testTheMainWindowRecognisesOnlyItsOwnResults() {
        XCTAssertTrue(FileDragOut.isOwnResults([FileDragOut.provider(for: file)]))
        // From Finder, or anywhere else: a real drop.
        XCTAssertFalse(FileDragOut.isOwnResults([NSItemProvider(contentsOf: file)!]))
        // A mix is a real drop too: the other files were meant.
        XCTAssertFalse(FileDragOut.isOwnResults([FileDragOut.provider(for: file), NSItemProvider(contentsOf: file)!]))
        XCTAssertFalse(FileDragOut.isOwnResults([]))
    }

    @MainActor
    func testNoExportDragIsInFlightAtRest() {
        XCTAssertFalse(FileDragOut.isDraggingExports)
    }
}
