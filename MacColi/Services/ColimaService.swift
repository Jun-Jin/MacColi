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
        let instance = all.first(where: { $0.name == profile }) ?? all.first
        let name = instance?.name ?? profile
        let yaml = Self.readProfileYAML(profile: name)
        // Need at least one source. A stopped/deleted VM has no `colima list`
        // entry but its `colima.yaml` survives — read from the file so "Reload
        // from colima.yaml" works regardless of whether the VM is running.
        guard instance != nil || yaml != nil else { return nil }

        var config = ColimaConfig(profile: name)
        // Resource fields: prefer the live instance (its actual allocation), but
        // fall back to the saved YAML (plain GiB integers) when the VM isn't up.
        if let cpus = instance?.cpus { config.cpus = cpus }
        else if let v = yaml.flatMap({ Self.yamlScalar("cpu", in: $0) }).flatMap(Int.init) { config.cpus = v }
        if let memory = instance?.memory { config.memoryGiB = Self.gibFromBytes(memory) }
        else if let v = yaml.flatMap({ Self.yamlScalar("memory", in: $0) }).flatMap(Int.init) { config.memoryGiB = v }
        if let disk = instance?.disk { config.diskGiB = Self.gibFromBytes(disk) }
        else if let v = yaml.flatMap({ Self.yamlScalar("disk", in: $0) }).flatMap(Int.init) { config.diskGiB = v }
        if let arch = instance?.arch.flatMap({ VMArch(rawValue: $0) }) { config.arch = arch }
        else if let v = yaml.flatMap({ Self.yamlScalar("arch", in: $0) }).flatMap({ VMArch(rawValue: $0) }) { config.arch = v }
        if let runtime = instance?.runtime.flatMap({ ContainerRuntime(rawValue: $0) }) { config.runtime = runtime }
        else if let v = yaml.flatMap({ Self.yamlScalar("runtime", in: $0) }).flatMap({ ContainerRuntime(rawValue: $0) }) { config.runtime = v }

        if let yaml {
            if let v = Self.yamlScalar("vmType", in: yaml).flatMap({ VMType(rawValue: $0) }) {
                config.vmType = v
            }
            if let m = Self.yamlScalar("mountType", in: yaml).flatMap({ MountType(rawValue: $0) }) {
                config.mountType = m
            }
            if let r = Self.yamlScalar("rosetta", in: yaml) {
                config.vzRosetta = (r == "true")
            }
            if let h = Self.yamlScalar("hostname", in: yaml) { config.hostname = h }
            if let f = Self.yamlScalar("forwardAgent", in: yaml) {
                config.sshAgent = (f == "true")
            }
            if let network = Self.topLevelBlock("network", in: yaml) {
                if let a = Self.indentedScalar("address", in: network) {
                    config.networkAddress = (a == "true")
                }
                config.dnsHosts = Self.indentedMap("dnsHosts", in: network)
                    .map { DNSHostMapping(host: $0.0, target: $0.1) }
            }
            if let k8s = Self.topLevelBlock("kubernetes", in: yaml) {
                if let e = Self.indentedScalar("enabled", in: k8s) {
                    config.kubernetesEnabled = (e == "true")
                }
                if let v = Self.indentedScalar("version", in: k8s) {
                    config.kubernetesVersion = v
                }
            }
        }
        return config
    }

    /// Rounds a byte count to whole GiB (1 GiB = 1024³ bytes).
    private static func gibFromBytes(_ bytes: Int64) -> Int {
        let gib = Int64(1) << 30
        return Int((bytes + gib / 2) / gib)
    }

    /// Candidate Colima home directories in Colima's own resolution order:
    /// `$COLIMA_HOME`, then the legacy `~/.colima` (which Colima prefers and uses
    /// to *ignore* XDG when it exists), then the XDG default
    /// (`$XDG_CONFIG_HOME`/`~/.config` → `colima`). Matching this order is what
    /// keeps the app and the CLI reading/writing the same `colima.yaml`.
    private static func candidateHomes() -> [String] {
        let env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory() as NSString
        var roots: [String] = []
        if let explicit = env["COLIMA_HOME"], !explicit.isEmpty { roots.append(explicit) }
        roots.append(home.appendingPathComponent(".colima"))
        let configBase = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? home.appendingPathComponent(".config")
        roots.append((configBase as NSString).appendingPathComponent("colima"))
        return roots
    }

    /// The home Colima itself operates on: `$COLIMA_HOME` if set; else legacy
    /// `~/.colima` when it exists (Colima ignores XDG in that case); else the XDG
    /// default. A fresh install with none present resolves to XDG — Colima's
    /// modern default — never the legacy path.
    private static func colimaHome() -> String {
        let env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory() as NSString
        if let explicit = env["COLIMA_HOME"], !explicit.isEmpty { return explicit }
        let legacy = home.appendingPathComponent(".colima")
        if FileManager.default.fileExists(atPath: legacy) { return legacy }
        let configBase = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? home.appendingPathComponent(".config")
        return (configBase as NSString).appendingPathComponent("colima")
    }

    /// Path to a profile's `colima.yaml` — an existing file if found across the
    /// candidate homes, otherwise the path under the default home.
    private static func profileYAMLPath(_ profile: String) -> String {
        for root in candidateHomes() {
            let path = (root as NSString).appendingPathComponent("\(profile)/colima.yaml")
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return (colimaHome() as NSString).appendingPathComponent("\(profile)/colima.yaml")
    }

    /// Reads a profile's `colima.yaml`. Returns nil if none exists.
    private static func readProfileYAML(profile: String) -> String? {
        try? String(contentsOfFile: profileYAMLPath(profile), encoding: .utf8)
    }

    /// Extracts a top-level (column-0) scalar from a Colima YAML document,
    /// stripping any inline `#` comment. Top-level-only matching avoids picking
    /// up indented keys nested under other mappings. Returns nil if absent.
    private static func yamlScalar(_ key: String, in yaml: String) -> String? {
        for line in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let first = line.first, first != " ", first != "\t" else { continue }
            guard line.hasPrefix("\(key):") else { continue }
            return scalarValue(of: line, key: key)
        }
        return nil
    }

    /// The lines nested under a top-level mapping `key:`, i.e. everything between
    /// it and the next column-0 line. Returns nil if the key isn't present.
    private static func topLevelBlock(_ key: String, in yaml: String) -> [Substring]? {
        var block: [Substring] = []
        var inBlock = false
        for line in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let isTopLevel = !(line.first == " " || line.first == "\t") && !line.isEmpty
            if inBlock {
                if isTopLevel { break }
                block.append(line)
            } else if isTopLevel && line.hasPrefix("\(key):") {
                inBlock = true
            }
        }
        return inBlock ? block : nil
    }

    /// First scalar matching `key:` within a set of already-extracted block
    /// lines, ignoring indentation. Strips inline comments. Returns nil if absent.
    private static func indentedScalar(_ key: String, in lines: [Substring]) -> String? {
        for line in lines {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            guard trimmed.hasPrefix("\(key):") else { continue }
            return scalarValue(of: trimmed, key: key)
        }
        return nil
    }

    /// Parses an indented `key:` mapping inside block lines into ordered
    /// host/value pairs. Entries are the lines indented deeper than the key;
    /// a dedent ends the mapping.
    private static func indentedMap(_ key: String, in lines: [Substring]) -> [(String, String)] {
        var pairs: [(String, String)] = []
        var keyIndent: Int?
        for line in lines {
            let indent = line.prefix(while: { $0 == " " }).count
            let trimmed = line.drop(while: { $0 == " " })
            guard keyIndent != nil else {
                if trimmed.hasPrefix("\(key):") { keyIndent = indent }
                continue
            }
            if trimmed.isEmpty { continue }
            if indent <= keyIndent! { break }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let host = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
            var rest = trimmed[trimmed.index(after: colon)...]
            if let hash = rest.firstIndex(of: "#") { rest = rest[..<hash] }
            let target = rest.trimmingCharacters(in: .whitespaces)
            if !host.isEmpty, !target.isEmpty { pairs.append((host, target)) }
        }
        return pairs
    }

    /// Returns the value following `key:` on a single line, comment-stripped.
    private static func scalarValue(of line: Substring, key: String) -> String? {
        var value = line.dropFirst(key.count + 1)
        if let hash = value.firstIndex(of: "#") { value = value[..<hash] }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    func start(_ config: ColimaConfig) async throws {
        // Write the managed CA-cert provision block into the profile YAML before
        // starting, so Colima runs it (installs corporate root CAs into the VM)
        // during this start. Best-effort: a write failure shouldn't block start.
        try? reconcileCAProvision(profile: config.profile)
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
        // Boolean flags are passed in explicit `=value` form so toggling an
        // option off overrides whatever the saved config currently holds,
        // rather than relying on flag presence (which can only turn things on).
        args += ["--network-address=\(config.networkAddress)", "--ssh-agent=\(config.sshAgent)"]
        if !config.hostname.isEmpty {
            args += ["--hostname", config.hostname]
        }
        for mapping in config.dnsHosts where !mapping.host.isEmpty && !mapping.target.isEmpty {
            args += ["--dns-host", "\(mapping.host)=\(mapping.target)"]
        }
        args.append("--kubernetes=\(config.kubernetesEnabled)")
        if config.kubernetesEnabled, !config.kubernetesVersion.isEmpty {
            args += ["--kubernetes-version", config.kubernetesVersion]
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

    // MARK: - CA certificates (corporate-proxy provisioning)

    private static let caBeginMarker = "# maccoli:ca-certs:begin (managed by MacColi — do not edit)"
    private static let caEndMarker = "# maccoli:ca-certs:end"

    /// Directory holding MacColi-managed root CA certificates. Kept separate from
    /// any `certs/` directory the user manages by hand so the two never collide.
    private static func managedCertsDir() -> String {
        (colimaHome() as NSString).appendingPathComponent("maccoli-certs")
    }

    /// Filenames of the currently managed root CA certificates.
    func managedCACertificates() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.managedCertsDir())) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted()
    }

    /// Copies a certificate into the managed directory, returning its stored name.
    @discardableResult
    func addCACertificate(from source: URL) throws -> String {
        let dir = Self.managedCertsDir()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let name = Self.sanitizedFilename(source.lastPathComponent)
        let dest = (dir as NSString).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest) {
            try FileManager.default.removeItem(atPath: dest)
        }
        try FileManager.default.copyItem(atPath: source.path, toPath: dest)
        return name
    }

    /// Removes a managed certificate. The VM keeps trusting it until the next start.
    func removeCACertificate(_ name: String) throws {
        let dest = (Self.managedCertsDir() as NSString).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest) {
            try FileManager.default.removeItem(atPath: dest)
        }
    }

    /// True if the profile has *hand-authored* provisioning that would be lost on
    /// VM deletion — used to warn before destructive actions. MacColi's own
    /// managed CA region is excluded: it's regenerated from `maccoli-certs/` on
    /// the next start, so it isn't something the user loses.
    func hasProvisioning(profile: String = "default") -> Bool {
        guard let yaml = Self.readProfileYAML(profile: profile),
              let block = Self.topLevelBlock("provision", in: yaml) else { return false }
        var inManagedRegion = false
        for line in block {
            if line.contains("maccoli:ca-certs:begin") { inManagedRegion = true; continue }
            if line.contains("maccoli:ca-certs:end") { inManagedRegion = false; continue }
            guard !inManagedRegion else { continue }
            if line.drop(while: { $0 == " " }).hasPrefix("-") { return true }
        }
        return false
    }

    /// Writes/updates/removes the MacColi-managed provision block in the profile
    /// YAML to match the current managed certs. No-op if already in sync.
    func reconcileCAProvision(profile: String = "default") throws {
        let certs = managedCACertificates()
        let path = Self.profileYAMLPath(profile)
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let updated = Self.applyManagedProvision(to: existing, certs: certs, certsDir: Self.managedCertsDir())
        guard updated != existing else { return }
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try updated.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Pure text transform: inserts, replaces, or removes the sentinel-delimited
    /// managed provision region so the file installs exactly `certs`, leaving any
    /// user-authored provision entries and the rest of the document untouched.
    static func applyManagedProvision(to yaml: String, certs: [String], certsDir: String) -> String {
        var lines = yaml.isEmpty ? [] : yaml.components(separatedBy: "\n")
        // Drop a single trailing empty element from a final newline so we control it.
        if lines.last == "" { lines.removeLast() }

        // 1. Remove any existing managed region (by sentinel markers).
        if let begin = lines.firstIndex(where: { $0.contains("maccoli:ca-certs:begin") }),
           let end = lines.firstIndex(where: { $0.contains("maccoli:ca-certs:end") }), end >= begin {
            lines.removeSubrange(begin...end)
        }

        let region = certs.isEmpty ? [] : managedRegionLines(certs: certs, certsDir: certsDir)
        guard !region.isEmpty else {
            return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        }

        // 2. Insert under an existing top-level `provision:`, or append a new one.
        if let idx = lines.firstIndex(where: { isProvisionKey($0) }) {
            if lines[idx].trimmingCharacters(in: .whitespaces) == "provision: []" {
                lines[idx] = "provision:"
            }
            lines.insert(contentsOf: region, at: idx + 1)
        } else {
            if let last = lines.last, !last.isEmpty { lines.append("") }
            lines.append("provision:")
            lines.append(contentsOf: region)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func isProvisionKey(_ line: String) -> Bool {
        guard let first = line.first, first != " ", first != "\t" else { return false }
        return line.hasPrefix("provision:")
    }

    /// The managed provision list entry: one `mode: system` script that installs
    /// every managed cert and refreshes the trust store + container runtime.
    private static func managedRegionLines(certs: [String], certsDir: String) -> [String] {
        var script: [String] = []
        for name in certs {
            let src = (certsDir as NSString).appendingPathComponent(name)
            let base = (("maccoli-" + name) as NSString).deletingPathExtension
            script.append("      install -m644 \(shellSingleQuoted(src)) /usr/local/share/ca-certificates/\(base).crt")
        }
        script.append("      update-ca-certificates")
        script.append("      systemctl restart docker 2>/dev/null || systemctl restart containerd 2>/dev/null || true")
        return ["  \(caBeginMarker)", "  - mode: system", "    script: |"] + script + ["  \(caEndMarker)"]
    }

    /// Keeps a copied cert filename safe for a path: basename only, spaces → `_`.
    private static func sanitizedFilename(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        let cleaned = base.replacingOccurrences(of: " ", with: "_")
        return cleaned.isEmpty ? "certificate.pem" : cleaned
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
