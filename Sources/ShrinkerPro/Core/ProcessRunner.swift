import Darwin
import Foundation

enum ProcessRunner {

    /// How long, after the child has exited, its stderr may take to reach end-of-file before
    /// what has arrived is taken as all of it.
    static let stderrGrace: DispatchTimeInterval = .seconds(2)

    /// Runs an executable to completion and returns its exit code and stderr.
    ///
    /// stderr is read while the child runs, so a child that fills the pipe buffer never blocks.
    /// stdout and stdin are /dev/null because none of the compressors use them.
    ///
    /// Spawned directly rather than through `Process` (21 Nov 2026). With many compressors
    /// launched at once, as Studio's quality search does, `Process` hung the test host twice:
    /// once reading stderr after the child had exited, its pipe still open somewhere, and once
    /// in `waitUntilExit` for a child already gone. Here:
    /// - the pipe is close-on-exec and the child inherits only its three standard streams, so
    ///   no other launch can hold this one's stderr open;
    /// - the exit is waited for with `waitpid` on this child alone, not a run loop;
    /// - stderr's end-of-file gets a short grace after the exit, then what arrived is the message.
    static func run(_ executable: URL, _ arguments: [String]) throws -> (code: Int32, stderr: String) {
        let result = try spawn(executable, arguments, captureStdout: false, deadline: nil)
        return (result.code, result.stderr)
    }

    /// What `spawn` gives back.
    struct Outcome: Sendable {
        let code: Int32
        let stdout: Data
        let stderr: String
        /// The deadline passed and the child was stopped (SIGTERM, then SIGKILL).
        let timedOut: Bool
    }

    /// How long a child stopped at its deadline gets between SIGTERM and SIGKILL.
    static let killGrace: TimeInterval = 1

    /// Runs `executable` with stderr (and, with `captureStdout`, stdout) captured, stopping it
    /// at `deadline` seconds. Nothing here waits on a dispatch queue: readers are threads of
    /// their own and the exit is `waitpid`, so it can't be starved when every worker is busy,
    /// which is how the quality search runs it.
    static func spawn(
        _ executable: URL, _ arguments: [String], captureStdout: Bool, deadline: TimeInterval?
    ) throws -> Outcome {
        let errPipe = try closeOnExecPipe(executable)
        var outPipe: (read: Int32, write: Int32)?
        if captureStdout {
            do { outPipe = try closeOnExecPipe(executable) } catch {
                close(errPipe.read); close(errPipe.write)
                throw error
            }
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        if let outPipe {
            posix_spawn_file_actions_adddup2(&actions, outPipe.write, 1)
        } else {
            posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, errPipe.write, 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the descriptors set up above reach the child.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable.path, &actions, &attributes, argv, environ)
        close(errPipe.write)
        if let outPipe { close(outPipe.write) }
        guard spawned == 0 else {
            close(errPipe.read)
            if let outPipe { close(outPipe.read) }
            throw launchError(executable, spawned)
        }

        let errors = Collected(), output = Collected()
        Collected.read(errPipe.read, into: errors)
        if let outPipe { Collected.read(outPipe.read, into: output) } else { output.ended.signal() }

        var status: Int32 = 0
        var timedOut = false
        let waited: pid_t
        if let deadline {
            // Polled, so the deadline can be kept; a few milliseconds at a time.
            let end = Date().addingTimeInterval(deadline)
            var reaped = reap(pid, &status, hang: false)
            while reaped == 0 && Date() < end {
                usleep(5_000)
                reaped = reap(pid, &status, hang: false)
            }
            if reaped == 0 {
                timedOut = true
                kill(pid, SIGTERM)
                let grace = Date().addingTimeInterval(killGrace)
                while reaped == 0 && Date() < grace {
                    usleep(5_000)
                    reaped = reap(pid, &status, hang: false)
                }
                if reaped == 0 {
                    kill(pid, SIGKILL)
                    reaped = reap(pid, &status, hang: true)
                }
            }
            waited = reaped
        } else {
            waited = reap(pid, &status, hang: true)
        }
        // Reaped by someone else (ECHILD): the exit code is lost, so it reads as a failure.
        let code: Int32 = waited == pid ? exitCode(status) : -1

        _ = errors.ended.wait(timeout: .now() + stderrGrace)
        _ = output.ended.wait(timeout: .now() + stderrGrace)
        let message = String(decoding: errors.data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Outcome(code: code, stdout: output.data, stderr: message, timedOut: timedOut)
    }

    /// `waitpid` for this child, retried over signals. 0 while it runs (only without `hang`).
    private static func reap(_ pid: pid_t, _ status: inout Int32, hang: Bool) -> pid_t {
        var result: pid_t
        repeat {
            result = waitpid(pid, &status, hang ? 0 : WNOHANG)
        } while result == -1 && errno == EINTR
        return result
    }

    private static func closeOnExecPipe(_ executable: URL) throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw launchError(executable, errno) }
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        return (fds[0], fds[1])
    }

    /// The exit status as `Process.terminationStatus` gives it: the code for a normal exit,
    /// the signal number for a crash.
    private static func exitCode(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : signal
    }

    private static func launchError(_ executable: URL, _ code: Int32) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
            NSLocalizedDescriptionKey: "could not run \(executable.lastPathComponent): \(String(cString: strerror(code)))",
        ])
    }

    /// A pipe's bytes as its reader gets them; `ended` once the pipe has closed.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        let ended = DispatchSemaphore(value: 0)

        func append(_ data: Data) { lock.withLock { buffer.append(data) } }

        var data: Data { lock.withLock { buffer } }

        /// Reads `fd` to its end on a thread of its own, in pieces as they come, so what
        /// arrived is there even if the end never does. Closes `fd`.
        static func read(_ fd: Int32, into collected: Collected) {
            let thread = Thread {
                var buffer = [UInt8](repeating: 0, count: 16 * 1024)
                while true {
                    let count = Darwin.read(fd, &buffer, buffer.count)
                    if count > 0 {
                        collected.append(Data(buffer[0..<count]))
                    } else if count < 0 && errno == EINTR {
                        continue
                    } else {
                        break
                    }
                }
                close(fd)
                collected.ended.signal()
            }
            thread.stackSize = 128 * 1024
            thread.start()
        }
    }
}
