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

    /// Best-effort snapshot of an existing profile's *live* configuration, so the
    /// UI can reflect the real VM rather than the app's stale defaults. Resource
    /// fields (cpu/memory/disk/arch/runtime) come from `colima list --json`;
    /// `vmType`/`rosetta`/`mountType` are absent there, so they're read from the
    /// profile's `colima.yaml` when it can be located. Returns nil if no profile
    /// exists yet.
    func currentConfig(profile: String = "default") async -> ColimaConfig? {
        let all = (try? await list()) ?? []
        guard let instance = all.first(where: { $0.name == profile }) ?? all.first else {
            return nil
        }
        var config = ColimaConfig(profile: instance.name)
        if let cpus = instance.cpus { config.cpus = cpus }
        if let memory = instance.memory { config.memoryGiB = Self.gibFromBytes(memory) }
        if let disk = instance.disk { config.diskGiB = Self.gibFromBytes(disk) }
        if let arch = instance.arch.flatMap({ VMArch(rawValue: $0) }) { config.arch = arch }
        if let runtime = instance.runtime.flatMap({ ContainerRuntime(rawValue: $0) }) {
            config.runtime = runtime
        }
        if let yaml = Self.readProfileYAML(profile: instance.name) {
            if let v = Self.yamlScalar("vmType", in: yaml).flatMap({ VMType(rawValue: $0) }) {
                config.vmType = v
            }
            if let m = Self.yamlScalar("mountType", in: yaml).flatMap({ MountType(rawValue: $0) }) {
                config.mountType = m
            }
            if let r = Self.yamlScalar("rosetta", in: yaml) {
                config.vzRosetta = (r == "true")
            }
        }
        return config
    }

    /// Rounds a byte count to whole GiB (1 GiB = 1024³ bytes).
    private static func gibFromBytes(_ bytes: Int64) -> Int {
        let gib = Int64(1) << 30
        return Int((bytes + gib / 2) / gib)
    }

    /// Reads a profile's `colima.yaml`, trying `$COLIMA_HOME`, then Colima's
    /// XDG default (`$XDG_CONFIG_HOME`/`~/.config` → `colima`), then the legacy
    /// `~/.colima`. Returns nil if none exist.
    private static func readProfileYAML(profile: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory() as NSString
        var roots: [String] = []
        if let explicit = env["COLIMA_HOME"], !explicit.isEmpty { roots.append(explicit) }
        let configBase = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? home.appendingPathComponent(".config")
        roots.append((configBase as NSString).appendingPathComponent("colima"))
        roots.append(home.appendingPathComponent(".colima"))
        for root in roots {
            let path = (root as NSString).appendingPathComponent("\(profile)/colima.yaml")
            if let yaml = try? String(contentsOfFile: path, encoding: .utf8) { return yaml }
        }
        return nil
    }

    /// Extracts a top-level (column-0) scalar from a Colima YAML document,
    /// stripping any inline `#` comment. Top-level-only matching avoids picking
    /// up indented keys nested under other mappings. Returns nil if absent.
    private static func yamlScalar(_ key: String, in yaml: String) -> String? {
        for line in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let first = line.first, first != " ", first != "\t" else { continue }
            guard line.hasPrefix("\(key):") else { continue }
            var value = line.dropFirst(key.count + 1)
            if let hash = value.firstIndex(of: "#") { value = value[..<hash] }
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    func start(_ config: ColimaConfig) async throws {
        // `colima start [profile]` accepts the profile positionally; starting the
        // default profile also points the `docker` CLI context at this VM.
        var args = [
            "start", config.profile,
            "--cpu", String(config.cpus),
            "--memory", String(config.memoryGiB),
            "--disk", String(config.diskGiB),
            "--runtime", config.runtime.rawValue,
            "--arch", config.arch.rawValue,
            "--vm-type", config.vmType.rawValue,
            "--mount-type", config.mountType.rawValue,
        ]
        // `--vz-rosetta` is a boolean flag and only valid with the `vz` VM type.
        if config.vzRosetta && config.vmType == .vz {
            args.append("--vz-rosetta")
        }
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
