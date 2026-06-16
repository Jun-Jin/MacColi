import SwiftUI

/// Status pill + lifecycle controls shown at the bottom of the sidebar.
struct ColimaControlView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text("Colima")
                    .font(.headline)
                Spacer()
                Text(state.colimaState.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let instance = runningInstance {
                Text("\(instance.cpus ?? 0) CPU · \(Format.bytes(instance.memory)) · \(instance.runtime ?? "—")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            controls
        }
    }

    private var runningInstance: ColimaInstance? {
        if case .running(let instance) = state.colimaState { return instance }
        return nil
    }

    @ViewBuilder
    private var controls: some View {
        switch state.colimaState {
        case .notInstalled:
            Button {
                state.installColima()
            } label: {
                Label("Install Colima…", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
            .help("Installs Colima and Docker via Homebrew, inside the app")

        case .running:
            HStack(spacing: 8) {
                Button(role: .destructive) { state.stopColima() } label: {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                Button { state.restartColima() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Restart Colima")
            }
            .disabled(state.isBusy)

        case .starting, .stopping:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(state.colimaState.label).font(.caption)
            }

        default: // stopped / unknown
            Button { state.startColima() } label: {
                Label("Start", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .disabled(state.isBusy)
        }
    }

    private var statusColor: Color {
        switch state.colimaState {
        case .running: return .green
        case .starting, .stopping: return .yellow
        case .notInstalled: return .gray
        default: return .red
        }
    }
}
