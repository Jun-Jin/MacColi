import SwiftUI

struct VolumesView: View {
    @Environment(AppState.self) private var state
    @State private var showCreate = false
    @State private var newName = ""

    var body: some View {
        Group {
            if !state.colimaState.isRunning {
                RequiresColimaView(noun: "volumes")
            } else if state.volumes.isEmpty {
                ContentUnavailableView("No volumes", systemImage: "externaldrive",
                                       description: Text("Create a volume to persist container data."))
            } else {
                List(state.volumes) { volume in
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
