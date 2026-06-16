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

    // MARK: Images

    func images() async throws -> [DockerImage] {
        let out = try await cli.run("docker", ["images", "--format", "{{json .}}"], environment: env())
        return JSONLines.decode(DockerImage.self, from: out)
    }

    func pullImage(_ reference: String) async throws {
        try await cli.run("docker", ["pull", reference], environment: env())
    }

    func removeImage(_ id: String, force: Bool) async throws {
        var args = ["rmi"]
        if force { args.append("-f") }
        args.append(id)
        try await cli.run("docker", args, environment: env())
    }

    // MARK: Volumes

    func volumes() async throws -> [Volume] {
        let out = try await cli.run("docker", ["volume", "ls", "--format", "{{json .}}"], environment: env())
        return JSONLines.decode(Volume.self, from: out)
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
