import SwiftUI

struct VolumesView: View {
    @Environment(AppState.self) private var state
    @State private var showCreate = false
    @State private var newName = ""
    @State private var search = ""
    // Driven by the ⌘F command; setting it true focuses the search field on macOS.
    @State private var searchPresented = false
    // "Select" mode: reveals leading checkboxes and a bulk-remove bar; row taps
    // toggle selection.
    @State private var selectMode = false
    @State private var selection = Set<String>()
    @State private var confirmRemove = false

    /// Volumes matching the filter, by name, driver or mountpoint.
    private var filtered: [Volume] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return state.volumes }
        return state.volumes.filter {
            $0.name.lowercased().contains(q)
                || $0.driver.lowercased().contains(q)
                || $0.mountpoint.lowercased().contains(q)
        }
    }

    /// The selected volumes, resolved against the visible (filtered) list.
    private var selected: [Volume] { filtered.filter { selection.contains($0.id) } }

    var body: some View {
        Group {
            if !state.colimaState.isRunning {
                RequiresColimaView(noun: "volumes")
            } else if state.volumes.isEmpty {
                ContentUnavailableView("No volumes", systemImage: "externaldrive",
                                       description: Text("Create a volume to persist container data."))
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                List(filtered) { volume in
                    HStack(spacing: 12) {
                        if selectMode {
                            SelectionCheckmark(isSelected: selection.contains(volume.id))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(volume.name).font(.body.weight(.medium))
                            Text(volume.mountpoint)
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(volume.driver).font(.caption).foregroundStyle(.tertiary)
                        if !selectMode {
                            Button(role: .destructive) { state.removeVolume(volume) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove volume")
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture { if selectMode { toggle(volume.id) } }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Volumes")
        .searchable(text: $search, isPresented: $searchPresented, placement: .toolbar, prompt: "Filter volumes")
        .onChange(of: state.findRequestToken) { searchPresented = true }
        .safeAreaInset(edge: .bottom) {
            if selectMode {
                SelectionBar(count: selected.count, total: filtered.count,
                             onSelectAll: { selection = Set(filtered.map(\.id)) },
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
                .disabled(!state.colimaState.isRunning || state.volumes.isEmpty)
            }
            RefreshButton()
        }
        .confirmationDialog("Remove \(selected.count) volume\(selected.count == 1 ? "" : "s")?",
                            isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                state.removeVolumes(selected)
                selectMode = false
                selection.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
        .alert("Create Volume", isPresented: $showCreate) {
            TextField("Volume name", text: $newName)
            Button("Create") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { state.createVolume(name) }
                newName = ""
            }
            Button("Cancel", role: .cancel) { newName = "" }
        }
    }

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }
}
