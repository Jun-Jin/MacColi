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

/// What the sidebar (and detail pane) is pointed at. Distinct from `Panel`
/// because the Containers item expands into "All Containers" plus any number of
/// user-defined lists — each a selectable destination that reuses ContainersView.
/// The remaining cases mirror `Panel` one-for-one.
enum SidebarSelection: Hashable {
    case containers                 // "All Containers"
    case list(UUID)
    case images, volumes, networks, settings
}

struct DashboardView: View {
    @Environment(AppState.self) private var state
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: SidebarSelection? = .containers
    @State private var containersExpanded = true

    // Container-list editing UI. `creating` presents the new-list sheet; `editing`
    // presents the membership editor for an existing list; `renaming`/`renameText`
    // drive the quick-rename alert; `pendingDelete` drives the delete confirmation.
    @State private var creating = false
    @State private var editing: ContainerList?
    @State private var renaming: ContainerList?
    @State private var renameText = ""
    @State private var pendingDelete: ContainerList?

    var body: some View {
        @Bindable var state = state
        return NavigationSplitView {
            VStack(spacing: 0) {
                sidebar
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
        .sheet(isPresented: $creating) {
            ListEditorSheet(mode: .create(prefill: [])) { selection = .list($0) }
        }
        .sheet(item: $editing) { list in
            ListEditorSheet(mode: .edit(list))
        }
        .alert("Rename List", isPresented: renamingBinding) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let renaming, !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                    state.renameList(renaming.id, to: renameText)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete list \(pendingDelete?.name ?? "")?",
                            isPresented: pendingDeleteBinding, titleVisibility: .visible,
                            presenting: pendingDelete) { list in
            Button("Delete List", role: .destructive) {
                if selection == .list(list.id) { selection = .containers }
                state.deleteList(list.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes the list only. The containers in it are not affected.")
        }
        // A banner button can request a jump to a panel (e.g. Settings to add a
        // CA cert); honor it here where the sidebar selection lives, then clear.
        .onChange(of: state.requestedPanel) { _, panel in
            guard let panel else { return }
            selection = Self.selection(for: panel)
            state.requestedPanel = nil
        }
        // Poll fast only while this window is frontmost; back off otherwise so a
        // closed/backgrounded app stops round-tripping into the VM every 4s.
        .onChange(of: scenePhase) { _, phase in
            state.setActivePolling(phase == .active)
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            DisclosureGroup(isExpanded: $containersExpanded) {
                Label("All Containers", systemImage: Panel.containers.systemImage)
                    .tag(SidebarSelection.containers)
                ForEach(state.containerLists) { list in
                    Label(list.name, systemImage: "line.3.horizontal")
                        .tag(SidebarSelection.list(list.id))
                        .contextMenu {
                            Button("Edit…") { editing = list }
                            Button("Rename…") { renaming = list; renameText = list.name }
                            Divider()
                            Button("Delete", role: .destructive) { pendingDelete = list }
                        }
                }
            } label: {
                HStack(spacing: 0) {
                    Label(Panel.containers.title, systemImage: Panel.containers.systemImage)
                    Spacer()
                    Button { creating = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("New Container List")
                }
            }

            Label(Panel.images.title, systemImage: Panel.images.systemImage)
                .tag(SidebarSelection.images)
            Label(Panel.volumes.title, systemImage: Panel.volumes.systemImage)
                .tag(SidebarSelection.volumes)
            Label(Panel.networks.title, systemImage: Panel.networks.systemImage)
                .tag(SidebarSelection.networks)
            Label(Panel.settings.title, systemImage: Panel.settings.systemImage)
                .tag(SidebarSelection.settings)
        }
        .listStyle(.sidebar)
    }

    /// Presenting a rename via `.alert(isPresented:)` needs a Bool binding; derive
    /// it from `renaming` so dismissal clears the target.
    private var renamingBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }
    private var pendingDeleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    /// Maps a banner-requested `Panel` onto the sidebar's richer selection type.
    private static func selection(for panel: Panel) -> SidebarSelection {
        switch panel {
        case .containers: return .containers
        case .images: return .images
        case .volumes: return .volumes
        case .networks: return .networks
        case .settings: return .settings
        }
    }

    @ViewBuilder
    private func detail(for selection: SidebarSelection) -> some View {
        switch selection {
        case .containers:
            ContainersView(list: nil).id("all-containers")
        case .list(let id):
            // A list can vanish (deleted elsewhere) while still selected; fall back
            // to All Containers. `.id` keys view identity per list so the panel's
            // local state (search text, Select mode) resets when switching lists.
            if let list = state.containerLists.first(where: { $0.id == id }) {
                ContainersView(list: list).id(id)
            } else {
                ContainersView(list: nil).id("all-containers")
            }
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
