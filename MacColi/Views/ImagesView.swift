import SwiftUI

struct ImagesView: View {
    @Environment(AppState.self) private var state
    @State private var showPull = false
    @State private var pullReference = ""
    @State private var search = ""
    // Driven by the ⌘F command; setting it true focuses the search field on macOS.
    @State private var searchPresented = false
    // "Select" mode: reveals leading checkboxes and a bulk-remove bar; row taps
    // toggle selection.
    @State private var selectMode = false
    @State private var selection = Set<String>()
    @State private var confirmRemove = false

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

    /// The selected images, resolved against the visible (filtered) list.
    private var selected: [DockerImage] { filtered.filter { selection.contains($0.id) } }

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
                        if selectMode {
                            SelectionCheckmark(isSelected: selection.contains(image.id))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(image.reference).font(.body.weight(.medium))
                            Text("\(image.size) · \(image.createdSince)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !selectMode {
                            Button(role: .destructive) { state.removeImage(image) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove image")
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture { if selectMode { toggle(image.id) } }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Images")
        .searchable(text: $search, isPresented: $searchPresented, placement: .toolbar, prompt: "Filter images")
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
                Button { showPull = true } label: { Label("Pull", systemImage: "arrow.down.circle") }
                    .disabled(!state.colimaState.isRunning || selectMode)
            }
            ToolbarItem(placement: .primaryAction) {
                Button(selectMode ? "Done" : "Select") {
                    selectMode.toggle()
                    if !selectMode { selection.removeAll() }
                }
                .disabled(!state.colimaState.isRunning || state.images.isEmpty)
            }
            RefreshButton()
        }
        .confirmationDialog("Remove \(selected.count) image\(selected.count == 1 ? "" : "s")?",
                            isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                state.removeImages(selected)
                selectMode = false
                selection.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Images in use will be force-removed. This cannot be undone.")
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

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }
}
