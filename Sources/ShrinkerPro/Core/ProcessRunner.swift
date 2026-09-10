import Foundation

enum ProcessRunner {

    /// Runs an executable to completion and returns its exit code and stderr.
    ///
    /// stderr is drained before `waitUntilExit()` — waiting first would deadlock
    /// if the child fills the pipe buffer. stdout goes to /dev/null because none
    /// of the compressors write image data there.
    static func run(_ executable: URL, _ arguments: [String]) throws -> (code: Int32, stderr: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let message = String(decoding: errorData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, message)
    }
}
