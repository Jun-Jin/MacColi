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
}

/// Process-wide cache of executable directories discovered from the user's login
/// shell. A Finder-launched `.app` only inherits a minimal PATH, so tools
/// installed via Homebrew, the official curl script, asdf, MacPorts, or a custom
/// directory aren't visible without consulting the shell's configured PATH.
final class ShellPaths: @unchecked Sendable {
    static let shared = ShellPaths()
    private let lock = NSLock()
    private var dirs: [String] = []

    var directories: [String] { lock.withLock { dirs } }
    func update(_ newDirs: [String]) { lock.withLock { dirs = newDirs } }
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

    /// Path to Colima's docker socket for the default profile, if present.
    var colimaDockerSocket: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = "\(home)/.colima/default/docker.sock"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Environment for invoking `docker`, routed through Colima's socket when available.
    func dockerEnvironment() -> [String: String] {
        var env = ["PATH": augmentedPATH]
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
        guard let result = try? await runner.run(shell, ["-lc", "echo $PATH"]),
              result.succeeded else { return }
        // Interactive shells may print banners; the PATH is the last non-empty line.
        let line = result.stdout
            .split(whereSeparator: \.isNewline)
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map(String.init) ?? ""
        let dirs = line.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        if !dirs.isEmpty { ShellPaths.shared.update(dirs) }
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
}
