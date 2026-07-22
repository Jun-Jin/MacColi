import Foundation

// MARK: - Workflows

/// One step of a workflow: either a shell command run in the workflow's working
/// directory, or a reference to another saved workflow. A referenced workflow's
/// steps run inline at that position — in *its own* working directory — which is
/// how chaining/composition works (a "deploy" workflow can start with a shared
/// "sync main" workflow, etc.).
struct WorkflowStep: Identifiable, Codable, Hashable {
    enum Action: Codable, Hashable {
        case shell(command: String)
        case runWorkflow(id: UUID)
    }

    var id: UUID
    var action: Action

    init(id: UUID = UUID(), action: Action) {
        self.id = id
        self.action = action
    }

    /// First non-empty line of a (possibly multi-line) command, with an ellipsis
    /// marking that more follows — used wherever a step must render on one line
    /// (run rows, tile previews).
    static func summary(of command: String) -> String {
        let lines = command.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return command }
        return lines.count > 1 ? first + " …" : first
    }
}

/// A user-defined, named sequence of shell steps shown as a runnable tile on the
/// Workflows panel. Like `ContainerList`, this is pure client-side metadata,
/// persisted as JSON in UserDefaults (see WorkflowStore).
struct Workflow: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    /// Optional section name; tiles with the same group render under one header.
    var group: String
    /// Where shell steps run. `~` is expanded; empty falls back to the user's home.
    var workingDirectory: String
    /// Optional file (`~/.zshrc`, a project env file, …) sourced before each
    /// shell step so functions, aliases, and variables defined there are
    /// available. `~` is expanded; empty means nothing extra is sourced.
    var sourceFile: String
    var steps: [WorkflowStep]

    init(id: UUID = UUID(), name: String = "", group: String = "",
         workingDirectory: String = "~", sourceFile: String = "",
         steps: [WorkflowStep] = []) {
        self.id = id
        self.name = name
        self.group = group
        self.workingDirectory = workingDirectory
        self.sourceFile = sourceFile
        self.steps = steps
    }

    // Custom decoding only so workflows persisted before `sourceFile` existed
    // still load (a thrown decode would silently drop every saved workflow).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        group = try container.decode(String.self, forKey: .group)
        workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
        sourceFile = try container.decodeIfPresent(String.self, forKey: .sourceFile) ?? ""
        steps = try container.decode([WorkflowStep].self, forKey: .steps)
    }
}

// MARK: - Run state

/// A fully resolved, executable step of a run. Chained workflows are flattened
/// into this list before execution; `title` carries the provenance for chained
/// steps ("Sync main ▸ git fetch origin"), and `workingDirectory` is the owning
/// workflow's, not necessarily the top-level one's.
struct WorkflowRunStep: Identifiable, Equatable {
    enum Phase: Equatable {
        case pending
        case running
        case succeeded
        case failed(String)
        case cancelled
        case skipped
    }

    let id = UUID()
    let title: String
    let command: String
    let workingDirectory: String
    /// The owning workflow's source file (empty when none) — like
    /// `workingDirectory`, a chained step keeps its own workflow's value.
    var sourceFile: String = ""
    var phase: Phase = .pending
    var output: String = ""
    /// PID of the step's `zsh` process, set once it launches. Children the step
    /// spawns have their own PIDs (`pgrep -P <pid>`). Kept after exit; the UI
    /// shows it only while the step is running.
    var pid: Int32?
}

/// The latest (possibly in-flight) run of one workflow, kept per workflow id in
/// WorkflowStore. Drives the tile's status badge and the run-detail sheet.
struct WorkflowRunState {
    enum Outcome { case running, succeeded, failed, cancelled }

    let workflowID: UUID
    var steps: [WorkflowRunStep]
    let startedAt: Date
    var finishedAt: Date?
    /// Set when the run couldn't start at all (missing chained workflow, cycle,
    /// no steps) — shown in place of a step list.
    var setupError: String?

    var isRunning: Bool { finishedAt == nil }

    var outcome: Outcome {
        guard finishedAt != nil else { return .running }
        if setupError != nil { return .failed }
        if steps.contains(where: { if case .failed = $0.phase { return true }; return false }) {
            return .failed
        }
        if steps.contains(where: { $0.phase == .cancelled }) { return .cancelled }
        return .succeeded
    }

    var duration: TimeInterval? { finishedAt.map { $0.timeIntervalSince(startedAt) } }
}
