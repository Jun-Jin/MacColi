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
    /// Optional files (`~/.zshrc`, a project env file, …) sourced in order
    /// before each shell step so functions, aliases, and variables defined
    /// there are available. `~` is expanded in each.
    var sourceFiles: [String]
    /// Drop this workflow's step output instead of keeping it. Shell redirection
    /// is an awkward substitute: the runner merges stdout and stderr into one
    /// pipe, so `> /dev/null` alone still leaks half the noise. Set here, the
    /// run detail stays clear of output — except for a failing step, whose
    /// captured tail is surfaced so the failure can be debugged.
    var discardsOutput: Bool
    var steps: [WorkflowStep]

    init(id: UUID = UUID(), name: String = "", group: String = "",
         workingDirectory: String = "~", sourceFiles: [String] = [],
         discardsOutput: Bool = false, steps: [WorkflowStep] = []) {
        self.id = id
        self.name = name
        self.group = group
        self.workingDirectory = workingDirectory
        self.sourceFiles = sourceFiles
        self.discardsOutput = discardsOutput
        self.steps = steps
    }

    /// Key of the short-lived single-file predecessor of `sourceFiles`.
    private enum LegacyCodingKeys: String, CodingKey { case sourceFile }

    // Custom decoding only so workflows persisted by older builds still load
    // (a thrown decode would silently drop every saved workflow): a missing
    // key means [], and a single `sourceFile` string folds into `sourceFiles`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        group = try container.decode(String.self, forKey: .group)
        workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
        if let files = try container.decodeIfPresent([String].self, forKey: .sourceFiles) {
            sourceFiles = files
        } else {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            let single = try legacy.decodeIfPresent(String.self, forKey: .sourceFile) ?? ""
            sourceFiles = single.isEmpty ? [] : [single]
        }
        discardsOutput = try container.decodeIfPresent(Bool.self, forKey: .discardsOutput) ?? false
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
    /// The owning workflow's source files (empty when none) — like
    /// `workingDirectory`, a chained step keeps its own workflow's values.
    var sourceFiles: [String] = []
    /// The owning workflow's `discardsOutput`, so a chained workflow marked
    /// quiet stays quiet no matter which workflow pulls it in.
    var discardsOutput: Bool = false
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
