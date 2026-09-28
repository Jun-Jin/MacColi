import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(UpdateChecker.self) private var updater
    @State private var confirmDelete = false
    @State private var importingCert = false
    @State private var showNewProfile = false
    @State private var newProfileName = ""

    /// File types accepted by the CA importer. `.x509Certificate` covers DER/CER;
    /// PEM is plain text, so `.pem`/`.crt`-style content is allowed via `.text`
    /// and the broad `.data` fallback (some exporters use generic types).
    private var certContentTypes: [UTType] {
        var types: [UTType] = [.x509Certificate, .text, .data]
        if let pem = UTType(filenameExtension: "pem") { types.append(pem) }
        if let crt = UTType(filenameExtension: "crt") { types.append(crt) }
        if let cer = UTType(filenameExtension: "cer") { types.append(cer) }
        return types
    }

    /// Mount drivers valid for a given backend. virtiofs is macOS+vz only.
    private func allowedMountTypes(for vmType: VMType) -> [MountType] {
        vmType == .vz ? MountType.allCases : MountType.allCases.filter { $0 != .virtiofs }
    }

    var body: some View {
        // `@Bindable` exposes bindings ($state.cpus, …) for an @Observable object
        // obtained from the environment.
        @Bindable var state = state

        Form {
            Section("Profile") {
                Picker("Profile", selection: $state.profile) {
                    ForEach(state.availableProfiles, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                // Disabled while a lifecycle command runs so the switch can't
                // re-point status/resources mid start/stop of another VM.
                .disabled(state.isBusy)
                Button("New Profile…") {
                    newProfileName = ""
                    showNewProfile = true
                }
                .disabled(state.isBusy)
                Text("Each profile is a separate VM with its own containers, images, and volumes. Switching re-points the whole app — status, resources, and the settings below. A new profile's VM is created on its first Start.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Virtual Machine") {
                Stepper("CPUs: \(state.cpus)", value: $state.cpus, in: 1...16)
                Stepper("Memory: \(state.memoryGiB) GiB", value: $state.memoryGiB, in: 1...64)
                Stepper("Disk: \(state.diskGiB) GiB", value: $state.diskGiB, in: 10...512, step: 10)
                Picker("Runtime", selection: $state.runtime) {
                    ForEach(ContainerRuntime.allCases) { runtime in
                        Text(runtime.label).tag(runtime)
                    }
                }
                Picker("Architecture", selection: $state.arch) {
                    ForEach(VMArch.allCases) { arch in
                        Text(arch.label).tag(arch)
                    }
                }
                Picker("VM Type", selection: $state.vmType) {
                    ForEach(VMType.allCases) { vmType in
                        Text(vmType.label).tag(vmType)
                    }
                }
                Picker("Mount Type", selection: $state.mountType) {
                    // virtiofs is only valid with the vz backend, so it's hidden
                    // under qemu to keep the selection startable.
                    ForEach(allowedMountTypes(for: state.vmType)) { mountType in
                        Text(mountType.label).tag(mountType)
                    }
                }
                Toggle("Rosetta 2 (fast linux/amd64)", isOn: $state.vzRosetta)
                    .disabled(state.vmType != .vz)
                Text("Architecture, VM type, mount type, and runtime are fixed once the VM is created — changing them only takes effect on a fresh VM.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Network") {
                TextField("Hostname", text: $state.hostname, prompt: Text("colima"))
                Toggle("Assign reachable IP address", isOn: $state.networkAddress)
                Toggle("Forward SSH agent", isOn: $state.sshAgent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom DNS hosts")
                    TextField("host=target, one per line", text: $state.dnsHostsText, axis: .vertical)
                        .lineLimit(2...5)
                        .font(.system(.body, design: .monospaced))
                    Text("Maps DNS names to a custom IP or host, e.g. host.docker.internal=host.lima.internal")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Kubernetes") {
                Toggle("Enable Kubernetes (k3s)", isOn: $state.kubernetesEnabled)
                TextField("Version", text: $state.kubernetesVersion, prompt: Text("latest stable"))
                    .disabled(!state.kubernetesEnabled)
            }

            Section("Custom Root CA Certificates") {
                if state.caCertificates.isEmpty {
                    Text("No certificates added.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(state.caCertificates, id: \.self) { name in
                        HStack {
                            Image(systemName: "lock.shield").foregroundStyle(.secondary)
                            Text(name).font(.system(.body, design: .monospaced))
                            Spacer()
                            Button(role: .destructive) {
                                state.removeCACertificate(name)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                Button("Add Certificate…") { importingCert = true }
                Text("Installs the certificate into the VM's trust store on the next start — the fix for `x509: certificate signed by unknown authority` errors behind a TLS-inspecting corporate proxy. Apply & Restart to take effect now.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Text("Changes apply the next time Colima starts. Apply restarts now with the new configuration. Reload re-reads the VM's colima.yaml from disk, discarding edits made here.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Apply & Restart") { state.applyConfig() }
                        .disabled(!state.colimaState.isRunning || state.isBusy)
                    Button("Reload from colima.yaml") { state.reloadConfigFromVM() }
                        .disabled(state.colimaState == .notInstalled || state.isBusy)
                    Spacer()
                }
            }

            Section("Updates") {
                HStack {
                    Button("Check for Updates") {
                        Task { await updater.check() }
                    }
                    .disabled(updater.phase == .checking || updater.phase == .upgrading)
                    if updater.phase == .checking {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    Text("Version \(updater.currentVersion)")
                        .foregroundStyle(.secondary)
                }
                switch updater.phase {
                case .upToDate:
                    Text("MacColi is up to date.")
                        .font(.caption).foregroundStyle(.secondary)
                case .available(let version):
                    HStack {
                        Text("Version \(version) is available.")
                        Spacer()
                        if updater.isBrewInstall {
                            Button("Update via Homebrew") {
                                Task { await updater.upgrade() }
                            }
                        } else {
                            // No cask entry to upgrade — the user installed the
                            // DMG by hand, so hand them the download instead.
                            Link("Open Releases Page", destination: UpdateChecker.releasesPage)
                        }
                    }
                case .upgrading:
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(updater.upgradeStatusLine.isEmpty
                             ? "Running brew upgrade…" : updater.upgradeStatusLine)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                case .relaunchReady:
                    HStack {
                        Text("Update installed. Relaunch to start using it.")
                        Spacer()
                        Button("Relaunch MacColi") { updater.relaunch() }
                    }
                case .failed(let message):
                    Text(message)
                        .font(.caption).foregroundStyle(.red)
                case .idle, .checking:
                    EmptyView()
                }
            }

            Section("Danger Zone") {
                Button("Delete Colima VM & Profile…", role: .destructive) { confirmDelete = true }
                    .disabled(state.colimaState == .notInstalled || state.isBusy)
                Text("Deletes the VM — containers, images, and volumes — and the profile's configuration folder. The selection then returns to “default”.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .fileImporter(isPresented: $importingCert,
                      allowedContentTypes: certContentTypes,
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { state.addCACertificate(url) }
            case .failure(let error):
                state.errorMessage = "Couldn't read the certificate: \(error.localizedDescription)"
            }
        }
        .alert("New Profile", isPresented: $showNewProfile) {
            TextField("Name", text: $newProfileName)
            Button("Create") { state.selectNewProfile(newProfileName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Names the new Colima profile. Its VM is created with the current settings when you press Start.")
        }
        .alert(deleteVMCopy.title, isPresented: $confirmDelete) {
            Button(deleteVMCopy.actionLabel, role: .destructive) { state.deleteColima() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteVMCopy.message)
        }
    }

    private var deleteVMCopy: ConfirmationCopy {
        Confirmations.deleteVM(profile: state.profile, hasCustomProvisioning: state.hasCustomProvisioning)
    }
}
