import SwiftUI

/// Status pill + lifecycle controls shown at the bottom of the sidebar.
struct ColimaControlView: View {
    @Environment(AppState.self) private var state
    @State private var confirmPrune = false

    var body: some View {
        @Bindable var state = state

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                // The header doubles as the profile switcher: it names the VM
                // the status and controls target, and clicking it re-points the
                // app. Same binding as the Settings picker, so the two stay in
                // step. Creating profiles stays in Settings — this only switches.
                Menu {
                    Picker("Profile", selection: $state.profile) {
                        ForEach(state.availableProfiles, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(state.profile == "default" ? "Colima" : "Colima · \(state.profile)")
                        .font(.headline)
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                // Same guard as Settings: no re-pointing mid start/stop.
                .disabled(state.isBusy)
                .help("Switch Colima profile")
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
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button(role: .destructive) { state.stopColima() } label: {
                        Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    Button { state.restartColima() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Restart Colima")
                }
                Button { confirmPrune = true } label: {
                    Label("Clean Up…", systemImage: "sparkles").frame(maxWidth: .infinity)
                }
                .help("docker system prune — remove unused containers, images, networks, and build cache older than 24h")
            }
            .disabled(state.isBusy)
            .confirmationDialog(Confirmations.prune.title,
                                isPresented: $confirmPrune, titleVisibility: .visible) {
                Button(Confirmations.prune.actionLabel, role: .destructive) { state.pruneSystem() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(Confirmations.prune.message)
            }

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
