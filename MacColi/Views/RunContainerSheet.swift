import SwiftUI

/// Sheet that collects `docker run` parameters and starts a container. Launched
/// from the Images list with the image reference prefilled (and editable).
struct RunContainerSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var image: String
    // True once the user opts to type an arbitrary reference (the "Custom…"
    // pull-down entry) instead of picking a locally-pulled image.
    @State private var isCustom = false
    @State private var name = ""
    // Empty = docker's default bridge; otherwise a network name (--network).
    @State private var network = ""
    @State private var ports: [EditableField] = []
    @State private var env: [EditableField] = []
    @State private var volumes: [EditableField] = []
    @State private var command = ""

    init(image: String) {
        _image = State(initialValue: image)
    }

    private var canRun: Bool { !image.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Tagged, already-pulled images offered in the pull-down. Dangling (`<none>`)
    /// images are omitted — they have no useful reference to run by.
    private var pulledReferences: [String] {
        state.images
            .filter { $0.repository != "<none>" && $0.tag != "<none>" }
            .map(\.reference)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Networks offered in the picker. "bridge" is omitted — "Default (bridge)"
    /// already represents it (running with no --network uses the default bridge).
    private var networkOptions: [DockerNetwork] {
        state.networks.filter { $0.name != "bridge" }
    }

    /// Pull-down's current-selection label: "Custom…" while typing a custom
    /// reference, otherwise the chosen image (or a placeholder when none yet).
    private var menuLabel: String {
        if isCustom { return "Custom…" }
        return image.isEmpty ? "Select an image" : image
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Image") {
                    // Pick from locally-pulled images. "Custom…" keeps the
                    // pull-down (showing "Custom…") and reveals a free-text field
                    // below, where any reference works — docker pulls it if absent.
                    if pulledReferences.isEmpty {
                        TextField("", text: $image)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        HStack(spacing: 8) {
                            Menu(menuLabel) {
                                ForEach(pulledReferences, id: \.self) { ref in
                                    Button(ref) { image = ref; isCustom = false }
                                }
                                Divider()
                                Button("Custom…") { image = ""; isCustom = true }
                            }
                            // Hug the label so the field gets the rest of the row.
                            .fixedSize()
                            if isCustom {
                                TextField("", text: $image)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                }
                Section("Name") {
                    TextField("Optional", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                Section("Network") {
                    Picker("Network", selection: $network) {
                        Text("Default (bridge)").tag("")
                        ForEach(networkOptions) { net in
                            Text(net.name).tag(net.name)
                        }
                    }
                    .labelsHidden()
                }
                FieldListSection(title: "Ports", placeholder: "8080:80",
                                 systemImage: "arrow.left.arrow.right", fields: $ports)
                FieldListSection(title: "Environment", placeholder: "KEY=value",
                                 systemImage: "character.cursor.ibeam", fields: $env)
                FieldListSection(title: "Volumes", placeholder: "host:container",
                                 systemImage: "externaldrive", fields: $volumes)
                Section("Command") {
                    TextField("Optional", text: $command)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack(spacing: 12) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Run") { run() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canRun)
            }
            .padding(12)
        }
        .frame(width: 460, height: 560)
        .onAppear {
            // A prefilled reference that isn't a clean pulled tag (e.g. a dangling
            // image's id) starts in the text field so it stays visible/editable.
            if !image.isEmpty && !pulledReferences.contains(image) { isCustom = true }
        }
    }

    private func run() {
        state.runContainer(ContainerRunSpec(
            image: image,
            name: name,
            network: network,
            ports: ports.map(\.value),
            env: env.map(\.value),
            volumes: volumes.map(\.value),
            command: command
        ))
        dismiss()
    }
}

/// One editable text row in a `FieldListSection`. A stable `id` lets ForEach
/// track rows across insertions/removals so focus and text don't jump.
struct EditableField: Identifiable {
    let id = UUID()
    var value: String = ""
}

/// A Form section holding a variable-length list of single-line text rows, each
/// removable, with an "Add" button that appends a fresh empty row.
private struct FieldListSection: View {
    let title: String
    let placeholder: String
    let systemImage: String
    @Binding var fields: [EditableField]

    var body: some View {
        Section {
            ForEach($fields) { $field in
                HStack(spacing: 8) {
                    TextField(placeholder, text: $field.value)
                        .textFieldStyle(.roundedBorder)
                    Button(role: .destructive) {
                        fields.removeAll { $0.id == field.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove")
                }
            }
            Button { fields.append(EditableField()) } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        } header: {
            Label(title, systemImage: systemImage)
        }
    }
}
