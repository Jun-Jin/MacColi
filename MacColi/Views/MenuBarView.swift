import SwiftUI

/// Contents of the menu bar dropdown.
struct MenuBarView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Text(statusLine)

            Divider()

            switch state.colimaState {
            case .notInstalled:
                Button("Install Colima…") { TerminalLauncher.run("brew install colima docker") }
            case .running:
                Button("Stop Colima") { state.stopColima() }
                Button("Restart Colima") { state.restartColima() }
            case .starting, .stopping:
                Text(state.colimaState.label)
            default:
                Button("Start Colima") { state.startColima() }
            }

            Divider()

            Button("Open Dashboard…") {
                openWindow(id: WindowID.dashboard)
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("d")

            Button("Refresh") { Task { await state.refresh() } }
                .keyboardShortcut("r")

            Divider()

            Button("Quit MacColi") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .task { await state.refresh() }
    }

    private var statusLine: String {
        switch state.colimaState {
        case .running:
            let count = state.containers.filter(\.isRunning).count
            return "Colima: Running · \(count) container\(count == 1 ? "" : "s")"
        default:
            return "Colima: \(state.colimaState.label)"
        }
    }
}
