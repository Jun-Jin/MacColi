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

    // Live stats (running containers only), keyed by short container id, plus
    // rolling per-container and VM-wide history for sparklines. Populated by a
    // dedicated, slower loop that runs only while the Containers panel is on
    // screen — `docker stats` is too costly for the main refresh cadence.
    private(set) var stats: [String: ContainerStats] = [:]
    private(set) var cpuHistory: [String: [Double]] = [:]
    private(set) var memHistory: [String: [Double]] = [:]
    private(set) var vmCPUHistory: [Double] = []
    private(set) var vmMemHistory: [Double] = []

    // User switch for live monitoring. While off, the stats loop never runs, so
    // there is zero `docker stats` cost — and the summary/sparklines disappear.
    // Deliberately starts off every launch (not persisted): monitoring is an
    // explicit, in-session opt-in, so opening the app never incurs stats cost.
    var monitoringEnabled = false {
        didSet {
            reconcileStatsMonitoring()
            if !monitoringEnabled { clearStats() }
        }
    }

    // UI feedback
    private(set) var isBusy: Bool = false
    var busyMessage: String = ""
    var errorMessage: String?
    // A transient success note (e.g. space reclaimed by a prune), shown in the
    // status banner until the user dismisses it or the next action clears it.
    var infoMessage: String?
    // Set when an operation failed because the VM doesn't trust the network's
    // TLS certificate; drives the "add a CA" affordance in the error banner.
    var caCertIssue: Bool = false
    // A panel the UI should navigate to (e.g. jumping to Settings from a banner).
    var requestedPanel: Panel?
    // Bumped by the ⌘F "Find" menu command. The visible resource panel observes
    // this and focuses its search field — the bridge from an app-level keyboard
    // command to the active view's local focus state.
    var findRequestToken = 0

    // Managed root CA certificates installed into the VM (corporate proxy fix).
    private(set) var caCertificates: [String] = []

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
    var arch: VMArch { didSet { defaults.set(arch.rawValue, forKey: "config.arch") } }
    var vmType: VMType {
        didSet {
            defaults.set(vmType.rawValue, forKey: "config.vmType")
            // virtiofs requires the vz backend; fall back to sshfs (Colima's qemu
            // default) so the selection can't form a combination Colima rejects.
            if vmType != .vz, mountType == .virtiofs { mountType = .sshfs }
        }
    }
    var vzRosetta: Bool { didSet { defaults.set(vzRosetta, forKey: "config.vzRosetta") } }
    var mountType: MountType { didSet { defaults.set(mountType.rawValue, forKey: "config.mountType") } }
    var hostname: String { didSet { defaults.set(hostname, forKey: "config.hostname") } }
    var networkAddress: Bool { didSet { defaults.set(networkAddress, forKey: "config.networkAddress") } }
    var sshAgent: Bool { didSet { defaults.set(sshAgent, forKey: "config.sshAgent") } }
    var kubernetesEnabled: Bool { didSet { defaults.set(kubernetesEnabled, forKey: "config.kubernetesEnabled") } }
    var kubernetesVersion: String { didSet { defaults.set(kubernetesVersion, forKey: "config.kubernetesVersion") } }
    // One `host=target` per line; parsed into `DNSHostMapping`s for the config.
    var dnsHostsText: String { didSet { defaults.set(dnsHostsText, forKey: "config.dnsHosts") } }

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let colima = ColimaService()
    @ObservationIgnored private let docker = DockerService()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    // The stats loop runs only when both are true: the Containers panel is
    // visible and the window is frontmost. See reconcileStatsMonitoring.
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var statsPanelVisible = false
    @ObservationIgnored private var statsSceneActive = true
    // Samples retained per series for sparklines.
    @ObservationIgnored private static let historyLength = 40
    // Polling cadence (seconds): fast while the dashboard is frontmost, slow when
    // it isn't. Each poll spawns colima/docker subprocesses that round-trip into
    // the VM, so backing off when no one is watching avoids needless VM (and
    // host disk/security-daemon) churn. See setActivePolling.
    @ObservationIgnored private var pollInterval: TimeInterval = 4
    // Seed Settings from the real VM only once per launch, so polling never
    // clobbers edits the user is making in the Settings panel.
    @ObservationIgnored private var didSyncLiveConfig = false

    init() {
        let d = UserDefaults.standard
        // `didSet` does not fire during initialization, so no redundant writes here.
        cpus = d.object(forKey: "config.cpus") as? Int ?? 2
        memoryGiB = d.object(forKey: "config.memoryGiB") as? Int ?? 4
        diskGiB = d.object(forKey: "config.diskGiB") as? Int ?? 60
        runtime = (d.string(forKey: "config.runtime")).flatMap(ContainerRuntime.init) ?? .docker
        arch = (d.string(forKey: "config.arch")).flatMap(VMArch.init) ?? .aarch64
        vmType = (d.string(forKey: "config.vmType")).flatMap(VMType.init) ?? .vz
        vzRosetta = d.object(forKey: "config.vzRosetta") as? Bool ?? true
        mountType = (d.string(forKey: "config.mountType")).flatMap(MountType.init) ?? .virtiofs
        hostname = d.string(forKey: "config.hostname") ?? ""
        networkAddress = d.object(forKey: "config.networkAddress") as? Bool ?? false
        sshAgent = d.object(forKey: "config.sshAgent") as? Bool ?? false
        kubernetesEnabled = d.object(forKey: "config.kubernetesEnabled") as? Bool ?? false
        kubernetesVersion = d.string(forKey: "config.kubernetesVersion") ?? ""
        dnsHostsText = d.string(forKey: "config.dnsHosts") ?? ""
        caCertificates = colima.managedCACertificates()
    }

    var config: ColimaConfig {
        ColimaConfig(
            profile: "default", cpus: cpus, memoryGiB: memoryGiB, diskGiB: diskGiB, runtime: runtime,
            arch: arch, vmType: vmType, vzRosetta: vzRosetta, mountType: mountType,
            hostname: hostname.trimmingCharacters(in: .whitespaces),
            networkAddress: networkAddress,
            dnsHosts: Self.parseDNSHosts(dnsHostsText),
            sshAgent: sshAgent,
            kubernetesEnabled: kubernetesEnabled,
            kubernetesVersion: kubernetesVersion.trimmingCharacters(in: .whitespaces)
        )
    }

    /// Parses the `host=target` lines of the DNS-hosts editor into mappings,
    /// skipping blanks and malformed entries.
    private static func parseDNSHosts(_ text: String) -> [DNSHostMapping] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let host = parts[0].trimmingCharacters(in: .whitespaces)
            let target = parts[1].trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty, !target.isEmpty else { return nil }
            return DNSHostMapping(host: host, target: target)
        }
    }

    // MARK: - Polling

    /// Begins periodic refresh of status and resources. Safe to call repeatedly.
    /// The loop re-reads `pollInterval` each iteration so the cadence can change
    /// live (see setActivePolling) without tearing down the task.
    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            // Resolve the login-shell PATH once so tools installed by any method
            // (Homebrew, curl, asdf, MacPorts, …) are discoverable.
            await CLI.shared.discoverShellPaths()
            while !Task.isCancelled {
                guard let self else { return }
                // Skip while a lifecycle operation is running so the poll never
                // clobbers a transient state or runs a colima command concurrently.
                if !self.isBusy { await self.refresh() }
                try? await Task.sleep(for: .seconds(self.pollInterval))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Switches polling between a fast cadence (dashboard frontmost) and a slow
    /// one (window backgrounded or closed). When the window isn't visible there's
    /// nothing live to update, so we poll rarely — just often enough to keep the
    /// menu-bar status roughly current — instead of spawning subprocesses into
    /// the VM every few seconds. Returning to the foreground refreshes at once.
    func setActivePolling(_ active: Bool) {
        statsSceneActive = active
        reconcileStatsMonitoring()
        let target: TimeInterval = active ? 4 : 30
        guard target != pollInterval else { return }
        pollInterval = target
        // The loop may be mid-sleep; refresh now so the foreground shows current
        // data immediately rather than waiting out the previous (slow) delay.
        if active, !isBusy { Task { await refresh() } }
    }

    // MARK: - Live stats monitoring

    /// Called by the Containers panel as it appears/disappears. Stats are only
    /// worth collecting while that panel is on screen, so this gates the
    /// expensive `docker stats` loop on visibility (combined with scene focus).
    func setStatsPanelVisible(_ visible: Bool) {
        statsPanelVisible = visible
        reconcileStatsMonitoring()
    }

    /// Starts the stats loop when the panel is visible and the window is
    /// frontmost; tears it down otherwise. Idempotent.
    private func reconcileStatsMonitoring() {
        let shouldRun = monitoringEnabled && statsPanelVisible && statsSceneActive
        if shouldRun {
            guard statsTask == nil else { return }
            statsTask = Task { [weak self] in await self?.runStatsLoop() }
        } else {
            statsTask?.cancel()
            statsTask = nil
        }
    }

    /// Samples `docker stats` until cancelled. The call itself costs ~1-2 s (the
    /// daemon's own sampling window, scaling with container count).
    ///
    /// The loop warms up: the first few samples come back-to-back (no sleep) so a
    /// freshly-toggled-on monitor fills its bars and sparklines within a couple
    /// of cycles instead of over ~10 s. It then settles to a 5 s sleep (~7 s
    /// cycle, ~28 % daemon duty) — slower than the 4 s lifecycle poll on purpose:
    /// this is trend data you glance at, not action feedback you wait on.
    private func runStatsLoop() async {
        var sample = 0
        while !Task.isCancelled {
            if colimaState.isRunning, dockerInstalled,
               let snapshot = try? await docker.containerStats(),
               // The ~2 s call may have been cancelled mid-flight (e.g. monitoring
               // toggled off); don't repopulate the just-cleared state.
               !Task.isCancelled {
                applyStats(snapshot)
            }
            // No pause for the first few samples so the sparkline gets points
            // fast right after the loop starts; back off to 5 s once warmed up.
            sample += 1
            if sample >= 4 { try? await Task.sleep(for: .seconds(5)) }
        }
    }

    /// Folds a fresh sample into the current map and the rolling histories,
    /// dropping history for containers that are no longer running.
    private func applyStats(_ snapshot: [ContainerStats]) {
        let live = Set(snapshot.map(\.id))
        var byID: [String: ContainerStats] = [:]
        for s in snapshot {
            byID[s.id] = s
            cpuHistory[s.id, default: []].appendCapped(s.cpuPercent, max: Self.historyLength)
            memHistory[s.id, default: []].appendCapped(s.memPercent, max: Self.historyLength)
        }
        stats = byID
        cpuHistory = cpuHistory.filter { live.contains($0.key) }
        memHistory = memHistory.filter { live.contains($0.key) }
        if let usage = computeVMUsage(snapshot) {
            vmCPUHistory.appendCapped(usage.cpuFraction * 100, max: Self.historyLength)
            vmMemHistory.appendCapped(usage.memFraction * 100, max: Self.historyLength)
        }
    }

    /// Sums running containers' usage against the VM's allocated budget (cores
    /// and memory from `colima list --json`). Nil unless the VM is running.
    private func computeVMUsage(_ snapshot: [ContainerStats]) -> VMUsage? {
        guard case let .running(instance) = colimaState else { return nil }
        let coresUsed = snapshot.reduce(0.0) { $0 + $1.cpuPercent } / 100.0
        let memUsed = snapshot.reduce(Int64(0)) { $0 + $1.memUsedBytes }
        return VMUsage(
            cpuCoresUsed: coresUsed,
            cpuCoresTotal: instance.cpus ?? 0,
            memUsedBytes: memUsed,
            // Fall back to the limit docker reports when colima omits memory.
            memTotalBytes: instance.memory ?? (snapshot.map(\.memLimitBytes).max() ?? 0)
        )
    }

    /// Current VM-wide usage for the summary header.
    var vmUsage: VMUsage? { computeVMUsage(Array(stats.values)) }

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
                await syncConfigFromLiveVM()
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

    /// Seeds the editable Settings fields from the real VM the first time an
    /// existing profile is observed. Without this, the panel shows the app's
    /// hardcoded defaults (2 CPU / 4 GiB / 60 GiB) regardless of the actual VM,
    /// so "Apply & Restart" would shrink a larger VM (and error on disk, which
    /// can only grow). Runs once per launch — the guard is set only on a
    /// successful read, so it retries until a profile exists, then stops so it
    /// never overwrites in-progress edits.
    private func syncConfigFromLiveVM() async {
        guard !didSyncLiveConfig else { return }
        guard let live = await colima.currentConfig() else { return }
        didSyncLiveConfig = true
        applyLiveConfig(live)
    }

    /// Manually re-reads the live VM's `colima.yaml` and overwrites the editable
    /// Settings fields — the on-demand counterpart to the once-per-launch
    /// auto-sync. Lets the user pull in edits made to `colima.yaml` outside the
    /// app without relaunching; any unsaved edits in the panel are intentionally
    /// discarded in favor of what's on disk.
    func reloadConfigFromVM() {
        Task {
            isBusy = true
            busyMessage = "Reloading from colima.yaml…"
            errorMessage = nil
            defer { isBusy = false; busyMessage = "" }
            guard let live = await colima.currentConfig() else {
                errorMessage = "No Colima profile was found to read configuration from."
                return
            }
            applyLiveConfig(live)
            didSyncLiveConfig = true
            refreshCACertificates()
        }
    }

    /// Copies a config snapshot into the editable Settings fields.
    private func applyLiveConfig(_ live: ColimaConfig) {
        cpus = live.cpus
        memoryGiB = live.memoryGiB
        diskGiB = live.diskGiB
        runtime = live.runtime
        arch = live.arch
        vmType = live.vmType
        vzRosetta = live.vzRosetta
        mountType = live.mountType
        hostname = live.hostname
        networkAddress = live.networkAddress
        sshAgent = live.sshAgent
        kubernetesEnabled = live.kubernetesEnabled
        kubernetesVersion = live.kubernetesVersion
        dnsHostsText = live.dnsHosts.map { "\($0.host)=\($0.target)" }.joined(separator: "\n")
    }

    func refreshResources() async {
        async let c = try? await docker.containers()
        async let i = try? await docker.images()
        async let v = try? await docker.volumes()
        let (containers, images, volumes) = await (c, i, v)
        // Replace a list only on a successful read. A transient docker failure —
        // e.g. the socket briefly gone while the VM (re)starts, which returns nil —
        // keeps the last-known list instead of flashing the panel empty. A real
        // empty (docker returns []) still updates; a stopped VM is cleared by
        // refresh()'s clearResources() branch, not here.
        if let containers { self.containers = containers }
        if let images { self.images = images }
        if let volumes { self.volumes = volumes }
    }

    /// Refreshes resources, retrying on a short cadence while docker is still
    /// coming up after a (re)start. The daemon's socket can lag the VM's
    /// "running" status by several seconds; without this the panels stay on their
    /// last-known contents until the next (possibly 30 s background) poll. Stops
    /// as soon as a container read succeeds, or after the window elapses.
    private func refreshResourcesUntilReady(maxAttempts: Int = 15) async {
        for attempt in 0..<maxAttempts {
            if Task.isCancelled { return }
            if (try? await docker.containers()) != nil {
                await refreshResources()
                return
            }
            if attempt < maxAttempts - 1 { try? await Task.sleep(for: .seconds(2)) }
        }
    }

    private func clearResources() {
        containers = []
        images = []
        volumes = []
        clearStats()
    }

    private func clearStats() {
        stats = [:]
        cpuHistory = [:]
        memHistory = [:]
        vmCPUHistory = []
        vmMemHistory = []
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
        runToRunning("Starting Colima… (first run may take a few minutes)") {
            self.colimaState = .starting
            try await self.colima.start(self.config)
        }
    }

    func stopColima() {
        perform("Stopping Colima…") {
            self.colimaState = .stopping
            try await self.colima.stop()
            await self.refresh()
        }
    }

    /// Restarts by an explicit stop → bare start (reusing the saved config) rather
    /// than `colima restart`. The synchronous stop guarantees the VM is observed
    /// down, so runToRunning's watcher reliably catches the down→up edge and drops
    /// the busy overlay the moment the VM is back — instead of missing the brief
    /// down window `colima restart` exposes and blocking until the command returns.
    func restartColima() {
        runToRunning("Restarting Colima…") {
            self.colimaState = .stopping
            try await self.colima.stop()
            self.colimaState = .starting
            try await self.colima.start()
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
        runToRunning("Applying configuration…") {
            self.colimaState = .stopping
            try await self.colima.stop()
            self.colimaState = .starting
            try await self.colima.start(self.config)
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

    /// Streams `c`'s logs live until the stream ends or the caller's task is
    /// cancelled. Lines arrive on a background thread, so `onLine` must be safe
    /// to call off the main actor (the log view buffers them and renders on a timer).
    func followLogs(for c: Container, onLine: @escaping @Sendable (String) -> Void) async {
        await docker.followLogs(c.id, onLine: onLine)
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

    // MARK: - System maintenance

    /// Runs `docker system prune --filter until=24h`: reclaims stopped
    /// containers, dangling images, unused networks, and build cache older than
    /// 24 hours (volumes untouched), then surfaces the reclaimed space as an
    /// info note. Not routed through `resourceAction` because it reports a
    /// success summary rather than just refreshing.
    func pruneSystem() {
        Task {
            isBusy = true
            busyMessage = "Cleaning up data older than 24h…"
            errorMessage = nil
            infoMessage = nil
            defer { isBusy = false; busyMessage = "" }
            do {
                let report = try await docker.systemPrune(until: "24h")
                await refreshResources()
                infoMessage = Self.reclaimedSummary(from: report)
            } catch {
                errorMessage = describe(error)
            }
        }
    }

    /// Extracts docker's "Total reclaimed space: …" line from a prune report,
    /// falling back to a generic note if the format ever changes.
    private static func reclaimedSummary(from report: String) -> String {
        let summary = report
            .split(whereSeparator: \.isNewline)
            .last { $0.localizedCaseInsensitiveContains("reclaimed space") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return summary ?? "Cleanup complete."
    }

    // MARK: - Bulk actions

    func startContainers(_ cs: [Container]) { bulkAction(cs, "Starting \(cs.count) containers…") { try await self.docker.startContainer($0.id) } }
    func stopContainers(_ cs: [Container]) { bulkAction(cs, "Stopping \(cs.count) containers…") { try await self.docker.stopContainer($0.id) } }
    func restartContainers(_ cs: [Container]) { bulkAction(cs, "Restarting \(cs.count) containers…") { try await self.docker.restartContainer($0.id) } }
    func removeContainers(_ cs: [Container]) { bulkAction(cs, "Removing \(cs.count) containers…") { try await self.docker.removeContainer($0.id, force: $0.isRunning) } }
    func removeImages(_ imgs: [DockerImage]) { bulkAction(imgs, "Removing \(imgs.count) images…") { try await self.docker.removeImage($0.id, force: true) } }
    func removeVolumes(_ vols: [Volume]) { bulkAction(vols, "Removing \(vols.count) volumes…") { try await self.docker.removeVolume($0.name, force: false) } }

    /// Applies `work` to each selected item under a single busy overlay, then
    /// refreshes resources once. Individual failures don't abort the run — the
    /// rest still proceed — and are surfaced together: the first error's message
    /// plus a count, rather than one banner per failed item.
    private func bulkAction<Item: Sendable>(_ items: [Item], _ message: String,
                                            _ work: @escaping (Item) async throws -> Void) {
        guard !items.isEmpty else { return }
        Task {
            isBusy = true
            busyMessage = message
            errorMessage = nil
            infoMessage = nil
            defer { isBusy = false; busyMessage = "" }
            var firstError: Error?
            var failures = 0
            for item in items {
                do { try await work(item) }
                catch {
                    failures += 1
                    if firstError == nil { firstError = error }
                }
            }
            await refreshResources()
            if let firstError {
                let suffix = failures > 1 ? " (\(failures) of \(items.count) failed)" : ""
                errorMessage = describe(firstError) + suffix
            }
        }
    }

    // MARK: - Root CA certificates (corporate proxy fix)

    /// Imports a root CA certificate so it's installed into the VM on the next
    /// start. Security-scoped access is required because the file comes from an
    /// NSOpenPanel/fileImporter outside the app's sandbox container.
    func addCACertificate(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try colima.addCACertificate(from: url)
            refreshCACertificates()
            // The user just supplied the fix; clear the prompt and re-arm so the
            // banner returns only if a fresh start still fails.
            caCertIssue = false
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't add the certificate: \(error.localizedDescription)"
        }
    }

    /// Removes a managed CA certificate. It stays in the VM until the next start
    /// rewrites the provision block.
    func removeCACertificate(_ name: String) {
        do {
            try colima.removeCACertificate(name)
            refreshCACertificates()
        } catch {
            errorMessage = "Couldn't remove the certificate: \(error.localizedDescription)"
        }
    }

    private func refreshCACertificates() {
        caCertificates = colima.managedCACertificates()
    }

    /// True when the profile's `colima.yaml` carries a hand-written `provision`
    /// block (beyond MacColi's managed CA region), so deleting the VM also
    /// discards setup the user maintains outside this app.
    var hasCustomProvisioning: Bool { colima.hasProvisioning() }

    // MARK: - Helpers

    /// Turns a raw error into a user-facing message, and flags the CA-trust case
    /// so the banner can offer to import a certificate. Returns the message and
    /// whether it was a certificate-trust failure.
    private func describe(_ error: Error) -> String {
        if let cliError = error as? CLIError, cliError.isCertificateTrust {
            caCertIssue = true
            return "The VM doesn't trust the network's TLS certificate — usually a "
                + "corporate proxy inspecting traffic. Add the proxy's root CA in "
                + "Settings, then try again."
        }
        return error.localizedDescription
    }

    /// Runs a lifecycle operation that ends with the VM running (start / restart /
    /// apply), while a parallel watcher flips the UI to "running" and drops the
    /// busy overlay as soon as the VM reports up — instead of blocking until the
    /// command returns, which waits out post-boot provisioning (CA trust store,
    /// Kubernetes, …) long after the VM is actually usable.
    ///
    /// The watcher is edge-triggered: it only fires after first observing a
    /// not-running state, so restart/apply (where the VM is up at the outset)
    /// don't latch onto the pre-existing running instance before the stop.
    private func runToRunning(_ message: String, _ work: @escaping () async throws -> Void) {
        isBusy = true
        busyMessage = message
        errorMessage = nil
        infoMessage = nil

        Task {
            let watcher = Task { @MainActor in
                var sawDown = false
                while !Task.isCancelled {
                    let inst = try? await self.colima.defaultInstance()
                    if let inst, inst.isRunning {
                        if sawDown {
                            self.colimaState = .running(inst)
                            self.isBusy = false
                            self.busyMessage = ""
                            await self.refreshResourcesUntilReady()
                            return
                        }
                    } else {
                        sawDown = true   // includes nil reads during boot/teardown
                    }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            defer { watcher.cancel() }

            do { try await work() }
            catch { errorMessage = describe(error) }
            await refresh()
            isBusy = false
            busyMessage = ""
        }
    }

    /// Runs a lifecycle operation with busy/error handling, then refreshes everything.
    private func perform(_ message: String, _ work: @escaping () async throws -> Void) {
        Task {
            isBusy = true
            busyMessage = message
            errorMessage = nil
            infoMessage = nil
            defer { isBusy = false; busyMessage = "" }
            do { try await work() }
            catch {
                errorMessage = describe(error)
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
            infoMessage = nil
            defer { isBusy = false; busyMessage = "" }
            do {
                try await work()
                await refreshResources()
            } catch {
                errorMessage = describe(error)
            }
        }
    }
}

private extension Array {
    /// Appends an element and trims from the front so the array never exceeds
    /// `max` — a fixed-size rolling window for sparkline series.
    mutating func appendCapped(_ element: Element, max: Int) {
        append(element)
        if count > max { removeFirst(count - max) }
    }
}
