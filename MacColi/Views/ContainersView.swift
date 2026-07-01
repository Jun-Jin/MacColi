import SwiftUI

struct ContainersView: View {
    /// The list this panel shows, or nil for "All Containers". A list restricts
    /// the source set to its members and switches Remove to list-aware semantics.
    var list: ContainerList?

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
    // Presents the new-list sheet prefilled with the current selection, for the
    // "Add to List → New List…" bulk action.
    @State private var creatingListFromSelection = false

    /// The containers this panel draws from before filtering: every container, or
    /// just the members of the current list.
    private var base: [Container] {
        if let list { return state.containers(in: list) }
        return state.containers
    }

    /// Containers matching the status filter and, if any, the text query (by
    /// name, image, status or ports).
    private var filtered: [Container] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return base.filter { c in
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
            } else if base.isEmpty {
                if list != nil {
                    ContentUnavailableView("No containers in this list", systemImage: "shippingbox",
                                           description: Text("Add containers from All Containers, or Edit the list."))
                } else {
                    ContentUnavailableView("No containers", systemImage: "shippingbox",
                                           description: Text("Run a container to see it here."))
                }
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
                        showLogs: { openWindow(value: container) },
                        listName: list?.name,
                        onRemoveFromList: {
                            if let list { state.removeFromList(list.id, keys: [container.membershipKey]) }
                        }
                    )
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(list?.name ?? "Containers")
        .searchable(text: $search, isPresented: $searchPresented, placement: .toolbar, prompt: "Filter containers")
        .onChange(of: state.findRequestToken) { searchPresented = true }
        .safeAreaInset(edge: .bottom) {
            if selectMode { bulkBar }
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
        .confirmationDialog(bulkRemoveTitle, isPresented: $confirmRemove, titleVisibility: .visible) {
            if let list {
                Button("Remove from \(list.name)") {
                    state.removeFromList(list.id, keys: selected.map(\.membershipKey))
                    endSelect()
                }
                Button("Delete Container\(selected.count == 1 ? "" : "s")", role: .destructive) {
                    state.removeContainers(selected)
                    endSelect()
                }
            } else {
                Button("Remove", role: .destructive) {
                    state.removeContainers(selected)
                    endSelect()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(list == nil
                 ? "Running containers will be force-removed. This cannot be undone."
                 : "Remove takes them out of this list only. Delete force-removes them from Docker (and every list) — this cannot be undone.")
        }
        .sheet(isPresented: $creatingListFromSelection) {
            ListEditorSheet(mode: .create(prefill: selected.map(\.membershipKey)))
        }
    }

    /// Bottom bulk-action bar shown in Select mode. Extracted from `body` to keep
    /// the main view expression within the type-checker's reach.
    @ViewBuilder
    private var bulkBar: some View {
        SelectionBar(count: selected.count, total: filtered.count,
                     onSelectAll: { selection = Set(filtered.map(\.id)) },
                     onClear: { selection.removeAll() }) {
            Button("Start") { state.startContainers(selected) }
            Button("Stop") { state.stopContainers(selected) }
            Button("Restart") { state.restartContainers(selected) }
            addToListMenu
            Button(list == nil ? "Remove" : "Remove…", role: .destructive) { confirmRemove = true }
        }
    }

    /// "Add to List" bulk action: create a new list from the selection, or fold it
    /// into an existing one.
    @ViewBuilder
    private var addToListMenu: some View {
        Menu("Add to List") {
            Button("New List…") { creatingListFromSelection = true }
            if !state.containerLists.isEmpty {
                Divider()
                ForEach(state.containerLists) { l in
                    Button(l.name) { state.addToList(l.id, containers: selected) }
                }
            }
        }
        .fixedSize()
    }

    /// Bulk-remove dialog title, scoped to the current list when there is one.
    private var bulkRemoveTitle: String {
        let n = selected.count
        let noun = "container\(n == 1 ? "" : "s")"
        if let list { return "Remove \(n) \(noun) from \(list.name)?" }
        return "Remove \(n) \(noun)?"
    }

    /// Leaves Select mode and clears the current selection.
    private func endSelect() {
        selectMode = false
        selection.removeAll()
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
    // Non-nil when the row is shown inside a custom list: the ⋯ menu then offers
    // "Remove from <list>" (detach) alongside a destructive "Delete Container…".
    let listName: String?
    let onRemoveFromList: () -> Void
    // Drives the per-container removal confirmation from the row's ⋯ menu.
    @State private var confirmRemove = false

    var body: some View {
        HStack(spacing: 12) {
            if selectMode {
                SelectionCheckmark(isSelected: isSelected)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onToggle)
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

                if container.isRunning, let s = state.stats[container.id] {
                    VStack(alignment: .trailing, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(String(format: "%.1f%%", s.cpuPercent))
                                .font(.caption.weight(.medium)).monospacedDigit()
                                .foregroundStyle(loadColor(s.cpuPercent))
                            Sparkline(values: state.cpuHistory[container.id] ?? [], color: .blue)
                                .frame(width: 40, height: 14)
                        }
                        HStack(spacing: 6) {
                            Text(Format.bytes(s.memUsedBytes))
                                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                            Sparkline(values: state.memHistory[container.id] ?? [], color: .green, ceiling: 100)
                                .frame(width: 40, height: 14)
                        }
                    }
                    .help(String(format: "CPU %.1f%% · Memory %@ (%.1f%%)",
                                 s.cpuPercent, Format.bytes(s.memUsedBytes), s.memPercent))
                }

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
        // Right-click anywhere on the row for the same actions as the ⋯ button.
        // Suppressed in Select mode, where a click means "toggle selection" and a
        // single-row action menu would conflict with the multi-select workflow.
        .contextMenuIf(!selectMode) { rowMenu }
        .confirmationDialog(listName == nil ? "Remove \(container.displayName)?"
                                            : "Delete \(container.displayName)?",
                            isPresented: $confirmRemove, titleVisibility: .visible) {
            Button(listName == nil ? "Remove" : "Delete Container", role: .destructive) {
                state.removeContainer(container)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(container.isRunning
                 ? "This container is running and will be force-removed. This cannot be undone."
                 : "This cannot be undone.")
        }
    }

    /// Amber/red tint for CPU pressure; plain otherwise (per-core percentage,
    /// so the thresholds are deliberately generous).
    private func loadColor(_ cpuPercent: Double) -> Color {
        switch cpuPercent {
        case 150...: return .red
        case 80...: return .orange
        default: return .primary
        }
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

        Menu { rowMenu } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// The per-container action menu, shared by the trailing ⋯ button and the
    /// row's right-click context menu so both stay in lockstep. Remove is
    /// list-aware: in a list it offers detach ("Remove from …") plus a
    /// destructive delete; in All Containers it's a plain Remove.
    @ViewBuilder
    private var rowMenu: some View {
        Button("Restart") { state.restartContainer(container) }
        Button("View Logs…", action: showLogs)
        if container.isRunning {
            Button("Open Shell…") { state.openShell(container) }
        }
        Divider()
        if let listName {
            Button("Remove from \(listName)", action: onRemoveFromList)
            Button("Delete Container…", role: .destructive) { confirmRemove = true }
        } else {
            Button("Remove", role: .destructive) { confirmRemove = true }
        }
    }
}

private extension View {
    /// Attaches a context menu only when `enabled`; otherwise returns the view
    /// untouched (an always-present but empty context menu would still swallow the
    /// right-click).
    @ViewBuilder
    func contextMenuIf<M: View>(_ enabled: Bool, @ViewBuilder menu: () -> M) -> some View {
        if enabled { contextMenu(menuItems: menu) } else { self }
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
