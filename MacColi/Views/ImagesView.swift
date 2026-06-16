import SwiftUI

struct ImagesView: View {
    @Environment(AppState.self) private var state
    @State private var showPull = false
    @State private var pullReference = ""

    var body: some View {
        Group {
            if !state.colimaState.isRunning {
                RequiresColimaView(noun: "images")
            } else if state.images.isEmpty {
                ContentUnavailableView("No images", systemImage: "square.stack.3d.up",
                                       description: Text("Pull an image to get started."))
            } else {
                List(state.images) { image in
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
