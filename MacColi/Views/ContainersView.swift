import SwiftUI

struct ContainersView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""
    // Driven by the ⌘F command; setting it true focuses the search field on macOS.
    @State private var searchPresented = false
    @State private var statusFilter: StatusFilter = .all
    // "Select" mode: reveals leading checkboxes and a bulk-action bar; row taps
    // toggle selection instead of opening logs.
    @State private var selectMode = false
    @State private var selection = Set<String>()
    @State private var confirmRemove = false

    /// Containers matching the status filter and, if any, the text query (by
    /// name, image, status or ports).
    private var filtered: [Container] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return state.containers.filter { c in
            guard statusFilter.matches(c) else { return false }
            guard !q.isEmpty else { return true }
            return c.displayName.lowercased().contains(q)
                || c.image.lowercased().contains(q)
                || c.status.lowercased().contains(q)
                || c.ports.lowercased().contains(q)
        }
    }

    /// The selected containers, resolved against the visible (filtered) list so
    /// stale or filtered-out ids never count toward an action.
    private var selected: [Container] { filtered.filter { selection.contains($0.id) } }

    var body: some View {
        Group {
            if !state.colimaState.isRunning {
                RequiresColimaView(noun: "containers")
            } else if state.containers.isEmpty {
                ContentUnavailableView("No containers", systemImage: "shippingbox",
                                       description: Text("Run a container to see it here."))
            } else if filtered.isEmpty {
                if search.isEmpty {
                    ContentUnavailableView("No \(statusFilter.label.lowercased()) containers",
                                           systemImage: "shippingbox",
                                           description: Text("No containers match this filter."))
                } else {
                    ContentUnavailableView.search(text: search)
                }
            } else {
                List(filtered) { container in
                    ContainerRow(
                        container: container,
                        selectMode: selectMode,
                        isSelected: selection.contains(container.id),
                        onToggle: { toggle(container.id) },
                        showLogs: { openWindow(value: container) }
                    )
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Containers")
        .searchable(text: $search, isPresented: $searchPresented, placement: .toolbar, prompt: "Filter containers")
        .onChange(of: state.findRequestToken) { searchPresented = true }
        .safeAreaInset(edge: .bottom) {
            if selectMode {
                SelectionBar(count: selected.count, total: filtered.count,
                             onSelectAll: { selection = Set(filtered.map(\.id)) },
                             onClear: { selection.removeAll() }) {
                    Button("Start") { state.startContainers(selected) }
                    Button("Stop") { state.stopContainers(selected) }
                    Button("Restart") { state.restartContainers(selected) }
                    Button("Remove", role: .destructive) { confirmRemove = true }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Status", selection: $statusFilter) {
                    ForEach(StatusFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(selectMode)
            }
            ToolbarItem(placement: .primaryAction) {
                Button(selectMode ? "Done" : "Select") {
                    selectMode.toggle()
                    if !selectMode { selection.removeAll() }
                }
                .disabled(!state.colimaState.isRunning || state.containers.isEmpty)
            }
            RefreshButton()
        }
        .confirmationDialog("Remove \(selected.count) container\(selected.count == 1 ? "" : "s")?",
                            isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                state.removeContainers(selected)
                selectMode = false
                selection.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Running containers will be force-removed. This cannot be undone.")
        }
    }

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }
}

/// Container list filter by run state.
private enum StatusFilter: String, CaseIterable, Identifiable {
    case all, running, stopped
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .running: return "Running"
        case .stopped: return "Stopped"
        }
    }

    func matches(_ c: Container) -> Bool {
        switch self {
        case .all: return true
        case .running: return c.isRunning
        case .stopped: return !c.isRunning
        }
    }
}

private struct ContainerRow: View {
    @Environment(AppState.self) private var state
    let container: Container
    let selectMode: Bool
    let isSelected: Bool
    let onToggle: () -> Void
    let showLogs: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if selectMode {
                SelectionCheckmark(isSelected: isSelected)
            }

            // Tapping anywhere across the info area opens logs (or, in select
            // mode, toggles selection); the trailing controls sit outside this
            // region so their clicks aren't hijacked.
            HStack(spacing: 12) {
                Circle()
                    .fill(container.isRunning ? Color.green : Color.secondary)
                    .frame(width: 9, height: 9)

                VStack(alignment: .leading, spacing: 2) {
                    Text(container.displayName).font(.body.weight(.medium))
                    Text(container.image).font(.caption).foregroundStyle(.secondary)
                    if !container.ports.isEmpty {
                        Text(container.ports).font(.caption2).foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                Text(container.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture { selectMode ? onToggle() : showLogs() }
            .help(selectMode ? "Select" : "View logs")

            if !selectMode {
                actions
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var actions: some View {
        if container.isRunning {
            Button { state.stopContainer(container) } label: { Image(systemName: "stop.fill") }
                .help("Stop")
        } else {
            Button { state.startContainer(container) } label: { Image(systemName: "play.fill") }
                .help("Start")
        }

        Menu {
            Button("Restart") { state.restartContainer(container) }
            Button("View Logs…", action: showLogs)
            if container.isRunning {
                Button("Open Shell…") { state.openShell(container) }
            }
            Divider()
            Button("Remove", role: .destructive) { state.removeContainer(container) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// Toolbar refresh button reused across panels.
struct RefreshButton: ToolbarContent {
    @Environment(AppState.self) private var state

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { Task { await state.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
            .disabled(state.isBusy)
        }
    }
}
