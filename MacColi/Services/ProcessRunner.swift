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

/// Runs subprocesses asynchronously. stdout/stderr are drained concurrently so
/// large output (e.g. `docker logs`) cannot deadlock on a full pipe buffer.
actor ProcessRunner {
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

        try process.run()

        // Reading to EOF unblocks only once the process closes its pipe ends
        // (i.e. on termination), so this drains concurrently and avoids deadlock.
        async let outData = Self.readToEnd(outPipe.fileHandleForReading)
        async let errData = Self.readToEnd(errPipe.fileHandleForReading)
        let (out, err) = await (outData, errData)

        process.waitUntilExit() // returns immediately; the reads already saw EOF

        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self)
        )
    }

    /// Reads a file handle to EOF on a background queue, bridged to async.
    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
            let box = UncheckedSendable(handle)
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: box.value.readDataToEndOfFile())
            }
        }
    }
}

/// Transfers a non-Sendable value across a concurrency boundary where we can
/// guarantee single-threaded access by construction.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
