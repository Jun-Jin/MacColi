import Foundation

/// One buffered log line with a stable identity. `id` is the line's absolute
/// position since the buffer was created (monotonic across ring trims), so a
/// SwiftUI `ForEach` can diff appends instead of rebuilding every row.
struct LogLine: Identifiable, Equatable, Sendable {
    let id: Int
    let text: String
}

/// Thread-safe ring of the most recent log lines, capped to bound memory while
/// a chatty process streams. Written from background stream callbacks, drained
/// on the main actor for display — so render rate is decoupled from log rate.
/// Used by the container log follow view (incrementally, via `drainNew`) and by
/// workflow step output (whole-text, via `drainIfChanged`/`tail`).
final class LogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var dirty = false
    private let maxLines: Int
    // Trim in batches (not every overflowing line) to avoid O(n) shifting per
    // append once full; the buffer drifts up to this slack above maxLines.
    private let slack = 512
    // Absolute id of lines[0]; advances when the ring trims so line ids stay
    // stable. The incremental consumer's cursor is the next unseen absolute id.
    private var firstID = 0
    private var cursor = 0

    init(maxLines: Int = 5_000) { self.maxLines = maxLines }

    func append(_ line: String) {
        lock.withLock {
            lines.append(line)
            if lines.count > maxLines + slack {
                let overflow = lines.count - maxLines
                lines.removeFirst(overflow)
                firstID += overflow
            }
            dirty = true
        }
    }

    func clear() {
        lock.withLock {
            firstID += lines.count
            lines.removeAll()
            cursor = firstID
            dirty = true
        }
    }

    /// Lines appended since the last `drainNew` call, or nil when there are
    /// none — so an idle stream costs nothing per poll. `dropped` is true when
    /// the ring trimmed lines the consumer never saw (it fell behind by more
    /// than the buffer capacity); the batch is then the entire buffer and the
    /// display should replace its contents rather than append across the gap.
    /// Single-consumer: the cursor is shared, independent of `drainIfChanged`.
    func drainNew() -> (lines: [LogLine], dropped: Bool)? {
        lock.withLock {
            let end = firstID + lines.count
            let start = Swift.max(cursor, firstID)
            guard start < end else { return nil }
            let dropped = cursor < firstID
            let batch = zip(start..<end, lines[(start - firstID)...])
                .map { LogLine(id: $0, text: $1) }
            cursor = end
            return (batch, dropped)
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

    /// The last `maxLines` lines as joined text, or nil when nothing was
    /// captured. Unlike `drainIfChanged`, this is exact: the ring itself drifts
    /// up to `slack` above `maxLines` between trims, and callers surfacing a
    /// bounded tail (a failing discard-output step) shouldn't expose the drift.
    func tail() -> String? {
        lock.withLock {
            guard !lines.isEmpty else { return nil }
            return lines.suffix(maxLines).joined(separator: "\n")
        }
    }
}
