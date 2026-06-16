import SwiftUI

/// Sheet showing the tail of a container's logs.
struct LogsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let container: Container

    @State private var text = ""
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Logs · \(container.displayName)").font(.headline)
                Spacer()
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload")
                Button("Done") { dismiss() }
            }
            .padding(12)
            Divider()

            ScrollView {
                if isLoading {
                    ProgressView().padding(40)
                } else {
                    Text(text.isEmpty ? "No log output." : text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(width: 680, height: 460)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        text = await state.logs(for: container)
        isLoading = false
    }
}
