import SwiftUI

/// In-app installer sheet. Streams `brew install colima docker` output live
/// instead of opening Terminal.
struct InstallView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Install Colima & Docker", systemImage: "arrow.down.circle")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .disabled(state.isInstalling)
            }
            .padding(12)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    Text(state.installLog.isEmpty ? "Preparing…" : state.installLog)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: state.installLog) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }

            Divider()
            HStack(spacing: 8) {
                if state.isInstalling {
                    ProgressView().controlSize(.small)
                    Text("Installing via Homebrew… this can take a few minutes.")
                        .font(.callout).foregroundStyle(.secondary)
                } else if let error = state.installError {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    Text(error).font(.callout).textSelection(.enabled)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Finished.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
        }
        .frame(width: 660, height: 460)
    }
}
