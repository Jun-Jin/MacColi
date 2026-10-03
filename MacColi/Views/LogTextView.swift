import SwiftUI
import AppKit

/// AppKit-backed log pane: an `NSTextView` fed by incremental appends.
///
/// SwiftUI's `Text` re-lays-out the entire string on every change, and a lazy
/// per-line `ForEach` can't select across rows. An NSTextView gives both
/// properties at once: TextKit lays out only the viewport, an append costs the
/// batch (not the backlog), and the whole document stays selectable and
/// copyable while streaming.
///
/// `lines` carry absolute, monotonically increasing ids (see `LogLine`), which
/// is what makes the diff cheap: the coordinator compares the incoming id
/// window against the one in the text storage and only trims the front /
/// appends the tail. Ids that don't adjoin (snapshot reload, a dropped batch)
/// rebuild the document wholesale.
struct LogTextView: NSViewRepresentable {
    let lines: [LogLine]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isRichText = false
        textView.usesFindBar = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.sync(lines, in: scrollView)
    }

    @MainActor
    final class Coordinator {
        // Absolute-id window currently in the text storage. `lineLengths`
        // holds each line's UTF-16 length (incl. the trailing newline) so a
        // front trim knows exactly how many characters to delete.
        private var firstID = 0
        private var nextID = 0
        private var lineLengths: [Int] = []

        private static let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]

        func sync(_ lines: [LogLine], in scrollView: NSScrollView) {
            guard let textView = scrollView.documentView as? NSTextView,
                  let storage = textView.textStorage else { return }

            guard let first = lines.first, let last = lines.last else {
                if !lineLengths.isEmpty {
                    storage.setAttributedString(NSAttributedString())
                    lineLengths = []
                }
                // Keep the window's position so later, higher ids still adjoin.
                firstID = nextID
                return
            }

            // Ids that don't overlap or adjoin the stored window (snapshot
            // reload, a dropped batch): rebuild wholesale and pin to the end.
            guard first.id >= firstID, first.id <= nextID, last.id >= nextID - 1 else {
                storage.setAttributedString(Self.render(lines))
                lineLengths = lines.map { ($0.text as NSString).length + 1 }
                firstID = first.id
                nextID = last.id + 1
                textView.scrollToEndOfDocument(nil)
                return
            }

            let wasPinned = isPinnedToBottom(scrollView)
            storage.beginEditing()
            if first.id > firstID {
                let drop = first.id - firstID
                let chars = lineLengths.prefix(drop).reduce(0, +)
                storage.replaceCharacters(in: NSRange(location: 0, length: chars), with: "")
                lineLengths.removeFirst(drop)
                firstID = first.id
            }
            if last.id >= nextID {
                let fresh = lines.suffix(last.id - nextID + 1)
                storage.append(Self.render(Array(fresh)))
                lineLengths.append(contentsOf: fresh.map { ($0.text as NSString).length + 1 })
                nextID = last.id + 1
            }
            storage.endEditing()
            // Follow the tail only while the user is already there — scrolling
            // up to read pauses auto-scroll until they return to the bottom.
            if wasPinned { textView.scrollToEndOfDocument(nil) }
        }

        private static func render(_ lines: [LogLine]) -> NSAttributedString {
            NSAttributedString(string: lines.map { $0.text + "\n" }.joined(),
                               attributes: attributes)
        }

        /// Whether the view is scrolled to (near) the newest line. The slack
        /// absorbs sub-line offsets so tailing doesn't disengage on its own.
        private func isPinnedToBottom(_ scrollView: NSScrollView) -> Bool {
            let docHeight = scrollView.documentView?.frame.height ?? 0
            return scrollView.contentView.bounds.maxY >= docHeight - 30
        }
    }
}
