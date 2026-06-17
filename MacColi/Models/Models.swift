import Foundation

// MARK: - Colima

enum ContainerRuntime: String, CaseIterable, Identifiable, Codable {
    case docker
    case containerd
    case incus
    var id: String { rawValue }
    var label: String {
        switch self {
        case .docker: return "Docker"
        case .containerd: return "containerd"
        case .incus: return "Incus"
        }
    }
}

/// VM CPU architecture (`colima start --arch`).
enum VMArch: String, CaseIterable, Identifiable, Codable {
    case aarch64
    case x86_64
    var id: String { rawValue }
    var label: String {
        switch self {
        case .aarch64: return "aarch64 (Apple Silicon)"
        case .x86_64: return "x86_64 (Intel)"
        }
    }
}

/// VM backend (`colima start --vm-type`). `vz` uses Apple's
/// Virtualization.framework and is faster than the default QEMU.
enum VMType: String, CaseIterable, Identifiable, Codable {
    case vz
    case qemu
    var id: String { rawValue }
    var label: String {
        switch self {
        case .vz: return "vz (Virtualization.framework)"
        case .qemu: return "QEMU"
        }
    }
}

/// Host↔VM file-sharing backend (`colima start --mount-type`). `virtiofs`
/// is the fastest but requires the `vz` VM type.
enum MountType: String, CaseIterable, Identifiable, Codable {
    case virtiofs
    case sshfs
    case ninep = "9p"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .virtiofs: return "VirtioFS"
        case .sshfs: return "sshfs"
        case .ninep: return "9p"
        }
    }
}

/// One Colima profile, decoded from `colima list --json`.
struct ColimaInstance: Codable, Identifiable, Equatable {
    let name: String
    let status: String
    let arch: String?
    let cpus: Int?
    let memory: Int64?   // bytes
    let disk: Int64?     // bytes
    let runtime: String?
    let address: String?

    var id: String { name }
    var isRunning: Bool { status.lowercased() == "running" }
}

/// Desired VM configuration used when (re)starting Colima.
/// A custom DNS name → target mapping (`colima start --dns-host host=target`).
struct DNSHostMapping: Equatable {
    var host: String
    var target: String
}

struct ColimaConfig: Equatable {
    var profile: String = "default"
    var cpus: Int = 2
    var memoryGiB: Int = 2
    var diskGiB: Int = 60
    var runtime: ContainerRuntime = .docker
    var arch: VMArch = .aarch64
    var vmType: VMType = .vz
    /// Enables Rosetta 2 inside the VM for fast `linux/amd64` execution. Only
    /// meaningful with the `vz` VM type on Apple Silicon.
    var vzRosetta: Bool = true
    var mountType: MountType = .virtiofs
    /// Custom VM hostname; empty uses Colima's default (`colima`).
    var hostname: String = ""
    /// Assign a host-reachable IP address to the VM (`--network-address`).
    var networkAddress: Bool = false
    /// Custom DNS name resolutions (`--dns-host`).
    var dnsHosts: [DNSHostMapping] = []
    /// Forward the host's SSH agent into the VM (`--ssh-agent`).
    var sshAgent: Bool = false
    /// Start with Kubernetes (k3s) enabled (`--kubernetes`).
    var kubernetesEnabled: Bool = false
    /// k3s version to use; empty uses Colima's default.
    var kubernetesVersion: String = ""
}

/// High-level lifecycle state shown in the UI.
enum ColimaState: Equatable {
    case notInstalled
    case stopped
    case starting
    case running(ColimaInstance)
    case stopping
    case unknown

    var label: String {
        switch self {
        case .notInstalled: return "Not installed"
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .running: return "Running"
        case .stopping: return "Stopping…"
        case .unknown: return "Unknown"
        }
    }

    var isRunning: Bool { if case .running = self { return true }; return false }
    var isTransitioning: Bool { self == .starting || self == .stopping }
}

// MARK: - Docker

struct Container: Codable, Identifiable, Hashable {
    let id: String
    let image: String
    let names: String
    let state: String
    let status: String
    let ports: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case image = "Image"
        case names = "Names"
        case state = "State"
        case status = "Status"
        case ports = "Ports"
        case createdAt = "CreatedAt"
    }

    var isRunning: Bool { state.lowercased() == "running" }
    var displayName: String { names.split(separator: ",").first.map(String.init) ?? names }
}

struct DockerImage: Codable, Identifiable, Equatable {
    let id: String
    let repository: String
    let tag: String
    let size: String
    let createdSince: String

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case repository = "Repository"
        case tag = "Tag"
        case size = "Size"
        case createdSince = "CreatedSince"
    }

    var reference: String {
        guard repository != "<none>" else { return id }
        return tag == "<none>" ? repository : "\(repository):\(tag)"
    }
}

struct Volume: Codable, Identifiable, Equatable {
    let name: String
    let driver: String
    let mountpoint: String
    let scope: String

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case driver = "Driver"
        case mountpoint = "Mountpoint"
        case scope = "Scope"
    }

    var id: String { name }
}
