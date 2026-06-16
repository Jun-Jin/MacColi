import Foundation

/// Result of running a subprocess.
struct CommandResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { exitCode == 0 }

    /// Best-effort human message from a failed command.
    var message: String {
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { return err }
        let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? "exit code \(exitCode)" : out
    }
}

/// Runs subprocesses asynchronously.
actor ProcessRunner {
    /// Runs a process and returns once it *terminates*.
    ///
    /// Completion is tied to process termination rather than pipe EOF on
    /// purpose: `colima start` (and other tools) spawn long-lived background
    /// daemons that inherit the stdout/stderr pipe descriptors and hold them
    /// open indefinitely. Waiting for EOF would hang forever even though the
    /// command itself has exited, so output is collected incrementally via
    /// readability handlers and the call resolves in `terminationHandler`.
    func run(_ launchPath: String,
             _ arguments: [String],
             environment: [String: String]? = nil) async throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        if let environment { env.merge(environment) { _, new in new } }
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let collector = OutputCollector()
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResult, Error>) in
            outHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { collector.append(data, to: .out) }
            }
            errHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { collector.append(data, to: .err) }
            }

            process.terminationHandler = { proc in
                outHandle.readabilityHandler = nil
                errHandle.readabilityHandler = nil
                let (out, err) = collector.snapshot()
                continuation.resume(returning: CommandResult(
                    exitCode: proc.terminationStatus,
                    stdout: String(decoding: out, as: UTF8.self),
                    stderr: String(decoding: err, as: UTF8.self)
                ))
            }

            do {
                try process.run()
            } catch {
                outHandle.readabilityHandler = nil
                errHandle.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    /// Runs a process, forwarding merged stdout+stderr one line at a time, and
    /// returns the exit code. Used for long-running commands (e.g. `brew install`)
    /// whose progress should stream into the UI.
    func runStreaming(_ launchPath: String,
                      _ arguments: [String],
                      environment: [String: String]? = nil,
                      onOutput: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        if let environment { env.merge(environment) { _, new in new } }
        process.environment = env

        // Merge stdout and stderr into one pipe so output is interleaved in order.
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        // `await` on each line keeps the actor reentrant so other work isn't blocked.
        for try await line in pipe.fileHandleForReading.bytes.lines {
            onOutput(line)
        }

        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// Thread-safe accumulator for subprocess output, written from background
/// readability handlers and read back when the process terminates.
private final class OutputCollector: @unchecked Sendable {
    enum Stream { case out, err }

    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func append(_ data: Data, to stream: Stream) {
        lock.withLock {
            switch stream {
            case .out: out.append(data)
            case .err: err.append(data)
            }
        }
    }

    func snapshot() -> (Data, Data) {
        lock.withLock { (out, err) }
    }
}
