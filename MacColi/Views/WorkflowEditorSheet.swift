import SwiftUI
import UniformTypeIdentifiers

/// Create or edit a workflow: name, tile group, working directory, source
/// files, and the ordered step list. A step is either a shell command or a chain to another
/// saved workflow; steps reorder by drag and the whole thing saves as one
/// tile on the Workflows panel.
struct WorkflowEditorSheet: View {
    enum Mode {
        case create
        case edit(Workflow)
    }

    let mode: Mode

    @Environment(WorkflowStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Identity wrapper so source-file rows keep stable identity through
    /// reordering and removal; paths flatten back to `[String]` on save.
    private struct SourceFileEntry: Identifiable {
        let id = UUID()
        var path: String
    }

    @State private var name: String
    @State private var group: String
    @State private var workingDirectory: String
    @State private var sourceFiles: [SourceFileEntry]
    @State private var discardsOutput: Bool
    @State private var steps: [WorkflowStep]
    @State private var pickingDirectory = false
    /// Shell steps showing the expanded script area instead of the one-line
    /// field. Not persisted: steps that already contain newlines start expanded,
    /// everything else starts compact, and the user can toggle per step.
    @State private var expandedSteps: Set<UUID>

    init(mode: Mode) {
        self.mode = mode
        let initialSteps: [WorkflowStep]
        switch mode {
        case .create:
            _name = State(initialValue: "")
            _group = State(initialValue: "")
            _workingDirectory = State(initialValue: "~")
            _sourceFiles = State(initialValue: [])
            _discardsOutput = State(initialValue: false)
            initialSteps = [WorkflowStep(action: .shell(command: ""))]
        case .edit(let workflow):
            _name = State(initialValue: workflow.name)
            _group = State(initialValue: workflow.group)
            _workingDirectory = State(initialValue: workflow.workingDirectory)
            _sourceFiles = State(initialValue: workflow.sourceFiles.map { SourceFileEntry(path: $0) })
            _discardsOutput = State(initialValue: workflow.discardsOutput)
            initialSteps = workflow.steps
        }
        _steps = State(initialValue: initialSteps)
        _expandedSteps = State(initialValue: Set(initialSteps.compactMap { step in
            if case .shell(let command) = step.action, command.contains("\n") { return step.id }
            return nil
        }))
    }

    private var isEditing: Bool { if case .edit = mode { return true }; return false }
    private var editedID: UUID? { if case .edit(let workflow) = mode { return workflow.id }; return nil }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    /// Workflows offered by the chain picker: everything except the one being
    /// edited (a self-chain is always a cycle).
    private var chainable: [Workflow] { store.workflows.filter { $0.id != editedID } }

    /// Save requires a name and at least one complete step — no blank commands,
    /// no chain steps pointing at a deleted workflow.
    private var canSave: Bool {
        guard !trimmedName.isEmpty, !steps.isEmpty else { return false }
        return steps.allSatisfy { step in
            switch step.action {
            case .shell(let command):
                return !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .runWorkflow(let id):
                return chainable.contains { $0.id == id }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(isEditing ? "Edit Workflow" : "New Workflow")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()

            Divider()

            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Group", text: $group,
                              prompt: Text("Optional — tiles with the same group share a section"))
                    HStack(spacing: 6) {
                        TextField("Working Directory", text: $workingDirectory)
                            .autocorrectionDisabled()
                        Button("Choose…") { pickingDirectory = true }
                    }
                }

                Section {
                    ForEach($sourceFiles) { $entry in
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text").foregroundStyle(.secondary)
                            TextField("Source file", text: $entry.path,
                                      prompt: Text("~/.zshrc, a project env file, …"))
                                .labelsHidden()
                                .autocorrectionDisabled()
                            Button("Choose…") { chooseSourceFile(for: entry.id) }
                            removeButton { sourceFiles.removeAll { $0.id == entry.id } }
                        }
                    }
                    .onMove { sourceFiles.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { sourceFiles.remove(atOffsets: $0) }

                    Button {
                        sourceFiles.append(SourceFileEntry(path: ""))
                    } label: {
                        Label("Add Source File", systemImage: "plus")
                    }
                } header: {
                    Text("Source Files")
                } footer: {
                    Text("Sourced in order before each step, so functions and aliases defined there (e.g. in ~/.zshrc) can be used in steps. Blank rows are ignored.")
                }

                Section {
                    ForEach($steps) { $step in
                        stepRow($step)
                    }
                    .onMove { steps.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { steps.remove(atOffsets: $0) }

                    Menu {
                        Button("Shell Command") {
                            steps.append(WorkflowStep(action: .shell(command: "")))
                        }
                        Button("Run Another Workflow") {
                            if let first = chainable.first {
                                steps.append(WorkflowStep(action: .runWorkflow(id: first.id)))
                            }
                        }
                        .disabled(chainable.isEmpty)
                    } label: {
                        Label("Add Step", systemImage: "plus")
                    }
                } header: {
                    Text("Steps")
                } footer: {
                    Text("Steps run in order with zsh in the working directory; the run stops at the first failing step. A chained workflow's steps run in its own working directory, with its own source files.")
                }

                Section {
                    Toggle("Discard Output", isOn: $discardsOutput)
                } header: {
                    Text("Output")
                } footer: {
                    Text("Drops everything the steps print instead of keeping it in the run detail. A failing step is the exception: its output is kept so the failure can be debugged. Redirecting in the command itself is not enough: stdout and stderr share one stream here.")
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Create") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding()
        }
        .frame(width: 560, height: 540)
        .fileImporter(isPresented: $pickingDirectory,
                      allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                workingDirectory = (url.path as NSString).abbreviatingWithTildeInPath
            }
        }
    }

    @ViewBuilder
    private func stepRow(_ step: Binding<WorkflowStep>) -> some View {
        switch step.wrappedValue.action {
        case .shell:
            if expandedSteps.contains(step.wrappedValue.id) {
                expandedShellRow(step)
            } else {
                compactShellRow(step)
            }
        case .runWorkflow(let targetID):
            HStack(spacing: 8) {
                Image(systemName: "flowchart").foregroundStyle(.secondary)
                Picker("Workflow", selection: chainBinding(step)) {
                    // Keep a stale reference selectable so the picker isn't blank;
                    // canSave still blocks saving until it's fixed.
                    if !chainable.contains(where: { $0.id == targetID }) {
                        Text("Missing workflow").tag(targetID)
                    }
                    ForEach(chainable) { workflow in
                        Text(workflow.name).tag(workflow.id)
                    }
                }
                .labelsHidden()
                Spacer()
                removeButton { steps.removeAll { $0.id == step.wrappedValue.id } }
            }
        }
    }

    /// One-line mode: a compact field for typical `a && b` commands.
    private func compactShellRow(_ step: Binding<WorkflowStep>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "terminal").foregroundStyle(.secondary)
            TextField("Shell command", text: shellBinding(step), axis: .vertical)
                .lineLimit(1...4)
                .font(.body.monospaced())
                .autocorrectionDisabled()
            expandButton(step.wrappedValue.id, expand: true)
            removeButton { steps.removeAll { $0.id == step.wrappedValue.id } }
        }
    }

    /// Script mode: a real multi-line editor for pasting whole scripts. The step
    /// still runs as a single `zsh -lc` invocation, so no shebang is needed.
    private func expandedShellRow(_ step: Binding<WorkflowStep>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "terminal").foregroundStyle(.secondary)
                Text("Script").font(.caption).foregroundStyle(.secondary)
                Spacer()
                expandButton(step.wrappedValue.id, expand: false)
                removeButton { steps.removeAll { $0.id == step.wrappedValue.id } }
            }
            TextEditor(text: shellBinding(step))
                .font(.body.monospaced())
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .frame(minHeight: 120, maxHeight: 200)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        }
    }

    private func expandButton(_ id: UUID, expand: Bool) -> some View {
        Button {
            if expand { expandedSteps.insert(id) } else { expandedSteps.remove(id) }
        } label: {
            Image(systemName: expand
                  ? "arrow.up.left.and.arrow.down.right"
                  : "arrow.down.right.and.arrow.up.left")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(expand ? "Expand to script area" : "Collapse to one line")
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Remove")
    }

    private func shellBinding(_ step: Binding<WorkflowStep>) -> Binding<String> {
        Binding(
            get: {
                if case .shell(let command) = step.wrappedValue.action { return command }
                return ""
            },
            set: { step.wrappedValue.action = .shell(command: $0) }
        )
    }

    private func chainBinding(_ step: Binding<WorkflowStep>) -> Binding<UUID> {
        Binding(
            get: {
                if case .runWorkflow(let id) = step.wrappedValue.action { return id }
                return UUID()
            },
            set: { step.wrappedValue.action = .runWorkflow(id: $0) }
        )
    }

    /// NSOpenPanel rather than a second `.fileImporter`: presentation modifiers
    /// inside grouped-Form rows don't fire reliably, and fileImporter hides
    /// dotfiles — the typical pick here (`~/.zshrc`) is one.
    private func chooseSourceFile(for id: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        if panel.runModal() == .OK, let url = panel.url,
           let index = sourceFiles.firstIndex(where: { $0.id == id }) {
            sourceFiles[index].path = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }

    private func save() {
        let workflow = Workflow(
            id: editedID ?? UUID(),
            name: trimmedName,
            group: group.trimmingCharacters(in: .whitespaces),
            workingDirectory: workingDirectory.trimmingCharacters(in: .whitespaces),
            sourceFiles: sourceFiles
                .map { $0.path.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            discardsOutput: discardsOutput,
            steps: steps
        )
        store.save(workflow)
        dismiss()
    }
}
