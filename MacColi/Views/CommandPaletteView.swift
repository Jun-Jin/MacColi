import SwiftUI

// MARK: - Command model

/// One executable entry in the ⇧⌘P command palette.
struct PaletteCommand: Identifiable {
    /// Display grouping; also the default ordering when the query is empty.
    enum Section {
        case navigation, colima, workflows, containers

        var label: String {
            switch self {
            case .navigation: return "Go to"
            case .colima: return "Colima"
            case .workflows: return "Workflow"
            case .containers: return "Container"
            }
        }
    }

    let id: String
    let title: String
    var subtitle: String?
    let systemImage: String
    let section: Section
    /// Extra match terms beyond the title (e.g. a container's image reference),
    /// so "nginx" finds "Restart web-1" when web-1 runs an nginx image.
    var keywords: String = ""
    /// Present on destructive commands: the palette interposes a confirmation
    /// dialog with this content (from `Confirmations`, shared with the panels)
    /// instead of running the action directly.
    var confirmation: ConfirmationCopy?
    let action: @MainActor () -> Void

    var searchText: String { keywords.isEmpty ? title : title + " " + keywords }
}

// MARK: - Fuzzy matching

enum PaletteMatch {
    /// Scores `query` against `text`; nil when they don't match. The query is
    /// split on whitespace and every token must match independently, so
    /// "stop web" finds "Stop web-1". Per token: prefix > word start >
    /// substring > in-order subsequence. Higher total is better.
    static func score(query: String, in text: String) -> Int? {
        let text = fold(text)
        var total = 0
        for token in fold(query).split(whereSeparator: \.isWhitespace) {
            guard let s = tokenScore(token, in: text) else { return nil }
            total += s
        }
        return total
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }

    private static func tokenScore(_ token: Substring, in text: String) -> Int? {
        guard !token.isEmpty else { return 0 }
        if text.hasPrefix(token) { return 100 }
        if let range = text.range(of: token) {
            // Not at startIndex here — hasPrefix already covered that case.
            let before = text[text.index(before: range.lowerBound)]
            let wordStart = !before.isLetter && !before.isNumber
            return wordStart ? 60 : 30
        }
        var cursor = text.startIndex
        for ch in token {
            guard let found = text[cursor...].firstIndex(of: ch) else { return nil }
            cursor = text.index(after: found)
        }
        return 10
    }
}

// MARK: - Overlay

/// Full-window presentation layer for the palette: dims the dashboard and
/// dismisses on a click outside the panel. Shown while
/// `AppState.showCommandPalette` is set (toggled by the ⇧⌘P menu command).
struct CommandPaletteOverlay: View {
    @Environment(AppState.self) private var state
    @Binding var selection: SidebarSelection?

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.15)
                .onTapGesture { state.showCommandPalette = false }
            CommandPaletteView(selection: $selection)
                .padding(.top, 100)
        }
    }
}

// MARK: - Palette

struct CommandPaletteView: View {
    @Environment(AppState.self) private var state
    @Environment(WorkflowStore.self) private var workflows
    @Environment(\.openWindow) private var openWindow
    @Binding var selection: SidebarSelection?

    @State private var query = ""
    @State private var selectedIndex = 0
    /// A destructive command awaiting confirmation; drives the dialog.
    @State private var pendingCommand: PaletteCommand?
    @FocusState private var searchFocused: Bool

    var body: some View {
        let commands = filteredCommands
        VStack(spacing: 0) {
            searchField
            Divider()
            if commands.isEmpty {
                Text("No matching commands")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                commandList(commands)
            }
            Divider()
            footer
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        .onAppear { grabSearchFocus() }
        .onExitCommand { dismiss() }
        .onChange(of: query) { selectedIndex = 0 }
        .confirmationDialog(pendingCommand?.confirmation?.title ?? "",
                            isPresented: confirmationShown, titleVisibility: .visible,
                            presenting: pendingCommand) { command in
            Button(command.confirmation?.actionLabel ?? "Confirm", role: .destructive) {
                dismiss()
                command.action()
            }
            Button("Cancel", role: .cancel) {}
        } message: { command in
            Text(command.confirmation?.message ?? "")
        }
        // Cancelling the dialog returns to the still-open palette; hand focus
        // back to the search field so the keyboard flow isn't dead-ended.
        .onChange(of: pendingCommand == nil) { _, cleared in
            if cleared { grabSearchFocus() }
        }
    }

    private var confirmationShown: Binding<Bool> {
        Binding(get: { pendingCommand != nil },
                set: { if !$0 { pendingCommand = nil } })
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search commands…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .onSubmit { runSelected() }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
        }
        .padding(12)
    }

    private func commandList(_ commands: [PaletteCommand]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                        row(command, isSelected: index == selectedIndex)
                            .onTapGesture { run(command) }
                            .onHover { if $0 { selectedIndex = index } }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 360)
            .onChange(of: selectedIndex) {
                guard commands.indices.contains(selectedIndex) else { return }
                proxy.scrollTo(commands[selectedIndex].id)
            }
        }
    }

    private func row(_ command: PaletteCommand, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: command.systemImage)
                .frame(width: 20)
                .foregroundStyle(isSelected ? .white : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(command.title)
                    .foregroundStyle(isSelected ? .white : .primary)
                if let subtitle = command.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                }
            }
            Spacer()
            Text(command.section.label)
                .font(.caption2)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.7))
                                            : AnyShapeStyle(.tertiary))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(isSelected ? Color.accentColor : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("↑↓ navigate")
            Text("↩ run")
            Text("esc close")
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Actions

    /// Moves keyboard focus into the search field. Claiming focus in the same
    /// turn the overlay is inserted is unreliable on macOS — the field may not
    /// be registered with the focus system yet, leaving ⇧⌘P opening a palette
    /// that ignores typing. Retry briefly until the claim sticks (`searchFocused`
    /// reads back the system's actual focus, so success ends the loop).
    private func grabSearchFocus() {
        searchFocused = true
        Task { @MainActor in
            for _ in 0..<5 {
                try? await Task.sleep(for: .milliseconds(40))
                if searchFocused { return }
                searchFocused = true
            }
        }
    }

    private func dismiss() {
        state.showCommandPalette = false
    }

    private func move(_ delta: Int) {
        let count = filteredCommands.count
        guard count > 0 else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), count - 1)
    }

    private func runSelected() {
        let commands = filteredCommands
        guard commands.indices.contains(selectedIndex) else { return }
        run(commands[selectedIndex])
    }

    private func run(_ command: PaletteCommand) {
        if command.confirmation != nil {
            pendingCommand = command
        } else {
            dismiss()
            command.action()
        }
    }

    // MARK: - Command building

    private var filteredCommands: [PaletteCommand] {
        let all = allCommands
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.enumerated()
            .compactMap { index, command in
                PaletteMatch.score(query: q, in: command.searchText)
                    .map { (index: index, command: command, score: $0) }
            }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .map(\.command)
    }

    /// The full command list, rebuilt from live state on each evaluation so
    /// entries always reflect what's actually possible (a stopped container
    /// offers Start, a running one Stop/Restart/Shell, …).
    private var allCommands: [PaletteCommand] {
        var commands: [PaletteCommand] = []

        // Navigation — the sidebar destinations, including custom lists.
        commands.append(PaletteCommand(
            id: "nav.containers", title: "Go to All Containers",
            systemImage: Panel.containers.systemImage, section: .navigation
        ) { selection = .containers })
        for list in state.containerLists {
            commands.append(PaletteCommand(
                id: "nav.list.\(list.id)", title: "Go to \(list.name)",
                subtitle: "Container list", systemImage: "line.3.horizontal",
                section: .navigation, keywords: "list"
            ) { selection = .list(list.id) })
        }
        let panelDestinations: [(Panel, SidebarSelection)] = [
            (.images, .images), (.volumes, .volumes), (.networks, .networks),
            (.workflows, .workflows), (.settings, .settings),
        ]
        for (panel, destination) in panelDestinations {
            commands.append(PaletteCommand(
                id: "nav.\(panel.rawValue)", title: "Go to \(panel.title)",
                systemImage: panel.systemImage, section: .navigation
            ) { selection = destination })
        }

        // Colima lifecycle — only the transitions valid from the current state.
        switch state.colimaState {
        case .stopped:
            commands.append(PaletteCommand(
                id: "colima.start", title: "Start Colima",
                systemImage: "play.fill", section: .colima
            ) { state.startColima() })
        case .running:
            commands.append(PaletteCommand(
                id: "colima.stop", title: "Stop Colima",
                systemImage: "stop.fill", section: .colima
            ) { state.stopColima() })
            commands.append(PaletteCommand(
                id: "colima.restart", title: "Restart Colima",
                systemImage: "arrow.clockwise", section: .colima
            ) { state.restartColima() })
            commands.append(PaletteCommand(
                id: "colima.prune", title: "Clean Up…",
                subtitle: "docker system prune (data older than 24h)",
                systemImage: "sparkles", section: .colima, keywords: "prune clean",
                confirmation: Confirmations.prune
            ) { state.pruneSystem() })
        case .notInstalled:
            commands.append(PaletteCommand(
                id: "colima.install", title: "Install Colima…",
                systemImage: "arrow.down.circle", section: .colima
            ) { state.installColima() })
        case .starting, .stopping, .unknown:
            break
        }
        commands.append(PaletteCommand(
            id: "colima.refresh", title: "Refresh",
            systemImage: "arrow.triangle.2.circlepath", section: .colima
        ) { Task { await state.refresh() } })
        if state.colimaState != .notInstalled {
            commands.append(PaletteCommand(
                id: "colima.delete", title: "Delete Colima VM…",
                subtitle: "Deletes the VM and all its containers, images, and volumes",
                systemImage: "trash", section: .colima, keywords: "delete remove vm",
                confirmation: Confirmations.deleteVM(hasCustomProvisioning: state.hasCustomProvisioning)
            ) { state.deleteColima() })
        }

        // Workflows — Run, or Stop while one is in flight.
        for workflow in workflows.workflows where !workflow.name.isEmpty {
            let group = workflow.group.isEmpty ? nil : workflow.group
            if workflows.isRunning(workflow.id) {
                commands.append(PaletteCommand(
                    id: "workflow.stop.\(workflow.id)", title: "Stop Workflow \(workflow.name)",
                    subtitle: group, systemImage: "stop.circle",
                    section: .workflows, keywords: "workflow cancel"
                ) { workflows.cancel(workflow.id) })
            } else {
                commands.append(PaletteCommand(
                    id: "workflow.run.\(workflow.id)", title: "Run Workflow \(workflow.name)",
                    subtitle: group, systemImage: Panel.workflows.systemImage,
                    section: .workflows, keywords: "workflow"
                ) { workflows.run(workflow.id) })
            }
        }

        // Per-container actions — need a running VM to be executable.
        guard state.colimaState.isRunning else { return commands }
        for container in state.containers {
            let name = container.displayName
            let keywords = "container \(container.image)"
            if container.isRunning {
                commands.append(PaletteCommand(
                    id: "container.stop.\(container.id)", title: "Stop \(name)",
                    subtitle: container.image, systemImage: "stop.circle",
                    section: .containers, keywords: keywords
                ) { state.stopContainer(container) })
                commands.append(PaletteCommand(
                    id: "container.restart.\(container.id)", title: "Restart \(name)",
                    subtitle: container.image, systemImage: "arrow.clockwise.circle",
                    section: .containers, keywords: keywords
                ) { state.restartContainer(container) })
                commands.append(PaletteCommand(
                    id: "container.shell.\(container.id)", title: "Open Shell in \(name)",
                    subtitle: container.image, systemImage: "terminal",
                    section: .containers, keywords: keywords
                ) { state.openShell(container) })
            } else {
                commands.append(PaletteCommand(
                    id: "container.start.\(container.id)", title: "Start \(name)",
                    subtitle: container.image, systemImage: "play.circle",
                    section: .containers, keywords: keywords
                ) { state.startContainer(container) })
            }
            commands.append(PaletteCommand(
                id: "container.logs.\(container.id)", title: "Show Logs for \(name)",
                subtitle: container.image, systemImage: "text.alignleft",
                section: .containers, keywords: keywords
            ) { openWindow(value: container) })
            commands.append(PaletteCommand(
                id: "container.remove.\(container.id)", title: "Remove \(name)…",
                subtitle: container.image, systemImage: "trash",
                section: .containers, keywords: keywords + " delete rm",
                confirmation: Confirmations.removeContainer(container)
            ) { state.removeContainer(container) })
        }
        return commands
    }
}
