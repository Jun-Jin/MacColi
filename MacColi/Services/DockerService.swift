import Foundation

/// Wraps the `docker` CLI, routed through Colima's socket.
struct DockerService {
    private let cli = CLI.shared

    var isInstalled: Bool { cli.isInstalled("docker") }

    private func env() -> [String: String] { cli.dockerEnvironment() }

    // MARK: Containers

    func containers() async throws -> [Container] {
        let out = try await cli.run("docker", ["ps", "-a", "--format", "{{json .}}"], environment: env())
        return JSONLines.decode(Container.self, from: out)
    }

    /// One-shot live resource sample for the running containers
    /// (`docker stats --no-stream`). Only running containers appear. This walks a
    /// short sampling window in the daemon (~1-2s), so it is materially slower
    /// than `docker ps` — call it on its own cadence, not the main refresh loop.
    func containerStats() async throws -> [ContainerStats] {
        let out = try await cli.run("docker", ["stats", "--no-stream", "--format", "{{json .}}"],
                                    environment: env())
        return JSONLines.decode(RawStats.self, from: out).map { raw in
            let mem = raw.memUsage.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            return ContainerStats(
                id: raw.id,
                cpuPercent: Format.parsePercent(raw.cpuPerc) ?? 0,
                memUsedBytes: mem.first.flatMap(Format.parseBytes) ?? 0,
                memLimitBytes: mem.count > 1 ? (Format.parseBytes(mem[1]) ?? 0) : 0,
                memPercent: Format.parsePercent(raw.memPerc) ?? 0
            )
        }
    }

    func startContainer(_ id: String) async throws {
        try await cli.run("docker", ["start", id], environment: env())
    }

    func stopContainer(_ id: String) async throws {
        try await cli.run("docker", ["stop", id], environment: env())
    }

    func restartContainer(_ id: String) async throws {
        try await cli.run("docker", ["restart", id], environment: env())
    }

    func removeContainer(_ id: String, force: Bool) async throws {
        var args = ["rm"]
        if force { args.append("-f") }
        args.append(id)
        try await cli.run("docker", args, environment: env())
    }

    func logs(_ id: String, tail: Int = 500) async throws -> String {
        let result = try await cli.runRaw("docker", ["logs", "--tail", String(tail), id], environment: env())
        // Docker writes logs to both stdout and stderr; merge them.
        return result.stdout + result.stderr
    }

    /// Streams a container's logs live (`docker logs --follow`), emitting the last
    /// `tail` lines first and then each new line as it arrives. Returns when the
    /// stream ends (container stopped/removed) or the awaiting task is cancelled —
    /// cancellation terminates the underlying process (see ProcessRunner).
    func followLogs(_ id: String, tail: Int = 500,
                    onLine: @escaping @Sendable (String) -> Void) async {
        _ = try? await cli.runStreaming(
            "docker", ["logs", "--follow", "--tail", String(tail), id],
            environment: env(), onOutput: onLine)
    }

    // MARK: Images

    func images() async throws -> [DockerImage] {
        let out = try await cli.run("docker", ["images", "--format", "{{json .}}"], environment: env())
        return JSONLines.decode(DockerImage.self, from: out)
    }

    /// Pulls an image, forwarding `docker pull` progress line-by-line. Retries
    /// transient daemon errors (e.g. a momentary gRPC `context canceled`, common
    /// right after a Colima start/restart or under memory pressure) a couple of
    /// times before giving up, so a hiccup doesn't surface as a hard failure.
    func pullImage(_ reference: String,
                   onProgress: @escaping @Sendable (String) -> Void) async throws {
        let maxAttempts = 3
        var attempt = 0
        while true {
            attempt += 1
            do {
                try await cli.runStreamingChecked("docker", ["pull", reference],
                                                  environment: env(), onOutput: onProgress)
                return
            } catch let error as CLIError where error.isTransient && attempt < maxAttempts {
                onProgress("Transient daemon error — retrying (\(attempt)/\(maxAttempts - 1))…")
                try? await Task.sleep(for: .seconds(2))
                continue
            }
        }
    }

    func removeImage(_ id: String, force: Bool) async throws {
        var args = ["rmi"]
        if force { args.append("-f") }
        args.append(id)
        try await cli.run("docker", args, environment: env())
    }

    // MARK: Volumes

    /// Lists volumes via `docker system df -v` rather than `docker volume ls` so
    /// each volume carries its on-disk `Size` and `Links` (container reference
    /// count). The verbose df emits the same set of volumes plus those fields;
    /// `{{json .Volumes}}` renders them as a single JSON array (not JSON-lines).
    func volumes() async throws -> [Volume] {
        let out = try await cli.run("docker", ["system", "df", "-v", "--format", "{{json .Volumes}}"],
                                    environment: env())
        guard let data = out.data(using: .utf8),
              let vols = try? JSONDecoder().decode([Volume].self, from: data) else { return [] }
        // df -v returns volumes in an unstable order between calls; sort by name
        // so the list doesn't reshuffle (and flash) on every refresh.
        return vols.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func createVolume(_ name: String) async throws {
        try await cli.run("docker", ["volume", "create", name], environment: env())
    }

    func removeVolume(_ name: String, force: Bool) async throws {
        var args = ["volume", "rm"]
        if force { args.append("-f") }
        args.append(name)
        try await cli.run("docker", args, environment: env())
    }

    // MARK: Networks

    func networks() async throws -> [DockerNetwork] {
        let out = try await cli.run("docker", ["network", "ls", "--format", "{{json .}}"], environment: env())
        // `network ls` returns networks in an unstable order; sort by name so the
        // list doesn't reshuffle on every refresh (mirrors volumes()).
        return JSONLines.decode(DockerNetwork.self, from: out)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func createNetwork(_ name: String) async throws {
        try await cli.run("docker", ["network", "create", name], environment: env())
    }

    /// Removes a network by id. No force flag: docker can't remove a network that
    /// still has attached endpoints, and `--force` only suppresses "not found"
    /// errors — so a real in-use failure surfaces to the user instead.
    func removeNetwork(_ id: String) async throws {
        try await cli.run("docker", ["network", "rm", id], environment: env())
    }

    // MARK: System

    /// Reclaims space with `docker system prune`: removes stopped containers,
    /// dangling images, unused networks, and build cache. `until=<age>` limits
    /// it to objects created before that age (e.g. "24h"). `-f` skips the
    /// interactive y/N prompt, which our non-interactive process can't answer.
    /// Volumes are intentionally left alone (no `--volumes`). Returns docker's
    /// report, whose last line is "Total reclaimed space: …".
    func systemPrune(until: String = "24h") async throws -> String {
        try await cli.run("docker", ["system", "prune", "-f", "--filter", "until=\(until)"],
                          environment: env())
    }

    // MARK: Exec

    /// Opens an interactive shell inside the container in Terminal.app.
    ///
    /// Writes a `.command` script and launches it via LaunchServices (`open`)
    /// rather than driving Terminal with Apple Events. `open` needs no Automation
    /// (Apple Events) TCC permission, which an ad-hoc-signed, frequently-rebuilt
    /// app can't reliably obtain — that path silently failed to open a shell.
    @discardableResult
    func openShell(in container: Container) -> Bool {
        guard let dockerPath = cli.path(for: "docker") else { return false }

        var lines = ["#!/bin/zsh", "export PATH=\(shellQuoted(cli.augmentedPATH))"]
        if let socket = cli.colimaDockerSocket {
            lines.append("export DOCKER_HOST=\(shellQuoted("unix://\(socket)"))")
        }
        lines.append("clear")
        lines.append("echo \(shellQuoted("Connecting to \(container.displayName) (\(container.id))…"))")
        // Prefer bash if present, fall back to sh.
        lines.append("exec \(shellQuoted(dockerPath)) exec -it \(shellQuoted(container.id)) sh -c 'command -v bash >/dev/null 2>&1 && exec bash || exec sh'")
        let script = lines.joined(separator: "\n") + "\n"

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("maccoli-shell-\(container.id).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            return false
        }

        // `open -a Terminal <file.command>` runs the script in a new Terminal window.
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", "Terminal", url.path]
        do { try open.run(); return true } catch { return false }
    }

    /// Wraps a value in single quotes for safe inclusion in a shell script.
    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Raw `docker stats` row as emitted by `--format '{{json .}}'`; the string
/// fields ("3.80%", "467.8MiB / 11.66GiB") are parsed into `ContainerStats`.
private struct RawStats: Decodable {
    let id: String
    let cpuPerc: String
    let memUsage: String
    let memPerc: String

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case cpuPerc = "CPUPerc"
        case memUsage = "MemUsage"
        case memPerc = "MemPerc"
    }
}
