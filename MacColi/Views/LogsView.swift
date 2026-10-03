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

    // Both modes render through the same AppKit-backed pane (LogTextView):
    // a snapshot replaces the rows once, follow appends drained batches. The
    // ids stay absolute so the pane can diff appends against its text storage
    // instead of re-laying-out the whole log — full cross-line selection
    // included, which pure-SwiftUI rendering couldn't offer at this size.
    @State private var lines: [LogLine] = []
    @State private var isLoading = true
    @State private var follow = false
    // Lines stream in on a background thread; the buffer caps memory and a
    // timer drains only the new lines, so render rate is decoupled from log
    // rate and each flush costs the batch size, not the backlog.
    @State private var buffer = LogBuffer()
    // Mirrors controlActiveState for the flush loop: the window's environment
    // value can't be read live from the captured task closure, this can. While
    // the window is inactive the loop stops draining — the buffer keeps
    // absorbing (bounded), and reactivation catches the display up in one batch.
    @State private var renderActive = true
    @Environment(\.controlActiveState) private var activeState

    // Rows kept in the live view; matches the buffer cap so a long follow
    // can't grow the row set without bound.
    private static let maxDisplayLines = 5_000

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
                    .disabled(isLoading || lines.isEmpty)
                Button { Task { await loadSnapshot() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload")
                    .disabled(follow)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)   // Esc closes the log window
            }
            .padding(12)
            Divider()

            ZStack {
                LogTextView(lines: lines)
                if isLoading {
                    ProgressView()
                } else if lines.isEmpty {
                    Text("No log output.")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
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
        .onChange(of: activeState) { renderActive = activeState != .inactive }
    }

    /// Empties the visible log. Clears the stream buffer too, so while following
    /// the next flush resumes from new lines only instead of restoring the
    /// cleared history. View-only: docker's stored logs are untouched.
    private func clear() {
        buffer.clear()
        lines = []
    }

    /// One-shot snapshot of the current tail (the default, frozen view).
    private func loadSnapshot() async {
        isLoading = true
        let raw = await state.logs(for: container)
        // Fresh 0-based ids deliberately don't adjoin whatever was shown
        // before, which tells the pane to rebuild and pin to the newest line.
        let trimmed = raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
        lines = trimmed.isEmpty ? [] : trimmed
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { LogLine(id: $0.offset, text: String($0.element)) }
        isLoading = false
    }

    /// Live stream: ingest lines into the buffer off-thread, append only the
    /// new lines to the rows on a 2 Hz timer (paused while the window is
    /// inactive), and note when the stream ends on its own (container stopped).
    private func startFollowing() async {
        isLoading = true
        buffer.clear()
        lines = []

        let buf = buffer
        let flush = Task { @MainActor in
            while !Task.isCancelled {
                if renderActive, let batch = buf.drainNew() {
                    isLoading = false
                    appendBatch(batch)
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { flush.cancel() }

        await state.followLogs(for: container) { line in buf.append(line) }

        // Stream finished without being cancelled → the container's logs ended.
        guard !Task.isCancelled else { return }
        if let batch = buf.drainNew() { appendBatch(batch) }
        isLoading = false
        lines.append(LogLine(id: (lines.last?.id ?? -1) + 1, text: "— stream ended —"))
        follow = false
    }

    /// Folds a drained batch into the visible rows. A `dropped` batch means the
    /// ring outran the display (window inactive long enough, or a very chatty
    /// stream): what's on screen no longer adjoins the buffer, so replace it
    /// wholesale instead of appending across the gap.
    private func appendBatch(_ batch: (lines: [LogLine], dropped: Bool)) {
        if batch.dropped {
            lines = batch.lines
        } else {
            lines.append(contentsOf: batch.lines)
            if lines.count > Self.maxDisplayLines {
                lines.removeFirst(lines.count - Self.maxDisplayLines)
            }
        }
    }
}
