import SwiftUI

/// A minimal line chart of recent samples with a soft fill beneath it.
///
/// Values are plotted left-to-right (oldest → newest). By default the line
/// auto-scales to its own maximum so small movements stay visible; pass a fixed
/// `ceiling` (e.g. 100 for a percentage) when several sparklines must share one
/// scale to be comparable.
struct Sparkline: View {
    let values: [Double]
    var color: Color = .accentColor
    var ceiling: Double?

    var body: some View {
        GeometryReader { geo in
            // A single sample draws a flat line spanning the width, so the
            // sparkline appears with the first data point rather than blank until
            // a second arrives.
            let pts = points(in: geo.size)
            let drawn = pts.count == 1 ? [pts[0], CGPoint(x: geo.size.width, y: pts[0].y)] : pts
            if drawn.count >= 2 {
                ZStack {
                    path(drawn, in: geo.size, closed: true).fill(color.opacity(0.15))
                    path(drawn, in: geo.size, closed: false)
                        .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard !values.isEmpty else { return [] }
        let maxV = max(ceiling ?? values.max() ?? 1, 0.0001)
        let n = values.count
        return values.enumerated().map { i, v in
            let x = n > 1 ? size.width * CGFloat(i) / CGFloat(n - 1) : 0
            let y = size.height * (1 - CGFloat(min(max(v, 0) / maxV, 1)))
            return CGPoint(x: x, y: y)
        }
    }

    private func path(_ pts: [CGPoint], in size: CGSize, closed: Bool) -> Path {
        var p = Path()
        guard let first = pts.first, let last = pts.last else { return p }
        if closed {
            p.move(to: CGPoint(x: first.x, y: size.height))
            p.addLine(to: first)
            pts.dropFirst().forEach { p.addLine(to: $0) }
            p.addLine(to: CGPoint(x: last.x, y: size.height))
            p.closeSubpath()
        } else {
            p.move(to: first)
            pts.dropFirst().forEach { p.addLine(to: $0) }
        }
        return p
    }
}
