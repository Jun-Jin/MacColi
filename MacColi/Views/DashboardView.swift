import SwiftUI

enum Panel: String, CaseIterable, Identifiable {
    case containers, images, volumes, networks, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .containers: return "Containers"
        case .images: return "Images"
        case .volumes: return "Volumes"
        case .networks: return "Networks"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .containers: return "shippingbox"
        case .images: return "square.stack.3d.up"
        case .volumes: return "externaldrive"
        case .networks: return "point.3.connected.trianglepath.dotted"
        case .settings: return "gearshape"
        }
    }
}

struct DashboardView: View {
    @Environment(AppState.self) private var state
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: Panel? = .containers

    var body: some View {
        @Bindable var state = state
        return NavigationSplitView {
            VStack(spacing: 0) {
                List(Panel.allCases, selection: $selection) { panel in
                    Label(panel.title, systemImage: panel.systemImage)
                        .tag(panel)
                }
                .listStyle(.sidebar)

                Divider()
                VStack(spacing: 12) {
                    if state.colimaState.isRunning { VMMonitorSection() }
                    ColimaControlView()
                }
                .padding(12)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            VStack(spacing: 0) {
                StatusBanner()
                detail(for: selection ?? .containers)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("MacColi")
        .sheet(isPresented: $state.showInstaller) {
            InstallView()
        }
        // A banner button can request a jump to a panel (e.g. Settings to add a
        // CA cert); honor it here where the sidebar selection lives, then clear.
        .onChange(of: state.requestedPanel) { _, panel in
            guard let panel else { return }
            selection = panel
            state.requestedPanel = nil
        }
        // Poll fast only while this window is frontmost; back off otherwise so a
        // closed/backgrounded app stops round-tripping into the VM every 4s.
        .onChange(of: scenePhase) { _, phase in
            state.setActivePolling(phase == .active)
        }
    }

    @ViewBuilder
    private func detail(for panel: Panel) -> some View {
        switch panel {
        case .containers: ContainersView()
        case .images: ImagesView()
        case .volumes: VolumesView()
        case .networks: NetworksView()
        case .settings: SettingsView()
        }
    }
}

/// Busy/error feedback strip shown above the active panel.
struct StatusBanner: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            if state.isBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(state.busyMessage.isEmpty ? "Working…" : state.busyMessage)
                        .font(.callout)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.quaternary)
            }
            if let error = state.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.callout).textSelection(.enabled)
                    Spacer()
                    // Surfaced only for TLS-trust failures: jump straight to the
                    // Settings section where the root CA is imported.
                    if state.caCertIssue {
                        Button("Open Settings") { state.requestedPanel = .settings }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    Button { state.errorMessage = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Color.orange.opacity(0.12))
            }
            if let info = state.infoMessage {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(info).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button { state.infoMessage = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Color.green.opacity(0.12))
            }
        }
    }
}

/// Shown by resource panels when Colima isn't running.
struct RequiresColimaView: View {
    @Environment(AppState.self) private var state
    let noun: String

    var body: some View {
        ContentUnavailableView {
            Label("Colima is not running", systemImage: "exclamationmark.octagon")
        } description: {
            Text("Start Colima to manage \(noun).")
        } actions: {
            if case .stopped = state.colimaState {
                Button("Start Colima") { state.startColima() }
                    .buttonStyle(.borderedProminent)
            } else if case .notInstalled = state.colimaState {
                Button("Install Colima…") { state.installColima() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
