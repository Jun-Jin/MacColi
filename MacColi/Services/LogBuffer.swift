import Foundation

/// Thread-safe ring of the most recent log lines, capped to bound memory while
/// a chatty process streams. Written from background stream callbacks, drained
/// on the main actor for display — so render rate is decoupled from log rate.
/// Used by the container log follow view and by workflow step output.
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
