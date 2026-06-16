import Foundation
import Observation

/// Central observable state and command coordinator for the whole app.
///
/// Uses the Observation framework (`@Observable`, macOS 14+): plain `var`
/// properties are tracked automatically, replacing `ObservableObject`/`@Published`.
/// Marked `@MainActor` so all UI-facing state mutates on the main actor.
@Observable
@MainActor
final class AppState {
    // Lifecycle
    private(set) var colimaState: ColimaState = .unknown
    private(set) var dockerInstalled: Bool = true

    // Resources
    private(set) var containers: [Container] = []
    private(set) var images: [DockerImage] = []
    private(set) var volumes: [Volume] = []

    // UI feedback
    private(set) var isBusy: Bool = false
    var busyMessage: String = ""
    var errorMessage: String?

    // In-app installation
    var showInstaller: Bool = false
    private(set) var isInstalling: Bool = false
    private(set) var installLog: String = ""
    private(set) var installError: String?

    // Desired VM configuration. `@AppStorage` can't live inside an `@Observable`
    // class, so persistence is done manually against `UserDefaults` in `didSet`.
    var cpus: Int { didSet { defaults.set(cpus, forKey: "config.cpus") } }
    var memoryGiB: Int { didSet { defaults.set(memoryGiB, forKey: "config.memoryGiB") } }
    var diskGiB: Int { didSet { defaults.set(diskGiB, forKey: "config.diskGiB") } }
    var runtime: ContainerRuntime { didSet { defaults.set(runtime.rawValue, forKey: "config.runtime") } }

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let colima = ColimaService()
    @ObservationIgnored private let docker = DockerService()
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init() {
        let d = UserDefaults.standard
        // `didSet` does not fire during initialization, so no redundant writes here.
        cpus = d.object(forKey: "config.cpus") as? Int ?? 2
        memoryGiB = d.object(forKey: "config.memoryGiB") as? Int ?? 4
        diskGiB = d.object(forKey: "config.diskGiB") as? Int ?? 60
        runtime = (d.string(forKey: "config.runtime")).flatMap(ContainerRuntime.init) ?? .docker
    }

    var config: ColimaConfig {
        ColimaConfig(profile: "default", cpus: cpus, memoryGiB: memoryGiB, diskGiB: diskGiB, runtime: runtime)
    }

    // MARK: - Polling

    /// Begins periodic refresh of status and resources. Safe to call repeatedly.
    func startPolling(interval: TimeInterval = 4) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            // Resolve the login-shell PATH once so tools installed by any method
            // (Homebrew, curl, asdf, MacPorts, …) are discoverable.
            await CLI.shared.discoverShellPaths()
            while !Task.isCancelled {
                // Skip while a lifecycle operation is running so the poll never
                // clobbers a transient state or runs a colima command concurrently.
                if let self, !self.isBusy { await self.refresh() }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Refresh

    /// Refreshes Colima status and, if running, all docker resources.
    func refresh() async {
        dockerInstalled = docker.isInstalled

        guard colima.isInstalled else {
            colimaState = .notInstalled
            clearResources()
            return
        }

        do {
            if let instance = try await colima.defaultInstance() {
                colimaState = instance.isRunning ? .running(instance) : .stopped
            } else {
                colimaState = .stopped
            }
        } catch {
            colimaState = .unknown
        }

        if colimaState.isRunning, dockerInstalled {
            await refreshResources()
        } else {
            clearResources()
        }
    }

    func refreshResources() async {
        async let c = (try? await docker.containers()) ?? []
        async let i = (try? await docker.images()) ?? []
        async let v = (try? await docker.volumes()) ?? []
        let (containers, images, volumes) = await (c, i, v)
        self.containers = containers
        self.images = images
        self.volumes = volumes
    }

    private func clearResources() {
        containers = []
        images = []
        volumes = []
    }

    // MARK: - Colima lifecycle

    func startColima() {
        // Colima's `docker` runtime requires the docker CLI on PATH and fails at
        // start otherwise. Catch it here with an actionable message rather than
        // surfacing Colima's raw fatal error.
        if runtime == .docker, !docker.isInstalled {
            errorMessage = "Colima's Docker runtime needs the `docker` CLI, which isn't on your PATH. "
                + "Use Install to add it, switch the runtime to containerd in Settings, or — if you "
                + "installed it with Homebrew — run `brew link docker`."
            return
        }
        perform("Starting Colima… (first run may take a few minutes)") {
            self.colimaState = .starting
            try await self.colima.start(self.config)
            await self.refresh()
        }
    }

    func stopColima() {
        perform("Stopping Colima…") {
            self.colimaState = .stopping
            try await self.colima.stop()
            await self.refresh()
        }
    }

    func restartColima() {
        perform("Restarting Colima…") {
            self.colimaState = .starting
            try await self.colima.restart()
            await self.refresh()
        }
    }

    func deleteColima() {
        perform("Deleting Colima VM…") {
            self.colimaState = .stopping
            try await self.colima.delete()
            await self.refresh()
        }
    }

    /// Applies the current CPU/memory/disk/runtime config. `colima restart`
    /// reuses the saved config, so changed resources require stop + start.
    func applyConfig() {
        perform("Applying configuration…") {
            self.colimaState = .stopping
            try await self.colima.stop()
            self.colimaState = .starting
            try await self.colima.start(self.config)
            await self.refresh()
        }
    }

    // MARK: - Installation

    /// Installs Colima and the Docker CLI in-app via Homebrew, streaming progress
    /// into `installLog` — no Terminal window. A fully package-manager-free
    /// install would also need Lima and a VM backend, so we drive Homebrew when
    /// it's present rather than reimplementing its dependency resolution.
    func installColima() {
        guard !isInstalling else { showInstaller = true; return }
        showInstaller = true
        isInstalling = true
        installLog = ""
        installError = nil

        Task {
            defer { isInstalling = false }

            guard CLI.shared.isInstalled("brew") else {
                installError = "Homebrew was not found. Install it from https://brew.sh, then try again."
                appendInstall("Homebrew (brew) is required but was not found on your PATH.")
                return
            }

            appendInstall("$ brew install colima docker\n")
            do {
                let code = try await CLI.shared.runStreaming("brew", ["install", "colima", "docker"]) { line in
                    Task { @MainActor in self.appendInstall(line) }
                }
                if code == 0 {
                    appendInstall("\n✅ Done — Colima and Docker are installed.")
                    await CLI.shared.discoverShellPaths()
                    await refresh()
                } else {
                    installError = "Installation failed (exit code \(code)). See the log above."
                }
            } catch {
                installError = error.localizedDescription
                appendInstall("\n❌ \(error.localizedDescription)")
            }
        }
    }

    private func appendInstall(_ text: String) {
        installLog += text + "\n"
    }

    // MARK: - Container actions

    func startContainer(_ c: Container) { resourceAction("Starting \(c.displayName)…") { try await self.docker.startContainer(c.id) } }
    func stopContainer(_ c: Container) { resourceAction("Stopping \(c.displayName)…") { try await self.docker.stopContainer(c.id) } }
    func restartContainer(_ c: Container) { resourceAction("Restarting \(c.displayName)…") { try await self.docker.restartContainer(c.id) } }
    func removeContainer(_ c: Container) { resourceAction("Removing \(c.displayName)…") { try await self.docker.removeContainer(c.id, force: c.isRunning) } }
    func openShell(_ c: Container) {
        if !docker.openShell(in: c) {
            errorMessage = "Couldn't open a shell for \(c.displayName). Is the container running?"
        }
    }

    func logs(for c: Container) async -> String {
        (try? await docker.logs(c.id)) ?? "Failed to read logs."
    }

    // MARK: - Image actions

    func pullImage(_ reference: String) {
        resourceAction("Pulling \(reference)…") {
            try await self.docker.pullImage(reference) { line in
                Task { @MainActor in self.busyMessage = "Pulling \(reference): \(line)" }
            }
        }
    }
    func removeImage(_ image: DockerImage) { resourceAction("Removing \(image.reference)…") { try await self.docker.removeImage(image.id, force: true) } }

    // MARK: - Volume actions

    func createVolume(_ name: String) { resourceAction("Creating \(name)…") { try await self.docker.createVolume(name) } }
    func removeVolume(_ volume: Volume) { resourceAction("Removing \(volume.name)…") { try await self.docker.removeVolume(volume.name, force: false) } }

    // MARK: - Helpers

    /// Runs a lifecycle operation with busy/error handling, then refreshes everything.
    private func perform(_ message: String, _ work: @escaping () async throws -> Void) {
        Task {
            isBusy = true
            busyMessage = message
            errorMessage = nil
            defer { isBusy = false; busyMessage = "" }
            do { try await work() }
            catch {
                errorMessage = error.localizedDescription
                await refresh()
            }
        }
    }

    /// Runs a resource (docker) operation, then refreshes resources only.
    private func resourceAction(_ message: String, _ work: @escaping () async throws -> Void) {
        Task {
            isBusy = true
            busyMessage = message
            errorMessage = nil
            defer { isBusy = false; busyMessage = "" }
            do {
                try await work()
                await refreshResources()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
