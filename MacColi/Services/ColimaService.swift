import Foundation

/// Wraps the `colima` CLI.
struct ColimaService {
    private let cli = CLI.shared

    var isInstalled: Bool { cli.isInstalled("colima") }

    /// All Colima profiles. Empty when none have been created yet.
    func list() async throws -> [ColimaInstance] {
        let result = try await cli.runRaw("colima", ["list", "--json"], environment: ["PATH": cli.augmentedPATH])
        // `colima list --json` prints one JSON object per line (NDJSON).
        guard result.succeeded else {
            // A fresh install with no profiles can exit non-zero; treat as empty.
            if result.stderr.lowercased().contains("no") { return [] }
            throw CLIError.failed(command: "colima list --json", message: result.message)
        }
        return JSONLines.decode(ColimaInstance.self, from: result.stdout)
    }

    /// The "default" profile if present, else the first one.
    func defaultInstance() async throws -> ColimaInstance? {
        let all = try await list()
        return all.first { $0.name == "default" } ?? all.first
    }

    func start(_ config: ColimaConfig) async throws {
        // `colima start [profile]` accepts the profile positionally; starting the
        // default profile also points the `docker` CLI context at this VM.
        let args = [
            "start", config.profile,
            "--cpu", String(config.cpus),
            "--memory", String(config.memoryGiB),
            "--disk", String(config.diskGiB),
            "--runtime", config.runtime.rawValue,
        ]
        try await cli.run("colima", args, environment: ["PATH": cli.augmentedPATH])
    }

    func stop(profile: String = "default") async throws {
        try await cli.run("colima", ["stop", profile], environment: ["PATH": cli.augmentedPATH])
    }

    func restart(profile: String = "default") async throws {
        try await cli.run("colima", ["restart", profile], environment: ["PATH": cli.augmentedPATH])
    }

    func delete(profile: String = "default") async throws {
        try await cli.run("colima", ["delete", "--force", profile], environment: ["PATH": cli.augmentedPATH])
    }
}
