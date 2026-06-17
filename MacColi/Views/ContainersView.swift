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
        VStack(spacing: 0) {
        if state.colimaState.isRunning { VMResourceSummary() }
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
        }
        .navigationTitle("Containers")
        .searchable(text: $search, isPresented: $searchPresented, placement: .toolbar, prompt: "Filter containers")
        .onChange(of: state.findRequestToken) { searchPresented = true }
        .onAppear { state.setStatsPanelVisible(true) }
        .onDisappear { state.setStatsPanelVisible(false) }
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
        .confirmationDialog("Remove \(container.displayName)?",
                            isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { state.removeContainer(container) }
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

        Menu {
            Button("Restart") { state.restartContainer(container) }
            Button("View Logs…", action: showLogs)
            if container.isRunning {
                Button("Open Shell…") { state.openShell(container) }
            }
            Divider()
            Button("Remove", role: .destructive) { confirmRemove = true }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// VM-wide CPU and memory usage, summed across running containers and shown
/// against the Colima VM's allocated budget. Renders nothing until the first
/// stats sample arrives. Disk is intentionally omitted for now.
private struct VMResourceSummary: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if let usage = state.vmUsage {
            HStack(alignment: .top, spacing: 24) {
                meter(title: "CPU", fraction: usage.cpuFraction,
                      caption: String(format: "%.1f / %d cores", usage.cpuCoresUsed, usage.cpuCoresTotal),
                      history: state.vmCPUHistory, color: .blue)
                meter(title: "Memory", fraction: usage.memFraction,
                      caption: "\(Format.bytes(usage.memUsedBytes)) / \(Format.bytes(usage.memTotalBytes))",
                      history: state.vmMemHistory, color: .green)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.quaternary.opacity(0.4))
            Divider()
        }
    }

    private func meter(title: String, fraction: Double, caption: String,
                       history: [Double], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.caption.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(fraction >= 0.85 ? .orange : .primary)
            }
            ProgressView(value: min(max(fraction, 0), 1)).tint(color)
            HStack(spacing: 8) {
                Text(caption).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                // Shared 0-100 % ceiling so CPU and memory trends read on one scale.
                Sparkline(values: history, color: color, ceiling: 100)
                    .frame(width: 72, height: 16)
            }
        }
        .frame(maxWidth: .infinity)
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
