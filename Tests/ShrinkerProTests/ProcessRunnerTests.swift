import XCTest
@testable import ShrinkerPro

/// Every compressor runs through `ProcessRunner`, so a hang here hangs a whole export.
final class ProcessRunnerTests: XCTestCase {
    private let shell = URL(fileURLWithPath: "/bin/sh")

    func testExitCodeAndStderrComeBack() throws {
        let result = try ProcessRunner.run(shell, ["-c", "echo oops >&2; exit 3"])
        XCTAssertEqual(result.code, 3)
        XCTAssertEqual(result.stderr, "oops")
    }

    /// More than a pipe buffer holds: drained as it comes, or the child would block forever.
    func testALotOfStderrNeverBlocks() throws {
        let result = try ProcessRunner.run(shell, ["-c", "i=0; while [ $i -lt 4000 ]; do echo 'a line of noise on stderr' >&2; i=$((i+1)); done"])
        XCTAssertEqual(result.code, 0)
        XCTAssertEqual(result.stderr.split(separator: "\n").count, 4000)
    }

    /// A crash reads as its signal, as `Process.terminationStatus` gave it.
    func testACrashReadsAsItsSignal() throws {
        let result = try ProcessRunner.run(shell, ["-c", "kill -SEGV $$"])
        XCTAssertEqual(result.code, SIGSEGV)
    }

    func testAMissingExecutableThrows() {
        XCTAssertThrowsError(try ProcessRunner.run(URL(fileURLWithPath: "/nonexistent/cjpeg"), []))
    }

    /// Many at once, as the quality search launches them: each gets its own stderr and code.
    func testManyAtOnceKeepTheirOwnResults() {
        let results = UnsafeMutableBufferPointer<Int32>.allocate(capacity: 32)
        defer { results.deallocate() }
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            let result = try? ProcessRunner.run(shell, ["-c", "echo \(index) >&2; exit \(index % 7)"])
            results[index] = result.map { $0.stderr == "\(index)" ? $0.code : -2 } ?? -3
        }
        for index in 0..<32 { XCTAssertEqual(results[index], Int32(index % 7), "run \(index)") }
    }

    /// The hang of 21 Nov 2026: the child exits, but something else still holds stderr's write
    /// end (here a grandchild left running), so the pipe never reaches end-of-file. The run
    /// returns once the child is gone, within the grace, with what it wrote.
    func testAnExitedChildReturnsEvenWhileItsStderrStaysOpen() throws {
        let start = Date()
        let result = try ProcessRunner.run(shell, ["-c", "echo done >&2; sleep 20 & exit 0"])
        XCTAssertEqual(result.code, 0)
        XCTAssertEqual(result.stderr, "done")
        XCTAssertLessThan(Date().timeIntervalSince(start), 8, "waited for the exit, not for the grandchild")
    }
}
