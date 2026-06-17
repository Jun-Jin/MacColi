import SwiftUI

@main
struct MacColiApp: App {
    // The app owns the single AppState instance; `@State` preserves it across
    // redraws and is the correct owner for an `@Observable` model.
    @State private var state = AppState()

    var body: some Scene {
        // Full dashboard window.
        Window("MacColi", id: WindowID.dashboard) {
            DashboardView()
                .environment(state)
                .frame(minWidth: 820, minHeight: 520)
                .task { state.startPolling() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Refresh") { Task { await state.refresh() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
            // Standard ⌘F "Find" in the Edit menu. The active resource panel
            // focuses its filter field in response (see findRequestToken).
            CommandGroup(after: .textEditing) {
                Button("Find") { state.findRequestToken += 1 }
                    .keyboardShortcut("f", modifiers: .command)
            }
        }

        // Menu bar status item.
        MenuBarExtra {
            MenuBarView()
                .environment(state)
        } label: {
            Image(systemName: state.colimaState.isRunning ? "shippingbox.fill" : "shippingbox")
        }
        .menuBarExtraStyle(.menu)
    }
}

enum WindowID {
    static let dashboard = "dashboard"
}
