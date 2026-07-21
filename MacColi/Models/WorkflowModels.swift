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
    var steps: [WorkflowStep]

    init(id: UUID = UUID(), name: String = "", group: String = "",
         workingDirectory: String = "~", steps: [WorkflowStep] = []) {
        self.id = id
        self.name = name
        self.group = group
        self.workingDirectory = workingDirectory
        self.steps = steps
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
