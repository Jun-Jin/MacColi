import SwiftUI

enum Panel: String, CaseIterable, Identifiable {
    case containers, images, volumes, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .containers: return "Containers"
        case .images: return "Images"
        case .volumes: return "Volumes"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .containers: return "shippingbox"
        case .images: return "square.stack.3d.up"
        case .volumes: return "externaldrive"
        case .settings: return "gearshape"
        }
    }
}

struct DashboardView: View {
    @Environment(AppState.self) private var state
    @State private var selection: Panel? = .containers

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(Panel.allCases, selection: $selection) { panel in
                    Label(panel.title, systemImage: panel.systemImage)
                        .tag(panel)
                }
                .listStyle(.sidebar)

                Divider()
                ColimaControlView()
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
    }

    @ViewBuilder
    private func detail(for panel: Panel) -> some View {
        switch panel {
        case .containers: ContainersView()
        case .images: ImagesView()
        case .volumes: VolumesView()
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
                    Button { state.errorMessage = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Color.orange.opacity(0.12))
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
                Button("Install Colima…") { TerminalLauncher.run("brew install colima docker") }
            }
        }
    }
}
