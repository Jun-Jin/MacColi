import SwiftUI

struct ContainersView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""
    // Driven by the ⌘F command; setting it true focuses the search field on macOS.
    @State private var searchPresented = false
    @State private var statusFilter: StatusFilter = .all

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
                    ContainerRow(container: container) { openWindow(value: container) }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Containers")
        .searchable(text: $search, isPresented: $searchPresented, placement: .toolbar, prompt: "Filter containers")
        .onChange(of: state.findRequestToken) { searchPresented = true }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Status", selection: $statusFilter) {
                    ForEach(StatusFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            RefreshButton()
        }
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
    let showLogs: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Tapping anywhere across the info area opens logs; the trailing
            // controls sit outside this region so their clicks aren't hijacked.
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
            .onTapGesture(perform: showLogs)
            .help("View logs")

            actions
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
