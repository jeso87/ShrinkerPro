import XCTest
import AppKit
@testable import ShrinkerPro

/// Covers `AppDelegate`'s URL-queueing logic: plain Swift state machine with
/// no view hierarchy, so it is genuinely testable, unlike most of Task 12
/// (file-type registration, Cmd+O, Open Recent — see task-12-report.md for
/// why those are verified interactively instead).
@MainActor
final class AppDelegateTests: XCTestCase {

    private struct MissingTestResource: Error {}

    /// Mirrors AppModelTests.makeModel(): a real AppModel backed by the
    /// vendored compressors, so `handle(urls:)` genuinely runs to
    /// completion rather than exercising a stub.
    private func makeModel() throws -> AppModel {
        let repoRoot = ProcessInfo.processInfo.environment["SRCROOT"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let vendor = repoRoot.appendingPathComponent("vendor/compressors")
        guard FileManager.default.isExecutableFile(atPath: vendor.appendingPathComponent("cjpeg").path) else {
            XCTFail("compressors not built — run scripts/build-compressors.sh")
            throw MissingTestResource()
        }
        let bundle = Bundle(for: AppDelegateTests.self)
        guard let svgo = bundle.url(forResource: "svgo.jsc", withExtension: "js")
            ?? Bundle.main.url(forResource: "svgo.jsc", withExtension: "js") else {
            XCTFail("svgo.jsc.js not bundled — run scripts/prepare-svgo.sh, then xcodegen generate")
            throw MissingTestResource()
        }
        let engine = try ShrinkEngine(
            helperProvider: { vendor.appendingPathComponent($0) }, svgoScriptURL: svgo
        )
        let settings = Settings(defaults: UserDefaults(suiteName: "appdelegate-\(UUID().uuidString)")!)
        return AppModel(engine: engine, settings: settings, notifier: nil)
    }

    private func stagedPNG() throws -> URL {
        let bundle = Bundle(for: AppDelegateTests.self)
        guard let source = bundle.url(forResource: "sample", withExtension: "png", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "sample", withExtension: "png") else {
            XCTFail("fixture sample.png not found in test bundle — check project.yml's Fixtures resource entry and re-run xcodegen generate")
            throw MissingTestResource()
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let staged = dir.appendingPathComponent("sample.png")
        try FileManager.default.copyItem(at: source, to: staged)
        return staged
    }

    /// A URL that arrives via Finder ("open-file") before `.onAppear` has
    /// assigned `model` must not be dropped — it should be queued and, once
    /// the real model shows up, actually processed.
    func testURLsArrivingBeforeModelIsSetAreQueuedThenProcessed() async throws {
        let delegate = AppDelegate()
        let file = try stagedPNG()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        delegate.application(NSApplication.shared, open: [file])

        let model = try makeModel()
        delegate.model = model

        // `handle(urls:)` dispatches processing onto a detached Task; give
        // it a beat to actually run before asserting.
        for _ in 0..<50 where model.rows.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(model.rows.count, 1, "queued URL should have been handed to the model once it was set")
    }

    /// Once the model is set (even to a real, working one), a later Finder
    /// open is handled immediately — no queueing needed.
    func testURLsArrivingAfterModelIsSetAreHandledImmediately() async throws {
        let delegate = AppDelegate()
        let model = try makeModel()
        delegate.model = model

        let file = try stagedPNG()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        delegate.application(NSApplication.shared, open: [file])

        for _ in 0..<50 where model.rows.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(model.rows.count, 1)
    }

    /// The launch-failure path (ShrinkEngine.init threw, no AppModel exists):
    /// `.onAppear` still runs and assigns `model = nil`. A URL queued before
    /// that point must not be silently discarded — it must reach the
    /// failure-alert hook exactly once, with the right count.
    func testURLsQueuedBeforeConfirmedLaunchFailureTriggerAlertOnce() {
        let delegate = AppDelegate()
        var alertCounts: [Int] = []
        delegate.presentLaunchFailureAlert = { alertCounts.append($0) }

        let fileA = URL(fileURLWithPath: "/tmp/a.png")
        let fileB = URL(fileURLWithPath: "/tmp/b.png")
        delegate.application(NSApplication.shared, open: [fileA, fileB])

        XCTAssertTrue(alertCounts.isEmpty, "should still be queued, not yet alerted — model hasn't been configured")

        delegate.model = nil // .onAppear resolving to the LaunchFailureView branch

        XCTAssertEqual(alertCounts, [2], "queued URLs should surface as one alert reporting both files")
    }

    /// Once launch has been confirmed to have failed (model already set to
    /// nil once), a *subsequent* Finder open must alert immediately rather
    /// than queueing forever with nothing ever able to flush it.
    func testURLArrivingAfterConfirmedLaunchFailureAlertsImmediately() {
        let delegate = AppDelegate()
        delegate.model = nil // confirms the failure state, as .onAppear would

        var alertCounts: [Int] = []
        delegate.presentLaunchFailureAlert = { alertCounts.append($0) }

        delegate.application(NSApplication.shared, open: [URL(fileURLWithPath: "/tmp/c.png")])

        XCTAssertEqual(alertCounts, [1])
    }

    func testApplicationShouldNotTerminateAfterLastWindowClosed() {
        let delegate = AppDelegate()
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared),
                        "upstream keeps the app running after the window closes")
    }

    /// The return value itself is what tells AppKit to run its normal
    /// reopen behavior (restore/recreate a window) when there are no
    /// visible windows — e.g. Cmd+W followed by a Dock-icon click, with no
    /// Cmd+N available since `.newItem` was replaced. Whether that reopen
    /// actually *produces* a working window is not something a unit test
    /// can observe (it depends on AppKit's live window/scene machinery,
    /// not anything this delegate method touches) — that half is verified
    /// interactively in task-12-report.md. This test only pins the
    /// contract this delegate promises AppKit, which is a real assertion
    /// (a regression to `false` would silently break the reopen path).
    func testApplicationShouldHandleReopenReturnsTrue() {
        let delegate = AppDelegate()
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))
    }
}
