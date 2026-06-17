import SwiftUI

/// Live VM CPU/memory monitor docked at the bottom of the sidebar, above the
/// Colima controls. The toggle lives here (not in a panel toolbar) so monitoring
/// is reachable from every panel; the meters appear only while it's on. Usage is
/// summed across running containers and shown against the VM's allocated budget.
struct VMMonitorSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Monitor")
                    .font(.headline)
                Spacer()
                Button {
                    state.monitoringEnabled.toggle()
                } label: {
                    Image(systemName: state.monitoringEnabled
                          ? "gauge.with.dots.needle.bottom.50percent"
                          : "gauge.with.dots.needle.bottom.0percent")
                }
                .buttonStyle(.borderless)
                .help(state.monitoringEnabled
                      ? "Live monitoring on — turn off to stop sampling"
                      : "Live monitoring off — turn on to sample CPU & memory")
            }

            if state.monitoringEnabled {
                if let usage = state.vmUsage {
                    meter(title: "CPU", fraction: usage.cpuFraction,
                          caption: String(format: "%.1f / %d cores", usage.cpuCoresUsed, usage.cpuCoresTotal),
                          history: state.vmCPUHistory, color: .blue)
                    meter(title: "Memory", fraction: usage.memFraction,
                          caption: "\(Format.bytes(usage.memUsedBytes)) / \(Format.bytes(usage.memTotalBytes))",
                          history: state.vmMemHistory, color: .green)
                } else {
                    // The first docker stats sample takes a beat to arrive.
                    Text("Sampling…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func meter(title: String, fraction: Double, caption: String,
                       history: [Double], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.caption.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(fraction >= 0.85 ? .orange : .primary)
            }
            ProgressView(value: min(max(fraction, 0), 1)).tint(color)
            HStack(spacing: 8) {
                Text(caption).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                // Shared 0-100 % ceiling so CPU and memory trends read on one scale.
                Sparkline(values: history, color: color, ceiling: 100)
                    .frame(width: 60, height: 14)
            }
        }
    }
}
