import SwiftUI

/// Sheet showing a container's logs — a static tail by default, or a live
/// `docker logs --follow` stream when Follow is on.
struct LogsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let container: Container

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
                Button { Task { await loadSnapshot() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload")
                    .disabled(follow)
                Button("Done") { dismiss() }
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
        .frame(width: 680, height: 460)
        // Toggling Follow (or dismissing) cancels this task, which terminates the
        // stream process and stops the flush loop.
        .task(id: follow) { follow ? await startFollowing() : await loadSnapshot() }
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

/// Thread-safe ring of the most recent log lines, capped to bound memory while
/// following a chatty container. Written from the background stream callback,
/// drained on the main actor for display.
final class LogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var dirty = false
    private let maxLines: Int
    // Trim in batches (not every overflowing line) to avoid O(n) shifting per
    // append once full; the buffer drifts up to this slack above maxLines.
    private let slack = 512

    init(maxLines: Int = 5_000) { self.maxLines = maxLines }

    func append(_ line: String) {
        lock.withLock {
            lines.append(line)
            if lines.count > maxLines + slack { lines.removeFirst(lines.count - maxLines) }
            dirty = true
        }
    }

    func clear() {
        lock.withLock {
            lines.removeAll()
            dirty = true
        }
    }

    /// Joined text if it changed since the last drain, else nil (skips redundant rebuilds).
    func drainIfChanged() -> String? {
        lock.withLock {
            guard dirty else { return nil }
            dirty = false
            return lines.joined(separator: "\n")
        }
    }
}
