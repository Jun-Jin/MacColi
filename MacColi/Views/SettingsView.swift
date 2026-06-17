import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @State private var confirmDelete = false

    /// Mount drivers valid for a given backend. virtiofs is macOS+vz only.
    private func allowedMountTypes(for vmType: VMType) -> [MountType] {
        vmType == .vz ? MountType.allCases : MountType.allCases.filter { $0 != .virtiofs }
    }

    var body: some View {
        // `@Bindable` exposes bindings ($state.cpus, …) for an @Observable object
        // obtained from the environment.
        @Bindable var state = state

        Form {
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

            Section {
                Text("Changes apply the next time Colima starts. Use Apply to restart now with the new configuration.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Apply & Restart") { state.applyConfig() }
                        .disabled(!state.colimaState.isRunning || state.isBusy)
                    Spacer()
                }
            }

            Section("Danger Zone") {
                Button("Delete Colima VM…", role: .destructive) { confirmDelete = true }
                    .disabled(state.colimaState == .notInstalled || state.isBusy)
                Text("Deletes the VM and all its containers, images, and volumes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .alert("Delete Colima VM?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { state.deleteColima() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the VM and everything inside it. This cannot be undone.")
        }
    }
}
