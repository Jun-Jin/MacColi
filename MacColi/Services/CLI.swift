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

/// Locates command-line tools and runs them with a PATH that works even when
/// the app is launched from Finder (where Homebrew dirs are not on PATH).
struct CLI {
    static let shared = CLI()

    private let runner = ProcessRunner()

    /// Directories searched for binaries, in priority order.
    private let searchDirs: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.colima/bin",
            "\(home)/.docker/bin",
            "\(home)/.local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
    }()

    /// Absolute path to a tool, or nil if not installed in a known location.
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

    /// PATH value that includes Homebrew and Colima locations.
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
}
