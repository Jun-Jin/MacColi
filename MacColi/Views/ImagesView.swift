import SwiftUI

struct ImagesView: View {
    @Environment(AppState.self) private var state
    @State private var showPull = false
    @State private var pullReference = ""
    @State private var search = ""
    // Driven by the ⌘F command; setting it true focuses the search field on macOS.
    @State private var searchPresented = false

    /// Images matching the filter, by reference, repository or tag.
    private var filtered: [DockerImage] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return state.images }
        return state.images.filter {
            $0.reference.lowercased().contains(q)
                || $0.repository.lowercased().contains(q)
                || $0.tag.lowercased().contains(q)
        }
    }

    var body: some View {
        Group {
            if !state.colimaState.isRunning {
                RequiresColimaView(noun: "images")
            } else if state.images.isEmpty {
                ContentUnavailableView("No images", systemImage: "square.stack.3d.up",
                                       description: Text("Pull an image to get started."))
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                List(filtered) { image in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(image.reference).font(.body.weight(.medium))
                            Text("\(image.size) · \(image.createdSince)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) { state.removeImage(image) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove image")
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Images")
        .searchable(text: $search, isPresented: $searchPresented, placement: .toolbar, prompt: "Filter images")
        .onChange(of: state.findRequestToken) { searchPresented = true }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showPull = true } label: { Label("Pull", systemImage: "arrow.down.circle") }
                    .disabled(!state.colimaState.isRunning)
            }
            RefreshButton()
        }
        .alert("Pull Image", isPresented: $showPull) {
            TextField("e.g. nginx:latest", text: $pullReference)
            Button("Pull") {
                let ref = pullReference.trimmingCharacters(in: .whitespaces)
                if !ref.isEmpty { state.pullImage(ref) }
                pullReference = ""
            }
            Button("Cancel", role: .cancel) { pullReference = "" }
        } message: {
            Text("Enter an image reference to pull from the registry.")
        }
    }
}
