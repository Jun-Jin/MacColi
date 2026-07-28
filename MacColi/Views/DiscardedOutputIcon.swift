import SwiftUI

/// Shared marker for "this workflow discards step output" — shown on the
/// workflow tile and beside run-sheet step rows, so the quiet setting is
/// visible without opening the editor.
struct DiscardedOutputIcon: View {
    var body: some View {
        Image(systemName: "eye.slash")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("Output is discarded for this workflow.")
    }
}
