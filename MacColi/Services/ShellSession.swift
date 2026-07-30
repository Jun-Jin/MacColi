import Foundation

/// Failures of the shell a workflow run is fed through.
enum ShellSessionError: LocalizedError {
    case ended

    var errorDescription: String? {
        switch self {
        case .ended:
            return "The shell session ended before the step finished — a step may have run “exit”."
        }
    }
}

/// One long-lived `zsh` login shell that a whole workflow run is fed through.
///
/// Steps used to run as independent `zsh -lc` processes, so nothing a step did
/// to its shell outlived it: a variable it assigned, an `export`, a defined
/// function, a `cd` — all gone by the next step. Feeding every step to one
/// session keeps that state, which is what lets `RESULT=$(…)` in one step be
/// read as `$RESULT` in the next.
///
/// Step boundaries come from a per-step sentinel token printed after the body
/// with `$?` appended, not from process exit. That also decouples a step's end
/// from pipe EOF: a step that leaves a background job holding the output pipe
/// no longer stalls the run waiting for a close that never comes.
actor ShellSession {
    /// PID of the session's shell. A step's own commands are its children
    /// (`pgrep -P <pid>`), so every step of a run reports the same value.
    nonisolated let pid: Int32

    private nonisolated let holder: ProcessHolder
    private let input: FileHandle
    private let lines: LineReader

    /// Writing to a pipe whose reader is gone raises SIGPIPE, which by default
    /// kills the *app*, not the write. The session is the only thing here that
    /// writes to a subprocess, and a shell that died mid-run is exactly the
    /// case that would trigger it — so the signal is ignored once and the
    /// failure is taken as the `EPIPE` that `write` then returns.
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    init(environment: [String: String], currentDirectory: String) throws {
        _ = Self.ignoreSIGPIPE

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // `-l` sources login profiles so user-managed env (nvm, asdf, exported
        // variables a Makefile expects, …) is in place, exactly as the former
        // per-step `zsh -lc` did. `-s` reads the script from stdin, which is
        // the channel steps are handed over on, one at a time.
        process.arguments = ["-l", "-s"]
        process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)

        var env = ProcessInfo.processInfo.environment
        env.merge(environment) { _, new in new }
        process.environment = env

        let inPipe = Pipe()
        // Merge stdout and stderr into one pipe so output is interleaved in order.
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = outPipe

        try process.run()

        holder = ProcessHolder(process)
        pid = process.processIdentifier
        input = inPipe.fileHandleForWriting
        lines = LineReader(outPipe.fileHandleForReading)
    }

    /// Runs one step's script in the session and returns its exit status,
    /// forwarding output a line at a time as it arrives.
    ///
    /// Throws `ShellSessionError.ended` when the shell dies mid-step, and
    /// `CancellationError` when the awaiting task is cancelled — which
    /// terminates the shell, ending the run.
    func run(_ script: String,
             onOutput: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        guard holder.process.isRunning else { throw ShellSessionError.ended }

        // Fresh per step, so no step's output can close out a different step,
        // and a step can't fabricate its own end (it never sees the token).
        // UUID's alphabet needs no quoting inside the single quotes below.
        let marker = "__MacColiStepEnd_\(UUID().uuidString)__"
        let payload = script + "\nprintf '%s%s\\n' '\(marker)' \"$?\"\n"
        do {
            try input.write(contentsOf: Data(payload.utf8))
        } catch {
            throw ShellSessionError.ended
        }

        return try await withTaskCancellationHandler {
            while let line = try await lines.next() {
                // A step whose last write had no trailing newline leaves the
                // marker glued to it, so match anywhere in the line and flush
                // the remainder in front of it as output.
                guard let range = line.range(of: marker) else {
                    onOutput(line)
                    continue
                }
                let head = line[..<range.lowerBound]
                if !head.isEmpty { onOutput(String(head)) }
                return Int32(line[range.upperBound...]) ?? -1
            }
            // EOF without a marker: the shell is gone. Cancellation gets there
            // first when it was the cause, so callers can tell the two apart.
            try Task.checkCancellation()
            throw ShellSessionError.ended
        } onCancel: {
            holder.process.terminate()
        }
    }

    /// Ends the session. Closing stdin is the shell's cue to exit on its own;
    /// the terminate is a backstop for one that doesn't.
    func close() {
        try? input.close()
        if holder.process.isRunning { holder.process.terminate() }
    }
}

/// Lets a non-`Sendable` `Process` cross into the `@Sendable` cancellation
/// handler. `terminate()` only sends a signal, so it's safe from any thread.
private final class ProcessHolder: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}

/// Keeps one iterator over the session's merged output alive across steps.
/// `AsyncLineSequence.AsyncIterator` is a struct, so it has to live behind a
/// reference to be advanced by successive `run` calls instead of being copied
/// mid-stream. The session runs one step at a time, so calls are serialised.
private final class LineReader: @unchecked Sendable {
    private var iterator: AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator

    init(_ handle: FileHandle) {
        iterator = handle.bytes.lines.makeAsyncIterator()
    }

    func next() async throws -> String? {
        try await iterator.next()
    }
}
