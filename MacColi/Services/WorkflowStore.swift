import Foundation
import Observation

/// Errors raised while resolving a workflow into executable steps, before
/// anything runs.
enum WorkflowError: LocalizedError {
    case noSteps
    case missingReference
    case cycle(String)

    var errorDescription: String? {
        switch self {
        case .noSteps:
            return "This workflow has no runnable steps."
        case .missingReference:
            return "A step references a workflow that no longer exists."
        case .cycle(let name):
            return "The workflow chain loops back to “\(name)”. Remove the circular reference."
        }
    }
}

/// Owns the saved workflows and their runs.
///
/// Persistence mirrors AppState's container lists: JSON in UserDefaults, written
/// through by every mutator. A run feeds all of its flattened steps through one
/// `zsh` login session (see ShellSession), started in the first step's working
/// directory with the same augmented PATH / COLIMA_HOME / DOCKER_HOST
/// environment the rest of the app uses — so `git`, `make`, and `docker` behave
/// exactly as they do in the user's terminal, and shell state a step sets up
/// carries into the steps after it.
@Observable
@MainActor
final class WorkflowStore {
    private(set) var workflows: [Workflow] = []
    /// Latest (or in-flight) run per workflow id.
    private(set) var runs: [UUID: WorkflowRunState] = [:]

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private static let storageKey = "workflows"

    /// Ring size for a discard-output step's capture: the tail kept in case the
    /// step fails. Deliberately smaller than the 5,000-line streaming buffer —
    /// it exists only for failure debugging. The run sheet quotes this number
    /// when labelling a surfaced tail.
    static let discardedTailLines = 512

    init() {
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([Workflow].self, from: data) {
            workflows = decoded
        }
    }

    // MARK: - CRUD

    private func persist() {
        guard let data = try? JSONEncoder().encode(workflows) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    func workflow(_ id: UUID) -> Workflow? {
        workflows.first { $0.id == id }
    }

    /// Insert-or-update by id — the editor's Save for both create and edit.
    func save(_ workflow: Workflow) {
        if let i = workflows.firstIndex(where: { $0.id == workflow.id }) {
            workflows[i] = workflow
        } else {
            workflows.append(workflow)
        }
        persist()
    }

    func delete(_ id: UUID) {
        tasks[id]?.cancel()
        workflows.removeAll { $0.id == id }
        runs[id] = nil
        persist()
    }

    @discardableResult
    func duplicate(_ id: UUID) -> Workflow? {
        guard let source = workflow(id) else { return nil }
        var copy = source
        copy.id = UUID()
        copy.name = source.name + " copy"
        workflows.append(copy)
        persist()
        return copy
    }

    /// Workflows that chain to `id` — surfaced in the delete confirmation, since
    /// deleting a chained-to workflow breaks its referrers' runs.
    func workflowsReferencing(_ id: UUID) -> [Workflow] {
        workflows.filter { wf in
            wf.id != id && wf.steps.contains { $0.action == .runWorkflow(id: id) }
        }
    }

    // MARK: - Running

    func isRunning(_ id: UUID) -> Bool { tasks[id] != nil }

    /// Starts a run, replacing the workflow's previous run state. No-op while a
    /// run for the same workflow is already in flight.
    func run(_ id: UUID) {
        guard let workflow = workflow(id), tasks[id] == nil else { return }
        var run = WorkflowRunState(workflowID: id, steps: [], startedAt: Date())
        do {
            run.steps = try flatten(workflow, path: [])
            guard !run.steps.isEmpty else { throw WorkflowError.noSteps }
        } catch {
            run.setupError = error.localizedDescription
            run.finishedAt = Date()
            runs[id] = run
            return
        }
        runs[id] = run
        tasks[id] = Task { [weak self] in await self?.execute(id) }
    }

    /// Stops an in-flight run. The running subprocess is terminated (see
    /// ProcessRunner's cancellation handler); remaining steps become "skipped".
    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
    }

    /// Resolves a workflow — and any chained workflows, recursively — into the
    /// flat list of shell steps a run executes. Chained steps keep their own
    /// workflow's working directory and are labelled with their provenance.
    /// `path` carries the chain of workflow ids above this one for cycle detection.
    private func flatten(_ workflow: Workflow, path: [UUID],
                         titlePrefix: String = "") throws -> [WorkflowRunStep] {
        var result: [WorkflowRunStep] = []
        for step in workflow.steps {
            switch step.action {
            case .shell(let command):
                let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                result.append(WorkflowRunStep(title: titlePrefix + WorkflowStep.summary(of: trimmed),
                                              command: trimmed,
                                              workingDirectory: workflow.workingDirectory,
                                              sourceFiles: workflow.sourceFiles,
                                              discardsOutput: workflow.discardsOutput))
            case .runWorkflow(let subID):
                guard let sub = self.workflow(subID) else { throw WorkflowError.missingReference }
                guard subID != workflow.id, !path.contains(subID) else {
                    throw WorkflowError.cycle(sub.name)
                }
                result += try flatten(sub, path: path + [workflow.id],
                                      titlePrefix: titlePrefix + sub.name + " ▸ ")
            }
        }
        return result
    }

    /// Runs the flattened steps sequentially through one shell session,
    /// stopping at the first failure.
    private func execute(_ id: UUID) async {
        let environment = CLI.shared.dockerEnvironment()
        let count = runs[id]?.steps.count ?? 0

        // Started at the first step that gets far enough to run, so a run that
        // fails its directory check never spawns a shell at all.
        var session: ShellSession?
        // What the session was last *told* to cd to and source. Both are
        // re-emitted only when the step's configured values change, so a `cd`
        // a step performs itself survives into the next step of the same
        // workflow, while crossing into a chained workflow that declares a
        // different directory still resets to it.
        var currentDirectory: String?
        var currentSourceFiles: [String]?

        for index in 0..<count {
            guard let step = runs[id]?.steps[index] else { break }
            if Task.isCancelled {
                runs[id]?.steps[index].phase = .cancelled
                skipRemaining(id, from: index + 1)
                break
            }

            let directory = Self.expandPath(step.workingDirectory)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                runs[id]?.steps[index].phase =
                    .failed("Working directory “\(step.workingDirectory)” was not found.")
                skipRemaining(id, from: index + 1)
                break
            }

            let sourceFiles = step.sourceFiles
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if let missing = sourceFiles.first(where: {
                !FileManager.default.fileExists(atPath: Self.expandPath($0))
            }) {
                runs[id]?.steps[index].phase =
                    .failed("Source file “\(missing)” was not found.")
                skipRemaining(id, from: index + 1)
                break
            }

            if session == nil {
                do {
                    session = try ShellSession(environment: environment,
                                               currentDirectory: directory)
                    // The shell starts there, so this step needs no `cd`.
                    currentDirectory = step.workingDirectory
                } catch {
                    runs[id]?.steps[index].phase =
                        .failed("Could not start a shell: \(error.localizedDescription)")
                    skipRemaining(id, from: index + 1)
                    break
                }
            }
            guard let session else { break }

            // Every line below is redirected away from the session's stdin:
            // that is the channel the steps behind this one are queued on, and
            // a step running `cat` would otherwise swallow them.
            var script: [String] = []
            if step.workingDirectory != currentDirectory {
                // Existence was just checked, so a failure here would take a
                // race to produce; the shell reports it and the step's own
                // status still decides the outcome.
                script.append("cd \(Self.shellQuoted(directory)) < /dev/null")
            }
            if sourceFiles != currentSourceFiles {
                script += sourceFiles.map {
                    "source \(Self.shellQuoted(Self.expandPath($0))) < /dev/null"
                }
            }
            // The step body must go through `eval`: zsh parses a whole command
            // before running it, and alias expansion happens at parse time —
            // without the re-parse, sourced functions would work but sourced
            // aliases would not.
            script.append("eval \(Self.shellQuoted(step.command)) < /dev/null")
            currentDirectory = step.workingDirectory
            currentSourceFiles = sourceFiles

            runs[id]?.steps[index].pid = session.pid
            runs[id]?.steps[index].phase = .running

            // Lines land in the buffer straight from the stream thread — no
            // main-actor hop, no observable mutation per line. The flush loop
            // repaints the step's output at ~7 Hz, so a chatty step can't
            // drown the UI in per-line invalidations.
            //
            // A discard-output step skips only the flush loop, so nothing
            // streams to the run detail. Lines still land in the buffer — a
            // tight ring of the last `discardedTailLines` — because a failing
            // step surfaces its captured tail for debugging; success drops it.
            let buffer = step.discardsOutput
                ? LogBuffer(maxLines: Self.discardedTailLines) : LogBuffer()
            let flush: Task<Void, Never>? = step.discardsOutput ? nil
                : Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        if let joined = buffer.drainIfChanged() {
                            self?.setOutput(joined, id: id, step: index)
                        }
                        try? await Task.sleep(for: .milliseconds(150))
                    }
                }
            // Unstructured tasks don't inherit cancellation, so every exit
            // below must run this: stop the loop and land the buffered tail.
            // A quiet step lands its tail only when it failed — the one case
            // where the output earns its place in the run detail.
            func finishStreaming(failed: Bool) {
                flush?.cancel()
                if step.discardsOutput {
                    // `tail()`, not `drainIfChanged()`: the ring drifts above
                    // its cap between trims, and the run sheet promises "up to
                    // the last N lines" — surface exactly that.
                    guard failed, let tail = buffer.tail() else { return }
                    setOutput(tail, id: id, step: index)
                } else if let joined = buffer.drainIfChanged() {
                    setOutput(joined, id: id, step: index)
                }
            }

            do {
                let code = try await session.run(script.joined(separator: "\n")) { line in
                    buffer.append(line)
                }
                finishStreaming(failed: code != 0 && !Task.isCancelled)
                if Task.isCancelled {
                    runs[id]?.steps[index].phase = .cancelled
                    skipRemaining(id, from: index + 1)
                    break
                }
                if code == 0 {
                    runs[id]?.steps[index].phase = .succeeded
                } else {
                    runs[id]?.steps[index].phase = .failed("Exited with code \(code).")
                    skipRemaining(id, from: index + 1)
                    break
                }
            } catch is CancellationError {
                finishStreaming(failed: false)
                runs[id]?.steps[index].phase = .cancelled
                skipRemaining(id, from: index + 1)
                break
            } catch {
                finishStreaming(failed: true)
                runs[id]?.steps[index].phase = .failed(error.localizedDescription)
                skipRemaining(id, from: index + 1)
                break
            }
        }

        await session?.close()
        runs[id]?.finishedAt = Date()
        tasks[id] = nil
    }

    private func skipRemaining(_ id: UUID, from index: Int) {
        guard let count = runs[id]?.steps.count else { return }
        for i in index..<count where runs[id]?.steps[i].phase == .pending {
            runs[id]?.steps[i].phase = .skipped
        }
    }

    /// Replaces a step's visible output with the buffer's latest joined text.
    /// The buffer caps by line count, so no byte accounting is needed here.
    private func setOutput(_ joined: String, id: UUID, step index: Int) {
        guard runs[id]?.steps.indices.contains(index) == true else { return }
        runs[id]?.steps[index].output = joined
    }

    /// Wraps a string in single quotes for safe embedding in a zsh command.
    private static func shellQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func expandPath(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return FileManager.default.homeDirectoryForCurrentUser.path }
        return (trimmed as NSString).expandingTildeInPath
    }
}
