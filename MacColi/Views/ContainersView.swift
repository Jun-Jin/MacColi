import SwiftUI

struct ContainersView: View {
    @Environment(AppState.self) private var state
    @State private var logTarget: Container?
    @State private var search = ""
    // Driven by the ⌘F command; setting it true focuses the search field on macOS.
    @State private var searchPresented = false

    /// Containers matching the filter, by name, image, status or ports.
    private var filtered: [Container] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return state.containers }
        return state.containers.filter {
            $0.displayName.lowercased().contains(q)
                || $0.image.lowercased().contains(q)
                || $0.status.lowercased().contains(q)
                || $0.ports.lowercased().contains(q)
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
                ContentUnavailableView.search(text: search)
            } else {
                List(filtered) { container in
                    ContainerRow(container: container) { logTarget = container }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Containers")
        .searchable(text: $search, isPresented: $searchPresented, placement: .toolbar, prompt: "Filter containers")
        .onChange(of: state.findRequestToken) { searchPresented = true }
        .toolbar { RefreshButton() }
        .sheet(item: $logTarget) { container in
            LogsView(container: container)
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
