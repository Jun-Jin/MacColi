import Foundation

enum CLIError: LocalizedError {
    case notInstalled(String)
    case failed(command: String, message: String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let name):
            return "`\(name)` was not found. Install it with Homebrew (e.g. `brew install \(name)`)."
        case .failed(let command, let message):
            return "`\(command)` failed: \(message)"
        }
    }

    /// True for daemon errors that are typically transient rather than real
    /// failures: a momentary cancellation of dockerd's internal gRPC connection
    /// (`context canceled` / `client connection is closing`), a daemon that
    /// isn't quite ready yet right after a Colima start/restart, or a network
    /// blip. These are worth retrying before surfacing to the user.
    var isTransient: Bool {
        guard case .failed(_, let message) = self else { return false }
        let m = message.lowercased()
        return m.contains("context canceled")
            || m.contains("client connection is closing")
            || m.contains("code = canceled")
            || m.contains("connection refused")
            || m.contains("i/o timeout")
            || m.contains("unexpected eof")
    }

    /// True when the failure is the VM not trusting the TLS certificate served by
    /// the network — typically a corporate proxy doing TLS inspection. Fixed by
    /// installing the proxy's root CA into the VM (Settings → Custom Root CA).
    var isCertificateTrust: Bool {
        guard case .failed(_, let message) = self else { return false }
        let m = message.lowercased()
        return m.contains("x509: certificate signed by unknown authority")
            || m.contains("tls: failed to verify certificate")
            || m.contains("certificate signed by unknown authority")
    }
}

/// Process-wide cache of executable directories discovered from the user's login
/// shell. A Finder-launched `.app` only inherits a minimal PATH, so tools
/// installed via Homebrew, the official curl script, asdf, MacPorts, or a custom
/// directory aren't visible without consulting the shell's configured PATH.
final class ShellPaths: @unchecked Sendable {
    static let shared = ShellPaths()
    private let lock = NSLock()
    private var dirs: [String] = []
    // `COLIMA_HOME` / `XDG_CONFIG_HOME` as seen by the login shell. A
    // Finder-launched app doesn't inherit these, yet they decide which
    // `colima.yaml` and VM the `colima`/`docker` CLIs operate on, so they must
    // be discovered the same way the PATH is.
    private var colimaHomeValue: String?
    private var xdgConfigHomeValue: String?

    var directories: [String] { lock.withLock { dirs } }
    func update(_ newDirs: [String]) { lock.withLock { dirs = newDirs } }

    var colimaHome: String? { lock.withLock { colimaHomeValue } }
    var xdgConfigHome: String? { lock.withLock { xdgConfigHomeValue } }
    func updateColima(home: String?, xdg: String?) {
        lock.withLock { colimaHomeValue = home; xdgConfigHomeValue = xdg }
    }
}

/// Locates command-line tools and runs them with a PATH that works even when
/// the app is launched from Finder.
struct CLI {
    static let shared = CLI()

    private let runner = ProcessRunner()

    /// Well-known locations checked even before the shell PATH is resolved.
    private let baseDirs: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin",   // Homebrew (Apple Silicon)
            "/usr/local/bin",      // Homebrew (Intel) / curl install
            "/opt/local/bin",      // MacPorts
            "\(home)/.colima/bin",
            "\(home)/.docker/bin",
            "\(home)/.local/bin",
            "\(home)/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
    }()

    /// Base locations plus any directories discovered from the login shell,
    /// de-duplicated with base locations taking priority.
    private var searchDirs: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for dir in baseDirs + ShellPaths.shared.directories where seen.insert(dir).inserted {
            result.append(dir)
        }
        return result
    }

    /// Absolute path to a tool, or nil if not installed anywhere we can see.
    func path(for name: String) -> String? {
        for dir in searchDirs {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    func isInstalled(_ name: String) -> Bool { path(for: name) != nil }

    /// PATH value covering every directory we know about.
    var augmentedPATH: String {
        let existing = ProcessInfo.processInfo.environment["PATH"] ?? ""
        var parts = searchDirs
        if !existing.isEmpty { parts.append(existing) }
        return parts.joined(separator: ":")
    }

    /// The Colima home directory the app must operate on, resolved the way Colima
    /// itself does but seeded from the *login shell's* `COLIMA_HOME` /
    /// `XDG_CONFIG_HOME` — which a Finder-launched app doesn't otherwise inherit.
    /// Order: an explicit `COLIMA_HOME` (process env, then login shell) → legacy
    /// `~/.colima` when it exists → the XDG default. Honoring the shell's
    /// `COLIMA_HOME` is what keeps the app and the user's terminal pointed at the
    /// same VM; without it the app falls back to `~/.colima` and sees a different
    /// (or empty) world than `colima` does in Terminal.
    var colimaHome: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path as NSString
        let env = ProcessInfo.processInfo.environment
        if let explicit = env["COLIMA_HOME"], !explicit.isEmpty { return explicit }
        if let discovered = ShellPaths.shared.colimaHome, !discovered.isEmpty { return discovered }
        let legacy = home.appendingPathComponent(".colima")
        if FileManager.default.fileExists(atPath: legacy) { return legacy }
        let xdgBase = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? ShellPaths.shared.xdgConfigHome
            ?? home.appendingPathComponent(".config")
        return (xdgBase as NSString).appendingPathComponent("colima")
    }

    /// Path to Colima's docker socket for the default profile, if present.
    var colimaDockerSocket: String? {
        let path = (colimaHome as NSString).appendingPathComponent("default/docker.sock")
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Environment for invoking `colima`: augmented PATH plus the resolved
    /// `COLIMA_HOME`, so the subprocess targets the same home the app reasons
    /// about rather than re-resolving against its own minimal environment.
    func colimaEnvironment() -> [String: String] {
        ["PATH": augmentedPATH, "COLIMA_HOME": colimaHome]
    }

    /// Environment for invoking `docker`, routed through Colima's socket when available.
    func dockerEnvironment() -> [String: String] {
        var env = colimaEnvironment()
        if let socket = colimaDockerSocket {
            env["DOCKER_HOST"] = "unix://\(socket)"
        }
        return env
    }

    // MARK: - Discovery

    /// Resolves the login shell's PATH (sourcing the user's profile) and caches
    /// the directories, so tools installed by any method become discoverable.
    func discoverShellPaths() async {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // `-l` sources login profiles (where `brew shellenv` typically lives).
        // Emit PATH plus the two Colima-home variables as uniquely-keyed lines so
        // they survive any banner noise an interactive profile may print.
        let script = "echo \"__CLMC_PATH__=$PATH\"; "
            + "echo \"__CLMC_COLIMA_HOME__=$COLIMA_HOME\"; "
            + "echo \"__CLMC_XDG__=$XDG_CONFIG_HOME\""
        guard let result = try? await runner.run(shell, ["-lc", script]),
              result.succeeded else { return }

        func value(forKey key: String) -> String? {
            for raw in result.stdout.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let line = String(raw)
                if line.hasPrefix(key) { return String(line.dropFirst(key.count)) }
            }
            return nil
        }

        if let pathLine = value(forKey: "__CLMC_PATH__=") {
            let dirs = pathLine.split(separator: ":").map(String.init).filter { !$0.isEmpty }
            if !dirs.isEmpty { ShellPaths.shared.update(dirs) }
        }
        let colimaHome = value(forKey: "__CLMC_COLIMA_HOME__=").flatMap { $0.isEmpty ? nil : $0 }
        let xdg = value(forKey: "__CLMC_XDG__=").flatMap { $0.isEmpty ? nil : $0 }
        ShellPaths.shared.updateColima(home: colimaHome, xdg: xdg)
    }

    // MARK: - Running

    /// Runs a tool, returning the raw result without throwing on non-zero exit.
    func runRaw(_ name: String,
                _ arguments: [String],
                environment: [String: String]? = nil) async throws -> CommandResult {
        guard let binary = path(for: name) else { throw CLIError.notInstalled(name) }
        let env = environment ?? ["PATH": augmentedPATH]
        return try await runner.run(binary, arguments, environment: env)
    }

    /// Runs a tool and throws `CLIError.failed` on a non-zero exit, returning stdout otherwise.
    @discardableResult
    func run(_ name: String,
             _ arguments: [String],
             environment: [String: String]? = nil) async throws -> String {
        let result = try await runRaw(name, arguments, environment: environment)
        guard result.succeeded else {
            throw CLIError.failed(command: "\(name) \(arguments.joined(separator: " "))",
                                  message: result.message)
        }
        return result.stdout
    }

    /// Runs a tool, forwarding merged stdout+stderr line-by-line, returning the exit code.
    @discardableResult
    func runStreaming(_ name: String,
                      _ arguments: [String],
                      environment: [String: String]? = nil,
                      onOutput: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        guard let binary = path(for: name) else { throw CLIError.notInstalled(name) }
        let env = environment ?? ["PATH": augmentedPATH]
        return try await runner.runStreaming(binary, arguments, environment: env, onOutput: onOutput)
    }

    /// Streams a tool's merged output line-by-line (so the UI can show live
    /// progress) and throws `CLIError.failed` — carrying the tail of the output
    /// as the message — on a non-zero exit. The throwing counterpart to
    /// `runStreaming`, mirroring how `run` throws over `runRaw`.
    func runStreamingChecked(_ name: String,
                             _ arguments: [String],
                             environment: [String: String]? = nil,
                             onOutput: @escaping @Sendable (String) -> Void) async throws {
        let tail = LineTail()
        let code = try await runStreaming(name, arguments, environment: environment) { line in
            tail.append(line)
            onOutput(line)
        }
        guard code == 0 else {
            throw CLIError.failed(command: "\(name) \(arguments.joined(separator: " "))",
                                  message: tail.snapshot())
        }
    }
}

/// Thread-safe ring of the most recent non-empty output lines. Lets a streamed
/// command build an error message from its tail without retaining all output;
/// written from the background streaming callback, read when it exits non-zero.
private final class LineTail: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private let maxLines = 8

    func append(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.withLock {
            lines.append(trimmed)
            if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        }
    }

    func snapshot() -> String {
        let captured = lock.withLock { lines }
        return captured.isEmpty ? "command failed" : captured.joined(separator: "\n")
    }
}
