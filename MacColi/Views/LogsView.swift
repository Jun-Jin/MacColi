import SwiftUI

/// Sheet showing a container's logs — a static tail by default, or a live
/// `docker logs --follow` stream when Follow is on.
struct LogsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let container: Container

    // Persisted sheet size: the flexible frame opens at the last size and the
    // user can resize from there (see the size-tracking background below).
    @AppStorage("logWindow.width") private var width = 680.0
    @AppStorage("logWindow.height") private var height = 460.0

    @State private var text = ""
    @State private var isLoading = true
    @State private var follow = false
    // Lines stream in on a background thread; the buffer caps memory and a timer
    // drains it into `text`, so render rate is decoupled from log rate.
    @State private var buffer = LogBuffer()
    // Scroll to the bottom once after the first content loads (newest line first).
    @State private var pendingInitialScroll = true

    private let bottomID = "logs.bottom"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Logs · \(container.displayName)").font(.headline)
                Spacer()
                Toggle("Follow", isOn: $follow)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("Stream new log lines live")
                Button { clear() } label: { Image(systemName: "trash") }
                    .help("Clear the view (docker's stored logs are kept — Reload restores them)")
                    .disabled(isLoading || text.isEmpty)
                Button { Task { await loadSnapshot() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload")
                    .disabled(follow)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)   // Esc closes the log window
            }
            .padding(12)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    if isLoading {
                        ProgressView().padding(40)
                    } else {
                        Text(text.isEmpty ? "No log output." : text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    // Anchor used to pin the view to the newest line.
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: text) {
                    // Stay pinned while following; otherwise only on the first load.
                    guard follow || pendingInitialScroll else { return }
                    pendingInitialScroll = false
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
        }
        // A min…∞ range (with the stored ideal) makes the sheet user-resizable;
        // the background tracks the rendered size and persists it for next open.
        .frame(minWidth: 480, idealWidth: width, maxWidth: .infinity,
               minHeight: 300, idealHeight: height, maxHeight: .infinity)
        .background(
            GeometryReader { geo in
                Color.clear.onChange(of: geo.size) { _, size in
                    width = size.width
                    height = size.height
                }
            }
        )
        // Toggling Follow (or dismissing) cancels this task, which terminates the
        // stream process and stops the flush loop.
        .task(id: follow) { follow ? await startFollowing() : await loadSnapshot() }
    }

    /// Empties the visible log. Clears the stream buffer too, so while following
    /// the next flush rebuilds from new lines only instead of repainting the
    /// cleared history. View-only: docker's stored logs are untouched.
    private func clear() {
        buffer.clear()
        text = ""
        pendingInitialScroll = false
    }

    /// One-shot snapshot of the current tail (the default, frozen view).
    private func loadSnapshot() async {
        isLoading = true
        text = await state.logs(for: container)
        isLoading = false
        pendingInitialScroll = true
    }

    /// Live stream: ingest lines into the buffer off-thread, render on a ~10 Hz
    /// timer, and note when the stream ends on its own (container stopped).
    private func startFollowing() async {
        isLoading = true
        buffer.clear()
        text = ""

        let buf = buffer
        let flush = Task { @MainActor in
            while !Task.isCancelled {
                if let joined = buf.drainIfChanged() {
                    isLoading = false
                    text = joined
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        defer { flush.cancel() }

        await state.followLogs(for: container) { line in buf.append(line) }

        // Stream finished without being cancelled → the container's logs ended.
        guard !Task.isCancelled else { return }
        if let joined = buf.drainIfChanged() { text = joined }
        isLoading = false
        text += (text.isEmpty ? "" : "\n") + "— stream ended —"
        follow = false
    }
}
