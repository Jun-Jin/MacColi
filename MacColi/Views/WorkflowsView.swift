import SwiftUI

/// The Workflows panel: every saved workflow is a tile, sectioned by group, and
/// runnable with one click. A tile's badge and footer reflect its latest run;
/// clicking the tile body opens the run-detail sheet with per-step output.
struct WorkflowsView: View {
    @Environment(WorkflowStore.self) private var store

    @State private var creating = false
    @State private var editing: Workflow?
    @State private var inspecting: Workflow?
    @State private var pendingDelete: Workflow?

    var body: some View {
        Group {
            if store.workflows.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        // Right-clicking blank panel space offers creation; tiles' own menus
        // take precedence within their bounds.
        .contextMenu {
            Button("New Workflow…") { creating = true }
        }
        .toolbar {
            ToolbarItem {
                Button { creating = true } label: {
                    Label("New Workflow", systemImage: "plus")
                }
                .help("New Workflow")
            }
        }
        .sheet(isPresented: $creating) { WorkflowEditorSheet(mode: .create) }
        .sheet(item: $editing) { WorkflowEditorSheet(mode: .edit($0)) }
        .sheet(item: $inspecting) { WorkflowRunSheet(workflowID: $0.id) }
        .confirmationDialog("Delete workflow \(pendingDelete?.name ?? "")?",
                            isPresented: pendingDeleteBinding, titleVisibility: .visible,
                            presenting: pendingDelete) { workflow in
            Button("Delete Workflow", role: .destructive) { store.delete(workflow.id) }
            Button("Cancel", role: .cancel) {}
        } message: { workflow in
            let referrers = store.workflowsReferencing(workflow.id)
            if referrers.isEmpty {
                Text("This cannot be undone.")
            } else {
                Text("\(referrers.map(\.name).formatted(.list(type: .and))) chain to this workflow — their runs will fail until they are updated.")
            }
        }
    }

    private var pendingDeleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    /// Workflows bucketed by group: the ungrouped bucket first (no header), then
    /// named groups alphabetically.
    private var sections: [(title: String, items: [Workflow])] {
        let buckets = Dictionary(grouping: store.workflows) {
            $0.group.trimmingCharacters(in: .whitespaces)
        }
        var result: [(String, [Workflow])] = []
        if let ungrouped = buckets[""] { result.append(("", ungrouped)) }
        for key in buckets.keys.filter({ !$0.isEmpty }).sorted() {
            result.append((key, buckets[key]!))
        }
        return result
    }

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(sections, id: \.title) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        if !section.title.isEmpty {
                            Text(section.title)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 360),
                                                     spacing: 12)],
                                  spacing: 12) {
                            ForEach(section.items) { workflow in
                                WorkflowTile(
                                    workflow: workflow,
                                    run: store.runs[workflow.id],
                                    isRunning: store.isRunning(workflow.id),
                                    onRun: { store.run(workflow.id) },
                                    onStop: { store.cancel(workflow.id) },
                                    onOpen: { inspecting = workflow },
                                    onEdit: { editing = workflow },
                                    onDuplicate: { store.duplicate(workflow.id) },
                                    onDelete: { pendingDelete = workflow }
                                )
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Workflows", systemImage: "flowchart")
        } description: {
            Text("Save a sequence of shell commands as a tile, then rerun it with one click. Workflows can chain other workflows.")
        } actions: {
            Button("New Workflow…") { creating = true }
                .buttonStyle(.borderedProminent)
        }
    }
}

/// One workflow tile: name + status badge, working directory, and a Run/Stop
/// button. The tile body opens the run sheet; everything else is in the
/// context menu.
private struct WorkflowTile: View {
    let workflow: Workflow
    let run: WorkflowRunState?
    let isRunning: Bool
    let onRun: () -> Void
    let onStop: () -> Void
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "flowchart.fill").foregroundStyle(.tint)
                Text(workflow.name).font(.headline).lineLimit(1)
                if workflow.discardsOutput {
                    DiscardedOutputIcon()
                }
                Spacer()
                editButton
                statusBadge
            }
            Text(displayDirectory)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            HStack {
                if isRunning {
                    Button { onStop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    Button { onRun() } label: { Label("Run", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                Spacer()
                footerView
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovering = $0 }
        .onTapGesture { onOpen() }
        .contextMenu {
            if isRunning {
                Button("Stop") { onStop() }
            } else {
                Button("Run") { onRun() }
            }
            Button("Show Last Run") { onOpen() }
            Divider()
            Button("Edit…") { onEdit() }
            Button("Duplicate") { onDuplicate() }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
    }

    /// Hover-only pencil in the tile header. Fades via opacity rather than
    /// inserting/removing, so the status badge never shifts; hit testing is
    /// gated too since an opacity-0 view still takes clicks.
    private var editButton: some View {
        Button { onEdit() } label: {
            Image(systemName: "pencil")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Edit Workflow")
        .opacity(hovering ? 1 : 0)
        .allowsHitTesting(hovering)
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch run?.outcome {
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "stop.circle.fill").foregroundStyle(.orange)
        case nil:
            EmptyView()
        }
    }

    /// Bottom-right caption: while running, a small spinner plus the active
    /// step's PID (falling back to "Running…" until the PID lands); otherwise
    /// the last-run summary.
    @ViewBuilder
    private var footerView: some View {
        if isRunning {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                if let pid = run?.steps.first(where: { $0.phase == .running })?.pid {
                    Text(verbatim: "PID \(pid)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                } else {
                    Text("Running…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text(footer)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var displayDirectory: String {
        let raw = workflow.workingDirectory.trimmingCharacters(in: .whitespaces)
        return raw.isEmpty ? "~" : raw
    }

    private var footer: String {
        guard let run else {
            return "\(workflow.steps.count) step\(workflow.steps.count == 1 ? "" : "s")"
        }
        guard let finishedAt = run.finishedAt else { return "Running…" }
        let when = finishedAt.formatted(.relative(presentation: .named))
        switch run.outcome {
        case .succeeded: return "Succeeded \(when)"
        case .failed: return "Failed \(when)"
        case .cancelled: return "Stopped \(when)"
        case .running: return "Running…"
        }
    }
}
