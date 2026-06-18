import SwiftUI
import AppKit

@main
struct MacColiApp: App {
    // The app owns the single AppState instance; `@State` preserves it across
    // redraws and is the correct owner for an `@Observable` model.
    @State private var state = AppState()

    // Brings a bare `swift run` build to the front (see AppDelegate). No-op for
    // the shipped .app, which LaunchServices already activates.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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

        // Per-container log windows. A real window (not a sheet) is resizable and
        // remembers its size; opened with openWindow(value:) from the list.
        WindowGroup("Container Logs", for: Container.self) { $container in
            if let container {
                LogsView(container: container)
                    .environment(state)
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

// A bare `swift run` binary has no .app bundle, so LaunchServices launches it
// behind the terminal and never activates it — the dashboard opens but stays in
// the background. Nudge it to the front on launch. The shipped .app has a bundle
// identifier (and is activated by LaunchServices), so this is gated to the
// unbundled dev build only and is a no-op in release.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard Bundle.main.bundleIdentifier == nil else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }
}
