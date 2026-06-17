import SwiftUI

struct NetworksView: View {
    @Environment(AppState.self) private var state
    @State private var showCreate = false
    @State private var newName = ""
    @State private var search = ""
    // Driven by the ⌘F command; setting it true focuses the search field on macOS.
    @State private var searchPresented = false
    // "Select" mode: reveals leading checkboxes and a bulk-remove bar; row taps
    // toggle selection. Predefined networks are never selectable.
    @State private var selectMode = false
    @State private var selection = Set<String>()
    @State private var confirmRemove = false
    // Single-row removal awaiting confirmation; non-nil drives the per-network dialog.
    @State private var pendingRemove: DockerNetwork?

    /// Networks matching the filter, by name, driver or scope.
    private var filtered: [DockerNetwork] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return state.networks }
        return state.networks.filter {
            $0.name.lowercased().contains(q)
                || $0.driver.lowercased().contains(q)
                || $0.scope.lowercased().contains(q)
        }
    }

    /// Visible networks the user is allowed to remove — docker's built-in
    /// bridge/host/none are excluded, so they never enter a selection or count
    /// toward "Select All".
    private var removable: [DockerNetwork] { filtered.filter { !$0.isPredefined } }

    /// The selected networks, resolved against the removable (visible) list.
    private var selected: [DockerNetwork] { removable.filter { selection.contains($0.id) } }

    var body: some View {
        Group {
            if !state.colimaState.isRunning {
                RequiresColimaView(noun: "networks")
            } else if state.networks.isEmpty {
                ContentUnavailableView("No networks", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text("Create a network to connect containers."))
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                List(filtered) { network in
                    HStack(spacing: 12) {
                        if selectMode {
                            // Built-in networks can't be removed, so they show a
                            // lock instead of a checkbox and don't respond to taps.
                            if network.isPredefined {
                                Image(systemName: "lock")
                                    .foregroundStyle(.tertiary)
                                    .imageScale(.large)
                                    .help("Built-in network — can't be removed")
                            } else {
                                SelectionCheckmark(isSelected: selection.contains(network.id))
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(network.name).font(.body.weight(.medium))
                            Text(network.subtitle)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(network.networkID.prefix(12))
                            .font(.caption).foregroundStyle(.tertiary).monospaced()
                        if !selectMode && !network.isPredefined {
                            Button(role: .destructive) { pendingRemove = network } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove network")
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture { if selectMode && !network.isPredefined { toggle(network.id) } }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Networks")
        .searchable(text: $search, isPresented: $searchPresented, placement: .toolbar, prompt: "Filter networks")
        .onChange(of: state.findRequestToken) { searchPresented = true }
        .safeAreaInset(edge: .bottom) {
            if selectMode {
                SelectionBar(count: selected.count, total: removable.count,
                             onSelectAll: { selection = Set(removable.map(\.id)) },
                             onClear: { selection.removeAll() }) {
                    Button("Remove", role: .destructive) { confirmRemove = true }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showCreate = true } label: { Label("Create", systemImage: "plus") }
                    .disabled(!state.colimaState.isRunning || selectMode)
            }
            ToolbarItem(placement: .primaryAction) {
                Button(selectMode ? "Done" : "Select") {
                    selectMode.toggle()
                    if !selectMode { selection.removeAll() }
                }
                // Only built-in networks present → nothing is removable, so the
                // bulk-select affordance would be a dead end.
                .disabled(!state.colimaState.isRunning || !state.networks.contains { !$0.isPredefined })
            }
            RefreshButton()
        }
        .confirmationDialog("Remove \(selected.count) network\(selected.count == 1 ? "" : "s")?",
                            isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                state.removeNetworks(selected)
                selectMode = false
                selection.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Networks in use can't be removed. This cannot be undone.")
        }
        .confirmationDialog("Remove \(pendingRemove?.name ?? "network")?",
                            isPresented: Binding(get: { pendingRemove != nil },
                                                 set: { if !$0 { pendingRemove = nil } }),
                            titleVisibility: .visible, presenting: pendingRemove) { network in
            Button("Remove", role: .destructive) { state.removeNetwork(network) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Networks in use can't be removed. This cannot be undone.")
        }
        .alert("Create Network", isPresented: $showCreate) {
            TextField("Network name", text: $newName)
            Button("Create") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { state.createNetwork(name) }
                newName = ""
            }
            Button("Cancel", role: .cancel) { newName = "" }
        } message: {
            Text("Creates a bridge network containers can attach to.")
        }
    }

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }
}
