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

    /// Opens Terminal.app with an interactive shell inside the container.
    func openShell(in container: Container) {
        guard let dockerPath = cli.path(for: "docker") else { return }
        var command = "export PATH=\(cli.augmentedPATH); "
        if let socket = cli.colimaDockerSocket {
            command += "export DOCKER_HOST=unix://\(socket); "
        }
        // Prefer bash if present, fall back to sh.
        command += "\(dockerPath) exec -it \(container.id) sh -c 'command -v bash >/dev/null 2>&1 && exec bash || exec sh'"
        TerminalLauncher.run(command)
    }
}
