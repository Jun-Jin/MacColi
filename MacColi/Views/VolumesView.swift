import SwiftUI

struct VolumesView: View {
    @Environment(AppState.self) private var state
    @State private var showCreate = false
    @State private var newName = ""
    @State private var search = ""
    // Driven by the ⌘F command; setting it true focuses the search field on macOS.
    @State private var searchPresented = false

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
                        VStack(alignment: .leading, spacing: 2) {
                            Text(volume.name).font(.body.weight(.medium))
                            Text(volume.mountpoint)
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(volume.driver).font(.caption).foregroundStyle(.tertiary)
                        Button(role: .destructive) { state.removeVolume(volume) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove volume")
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Volumes")
        .searchable(text: $search, isPresented: $searchPresented, placement: .toolbar, prompt: "Filter volumes")
        .onChange(of: state.findRequestToken) { searchPresented = true }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showCreate = true } label: { Label("Create", systemImage: "plus") }
                    .disabled(!state.colimaState.isRunning)
            }
            RefreshButton()
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
}
