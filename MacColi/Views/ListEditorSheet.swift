import SwiftUI

/// Create or edit a custom container list. One sheet serves both flows: it edits
/// a name and a membership set (container names), toggled from a checklist of the
/// live containers. Membership is stored by name (`Container.membershipKey`), so
/// the checklist keys off that too.
struct ListEditorSheet: View {
    enum Mode {
        case create(prefill: [String])
        case edit(ContainerList)
    }

    let mode: Mode
    /// Called with the new list's id after a successful create, so the presenter
    /// can select it. Unused for edits.
    var onCreate: ((ContainerList.ID) -> Void)?

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var selected: Set<String>
    /// Text filter over the container checklist. View-only: it never changes
    /// which keys are in `selected`, just which rows are visible.
    @State private var query = ""

    init(mode: Mode, onCreate: ((ContainerList.ID) -> Void)? = nil) {
        self.mode = mode
        self.onCreate = onCreate
        switch mode {
        case .create(let prefill):
            _name = State(initialValue: "")
            _selected = State(initialValue: Set(prefill))
        case .edit(let list):
            _name = State(initialValue: list.name)
            _selected = State(initialValue: Set(list.members))
        }
    }

    private var isEditing: Bool { if case .edit = mode { return true }; return false }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(spacing: 0) {
            Text(isEditing ? "Edit List" : "New List")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()

            Divider()

            TextField("List name", text: $name)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.top, 12)

            HStack {
                Text("Containers")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(selected.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 4)

            if !state.containers.isEmpty { searchField }

            containerPicker

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Create") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
            .padding()
        }
        .frame(width: 420, height: 540)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter containers", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear filter")
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    /// The checklist filtered by `query`. Empty query shows everything; otherwise
    /// each row must match on its name or image — substring, case-insensitive,
    /// matching the search in ContainersView / ImagesView.
    private var visibleContainers: [Container] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return state.containers }
        return state.containers.filter {
            $0.displayName.lowercased().contains(q) || $0.image.lowercased().contains(q)
        }
    }

    @ViewBuilder
    private var containerPicker: some View {
        if state.containers.isEmpty {
            ContentUnavailableView("No containers", systemImage: "shippingbox",
                                   description: Text("Run a container first, then add it here."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleContainers.isEmpty {
            ContentUnavailableView.search(text: query)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(visibleContainers) { c in
                HStack(spacing: 12) {
                    SelectionCheckmark(isSelected: selected.contains(c.membershipKey))
                    Circle()
                        .fill(c.isRunning ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.displayName).font(.body)
                        Text(c.image).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { toggle(c.membershipKey) }
            }
            .listStyle(.inset)
        }
    }

    private func toggle(_ key: String) {
        if selected.contains(key) { selected.remove(key) } else { selected.insert(key) }
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        switch mode {
        case .create:
            let id = state.createList(name: trimmedName, members: Array(selected))
            onCreate?(id)
        case .edit(let list):
            if list.name != trimmedName { state.renameList(list.id, to: trimmedName) }
            state.setMembers(list.id, to: Array(selected))
        }
        dismiss()
    }
}
